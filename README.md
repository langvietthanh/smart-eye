# Smart Eye 👁️ – Hướng Dẫn Cài Đặt & Chạy Dự Án

**Smart Eye** là ứng dụng di động hỗ trợ người khiếm thị nhận diện vật thể thời gian thực (Real-time Object Detection) dựa trên mô hình **YOLOv8** nạp qua TFLite, tích hợp vẽ khung nhận diện (Bounding Box) và đọc cảnh báo bằng giọng nói tiếng Việt (TTS).

---

## 🧭 Chức Năng (theo `SMART-EYE-CHUC-NANG-TONG-HOP.md`)

| | Chức năng | Cài đặt trong code |
|---|---|---|
| F1 🔴 | Nhìn & nhận diện | YOLO + TFLite on-device, isolate riêng, tự chọn CPU/GPU, nhịp quét thích ứng (`detector_service.dart`, `detection/`) |
| F2 🔴 | Cảnh báo + chỉ hướng | Tracker IoU/centroid (CN5), rules engine (CN4), free-space 3 cột (CN6), khoảng cách theo % chiều cao box (CN7) |
| F3 🟠 | Mô tả + nói ra | Caption template (CN8), flutter_tts tiếng Việt (CN9), Speech Manager ưu tiên/barge-in/dedupe (CN10) — mặc định **chỉ mô tả khi được hỏi** |
| F4 🟡 | Lưu lịch sử | Event log JSONL (CN11), ảnh ghi nhớ thumbnail + GPS (CN12), recap template (CN13), tự dọn: tối đa 20 chuyến / 30 ngày / 40 ảnh mỗi chuyến |

**Nguyên tắc "nói ít, đúng lúc":** mỗi frame chỉ chọn 1 cảnh báo quan trọng nhất; vật xa phải xuất hiện ≥ 2 lần quét mới được báo (lọc báo nhầm), **vật gần + điểm cao báo ngay từ lần quét đầu**;
cùng 1 vật chỉ nhắc lại sau 6 giây (nguy hiểm) / 10 giây (chú ý) trừ khi mức nguy hiểm tăng; cảnh báo nguy hiểm ngắt lời mọi câu khác;
khi vật rất gần ngay trước mặt luôn nói **"Dừng lại"** và chỉ nêu phía trống, không ra lệnh rẽ.

### Cách dùng trên màn hình chính
- **Chạm 2 lần vào màn hình** hoặc nút **Xung quanh**: nghe mô tả xung quanh (F3 on-demand).
- **Giữ lâu vào màn hình** hoặc nút **Tóm tắt**: nghe tóm tắt chuyến đi hiện tại.
- Nút **Lịch sử**: danh sách chuyến đi, nghe tóm tắt, xem ảnh ghi nhớ, nghe lại toàn bộ.
- Chip **Đầy đủ / Yên lặng**: chế độ yên lặng chỉ báo khi nguy hiểm.
- Chip **Mô tả khi hỏi / Tự mô tả**: bật tự mô tả tần suất thấp (~45 giây, chỉ khi không có cảnh báo gần đây).

---

## 📋 Cấu Trúc Dự Án

