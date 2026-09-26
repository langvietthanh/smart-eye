r"""Gộp nhiều dataset định dạng YOLO (Roboflow, COCO subset, dữ liệu nhóm tự gán nhãn...) thành
1 dataset duy nhất theo danh sách lớp training/classes.yaml.

- Tên lớp của từng dataset nguồn được đổi về tên chuẩn qua `aliases` (VD "Electric Pole" → pole).
- Lớp không có trong classes.yaml bị bỏ (có báo cáo), ảnh không còn nhãn nào giữ lại một phần làm
  ảnh "nền" (giúp model bớt báo nhầm).
- Nhãn chung chung trong `generic_labels` (VD "stairs" không rõ lên / xuống): box trùng box lớp cụ thể thì bỏ box,
  không trùng thì bỏ cả ảnh.
- Ảnh có nhãn lạ (không đổi được) không bao giờ làm ảnh nền — chưa chắc ảnh đó không có gì.
- Giữ nguyên chia train/val của nguồn nếu có; không có thì chia ngẫu nhiên cố định theo tên file.
- Nhãn dạng polygon (segmentation) tự đổi thành box.

Cách dùng:
    python training/scripts/build_dataset.py \
        --source datasets/coco_subset \
        --source datasets/roboflow_pothole \
        --source tool/coco128@coco80 \            # nguồn không có data.yaml: chỉ định tên lớp
        --out datasets/smart_eye

    Nguồn dạng `DIR@names.yaml` dùng file tên lớp riêng; `DIR@coco80` dùng 80 lớp COCO.
    Thêm `#train` / `#val` ở cuối để ép cả nguồn vào 1 tập, VD `datasets/bpid#val`.
    Tên lớp tự đọc từ data.yaml / dataset.yaml, hoặc classes.txt / notes.json (Label Studio export YOLO).
    Nhãn PASCAL VOC (file .xml cạnh ảnh hoặc trong thư mục annotations/, VD dataset Kaggle "Pothole Detection")
    được tự đổi sang YOLO — tên lớp lấy từ thẻ <name> trong XML.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import random
import shutil
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from pathlib import Path

import yaml

from common import COCO80, IMAGE_EXTS, alias_map, label_path_for, load_classes, norm, read_names, generic_labels

VAL_DIRS = {'val', 'valid', 'validation', 'test', 'val2017'}
TRAIN_DIRS = {'train', 'train2017'}


def find_names(src: Path, override: str | None) -> list[str] | None:
    """Danh sách tên lớp của nguồn YOLO; None nếu nguồn là PASCAL VOC (tên lớp nằm trong từng XML)"""
    if override == 'coco80':
        return COCO80
    if override:
        return read_names(Path(override))
    for cand in ['data.yaml', 'dataset.yaml', 'data.yml']:
        if (src / cand).exists():
            return read_names(src / cand)
    # Label Studio (export YOLO): classes.txt mỗi dòng 1 tên, hoặc notes.json {"categories": [{id, name}]}
    for classes_txt in [src / 'classes.txt', *src.glob('*/classes.txt')]:
        if classes_txt.exists():
            names = [l.strip() for l in classes_txt.read_text(encoding='utf-8').splitlines() if l.strip()]
            if names:
                return names
    for notes in [src / 'notes.json', *src.glob('*/notes.json')]:
        if notes.exists():
            cats = json.loads(notes.read_text(encoding='utf-8')).get('categories', [])
            if cats:
                return [c['name'] for c in sorted(cats, key=lambda c: c['id'])]
    for y in src.glob('*.y*ml'):
        with open(y, encoding='utf-8') as f:
            if 'names' in (yaml.safe_load(f) or {}):
                return read_names(y)
    if next(src.rglob('*.xml'), None) is not None:
        return None  # PASCAL VOC
    raise SystemExit(f'Không tìm thấy tên lớp (data.yaml / classes.txt / notes.json / XML VOC) trong {src} — '
                     f'dùng cú pháp {src}@names.yaml')


def voc_boxes(xml_path: Path, image: Path) -> list[tuple[str, float, float, float, float]]:
    """PASCAL VOC → [(tên lớp, cx, cy, w, h)] chuẩn hoá [0..1]"""
    root = ET.parse(xml_path).getroot()
    size = root.find('size')
    w = float(size.findtext('width', '0')) if size is not None else 0
    h = float(size.findtext('height', '0')) if size is not None else 0
    if w <= 0 or h <= 0:  # XML thiếu kích thước → đọc từ ảnh
        from PIL import Image
        with Image.open(image) as im:
            w, h = im.size
    boxes = []
    for obj in root.iter('object'):
        bb = obj.find('bndbox')
        if bb is None:
            continue
        x0, y0 = float(bb.findtext('xmin')), float(bb.findtext('ymin'))
        x1, y1 = float(bb.findtext('xmax')), float(bb.findtext('ymax'))
        x0, x1 = max(0, min(x0, x1)), min(w, max(x0, x1))
        y0, y1 = max(0, min(y0, y1)), min(h, max(y0, y1))
        if x1 <= x0 or y1 <= y0:
            continue
        boxes.append((obj.findtext('name', '').strip(), (x0 + x1) / 2 / w, (y0 + y1) / 2 / h, (x1 - x0) / w, (y1 - y0) / h))
    return boxes


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


def overlap(a, b) -> float:
    """Diện tích giao / diện tích box nhỏ hơn (box dạng cx, cy, w, h) — 1.0 khi box này nằm trọn trong box kia"""
    w = min(a[0] + a[2] / 2, b[0] + b[2] / 2) - max(a[0] - a[2] / 2, b[0] - b[2] / 2)
    h = min(a[1] + a[3] / 2, b[1] + b[3] / 2) - max(a[1] - a[3] / 2, b[1] - b[3] / 2)
    return 0.0 if w <= 0 or h <= 0 else w * h / min(a[2] * a[3], b[2] * b[3])


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

    classes_yaml = Path(args.classes) if args.classes else None
    classes = load_classes(classes_yaml) if classes_yaml else load_classes()
    generic, covered_by = generic_labels(classes, classes_yaml) if classes_yaml else generic_labels(classes)
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
    skipped: Counter = Counter()
    merged: Counter = Counter()
    negatives: dict[str, list[tuple[Path, str]]] = {'train': [], 'val': []}

    for si, spec in enumerate(args.source):
        spec, _, forced_split = spec.partition('#')
        if forced_split not in ('', 'train', 'val'):
            raise SystemExit(f'Sau dấu # chỉ được train hoặc val: {spec}#{forced_split}')
        path, _, override = spec.partition('@')
        src = Path(path)
        names = find_names(src, override or None)
        tag = f's{si}_' + ''.join(ch if ch.isalnum() else '_' for ch in src.name)[:20]
        voc_index: dict[str, Path] = {}
        if names is None:
            voc_index = {p.stem: p for p in src.rglob('*.xml')}
            to_dst = {}
            print(f'[{tag}] {src} — PASCAL VOC, {len(voc_index)} file XML')
        else:
            to_dst = {i: amap.get(norm(n)) for i, n in enumerate(names)}
            print(f'[{tag}] {src} — {len(names)} lớp, đổi được {sum(v is not None for v in to_dst.values())}')

        for img in sorted(p for p in src.rglob('*') if p.suffix.lower() in IMAGE_EXTS):
            split = forced_split or split_of(img, src, args.val_ratio)
            lines = []
            lbl = label_path_for(img)
            if names is None:
                xml = voc_index.get(img.stem)
                boxes = [(amap.get(norm(n)), norm(n) in generic, n, b) for n, *b in (voc_boxes(xml, img) if xml else [])]
            elif lbl.exists():
                boxes = []
                for cls, *b in filter(None, map(parse_label_line, lbl.read_text(encoding='utf-8').splitlines())):
                    n = names[cls] if cls < len(names) else str(cls)
                    boxes.append((to_dst.get(cls), norm(n) in generic, n, b))
            else:
                boxes = []
            kept = [(dst, b) for dst, _, _, b in boxes if dst is not None]
            # Nhãn chung chung: trùng box lớp cụ thể (cùng 1 vật) → bỏ box; không trùng → bỏ cả ảnh
            loose = [b for dst, gen, _, b in boxes if dst is None and gen]
            if any(not any(d in covered_by and overlap(b, k) >= 0.6 for d, k in kept) for b in loose):
                skipped[tag] += 1
                continue
            if loose:
                merged[tag] += len(loose)
            for dst, gen, n, _ in boxes:
                if dst is None and not gen:
                    unmapped[tag][n] += 1
            for dst, (cx, cy, w, h) in kept:
                lines.append(f'{dst} {cx:.6f} {cy:.6f} {w:.6f} {h:.6f}')
                instances[split][dst] += 1
            name = f'{tag}_{img.stem}'
            if not lines:
                if not boxes:  # ảnh có nhãn lạ không phải ảnh nền thật
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
        'skipped_images': dict(skipped),
        'merged_generic_boxes': dict(merged),
    }
    (out / 'stats.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')

    print(f'\nẢnh: train {images["train"]} (+{images["train_background"]} nền), '
          f'val {images["val"]} (+{images["val_background"]} nền)')
    print(f'{"lớp":<16}{"train":>8}{"val":>8}  ')
    for i, c in enumerate(classes):
        tr, va = instances['train'][i], instances['val'][i]
        warn = '  ⚠ thiếu dữ liệu' if tr < args.min_instances else ''
        print(f'{c["name"]:<16}{tr:>8}{va:>8}{warn}')
    for tag in skipped.keys() | merged.keys():
        print(f'[{tag}] nhãn chung chung (VD "stairs"): bỏ {merged[tag]} box trùng box lên / xuống, '
              f'bỏ {skipped[tag]} ảnh có box không rõ hướng')
    for tag, cnt in unmapped.items():
        print(f'[{tag}] bỏ các lớp không có trong classes.yaml: {dict(cnt.most_common(10))}')
    print(f'\n→ {out / "data.yaml"}')


if __name__ == '__main__':
    main()
