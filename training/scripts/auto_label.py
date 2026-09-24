"""Gán nhãn TỰ ĐỘNG ảnh nhóm tự chụp bằng YOLO-World (model tìm vật theo tên, không cần train),
để người chỉ cần SỬA LẠI thay vì khoanh từ đầu (nhanh hơn ~3–5 lần).

    pip install ultralytics
    python training/scripts/auto_label.py --images photos/vinh_hoang_quoc_viet --out datasets/auto_hqv

Sau đó mở thư mục kết quả bằng CVAT / Label Studio / Roboflow (định dạng YOLO) để kiểm tra, sửa box sai,
xoá box thừa, thêm box thiếu. KHÔNG đưa nhãn tự động vào train khi chưa có người kiểm tra.

Kết quả: <out>/images, <out>/labels, <out>/data.yaml (names = toàn bộ lớp trong classes.yaml)
→ dùng trực tiếp làm 1 nguồn cho build_dataset.py.
"""
from __future__ import annotations

import argparse
import shutil
from collections import Counter
from pathlib import Path

import yaml

from common import IMAGE_EXTS, load_classes


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--images', required=True, help='Thư mục ảnh cần gán nhãn')
    ap.add_argument('--out', required=True)
    ap.add_argument('--model', default='yolov8s-worldv2.pt', help='Model YOLO-World (tự tải lần đầu)')
    ap.add_argument('--conf', type=float, default=0.2, help='Ngưỡng — thấp để bắt được nhiều, người sẽ lọc lại')
    ap.add_argument('--all-classes', action='store_true', help='Gán cả lớp COCO (mặc định chỉ các lớp mới)')
    args = ap.parse_args()

    from ultralytics import YOLOWorld  # import muộn để --help chạy được khi chưa cài

    classes = load_classes()
    targets = [(i, c) for i, c in enumerate(classes) if args.all_classes or c['source'] == 'new']
    model = YOLOWorld(args.model)
    model.set_classes([c['prompt'] for _, c in targets])

    out = Path(args.out)
    (out / 'images').mkdir(parents=True, exist_ok=True)
    (out / 'labels').mkdir(parents=True, exist_ok=True)
    files = sorted(p for p in Path(args.images).rglob('*') if p.suffix.lower() in IMAGE_EXTS)
    counts: Counter = Counter()

    for path in files:
        result = model.predict(str(path), conf=args.conf, verbose=False)[0]
        lines = []
        for box, k in zip(result.boxes.xywhn.tolist(), result.boxes.cls.int().tolist()):
            dst_id, cls = targets[k]
            counts[cls['name']] += 1
            lines.append(f'{dst_id} ' + ' '.join(f'{v:.6f}' for v in box))
        shutil.copy2(path, out / 'images' / path.name)
        (out / 'labels' / f'{path.stem}.txt').write_text('\n'.join(lines) + ('\n' if lines else ''), encoding='utf-8')

    with open(out / 'data.yaml', 'w', encoding='utf-8') as f:
        yaml.safe_dump({'names': {i: c['name'] for i, c in enumerate(classes)}}, f, allow_unicode=True, sort_keys=False)

    print(f'{len(files)} ảnh → {out}')
    for name, n in counts.most_common():
        print(f'  {name:<16}{n:>6} box')
    print('⚠ Nhớ kiểm tra & sửa lại bằng công cụ gán nhãn trước khi train.')


if __name__ == '__main__':
    main()