```
smart_eye/
├── 📁 assets/
│   ├── 📁 models/yolov8n_int8.tflite   # Model COCO mặc định (smart_eye.tflite nếu có sẽ được ưu tiên)
│   └── 📁 labels/coco.txt             # Nhãn dự phòng khi model không có metadata
├── 📁 lib/
│   ├── 📄 main.dart                    # Khởi tạo ứng dụng & danh sách Camera
│   ├── 📁 models/                      # Recognition, tracked_object, scene_info, trip
│   ├── 📁 utils/
│   │   ├── image_utils.dart            # Lấy mẫu frame (YUV/BGRA/NV12) → tensor, cắt vùng, JPEG, chữ ký độ sáng
│   │   └── label_catalog.dart          # Nhãn tiếng Việt + phân loại nguy hiểm (khớp training/classes.yaml)
│   ├── 📁 services/
│   │   ├── detector_service.dart       # F1: nạp model + metadata, điều phối isolate AI
│   │   ├── 📁 detection/
│   │   │   ├── detector_worker.dart    # Isolate AI: tự chọn CPU/GPU, tiền xử lý → model → giải mã
│   │   │   ├── yolo_decoder.dart       # Giải mã YOLO chỉ các lớp liên quan + NMS
│   │   │   ├── scan_scheduler.dart     # Nhịp quét: liên tục / tiết kiệm khi cảnh đứng yên
│   │   │   ├── frame_data.dart         # Bản sao frame gửi sang isolate, vùng cắt
│   │   │   └── model_metadata.dart     # Đọc tên lớp / kích thước ảnh nhúng trong model
│   │   ├── object_tracker.dart         # F2/CN5: Tracker IoU + centroid (biết vùng nào được quét)
│   │   ├── hazard_engine.dart          # F2/CN4+CN6+CN7: Rules, free-space, khoảng cách
│   │   ├── caption_builder.dart        # F3/CN8 + F4/CN13: Câu mô tả & recap
│   │   ├── tts_service.dart / speech_manager.dart  # F3/CN9+CN10: giọng nói, ưu tiên, barge-in, dedupe
│   │   ├── history_service.dart        # F4/CN11+CN12: Lưu JSONL + ảnh, tự dọn dẹp
│   │   └── location_service.dart       # F4: GPS, quãng đường
│   ├── 📁 widgets/bounding_box_painter.dart # Khung màu theo mức nguy hiểm + lưới 3 cột
│   └── 📁 screens/                     # camera_screen, history_screen, trip_detail_screen
├── 📁 training/                        # Quy trình train model có thêm cầu thang, cột điện... (xem training/README.md)
├── 📁 tool/
│   ├── eval_model.py                   # Đánh giá model bất kỳ trên dataset bất kỳ (mặc định COCO128)
│   └── inline_tflite_buffers.py        # Sửa định dạng trọng số model cho runtime Android/iOS
├── 📁 test/                            # Unit test: rules, tracker, xử lý ảnh, giải mã YOLO, nhịp quét, danh sách lớp
└── 📄 pubspec.yaml
```

---

## 🚀 Hướng Dẫn Chạy Trên Thiết Bị Android Thật (Khuyên Dùng)

Chạy ứng dụng trên thiết bị Android phần cứng thật sẽ cho **hiệu năng cao nhất (15-30 FPS)**, đúng góc dọc camera và đọc âm thanh trực tiếp qua loa điện thoại.

### Bước 1: Chuẩn bị điện thoại
1. Vào **Cài đặt** (Settings) trên điện thoại Android $\rightarrow$ **Thông tin điện thoại** (About Phone).
2. Nhấn 7 lần vào **Số phiên bản** (Build Number) để bật *Tùy chọn nhà phát triển*.
3. Vào **Tùy chọn nhà phát triển** (Developer Options) $\rightarrow$ Bật **Gỡ lỗi USB** (USB Debugging).
4. Dùng cáp USB cắm điện thoại vào máy tính.

### Bước 2: Clone & Chạy lệnh
1. Mở Terminal / PowerShell tại thư mục muốn lưu dự án và gõ:
   ```bash
   git clone <link_repository_of_project>
   cd smart_eye
   ```
2. Tải các thư viện phụ thuộc:
   ```bash
   flutter pub get
   ```
3. Kiểm tra máy tính đã nhận diện điện thoại:
   ```bash
   flutter devices
   ```
4. Tiến hành chạy ứng dụng lên điện thoại:
   ```bash
   flutter run
   ```
5. Trên điện thoại, chọn **"Cho phép" (Allow)** khi được yêu cầu cấp quyền Camera.

---

## 🖥️ Hướng Dẫn Chạy Trên Máy Ảo Android Studio (Emulator)

Nếu không có điện thoại thật, bạn có thể chạy trên máy ảo Android Studio kết hợp Webcam máy tính.

### Bước 1: Cấu hình Webcam cho máy ảo
1. Mở **Android Studio** $\rightarrow$ **Device Manager**.
2. Nhấn vào biểu tượng ✏️ **Edit** bên cạnh máy ảo của bạn.
3. Chọn **Show Advanced Settings** $\rightarrow$ Kéo xuống mục **Camera**:
   - **Front**: Chọn `Webcam0`
   - **Back**: Chọn `Webcam0`
