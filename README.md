# Smart Eye 👁️ – Hướng Dẫn Cài Đặt & Chạy Dự Án

**Smart Eye** là ứng dụng di động hỗ trợ người khiếm thị nhận diện vật thể thời gian thực (Real-time Object Detection) dựa trên mô hình **YOLOv8** nạp qua TFLite, tích hợp vẽ khung nhận diện (Bounding Box) và đọc cảnh báo bằng giọng nói tiếng Việt (TTS).

---

## 📋 Cấu Trúc Dự Án

```
smart_eye/
├── 📁 assets/
│   ├── 📁 models/yolov8n_int8.tflite   # Model YOLOv8 Quantized INT8
│   └── 📁 labels/coco.txt             # 80 nhãn vật thể chuẩn COCO
├── 📁 lib/
│   ├── 📄 main.dart                    # Khởi tạo ứng dụng & danh sách Camera
│   ├── 📁 models/Recognition.dart      # Data model vật thể nhận diện
│   ├── 📁 utils/image_utils.dart       # Converter YUV420 → RGB → Float32 & Xoay ảnh
│   ├── 📁 services/
│   │   ├── detector_service.dart       # YOLOv8 TFLite Engine & NMS & Dequantization
│   │   └── tts_service.dart            # Text-To-Speech đọc tiếng Việt chống lặp
│   ├── 📁 widgets/bounding_box_painter.dart # Cọ vẽ khung đỏ & nhãn vật thể
│   └── 📁 screens/camera_screen.dart   # Màn hình chính & xử lý luồng Camera
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
  - Bấm nút này để kích hoạt chế độ **Giả lập Cảnh báo**.
  - Hệ thống sẽ tự động vẽ một khung chữ nhật màu đỏ (xe ô tô 92%) và đọc câu thoại cảnh báo Tiếng Việt ra loa mà **không cần kết nối bất kỳ camera nào**.
- **🔄 Nút `Xoay AI: 90°`**:
  - Khi dùng Webcam máy tính hoặc iVCam hình ảnh bị nghiêng/nằm ngang, bấm nút này để xoay góc nhận diện AI (`0°` $\rightarrow$ `90°` $\rightarrow$ `180°` $\rightarrow$ `270°`) giúp AI đọc đúng vật thể.

---

## ⚙️ Thông Số Kỹ Thuật AI & Cấu Hình

- **Model AI**: YOLOv8 Nano (`yolov8n_int8.tflite`) - Kích thước ~3.5MB.
- **Tập dữ liệu**: COCO Dataset (80 lớp vật thể).
- **Input resolution**: $640 \times 640$ pixels.
- **Yêu cầu Android**: SDK Minimum 21 (Android 5.0 trở lên).
- **Thư viện chính**:
  - `camera`: Truy cập luồng camera real-time.
  - `tflite_flutter`: Chạy mô hình TensorFLow Lite với gia tốc phần cứng.
  - `flutter_tts`: Chuyển văn bản thành giọng nói tiếng Việt.

---

## 🛠️ Xử Lý Lỗi Thường Gặp (Troubleshooting)

- **Lỗi Java/Gradle build failed**: Đảm bảo project được mở từ đường dẫn thư mục **không có dấu tiếng Việt** (Ví dụ: `D:\Nam_4\smart_eye` thay vì `D:\Năm 4\...`).
- **Camera màn hình bị đen**: Vào Cài đặt trên điện thoại/máy ảo $\rightarrow$ Quyền ứng dụng (Permissions) $\rightarrow$ Bật quyền Camera cho Smart Eye.

