"""Gán nhãn BÙ các lớp COCO (người, xe, ghế...) cho ảnh train đến từ dataset ngoài COCO.

Vấn đề: ảnh ổ gà (Kaggle), Roboflow... có ô tô / xe máy / người nhưng KHÔNG được gán nhãn → khi train, model bị dạy
"xe ở đây là nền" → quên dần lớp COCO (v1/v2 nhận người, xe kém hơn model gốc). Script dùng 1 model COCO mạnh
(mặc định YOLO11x) khoanh bù các lớp đó, chỉ thêm box không trùng nhãn có sẵn. Chỉ chạy trên tập TRAIN
(tập val giữ nguyên để chấm điểm công bằng).

    python training/scripts/pseudo_label.py --ds datasets/smart_eye
"""
from __future__ import annotations

import argparse
from collections import Counter
from pathlib import Path

from common import IMAGE_EXTS, alias_map, load_classes, norm


def iou(a, b) -> float:
    ax0, ay0, ax1, ay1 = a[0] - a[2] / 2, a[1] - a[3] / 2, a[0] + a[2] / 2, a[1] + a[3] / 2
    bx0, by0, bx1, by1 = b[0] - b[2] / 2, b[1] - b[3] / 2, b[0] + b[2] / 2, b[1] + b[3] / 2
    w, h = min(ax1, bx1) - max(ax0, bx0), min(ay1, by1) - max(ay0, by0)
    if w <= 0 or h <= 0:
        return 0.0
    inter = w * h
    return inter / (a[2] * a[3] + b[2] * b[3] - inter)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--ds', required=True, help='Thư mục dataset gộp (kết quả build_dataset.py)')
    ap.add_argument('--teacher', default='yolo11x.pt', help='Model COCO dùng để gán nhãn bù (tự tải)')
    ap.add_argument('--conf', type=float, default=0.5, help='Chỉ lấy box teacher chắc chắn')
    ap.add_argument('--skip', nargs='*', default=['coco'], help='Bỏ ảnh có tên chứa chuỗi này (đã đủ nhãn COCO)')
    ap.add_argument('--imgsz', type=int, default=640)
    args = ap.parse_args()

    from ultralytics import YOLO  # import muộn để --help chạy được khi chưa cài

    classes = load_classes()
    amap = alias_map(classes)
    teacher = YOLO(args.teacher)
    # Chỉ bù các lớp gốc COCO (người, xe...) — lớp mới (cột, ổ gà...) teacher không biết đầy đủ
    to_dst = {i: amap.get(norm(n)) for i, n in teacher.names.items()}
    to_dst = {i: d for i, d in to_dst.items() if d is not None and classes[d]['source'] == 'coco'}

    ds = Path(args.ds)
    images = sorted(p for p in (ds / 'images' / 'train').iterdir()
                    if p.suffix.lower() in IMAGE_EXTS and not any(s in p.name for s in args.skip))
    added: Counter = Counter()
    for img in images:
        label = ds / 'labels' / 'train' / f'{img.stem}.txt'
        lines = label.read_text(encoding='utf-8').splitlines() if label.exists() else []
        existing = [(int(l.split()[0]), [float(v) for v in l.split()[1:5]]) for l in lines if l.strip()]
        result = teacher.predict(str(img), conf=args.conf, imgsz=args.imgsz, verbose=False)[0]
        for box, k in zip(result.boxes.xywhn.tolist(), result.boxes.cls.int().tolist()):
            dst = to_dst.get(k)
            if dst is None or any(c == dst and iou(box, b) > 0.5 for c, b in existing):
                continue
            existing.append((dst, box))
            lines.append(f'{dst} ' + ' '.join(f'{v:.6f}' for v in box))
            added[classes[dst]['name']] += 1
        label.write_text('\n'.join(lines) + ('\n' if lines else ''), encoding='utf-8')

    print(f'Gán nhãn bù {sum(added.values())} box trên {len(images)} ảnh train ngoài COCO:')
    for name, n in added.most_common():
        print(f'  {name:<16}{n:>6}')


if __name__ == '__main__':
    main()
