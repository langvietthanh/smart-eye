"""Đánh giá model TFLite của app trên dataset có nhãn — mô phỏng đúng pipeline Dart
(kéo giãn về input vuông, NCHW/NHWC theo model, NMS theo lớp, chỉ xét lớp liên quan tới đi lại).

Cách chạy (từ thư mục gốc repo):
    pip install ai-edge-litert pillow numpy pyyaml
    python tool/eval_model.py                                   # model của app trên COCO128 (tự tải ~7MB)
    python tool/eval_model.py --model new.tflite --data datasets/smart_eye/data.yaml

Tên lớp giữa model và dataset được so khớp theo tên + alias trong training/classes.yaml,
nên dataset COCO (80 lớp) và model Smart Eye (26 lớp) vẫn so được với nhau.
"""
from __future__ import annotations

import argparse
import glob
import io
import json
import os
import re
import sys
import urllib.request
import zipfile

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'training', 'scripts'))
from common import COCO80, alias_map, load_classes, norm  # noqa: E402

COCO128_URL = 'https://github.com/ultralytics/assets/releases/download/v0.0.0/coco128.zip'


def model_names(path: str) -> list[str]:
    """Tên lớp trong metadata Ultralytics nhúng ở cuối file .tflite"""
    try:
        meta = json.loads(zipfile.ZipFile(io.BytesIO(open(path, 'rb').read())).read('metadata.json'))
        names = meta['names']
        return [names[str(i)] if str(i) in names else names[i] for i in range(len(names))]
    except Exception:
        return COCO80


def load_dataset(data: str | None, split: str) -> tuple[list[str], list[str]]:
    """→ (danh sách ảnh, tên lớp của dataset)"""
    if data is None:
        base = os.path.join(ROOT, 'tool')
        if not os.path.isdir(os.path.join(base, 'coco128')):
            print('Đang tải COCO128... (lỗi mạng: tải tay link trên, giải nén vào tool/)', flush=True)
            zipfile.ZipFile(io.BytesIO(urllib.request.urlopen(COCO128_URL, timeout=120).read())).extractall(base)
        return sorted(glob.glob(os.path.join(base, 'coco128', 'images', 'train2017', '*.jpg'))), COCO80
    import yaml
    cfg = yaml.safe_load(open(data, encoding='utf-8'))
    root = cfg.get('path') or os.path.dirname(os.path.abspath(data))
    names = cfg['names']
    names = [names[k] for k in sorted(names, key=int)] if isinstance(names, dict) else list(names)
    img_dir = os.path.join(root, cfg[split])
    imgs = sorted(p for p in glob.glob(os.path.join(img_dir, '**', '*'), recursive=True)
                  if p.lower().endswith(('.jpg', '.jpeg', '.png', '.bmp', '.webp')))
    return imgs, names


def label_file(img: str) -> str:
    parts = re.split(r'([\\/])images([\\/])', img)
    joined = ''.join(parts[:-3]) + parts[-3] + 'labels' + parts[-2] + parts[-1] if len(parts) >= 4 else img
    return os.path.splitext(joined)[0] + '.txt'