4. Nhấn **Finish** và bật máy ảo lên.

### Bước 2: Khởi chạy app
Mở terminal tại thư mục dự án và chạy:
```bash
flutter run
```

### 💡 Các Tiện Ích Hỗ Trợ Test Trên Màn Hình App:

- **🧪 Nút `Test UI` (Góc dưới bên phải)**:
  - Bấm nút này để kích hoạt chế độ **Giả lập** (lặp mỗi 8 giây, chạy qua đúng pipeline tracker → rules → giọng nói):
    1. Xe máy phía trước to dần → *"Dừng lại! Xe máy đang tới gần phía trước!"*
    2. Ghế ở giữa cách ~2m, người sát bên trái → *"Cẩn thận, ghế phía trước, cách khoảng 2 mét. Đi chếch sang phải."*
  - Không cần camera — nút cũng có ở màn hình loading nếu camera lỗi.
- **🔄 Xoay màn hình**: app tự xoay theo hướng điện thoại — preview, khung vật thể, 3 cột free-space và ảnh đưa vào AI xoay cùng nhau (tính từ góc cảm biến camera + hướng máy), không cần bấm nút.

---

## 🍎 Chạy Trên iPhone Từ Máy Windows

Apple không cho build app iOS trên Windows → build trên máy macOS của **GitHub Actions** (miễn phí vì repo public),
rồi cài từ Windows bằng **Sideloadly**.

### Bước 1: Lấy file `.ipa`
1. Push code lên `main` hoặc nhánh `feature/**` → workflow **"iOS build (IPA chưa ký)"** tự chạy (~10–15 phút, có thể lâu hơn nếu máy Mac của GitHub đang xếp hàng).
   Muốn chạy tay: tab **Actions** → chọn workflow → **Run workflow**. **Không bấm Re-run** khi đang chờ — sẽ phải xếp hàng lại từ đầu.
2. Build xong, file được đăng lên mục **Releases** của repo — **link cố định, không cần đăng nhập**:
   - Nhánh `main`: https://github.com/langvietthanh/smart-eye/releases/download/ios-latest-main/smart-eye-unsigned.ipa
   - Nhánh khác: thay `main` bằng tên nhánh, dấu `/` đổi thành `-` (VD `ios-latest-feature-ios-support`).

### Bước 2: Cài lên iPhone (Windows)
1. Cài **iTunes bản tải từ trang Apple** (không dùng bản Microsoft Store) để Windows nhận iPhone.
2. Cài **Sideloadly**, cắm iPhone, bấm **Tin cậy** trên iPhone.
3. Kéo file `.ipa` vào Sideloadly → nhập Apple ID → **Start**. Sideloadly ký và cài app.

### Bước 3: Trên iPhone (lần đầu)
1. **Bật Chế độ nhà phát triển** (iOS 16+): *Cài đặt → Quyền riêng tư & Bảo mật* → kéo xuống cuối, mục BẢO MẬT →
   **Chế độ nhà phát triển** → bật → máy khởi động lại → bấm **Bật** và nhập mật mã.
   Mục này chỉ xuất hiện **sau khi** đã cài app ở bước 2.
2. **Tin cậy nhà phát triển**: *Cài đặt → Cài đặt chung → Quản lý VPN & thiết bị* → chọn Apple ID → **Tin cậy**.
3. Mở app, cho phép **Camera** (và Vị trí nếu muốn lưu quãng đường).

### Lưu ý
- Apple ID miễn phí: app **hết hạn sau 7 ngày** → cắm máy, cài lại bằng Sideloadly.
- Bản cài là **release**: không có hot reload/log trực tiếp → phát triển & debug trên Android, iPhone để kiểm tra theo mốc.
- App phải **để mở trên màn hình** (iOS không cho chạy camera ở nền). App tự giữ màn hình sáng khi đang quét.
- Cảnh báo **vẫn đọc khi gạt nút im lặng**; nhạc đang phát tự nhỏ lại khi có cảnh báo.
- Nếu app báo **thiếu giọng tiếng Việt**: *Cài đặt → Trợ năng → Nội dung được đọc → Giọng nói → Tiếng Việt*.

