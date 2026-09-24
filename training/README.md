# 🏋️ Train model Smart Eye có thêm cầu thang, cột điện, ổ gà...

Model hiện tại train trên **COCO (80 lớp đồ vật thông dụng)** nên **không có** cầu thang, lan can, ổ gà, cột điện...
Thư mục này là toàn bộ quy trình để nhóm tự train model mới — **không cần WSL hay máy Mac**, chạy trên Google Colab.

```
classes.yaml            ← danh sách lớp (nguồn duy nhất)
scripts/
  fetch_coco_subset.py  ← tải 1 phần COCO (giữ người, xe...)
  auto_label.py         ← gán nhãn tự động bằng YOLO-World (người sửa lại)
  build_dataset.py      ← gộp mọi nguồn dữ liệu theo classes.yaml
smart_eye_train.ipynb   ← notebook Colab chạy trọn quy trình
```

## 1. Danh sách lớp — ưu tiên theo file nghiệp vụ

File nghiệp vụ nói giá trị lớn nhất là vật **ở tầm ngực / cao mà gậy trắng không dò tới**.

| Ưu tiên | Lớp (`name` → đọc là) | Ghi chú |
|---|---|---|
| **1** | `pole` → cột · `traffic sign` → biển báo · `tree` → cây · `branch` → cành cây · `railing` → lan can · `barrier` → rào chắn · `vendor cart` → xe hàng rong | Gậy không dò tới — **cần nhiều dữ liệu nhất** (≥ 1000 vật/lớp) |
| **2** | `stairs` → bậc thang · `curb` → mép vỉa hè · `pothole` → ổ gà · `manhole` → hố ga · `bollard` → cọc chắn · `traffic cone` → cọc giao thông | Dưới chân, gậy dò được — báo sớm vẫn có ích (≥ 300 vật/lớp) |
| **3** | người, xe đạp, ô tô, xe máy, xe buýt, xe tải, chó, ghế, bàn, ghế băng, chậu cây, trụ nước cứu hỏa, ô dù | Lấy từ COCO để model **không quên** |

**Thêm / bớt lớp:** sửa `classes.yaml` **và** `lib/utils/label_catalog.dart` (tên tiếng Việt + nhóm nguy hiểm).
`flutter test` có test so khớp 2 file — lệch là báo lỗi ngay.

## 2. Thu thập ảnh

Dataset trên mạng chủ yếu là đường phố nước ngoài → **ảnh vỉa hè Việt Nam do nhóm tự chụp là quan trọng nhất**.

- Điện thoại **dọc, đặt trước ngực** (đúng tư thế dùng app), đi bộ chậm trên vỉa hè thật.
- Quay video rồi trích 1–2 ảnh/giây, hoặc chụp ảnh liên tục. Tránh ảnh gần như trùng nhau.
- Đa dạng: sáng / trưa / chiều / tối, nắng / râm / mưa, phố lớn / ngõ nhỏ / chợ / trường học / bệnh viện.
- Chụp cả lúc **tới gần** vật (1–2 m) lẫn **nhìn từ xa** (5–10 m) — app cần cả hai.
- Chụp cả cảnh **không có gì nguy hiểm** (giúp model bớt báo nhầm).

**Quyền riêng tư:** ảnh đường phố có mặt người, biển số xe → chỉ lưu trên Drive riêng của nhóm, **không công khai
dataset**; nếu cần chia sẻ, làm mờ mặt / biển số trước.

## 3. Quy tắc gán nhãn (cả nhóm phải khoanh giống nhau)

| Lớp | Khoanh gì | Không khoanh |
|---|---|---|
| `pole` | Toàn bộ phần cột nhìn thấy (chân → đỉnh trong khung), cột điện / cột đèn / cột biển báo | Dây điện |
| `traffic sign` | Chỉ **tấm biển** | Cột đỡ biển (cột → `pole`) |
| `tree` | Thân cây (từ gốc tới chạc đầu tiên) | Tán cây trên cao ngoài tầm đi |
| `branch` | Cành cây **thấp, dưới ~2 m**, chắn lối đi | Cành cao hơn đầu người |
| `railing` | Mỗi đoạn lan can / hàng rào liền mạch 1 box | |
| `barrier` | Rào chắn công trình, barie, dải phân cách tạm | |
| `vendor cart` | Xe đẩy / tủ kính / quầy hàng rong chiếm vỉa hè | Cửa hàng cố định |
| `stairs` | Cả đoạn bậc thang nhìn thấy (lên hoặc xuống) | Bậc thềm 1 bậc (→ `curb`) |
| `curb` | Đoạn mép vỉa hè / bậc thềm **cắt ngang lối đi, trong ~5 m** | Mép vỉa hè chạy dọc theo hướng đi, ở xa |
| `pothole` | Ổ gà, chỗ lún, hố trên mặt đường / vỉa hè | Vũng nước trên mặt phẳng |
| `manhole` | Nắp hố ga / cống, **đặc biệt hố ga mở** | |
| `bollard` | Cọc thấp chắn xe, cột đồng hồ đỗ xe | |
| `traffic cone` | Cọc nón giao thông | |

Quy tắc chung: khoanh **sát mép vật**; vật bị che ≥ 70% hoặc quá nhỏ (cao < 1% ảnh) thì **bỏ qua**; mỗi vật 1 box.

**Công cụ:** [CVAT](https://www.cvat.ai), [Label Studio](https://labelstud.io) hoặc [Roboflow](https://roboflow.com) —
export định dạng **YOLO**. Dùng `auto_label.py` (bước 4a trong notebook) để có box sẵn rồi sửa lại, nhanh hơn ~3–5 lần.

## 4. Train trên Colab

1. Mở `smart_eye_train.ipynb` bằng Google Colab (*File → Upload notebook*, hoặc mở từ GitHub).
2. *Runtime → Change runtime type → T4 GPU*.
3. Chạy lần lượt từng ô, làm theo hướng dẫn trong notebook. Dữ liệu và kết quả lưu ở `MyDrive/smart_eye`.

Các bước notebook làm: tải COCO subset → tải dataset Roboflow → gán nhãn tự động (tuỳ chọn) → gộp dữ liệu →
train `yolo11n` ở 320×320 → đánh giá từng lớp → xuất TFLite FP32 → sửa định dạng trọng số → chấm lại như app.

Chạy thử script ở máy (không cần GPU):
```bash
pip install ultralytics pyyaml
python training/scripts/build_dataset.py --source tool/coco128@coco80 --out datasets/test
```

## 5. Tiêu chí nhận model mới

Trước khi thay model trong app, chạy `python tool/eval_model.py --model <file mới> --data <data.yaml>` và so với
model cũ (`python tool/eval_model.py --data <data.yaml>`):

- Lớp **ưu tiên 1**: mAP50 ≥ 0.5 và recall vật lớn ≥ 0.7.
- Các lớp COCO (người, xe...): recall vật lớn **không giảm quá 0.05** so với model cũ.
- Chạy thật trên điện thoại: thời gian "AI" trên dòng chẩn đoán không tăng quá 20%.

## 6. Đưa model vào app

Đổi tên file thành **`smart_eye.tflite`**, chép vào `assets/models/`, chạy lại app. App tự ưu tiên file này,
đọc tên lớp từ metadata trong model (không cần sửa `coco.txt`). Log khởi động:
```
Model: assets/models/smart_eye.tflite (...) · nhãn từ metadata
Lớp: 26 (xét 26) · input 320 NCHW · output [1, 30, 2100]
```