def iou(a, b) -> float:
    ix = max(0, min(a[2], b[2]) - max(a[0], b[0]))
    iy = max(0, min(a[3], b[3]) - max(a[1], b[1]))
    inter = ix * iy
    u = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / u if u > 0 else 0


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--model', default=os.path.join(ROOT, 'assets', 'models', 'yolov8n_int8.tflite'))
    ap.add_argument('--data', default=None, help='data.yaml của dataset (mặc định COCO128)')
    ap.add_argument('--split', default='val')
    ap.add_argument('--conf', default='0.15,0.25,0.35,0.45')
    ap.add_argument('--large', type=float, default=0.05, help='Vật "lớn" = chiếm ≥ tỉ lệ này diện tích ảnh')
    args = ap.parse_args()

    from ai_edge_litert.interpreter import Interpreter
    it = Interpreter(args.model)
    it.allocate_tensors()
    inp, out = it.get_input_details()[0], it.get_output_details()[0]
    nchw = inp['shape'][1] == 3
    size = inp['shape'][2] if nchw else inp['shape'][1]

    classes = load_classes()
    amap = alias_map(classes)
    m_names = model_names(args.model)
    imgs, d_names = load_dataset(args.data, args.split)
    # Model và dataset so khớp qua "lớp chuẩn" trong classes.yaml; chỉ xét lớp liên quan tới đi lại
    m2c = {i: amap.get(norm(n)) for i, n in enumerate(m_names)}
    d2c = {i: amap.get(norm(n)) for i, n in enumerate(d_names)}
    relevant_model_ids = [i for i, c in m2c.items() if c is not None]
    print(f'Model: {os.path.basename(args.model)} · input {size}x{size} {"NCHW" if nchw else "NHWC"} · '
          f'{len(m_names)} lớp (xét {len(relevant_model_ids)}) · {len(imgs)} ảnh')

    def detect(img: Image.Image, conf: float):
        w, h = img.size
        x = np.asarray(img.resize((size, size), Image.NEAREST), np.float32) / 255
        it.set_tensor(inp['index'], (x.transpose(2, 0, 1) if nchw else x)[None])
        it.invoke()
        o = it.get_tensor(out['index'])[0]
        if o.shape[0] > o.shape[1]:
            o = o.T
        boxes = o[:4].T
        if boxes[:, :2].max() > 1.5:
            boxes = boxes / size
        scores = o[4:][relevant_model_ids]
        best = scores.max(0)
        cls = np.array(relevant_model_ids)[scores.argmax(0)]
        dets = []
        for i in np.where(best >= conf)[0]:
            cx, cy, bw, bh = boxes[i]
            dets.append([(cx - bw / 2) * w, (cy - bh / 2) * h, (cx + bw / 2) * w, (cy + bh / 2) * h, best[i], m2c[int(cls[i])]])
        dets.sort(key=lambda d: -d[4])
        keep = []
        for d in dets:
            if all(k[5] != d[5] or iou(k, d) <= 0.45 for k in keep):
                keep.append(d)
        return keep

    def ground_truth(path: str, w: int, h: int):
        gt = []
        lf = label_file(path)
        if os.path.exists(lf):
            for line in open(lf, encoding='utf-8'):
                v = line.split()
                if len(v) != 5:
                    continue
                c = d2c.get(int(v[0]))
                if c is None:
                    continue
                cx, cy, bw, bh = map(float, v[1:])
                gt.append([(cx - bw / 2) * w, (cy - bh / 2) * h, (cx + bw / 2) * w, (cy + bh / 2) * h, c])
        return gt

    data = []
    for p in imgs:
        img = Image.open(p).convert('RGB')
        data.append((img, ground_truth(p, *img.size)))

    per_class_at_25 = None
    for conf in [float(c) for c in args.conf.split(',')]:
        tp = fp = n_gt = wrong = large_hit = large_n = 0
        hit_by = np.zeros(len(classes), int)
        n_by = np.zeros(len(classes), int)
        for img, gt in data:
            w, h = img.size
            dets = detect(img, conf)
            n_gt += len(gt)
            used = set()
            for g in gt:
                n_by[g[4]] += 1
                ok = any(d[5] == g[4] and iou(d, g) >= 0.5 for d in dets)
                hit_by[g[4]] += ok
                if (g[2] - g[0]) * (g[3] - g[1]) >= args.large * w * h:
                    large_n += 1
                    large_hit += ok
            for d in dets:
                best, bj = 0, -1
                for j, g in enumerate(gt):
                    v = iou(d, g)
                    if v > best:
                        best, bj = v, j
                if best >= 0.5 and gt[bj][4] == d[5] and bj not in used:
                    tp += 1
                    used.add(bj)
                else:
                    fp += 1
                    wrong += best >= 0.5 and gt[bj][4] != d[5]
        print(f'conf={conf:.2f}  precision={tp / max(1, tp + fp):.2f}  recall={tp / max(1, n_gt):.2f}  '
              f'recall_vật_lớn={large_hit / max(1, large_n):.2f}  sai_lớp={wrong}  box_sai={fp}  đúng={tp}/{n_gt}')
        if abs(conf - 0.25) < 1e-6:
            per_class_at_25 = (hit_by, n_by)

    if per_class_at_25 is not None:
        hit_by, n_by = per_class_at_25
        print('\nRecall theo lớp (conf 0.25):')
        for i, c in enumerate(classes):
            if n_by[i]:
                print(f'  {c["name"]:<16}{hit_by[i]:>5}/{n_by[i]:<5} = {hit_by[i] / n_by[i]:.2f}')


if __name__ == '__main__':
    main()
