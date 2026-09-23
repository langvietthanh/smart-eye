"""Đánh giá model TFLite của app trên COCO128 (128 ảnh COCO có nhãn chuẩn).

Mô phỏng đúng pipeline Dart: kéo giãn về input vuông, NCHW/NHWC theo model, NMS theo lớp.
Cách chạy (từ thư mục gốc repo):
    pip install ai-edge-litert pillow numpy
    python tool/eval_coco.py
Lần đầu sẽ tự tải coco128.zip (~7MB) từ GitHub release của Ultralytics vào tool/coco128/.
"""
import glob, io, os, sys, urllib.request, zipfile, numpy as np
from PIL import Image
from ai_edge_litert.interpreter import Interpreter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODEL = os.path.join(ROOT, 'assets', 'models', 'yolov8n_int8.tflite')
DATA = os.path.join(ROOT, 'tool')
COCO128_URL = 'https://github.com/ultralytics/assets/releases/download/v0.0.0/coco128.zip'
if not os.path.isdir(os.path.join(DATA, 'coco128')):
    print('Đang tải COCO128... (nếu lỗi mạng: tải tay file zip ở link trên, giải nén vào tool/)', flush=True)
    zipfile.ZipFile(io.BytesIO(urllib.request.urlopen(COCO128_URL, timeout=120).read())).extractall(DATA)
it = Interpreter(MODEL); it.allocate_tensors()
inp, out = it.get_input_details()[0], it.get_output_details()[0]
NCHW = inp['shape'][1] == 3
S = inp['shape'][2] if NCHW else inp['shape'][1]

def preprocess(img, mode):
    w, h = img.size
    if mode == 'stretch':
        im = np.asarray(img.resize((S, S), Image.NEAREST), np.float32) / 255
        return im, (S / w, S / h, 0, 0)
    r = min(S / w, S / h); nw, nh = round(w * r), round(h * r)
    px, py = (S - nw) // 2, (S - nh) // 2
    canvas = np.full((S, S, 3), 114 / 255, np.float32)
    canvas[py:py + nh, px:px + nw] = np.asarray(img.resize((nw, nh), Image.NEAREST), np.float32) / 255
    return canvas, (r, r, px, py)

def iou(a, b):
    ix = max(0, min(a[2], b[2]) - max(a[0], b[0])); iy = max(0, min(a[3], b[3]) - max(a[1], b[1]))
    inter = ix * iy; u = (a[2]-a[0])*(a[3]-a[1]) + (b[2]-b[0])*(b[3]-b[1]) - inter
    return inter / u if u > 0 else 0

def detect(img, mode, conf):
    x, (sx, sy, px, py) = preprocess(img, mode)
    it.set_tensor(inp['index'], (x.transpose(2, 0, 1) if NCHW else x)[None])
    it.invoke()
    o = it.get_tensor(out['index'])[0]  # [4 + lớp, N]
    if o.shape[0] > o.shape[1]: o = o.T
    boxes, scores = o[:4].T, o[4:].T
    if boxes[:, :2].max() <= 1.5: boxes = boxes * S  # toạ độ chuẩn hoá → pixel input
    cls, sc = scores.argmax(1), scores.max(1)
    dets = []
    for i in np.where(sc >= conf)[0]:
        cx, cy, bw, bh = boxes[i]
        dets.append([((cx-bw/2)-px)/sx, ((cy-bh/2)-py)/sy, ((cx+bw/2)-px)/sx, ((cy+bh/2)-py)/sy, sc[i], cls[i]])
    dets.sort(key=lambda d: -d[4]); keep = []
    for d in dets:
        if all(k[5] != d[5] or iou(k, d) <= 0.45 for k in keep): keep.append(d)
    return keep

def gt_of(path, w, h):
    lp = path.replace(os.sep + 'images' + os.sep, os.sep + 'labels' + os.sep).rsplit('.', 1)[0] + '.txt'
    if not os.path.exists(lp): return []
    g = []
    for line in open(lp):
        c, cx, cy, bw, bh = map(float, line.split())
        g.append([(cx-bw/2)*w, (cy-bh/2)*h, (cx+bw/2)*w, (cy+bh/2)*h, int(c)])
    return g

imgs = sorted(glob.glob(os.path.join(DATA, 'coco128', 'images', 'train2017', '*.jpg')))
print(f'Model: input {S}x{S} {"NCHW" if NCHW else "NHWC"}, {len(imgs)} ảnh')
for mode in ('stretch', 'letterbox'):
    for conf in (0.15, 0.25, 0.35, 0.45):
        tp = fp = n_gt = wrong_cls = 0
        for p in imgs:
            img = Image.open(p).convert('RGB'); w, h = img.size
            g = gt_of(p, w, h); n_gt += len(g); used = set()
            for d in detect(img, mode, conf):
                best, bj = 0, -1
                for j, gg in enumerate(g):
                    v = iou(d, gg)
                    if v > best: best, bj = v, j
                if best >= 0.5 and g[bj][4] == d[5] and bj not in used: tp += 1; used.add(bj)
                else:
                    fp += 1
                    if best >= 0.5 and g[bj][4] != d[5]: wrong_cls += 1
        print(f'{mode:9s} conf={conf:.2f}  precision={tp/max(1,tp+fp):.2f}  recall={tp/n_gt:.2f}  '
              f'sai_lop={wrong_cls}  fp={fp}  tp={tp}/{n_gt}')
