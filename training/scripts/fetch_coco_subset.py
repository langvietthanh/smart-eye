"""Tải một phần COCO 2017 — chỉ ảnh có các lớp Smart Eye cần giữ (người, xe, ghế, biển báo...) —
để model mới KHÔNG "quên" các lớp cũ khi học thêm cầu thang, cột điện...

Dùng FiftyOne (chỉ tải đúng ảnh cần, không phải cả bộ COCO 20 GB):
    pip install fiftyone
    python training/scripts/fetch_coco_subset.py --out datasets/coco_subset --train 6000 --val 800

Kết quả là dataset YOLO (images/, labels/, dataset.yaml) → đưa vào build_dataset.py làm 1 nguồn.
"""
from __future__ import annotations

import argparse
from pathlib import Path

from common import coco_classes_needed, load_classes


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--out', required=True)
    ap.add_argument('--train', type=int, default=6000, help='Số ảnh train tối đa')
    ap.add_argument('--val', type=int, default=800, help='Số ảnh val tối đa')
    ap.add_argument('--seed', type=int, default=0)
    args = ap.parse_args()

    import fiftyone as fo  # import muộn để --help chạy được khi chưa cài fiftyone
    import fiftyone.zoo as foz

    wanted = coco_classes_needed(load_classes())
    print('Lớp COCO sẽ tải:', ', '.join(wanted))
    out = Path(args.out)

    for zoo_split, yolo_split, count in (('train', 'train', args.train), ('validation', 'val', args.val)):
        ds = foz.load_zoo_dataset(
            'coco-2017',
            split=zoo_split,
            label_types=['detections'],
            classes=wanted,
            only_matching=True,  # chỉ giữ nhãn của các lớp cần
            max_samples=count,
            shuffle=True,
            seed=args.seed,
            dataset_name=f'smart-eye-coco-{zoo_split}',
        )
        ds.export(
            export_dir=str(out),
            dataset_type=fo.types.YOLOv5Dataset,
            label_field='ground_truth',
            split=yolo_split,
            classes=wanted,
        )
        print(f'{yolo_split}: {len(ds)} ảnh')
    print(f'→ {out} (dataset.yaml)')


if __name__ == '__main__':
    main()
