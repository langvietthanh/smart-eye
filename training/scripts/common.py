"""Tiện ích dùng chung cho các script train Smart Eye."""
from __future__ import annotations

import re
from pathlib import Path

import yaml

TRAINING_DIR = Path(__file__).resolve().parents[1]
CLASSES_YAML = TRAINING_DIR / 'classes.yaml'
IMAGE_EXTS = {'.jpg', '.jpeg', '.png', '.bmp', '.webp'}

# 80 lớp COCO theo thứ tự chuẩn của Ultralytics (coco.yaml)
COCO80 = [
    'person', 'bicycle', 'car', 'motorcycle', 'airplane', 'bus', 'train', 'truck', 'boat', 'traffic light',
    'fire hydrant', 'stop sign', 'parking meter', 'bench', 'bird', 'cat', 'dog', 'horse', 'sheep', 'cow',
    'elephant', 'bear', 'zebra', 'giraffe', 'backpack', 'umbrella', 'handbag', 'tie', 'suitcase', 'frisbee',
    'skis', 'snowboard', 'sports ball', 'kite', 'baseball bat', 'baseball glove', 'skateboard', 'surfboard',
    'tennis racket', 'bottle', 'wine glass', 'cup', 'fork', 'knife', 'spoon', 'bowl', 'banana', 'apple',
    'sandwich', 'orange', 'broccoli', 'carrot', 'hot dog', 'pizza', 'donut', 'cake', 'chair', 'couch',
    'potted plant', 'bed', 'dining table', 'toilet', 'tv', 'laptop', 'mouse', 'remote', 'keyboard', 'cell phone',
    'microwave', 'oven', 'toaster', 'sink', 'refrigerator', 'book', 'clock', 'vase', 'scissors', 'teddy bear',
    'hair drier', 'toothbrush',
]


def norm(name: object) -> str:
    """'Utility_Pole ' → 'utility pole' — để so khớp tên lớp giữa các dataset"""
    return re.sub(r'[\s_\-]+', ' ', str(name).strip().lower())


def load_classes(path: Path = CLASSES_YAML) -> list[dict]:
    with open(path, encoding='utf-8') as f:
        classes = yaml.safe_load(f)['classes']
    for c in classes:
        c.setdefault('aliases', [])
    return classes


def alias_map(classes: list[dict]) -> dict[str, int]:
    """Tên chuẩn + mọi alias (đã chuẩn hoá) → id lớp đích. Báo lỗi nếu 1 alias trỏ tới 2 lớp."""
    mapping: dict[str, int] = {}
    for i, c in enumerate(classes):
        for n in [c['name'], *c['aliases']]:
            key = norm(n)
            if key in mapping and mapping[key] != i:
                raise ValueError(f'Alias "{key}" trỏ tới 2 lớp: {classes[mapping[key]]["name"]} và {c["name"]}')
            mapping[key] = i
    return mapping


def coco_classes_needed(classes: list[dict]) -> list[str]:
    """Các lớp COCO cần tải (tên COCO trùng tên chuẩn hoặc alias của 1 lớp đích)"""
    amap = alias_map(classes)
    return [n for n in COCO80 if norm(n) in amap]


def read_names(data_yaml: Path) -> list[str]:
    """Đọc `names` trong data.yaml (dạng list hoặc dict {id: tên})"""
    with open(data_yaml, encoding='utf-8') as f:
        names = yaml.safe_load(f)['names']
    if isinstance(names, dict):
        return [str(names[k]) for k in sorted(names, key=int)]
    return [str(n) for n in names]


def label_path_for(image: Path) -> Path:
    """.../images/xxx.jpg → .../labels/xxx.txt (đổi thư mục 'images' GẦN NHẤT)"""
    parts = list(image.parts)
    for i in range(len(parts) - 2, -1, -1):
        if parts[i].lower() == 'images':
            parts[i] = 'labels'
            break
    return Path(*parts).with_suffix('.txt')
