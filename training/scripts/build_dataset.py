r"""Gộp nhiều dataset định dạng YOLO (Roboflow, COCO subset, dữ liệu nhóm tự gán nhãn...) thành
1 dataset duy nhất theo danh sách lớp training/classes.yaml.

- Tên lớp của từng dataset nguồn được đổi về tên chuẩn qua `aliases` (VD "Electric Pole" → pole).
- Lớp không có trong classes.yaml bị bỏ (có báo cáo), ảnh không còn nhãn nào giữ lại một phần làm
  ảnh "nền" (giúp model bớt báo nhầm).
- Giữ nguyên chia train/val của nguồn nếu có; không có thì chia ngẫu nhiên cố định theo tên file.
- Nhãn dạng polygon (segmentation) tự đổi thành box.

Cách dùng:
    python training/scripts/build_dataset.py \
        --source datasets/coco_subset \
        --source datasets/roboflow_pothole \
        --source tool/coco128@coco80 \            # nguồn không có data.yaml: chỉ định tên lớp
        --out datasets/smart_eye

    Nguồn dạng `DIR@names.yaml` dùng file tên lớp riêng; `DIR@coco80` dùng 80 lớp COCO.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import random
import shutil
from collections import Counter, defaultdict
from pathlib import Path

import yaml

from common import COCO80, IMAGE_EXTS, alias_map, label_path_for, load_classes, norm, read_names

VAL_DIRS = {'val', 'valid', 'validation', 'test', 'val2017'}
TRAIN_DIRS = {'train', 'train2017'}


def find_names(src: Path, override: str | None) -> list[str]:
    if override == 'coco80':
        return COCO80
    if override:
        return read_names(Path(override))
    for cand in ['data.yaml', 'dataset.yaml', 'data.yml']:
        if (src / cand).exists():
            return read_names(src / cand)
    for y in src.glob('*.y*ml'):
        with open(y, encoding='utf-8') as f:
            if 'names' in (yaml.safe_load(f) or {}):
                return read_names(y)
    raise SystemExit(f'Không tìm thấy data.yaml có "names" trong {src} — dùng cú pháp {src}@names.yaml')


def parse_label_line(line: str) -> tuple[int, float, float, float, float] | None:
    vals = line.split()
    if len(vals) < 5:
        return None
    cls = int(float(vals[0]))
    nums = [float(v) for v in vals[1:]]
    if len(nums) == 4:
        cx, cy, w, h = nums
    else:  # polygon x1 y1 x2 y2 ... → box bao ngoài
        xs, ys = nums[0::2], nums[1::2]
        x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
        cx, cy, w, h = (x0 + x1) / 2, (y0 + y1) / 2, x1 - x0, y1 - y0
    if w <= 0 or h <= 0:
        return None
    return cls, cx, cy, w, h


def split_of(image: Path, src: Path, val_ratio: float) -> str:
    rel_parts = {p.lower() for p in image.relative_to(src).parts[:-1]}
    if rel_parts & VAL_DIRS:
        return 'val'
    if rel_parts & TRAIN_DIRS:
        return 'train'
    h = int(hashlib.md5(str(image.relative_to(src)).encode()).hexdigest()[:8], 16) / 0xFFFFFFFF
    return 'val' if h < val_ratio else 'train'


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--source', action='append', required=True, help='Thư mục dataset YOLO (có thể lặp lại)')
    ap.add_argument('--out', required=True)
    ap.add_argument('--classes', default=None, help='Đường dẫn classes.yaml (mặc định training/classes.yaml)')
    ap.add_argument('--val-ratio', type=float, default=0.15)
    ap.add_argument('--negatives', type=float, default=0.1, help='Tỉ lệ ảnh không có nhãn giữ lại (so với ảnh có nhãn)')
    ap.add_argument('--min-instances', type=int, default=300, help='Cảnh báo lớp có ít hơn số vật này trong train')
    ap.add_argument('--seed', type=int, default=0)
    args = ap.parse_args()

    classes = load_classes(Path(args.classes)) if args.classes else load_classes()
    amap = alias_map(classes)
    out = Path(args.out)
    if out.exists():
        shutil.rmtree(out)
    for split in ('train', 'val'):
        (out / 'images' / split).mkdir(parents=True)
        (out / 'labels' / split).mkdir(parents=True)

    rng = random.Random(args.seed)
    instances = {s: Counter() for s in ('train', 'val')}
    images = Counter()
    unmapped: dict[str, Counter] = defaultdict(Counter)
    negatives: dict[str, list[tuple[Path, str]]] = {'train': [], 'val': []}

    for si, spec in enumerate(args.source):
        path, _, override = spec.partition('@')
        src = Path(path)
        names = find_names(src, override or None)
        to_dst = {i: amap.get(norm(n)) for i, n in enumerate(names)}
        tag = f's{si}_' + ''.join(ch if ch.isalnum() else '_' for ch in src.name)[:20]
        print(f'[{tag}] {src} — {len(names)} lớp, đổi được {sum(v is not None for v in to_dst.values())}')

        for img in sorted(p for p in src.rglob('*') if p.suffix.lower() in IMAGE_EXTS):
            split = split_of(img, src, args.val_ratio)
            lines = []
            lbl = label_path_for(img)
            if lbl.exists():
                for raw in lbl.read_text(encoding='utf-8').splitlines():
                    parsed = parse_label_line(raw)
                    if parsed is None:
                        continue
                    cls, cx, cy, w, h = parsed
                    dst = to_dst.get(cls)
                    if dst is None:
                        unmapped[tag][names[cls] if cls < len(names) else str(cls)] += 1
                        continue
                    lines.append(f'{dst} {cx:.6f} {cy:.6f} {w:.6f} {h:.6f}')
                    instances[split][dst] += 1
            name = f'{tag}_{img.stem}'
            if not lines:
                negatives[split].append((img, name))
                continue
            shutil.copy2(img, out / 'images' / split / f'{name}{img.suffix.lower()}')
            (out / 'labels' / split / f'{name}.txt').write_text('\n'.join(lines) + '\n', encoding='utf-8')
            images[split] += 1

    # Ảnh nền (không có vật cần tìm) — giữ 1 phần để model học "không có gì ở đây"
    for split, items in negatives.items():
        keep = min(len(items), int(images[split] * args.negatives))
        for img, name in rng.sample(items, keep):
            shutil.copy2(img, out / 'images' / split / f'{name}{img.suffix.lower()}')
            (out / 'labels' / split / f'{name}.txt').write_text('', encoding='utf-8')
        images[f'{split}_background'] = keep

    data = {
        'path': str(out.resolve()),
        'train': 'images/train',
        'val': 'images/val',
        'names': {i: c['name'] for i, c in enumerate(classes)},
    }
    with open(out / 'data.yaml', 'w', encoding='utf-8') as f:
        yaml.safe_dump(data, f, allow_unicode=True, sort_keys=False)

    # Báo cáo
    report = {
        'images': dict(images),
        'instances': {c['name']: {s: instances[s][i] for s in ('train', 'val')} for i, c in enumerate(classes)},
        'unmapped_classes': {k: dict(v) for k, v in unmapped.items()},
    }
    (out / 'stats.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')

    print(f'\nẢnh: train {images["train"]} (+{images["train_background"]} nền), '
          f'val {images["val"]} (+{images["val_background"]} nền)')
    print(f'{"lớp":<16}{"train":>8}{"val":>8}  ')
    for i, c in enumerate(classes):
        tr, va = instances['train'][i], instances['val'][i]
        warn = '  ⚠ thiếu dữ liệu' if tr < args.min_instances else ''
        print(f'{c["name"]:<16}{tr:>8}{va:>8}{warn}')
    for tag, cnt in unmapped.items():
        print(f'[{tag}] bỏ các lớp không có trong classes.yaml: {dict(cnt.most_common(10))}')
    print(f'\n→ {out / "data.yaml"}')


if __name__ == '__main__':
    main()