### Danh sách kiểm tra trên iPhone
- [ ] Dòng thông số dưới màn hình có số ms và "max …%" thay đổi theo cảnh (AI đang chạy)
- [ ] Hướng camera vào người / ô tô → hiện khung, hình đứng thẳng
- [ ] Gạt nút im lặng → vẫn nghe cảnh báo
- [ ] Xoay ngang / dọc → khung vật vẫn khớp hình
- [ ] Để yên 1 phút → màn hình không tự khoá
- [ ] Chạm 2 lần → nghe mô tả xung quanh

---

## ⚙️ Thông Số Kỹ Thuật AI & Cấu Hình

- **Model AI**: YOLOv8 Nano (`yolov8n_int8.tflite`) - Kích thước ~3.5MB.
- **Tập dữ liệu**: COCO Dataset (80 lớp vật thể) — `assets/labels/coco.txt` khớp đúng tên nhãn nhúng trong model.
- **Input**: 320×320, layout **NCHW** `[1, 3, 320, 320]`, float32 — app **tự đọc** kích thước/layout/kiểu từ model, đổi model khác (640, NHWC, int8) không cần sửa code.
- **Ngưỡng confidence**: 0.25 (mặc định Ultralytics), chọn theo kết quả đo trên COCO128 bên dưới.
- **Yêu cầu Android**: SDK Minimum 21 (Android 5.0 trở lên).
- **Thư viện chính**:
  - `camera`: Truy cập luồng camera real-time.
  - `tflite_flutter`: Chạy mô hình TensorFLow Lite với gia tốc phần cứng.
  - `flutter_tts`: Chuyển văn bản thành giọng nói tiếng Việt.
  - `path_provider` + `image`: Lưu lịch sử & ảnh ghi nhớ on-device.
  - `geolocator`: GPS cho quãng đường chuyến đi (không bắt buộc — từ chối quyền vẫn chạy được).

### Chạy unit test
```bash
flutter test
```

### ⚡ Kiến trúc nhận diện (tối ưu tốc độ)

```
Camera (~30 fps) ─► Bộ điều phối nhịp quét ─(chỉ gửi khi cần)─► Isolate AI (luồng riêng)
   luồng UI            máy rảnh là quét; đứng yên thì giãn ra        tiền xử lý → model (CPU/GPU tự chọn)
                                                                  → giải mã (chỉ lớp liên quan) → NMS
        ◄──────────── danh sách vật (toạ độ chuẩn hoá) + thời gian từng bước ◄───────┘
```

| Kỹ thuật | Tác dụng |
|---|---|
| **Isolate AI riêng** | Luồng UI chỉ còn copy frame (~1 ms) → giao diện, nút bấm, giọng nói không giật |
| **Tự chọn CPU / GPU** (Android) · **CPU / Metal / CoreML** (iOS) | Lúc khởi động đo tốc độ từng cách, kiểm tra kết quả giống CPU, chọn cách nhanh nhất; GPU lỗi giữa chừng tự chuyển về CPU |
| **Chỉ xét lớp liên quan tới đi lại** | Bỏ cốc, dĩa, bàn chải… → giải mã ít phép tính hơn ~3 lần (15/80 lớp), **nhầm lớp giảm từ 17 → 2** trên COCO128 |
| **Quét liên tục, độ trễ thấp** | Máy rảnh là quét ngay (GPU ~11 lần/giây trên Samsung A05). *Tiết kiệm*: cảnh đứng yên 3 s và không có vật → 1 lần/giây, nhưng luồng camera vẫn so độ sáng **từng frame** — có chuyển động là quét ngay |
| **Vật gần báo ngay** | Vật cao ≥ 45% khung và điểm ≥ 0.4 được xác nhận ngay lần quét đầu (không chờ lần 2) — tiết kiệm 100–200 ms khi vật đang sát người |
| **Không cấp phát theo từng pixel** | Tiền xử lý không tạo đối tượng tạm cho mỗi điểm ảnh (bản cũ tạo ~100 000 đối tượng / frame) |

