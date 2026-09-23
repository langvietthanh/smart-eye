"""Chuyển model TFLite dùng "buffer offset" (định dạng mới, trọng số nằm ngoài flatbuffer)
về định dạng cũ (trọng số nằm trong flatbuffer) để runtime TFLite trên Android đọc được.

Lý do: Ultralytics ≥ 8.4 export TFLite kiểu mới. Runtime của tflite_flutter / TFLite-in-PlayServices
không hỗ trợ → log `E/tflite: Input tensor N lacks data` và Interpreter.invoke() thất bại mọi frame.

Cách chạy:  python tool/inline_tflite_buffers.py assets/models/yolov8n_int8.tflite
(ghi đè file sau khi kiểm tra output giống hệt model gốc; giữ lại metadata Ultralytics).
"""
import io, sys, zipfile
import flatbuffers
import numpy as np
from ai_edge_litert import schema_py_generated as schema
from ai_edge_litert.interpreter import Interpreter

path = sys.argv[1]
raw = open(path, 'rb').read()

model = schema.ModelT.InitFromPackedBuf(raw, 0)
moved = 0
for b in model.buffers:
    if b.offset and b.offset > 1:  # offset 1 = placeholder cho buffer rỗng
        b.data = np.frombuffer(raw[b.offset:b.offset + b.size], dtype=np.uint8)
        b.offset, b.size = 0, 0
        moved += 1
    elif b.offset:
        b.offset, b.size = 0, 0
if moved == 0:
    print('Model đã ở định dạng cũ, không cần chuyển.')
    sys.exit(0)

builder = flatbuffers.Builder(len(raw) + 1024)
builder.Finish(model.Pack(builder), file_identifier=b'TFL3')
out = bytes(builder.Output())

# Giữ metadata Ultralytics (zip nối ở cuối file: tên lớp, imgsz...)
try:
    names = zipfile.ZipFile(io.BytesIO(raw)).namelist()
    z = io.BytesIO()
    with zipfile.ZipFile(z, 'w') as zw:
        for n in names:
            zw.writestr(n, zipfile.ZipFile(io.BytesIO(raw)).read(n))
    out += z.getvalue()
except zipfile.BadZipFile:
    pass

# Kiểm tra: model mới cho output giống hệt model gốc
def run(model_bytes, x):
    it = Interpreter(model_content=model_bytes); it.allocate_tensors()
    it.set_tensor(it.get_input_details()[0]['index'], x); it.invoke()
    return it.get_tensor(it.get_output_details()[0]['index'])

x = np.random.default_rng(0).random(Interpreter(model_content=raw).get_input_details()[0]['shape'], np.float32)
diff = np.abs(run(raw, x) - run(out, x)).max()
assert diff < 1e-5, f'Output khác model gốc: {diff}'
check = schema.ModelT.InitFromPackedBuf(out, 0)
assert not any(b.offset for b in check.buffers)

open(path, 'wb').write(out)
print(f'Đã chuyển {moved} buffer vào trong flatbuffer. Chênh lệch output: {diff}. Kích thước {len(raw)} → {len(out)} bytes')
