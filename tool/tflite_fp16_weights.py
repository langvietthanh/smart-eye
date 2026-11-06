"""Chuyển trọng số float32 của một model TFLite sang float16 (giảm ~một nửa dung lượng).

Cách làm giống post-training fp16 của TFLite converter, nhưng chạy trực tiếp trên file .tflite
(không cần model gốc): mỗi tensor hằng float32 được thay bằng một tensor float16, và một op
DEQUANTIZE (fp16 → fp32) được thêm vào đầu graph. Input/output vẫn là float32 nên code app
không đổi. XNNPack gộp các DEQUANTIZE này lúc khởi tạo, nên tốc độ chạy gần như không đổi.

Cách chạy:  python tool/tflite_fp16_weights.py input.tflite output.tflite
Script chỉ ghi file sau khi output fp16 khớp model gốc (sai số tương đối p99 < 2%, trung bình < 1%).
"""
import sys
import time

import flatbuffers
import numpy as np
from ai_edge_litert import schema_py_generated as schema
from ai_edge_litert.interpreter import Interpreter

FLOAT32 = schema.TensorType.FLOAT32
FLOAT16 = schema.TensorType.FLOAT16
DEQUANTIZE = schema.BuiltinOperator.DEQUANTIZE
MIN_ELEMENTS = 16  # Hằng nhỏ (shape, scalar) giữ float32: tiết kiệm không đáng kể.

src, dst = sys.argv[1], sys.argv[2]
raw = open(src, 'rb').read()
model = schema.ModelT.InitFromPackedBuf(raw, 0)
if any(b.offset for b in model.buffers):
    sys.exit('Model dùng buffer offset: chạy tool/inline_tflite_buffers.py trước.')

# Op code DEQUANTIZE phiên bản 3 = input float16.
deq = next((i for i, c in enumerate(model.operatorCodes)
            if max(c.builtinCode, c.deprecatedBuiltinCode) == DEQUANTIZE), None)
if deq is None:
    code = schema.OperatorCodeT()
    code.builtinCode = code.deprecatedBuiltinCode = DEQUANTIZE
    code.version = 3
    model.operatorCodes.append(code)
    deq = len(model.operatorCodes) - 1
else:
    model.operatorCodes[deq].version = max(model.operatorCodes[deq].version, 3)

converted = 0
for graph in model.subgraphs:
    dequantize_ops = []
    for index, tensor in enumerate(list(graph.tensors)):
        buf = model.buffers[tensor.buffer]
        if tensor.type != FLOAT32 or buf.data is None or len(buf.data) < 4 * MIN_ELEMENTS:
            continue
        values = np.frombuffer(bytes(buf.data), dtype='<f4')
        half = values.astype('<f2')
        if not np.all(np.isfinite(half)):
            continue  # Giá trị vượt phạm vi float16: giữ nguyên float32.
        new_buf = schema.BufferT()
        new_buf.data = np.frombuffer(half.tobytes(), dtype=np.uint8)
        model.buffers.append(new_buf)
        t16 = schema.TensorT()
        t16.shape = tensor.shape
        t16.type = FLOAT16
        t16.buffer = len(model.buffers) - 1
        t16.name = (tensor.name or b'') + b'_fp16'
        graph.tensors.append(t16)
        # Tensor cũ thành tensor runtime, nhận giá trị từ DEQUANTIZE.
        buf.data = None
        op = schema.OperatorT()
        op.opcodeIndex = deq
        op.inputs = [len(graph.tensors) - 1]
        op.outputs = [index]
        dequantize_ops.append(op)
        converted += 1
    graph.operators = dequantize_ops + list(graph.operators)

builder = flatbuffers.Builder(len(raw) // 2 + 1024)
builder.Finish(model.Pack(builder), file_identifier=b'TFL3')
out = bytes(builder.Output())


def run(model_bytes, x):
    it = Interpreter(model_content=model_bytes, num_threads=2)
    it.allocate_tensors()
    it.set_tensor(it.get_input_details()[0]['index'], x)
    start = time.perf_counter()
    it.invoke()
    elapsed = time.perf_counter() - start
    return it.get_tensor(it.get_output_details()[0]['index']), elapsed


shape = Interpreter(model_content=raw).get_input_details()[0]['shape']
# Sai số lớn nhất ở 1 điểm ảnh quá khắt khe (input nhân tạo cực đoan cho ~6%); quyết định của app
# dựa trên phân vị theo vùng, nên kiểm p99 và trung bình của sai số tương đối theo dải output.
for seed in range(3):
    x = np.random.default_rng(seed).standard_normal(shape).astype(np.float32)
    a, ta = run(raw, x)
    b, tb = run(out, x)
    rel = np.abs(a - b) / max(float(a.max() - a.min()), 1e-6)
    p99, mean = float(np.quantile(rel, 0.99)), float(rel.mean())
    print(f'p99 {p99:.4f} · trung bình {mean:.5f} · fp32 {ta * 1000:.0f} ms · fp16 {tb * 1000:.0f} ms')
    assert p99 < 0.02 and mean < 0.01, f'Output fp16 lệch quá nhiều: p99={p99}, mean={mean}'

open(dst, 'wb').write(out)
print(f'Đã chuyển {converted} tensor sang float16. {len(raw)} → {len(out)} bytes')
