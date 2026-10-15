# Smart Eye 👁️ – Hướng Dẫn Cài Đặt & Chạy Dự Án

**Smart Eye** là ứng dụng di động hỗ trợ người khiếm thị nhận diện vật thể thời gian thực (Real-time Object Detection) dựa trên mô hình **YOLOv8** nạp qua TFLite, tích hợp vẽ khung nhận diện (Bounding Box) và đọc cảnh báo bằng giọng nói tiếng Việt (TTS).

---

## 🧭 Chức Năng (theo `SMART-EYE-CHUC-NANG-TONG-HOP.md`)

| | Chức năng | Cài đặt trong code |
|---|---|---|
| F1 🔴 | Nhìn & nhận diện | YOLOv8n INT8 + TFLite on-device (`detector_service.dart`) |
| F2 🔴 | Cảnh báo + chỉ hướng | Tracker IoU/centroid (CN5), rules engine (CN4), free-space 3 cột (CN6), khoảng cách theo % chiều cao box (CN7) |
| F3 🟠 | Mô tả + nói ra | Caption template (CN8), flutter_tts tiếng Việt (CN9), Speech Manager ưu tiên/barge-in/dedupe (CN10) — mặc định **chỉ mô tả khi được hỏi** |
| F4 🟡 | Lưu lịch sử | Event log JSONL (CN11), ảnh ghi nhớ thumbnail + GPS (CN12), recap template (CN13), tự dọn: tối đa 20 chuyến / 30 ngày / 40 ảnh mỗi chuyến |

**Nguyên tắc "nói ít, đúng lúc":** mỗi frame chỉ chọn 1 cảnh báo quan trọng nhất; vật phải xuất hiện ≥ 3 frame mới được báo;
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
│   ├── 📁 models/yolov8n_int8.tflite   # Model YOLOv8 Quantized INT8
│   └── 📁 labels/coco.txt             # 80 nhãn vật thể chuẩn COCO
├── 📁 lib/
│   ├── 📄 main.dart                    # Khởi tạo ứng dụng & danh sách Camera
│   ├── 📁 models/
│   │   ├── Recognition.dart            # Kết quả nhận diện 1 frame
│   │   ├── tracked_object.dart         # Vật được theo dõi qua nhiều frame
│   │   ├── scene_info.dart             # Vị trí, khoảng cách, mức cảnh báo, kết quả đánh giá
│   │   └── trip.dart                   # Sự kiện & tóm tắt chuyến đi
│   ├── 📁 utils/
│   │   ├── image_utils.dart            # YUV420 → RGB → Float32, xoay ảnh, thumbnail JPEG
│   │   └── label_catalog.dart          # Nhãn tiếng Việt + phân loại nguy hiểm
│   ├── 📁 services/
│   │   ├── detector_service.dart       # F1: YOLOv8 TFLite Engine & NMS & Dequantization
│   │   ├── object_tracker.dart         # F2/CN5: Tracker IoU + centroid
│   │   ├── hazard_engine.dart          # F2/CN4+CN6+CN7: Rules, free-space, khoảng cách
│   │   ├── caption_builder.dart        # F3/CN8 + F4/CN13: Câu mô tả & recap
│   │   ├── tts_service.dart            # F3/CN9: flutter_tts tiếng Việt
│   │   ├── speech_manager.dart         # F3/CN10: Ưu tiên, barge-in, dedupe
│   │   ├── history_service.dart        # F4/CN11+CN12: Lưu JSONL + ảnh, tự dọn dẹp
│   │   └── location_service.dart       # F4: GPS, quãng đường
│   ├── 📁 widgets/bounding_box_painter.dart # Khung màu theo mức nguy hiểm + lưới 3 cột
│   └── 📁 screens/
│       ├── camera_screen.dart          # Màn hình chính & pipeline mỗi frame
│       ├── history_screen.dart         # Danh sách chuyến đi
│       └── trip_detail_screen.dart     # Dòng thời gian, ảnh ghi nhớ, nghe lại
├── 📁 test/logic_test.dart             # Unit test tracker / rules / caption / recap
└── 📄 pubspec.yaml                     # Khai báo thư viện & assets
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

### Đánh giá model trên COCO (COCO128)
```bash
pip install ai-edge-litert pillow numpy
python tool/eval_coco.py
```
Script tự tải COCO128 (128 ảnh COCO có nhãn chuẩn, ~7MB) và chạy đúng pipeline của app. Kết quả với model hiện tại:

| Ngưỡng conf | Precision | Recall | Box sai | Recall vật lớn (≥5% khung) |
|---|---|---|---|---|
| 0.15 (cũ) | 0.71 | 0.39 | 149 | 0.73 |
| **0.25 (mới)** | **0.83** | 0.34 | **64** | **0.72** |
| 0.35 | 0.88 | 0.29 | 35 | 0.66 |

Recall tổng thấp vì COCO có nhiều vật rất nhỏ và model chạy ở 320px; với vật lớn (thứ quan trọng khi đi đường) recall ~0.72.

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
  Sau đó chép vào `assets/models/yolov8n_int8.tflite` (hoặc đổi `_modelPath`), chạy `tool/inline_tflite_buffers.py`, rồi `python tool/eval_coco.py` để so sánh.

---

## 🛠️ Xử Lý Lỗi Thường Gặp (Troubleshooting)

- **Lỗi Java/Gradle build failed**: Đảm bảo project được mở từ đường dẫn thư mục **không có dấu tiếng Việt** (Ví dụ: `D:\Nam_4\smart_eye` thay vì `D:\Năm 4\...`).
- **Camera màn hình bị đen**: Vào Cài đặt trên điện thoại/máy ảo $\rightarrow$ Quyền ứng dụng (Permissions) $\rightarrow$ Bật quyền Camera cho Smart Eye.