**Dòng chẩn đoán** (góc dưới màn hình) — ví dụ minh hoạ, số thật tuỳ máy:
`GPU · 62ms (ảnh 18 · AI 41) · 4.8 lần/s · Thường` / `2 vật · max người 50%`
= cách chạy · tổng thời gian (tiền xử lý · model · giải mã) · số lần quét mỗi giây · chế độ · vùng vừa quét.
Log `[Scan N] ...` mỗi 20 lần quét cho số liệu chi tiết (xem bằng `flutter run` hoặc Logcat).

### Đánh giá model (COCO128 hoặc dataset riêng)
```bash
pip install ai-edge-litert pillow numpy pyyaml
python tool/eval_model.py                                          # model của app trên COCO128
python tool/eval_model.py --model new.tflite --data datasets/smart_eye/data.yaml
```
Script tự tải COCO128 (128 ảnh COCO có nhãn chuẩn, ~7MB), chạy đúng pipeline của app, chỉ xét lớp liên quan tới đi lại,
và in recall theo từng lớp. Kết quả với model hiện tại (15 lớp liên quan):

| Ngưỡng conf | Precision | Recall | Recall vật lớn (≥5% khung) | Nhầm lớp |
|---|---|---|---|---|
| **0.25** | **0.82** | 0.40 | **0.81** | **2** |

(Trước khi lọc lớp, cùng ngưỡng 0.25: precision 0.83, recall vật lớn 0.72, nhầm lớp 17.)

### Thêm lớp mới (cầu thang, lan can, ổ gà, cột điện...)
Model COCO không có các lớp này — cần train thêm. Toàn bộ quy trình (danh sách lớp, cách chụp ảnh, quy tắc gán nhãn,
gán nhãn tự động, gộp dataset, notebook Google Colab, tiêu chí nhận model) ở **[training/README.md](training/README.md)**.
Model mới chỉ cần đặt tên `smart_eye.tflite` và chép vào `assets/models/` — app tự dùng, không cần sửa code.

### Lưu ý về model hiện tại & cách export lại (không bắt buộc)
- Model do Ultralytics ≥ 8.4 export lưu trọng số **ngoài flatbuffer** (buffer offset) → runtime TFLite trên Android
  báo `Input tensor N lacks data`. Đã xử lý bằng `python tool/inline_tflite_buffers.py <file.tflite>` (output giống hệt 100%).
  **Mỗi lần thay model mới phải chạy lại script này.**
- Model INT8 hiện tại bị hiệu chỉnh bằng 8 ảnh nên điểm tin cậy bị chặn trần ở 0.50 → đôi khi 2 lớp hoà điểm và app chọn nhầm lớp
  (~4% số phát hiện trên COCO128). Muốn tốt hơn thì export bản FP32. Export TFLite của Ultralytics chỉ chạy trên Linux/macOS,
  cách nhanh nhất là **Google Colab** (miễn phí, ~5 phút):
  ```python
  !pip install -q ultralytics
  from ultralytics import YOLO
  YOLO('yolov8n.pt').export(format='tflite', imgsz=320)   # tải file *_float32.tflite về
  ```
  Sau đó đổi tên thành `smart_eye.tflite`, chép vào `assets/models/`, chạy `tool/inline_tflite_buffers.py`, rồi `python tool/eval_model.py --model <file>` để so sánh. Notebook `training/smart_eye_train.ipynb` làm sẵn các bước này.

---

## 🛠️ Xử Lý Lỗi Thường Gặp (Troubleshooting)

- **Lỗi Java/Gradle build failed**: Đảm bảo project được mở từ đường dẫn thư mục **không có dấu tiếng Việt** (Ví dụ: `D:\Nam_4\smart_eye` thay vì `D:\Năm 4\...`).
- **Camera màn hình bị đen**: Vào Cài đặt trên điện thoại/máy ảo $\rightarrow$ Quyền ứng dụng (Permissions) $\rightarrow$ Bật quyền Camera cho Smart Eye.

