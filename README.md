# Smart Eye 👁️ – Hướng Dẫn Cài Đặt & Chạy Dự Án

**Smart Eye** là ứng dụng di động hỗ trợ người khiếm thị nhận diện vật thể thời gian thực (Real-time Object Detection) dựa trên mô hình **YOLOv8** nạp qua TFLite, tích hợp vẽ khung nhận diện (Bounding Box) và đọc cảnh báo bằng giọng nói tiếng Việt (TTS).

---

## 🧭 Chức Năng (theo `SMART-EYE-CHUC-NANG-TONG-HOP.md`)

| | Chức năng | Cài đặt trong code |
|---|---|---|
| F1 🔴 | Nhìn & nhận diện | YOLO + TFLite on-device trong isolate riêng; ưu tiên model v4 `smart_eye.tflite` (27 lớp, tên lớp trong metadata), thiếu thì dùng YOLOv8n COCO (`detector_service.dart`, `processing_worker.dart`) |
| F2 🔴 | Cảnh báo + chỉ hướng | Tracker IoU/centroid (CN5), rules engine (CN4), free-space 3 cột (CN6), khoảng cách theo % chiều cao box (CN7) |
| F3 🟠 | Mô tả + nói ra | Caption template (CN8), flutter_tts tiếng Việt (CN9), Speech Manager ưu tiên/barge-in/dedupe (CN10) — mặc định **chỉ mô tả khi được hỏi** |
| F4 🟡 | Lưu lịch sử | Event log JSONL (CN11), ảnh ghi nhớ thumbnail + GPS (CN12), recap template (CN13), tự dọn: tối đa 20 chuyến / 30 ngày / 40 ảnh mỗi chuyến |

**Nguyên tắc "nói ít, đúng lúc":** mỗi frame chỉ chọn 1 cảnh báo quan trọng nhất; vật xa phải xuất hiện ≥ 2 lần quét mới được báo (lọc báo nhầm), **vật gần + điểm cao báo ngay từ lần quét đầu**;
cùng 1 vật chỉ nhắc lại sau 6 giây (nguy hiểm) / 10 giây (chú ý) trừ khi mức nguy hiểm tăng; cảnh báo nguy hiểm ngắt lời mọi câu khác;
khi vật chiếm nhiều khung hình phía trước hoặc đang lớn nhanh sẽ nói **"Dừng lại"**, kèm tên vật và vị trí. Cảnh báo chú ý không chờ khoảng lặng 2 giây. App không suy diễn số mét hay lối đi an toàn từ chỗ chưa nhận diện được vật.

Đánh giá tốc độ, RAM, dung lượng và giới hạn hiện tại: [APP-PROCESSING-ASSESSMENT.md](APP-PROCESSING-ASSESSMENT.md).

### Cách dùng trên màn hình chính
- Nút **Xung quanh** (hoặc nói *"xung quanh"*): nghe mô tả xung quanh (F3 on-demand).
- **Chạm 2 lần** (hoặc giữ lâu) **vào màn hình**: app nói *"Đang nghe. Hãy nói đích đến."*, rung một cái và hiện khung xanh **Đang nghe…**; nói lệnh ngay sau tiếng rung (rung nhẹ lần nữa khi ngừng nghe) — *"đi đến ghế"* (hoặc vật khác model đang nhận ra), *"xung quanh"*, *"tóm tắt"*, *"dừng"*. Khi dẫn đường, app nói *"Đang tìm ghế. Xoay người chậm."*, thấy thì *"Thấy ghế ở hướng 1 giờ, còn xa."*, đi lệch thì *"Lệch trái"/"Lệch phải"*, tới nơi thì *"Đã tới. Ghế ngay trước mặt. Dò bằng gậy."* Cảnh báo nguy hiểm luôn được nói trước lời dẫn. Cần quyền micro.
- Nút **Tóm tắt**: nghe tóm tắt chuyến đi hiện tại.
- Nút **Lịch sử**: danh sách chuyến đi, nghe tóm tắt, xem ảnh ghi nhớ, nghe lại toàn bộ.
- Chip **Mô tả khi hỏi / Tự mô tả**: bật tự mô tả tần suất thấp (~45 giây, chỉ khi không có cảnh báo gần đây).
- **Rung liên tục kiểu cảm biến lùi xe**: có vật trong lối đi phía trước thì máy rung, vật càng gần rung càng dày. Không rung chỉ có nghĩa là không *nhận ra* vật nào, không chứng minh đường trống.
- **Báo khi 3 hướng bị chặn**: phía trước, bên trái và bên phải đều có vật cản (YOLO hoặc LiDAR ≤ 1,5 m) liên tục 1 giây → nói một lần *"Dừng lại! Vật cản ngay trước mặt. Hai bên có vật cản."* (không nói lại nếu cảnh báo vật cản vừa nói câu đó); tường chạy dọc lối đi hẹp không bị tính là chặn phía trước; trong lúc đó tạm im cảnh báo chú ý và cảnh báo độ sâu. Phía trước thông lại 1 giây → *"Đi thẳng."*. Khi phía trước thông liên tục 1 giây (LiDAR không thấy vật trong 2,2 m, YOLO không thấy vật ở cột giữa) app nói *"Đi thẳng."*, rồi nhắc lại mỗi 3 giây khi vẫn thông (mức ưu tiên thấp nhất của cảnh báo, không nói khi đang dẫn đường hay đang đọc câu khác) (`path_blockage.dart`).
- **Báo khi app không nhìn được**: camera/AI ngừng trả kết quả quá 1,5 giây, phòng quá tối hoặc camera bị che → nói "Dừng lại!" và rung dài; máy chĩa xuống sàn / lên trần → cảnh báo "Dừng lại! Máy đang chĩa xuống sàn..." / "...chĩa lên cao...".
- **Thấy vật cản không có tên** (tường, cửa, tủ, thùng đồ): model độ sâu MiDaS v2.1 small chạy song song với YOLO (~3 lần/giây). So độ gần của vùng phía trước ngang ngực với mảng sàn ngay trước chân; gần bằng nhau thì báo *"Dừng lại! Vật cản ngay trước mặt."* Độ sâu là tương đối, không phải mét.
- **Bậc lên / bậc xuống** (bục giảng, bậc cửa, mép bục): từ cùng ảnh độ sâu, so profile sàn ở giữa khung hình với một mặt phẳng; mặt nhô lên = bậc lên, tụt xuống = bậc xuống. Báo *"Chú ý, phía trước có bậc lên"* → *"Dừng lại! Bậc lên ngay phía trước. Dò bằng gậy."*; bậc xuống luôn *"Dừng lại!"*; rung 2 nhịp. Bậc thấp dưới ~10 cm có thể bị bỏ sót; khi đã sát chân, bậc ra khỏi khung hình.
- Thử nghiệm trong phòng: xem [INDOOR-TEST-PROTOCOL.md](INDOOR-TEST-PROTOCOL.md).

---

## 📋 Cấu Trúc Dự Án

```
smart_eye/
├── 📁 assets/
│   ├── 📁 models/yolov8n_int8.tflite   # Model YOLOv8 Quantized INT8
│   │   └── midas_small.tflite        # MiDaS v2.1 small (MIT, isl-org/MiDaS), trọng số fp16 (tool/tflite_fp16_weights.py), 256×256
│   └── 📁 labels/coco.txt             # 80 nhãn vật thể chuẩn COCO
├── 📁 lib/
│   ├── 📄 main.dart                    # Khởi tạo ứng dụng
│   ├── 📁 models/
│   │   ├── Recognition.dart            # Kết quả nhận diện 1 frame
│   │   ├── tracked_object.dart         # Vật được theo dõi qua nhiều frame
│   │   ├── scene_info.dart             # Vị trí, khoảng cách, mức cảnh báo, kết quả đánh giá
│   │   └── trip.dart                   # Sự kiện & tóm tắt chuyến đi
│   ├── 📁 utils/
│   │   ├── image_utils.dart            # Lấy mẫu frame (YUV/BGRA/NV12) → tensor, cắt vùng, JPEG, chữ ký độ sáng
│   │   └── label_catalog.dart          # Nhãn tiếng Việt + phân loại nguy hiểm (khớp training/classes.yaml)
│   ├── 📁 services/
│   │   ├── detector_service.dart       # F1: chọn model (v4 27 lớp hoặc YOLOv8n), chạy trong isolate AI
│   │   ├── processing_worker.dart      # Isolate sống lâu, mỗi lần một frame
│   │   ├── 📁 detection/
│   │   │   └── model_metadata.dart     # Đọc tên lớp / kích thước ảnh nhúng trong model
│   │   ├── path_blockage.dart          # Phát hiện 3 hướng bị chặn / đường thông lại
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
├── 📁 test/                            # Unit test: rules, tracker, xử lý ảnh, metadata model, LiDAR, 3 hướng bị chặn, danh sách lớp
└── 📄 pubspec.yaml
```

---

## 🚀 Hướng Dẫn Chạy Trên Thiết Bị Android Thật (Khuyên Dùng)

Nên chạy trên thiết bị Android thật để kiểm tra độ trễ nhận diện, góc dọc camera và âm thanh qua loa điện thoại. App lấy mẫu AI cách nhau ít nhất **150 ms** (trần khoảng **6,7 frame/giây**, tốc độ thực tế phụ thuộc máy); tốc độ preview camera độc lập với tốc độ chạy AI.

### Bước 1: Chuẩn bị điện thoại
1. Vào **Cài đặt** (Settings) trên điện thoại Android $\rightarrow$ **Thông tin điện thoại** (About Phone).
2. Nhấn 7 lần vào **Số phiên bản** (Build Number) để bật *Tùy chọn nhà phát triển*.
3. Vào **Tùy chọn nhà phát triển** (Developer Options) $\rightarrow$ Bật **Gỡ lỗi USB** (USB Debugging).
4. Dùng cáp USB cắm điện thoại vào máy tính.

### Bước 2: Clone & Chạy lệnh
1. Cài **Git LFS** trước (model độ sâu `midas_small.tflite` 33 MB lưu bằng LFS; thiếu LFS thì file chỉ là con trỏ vài dòng và app báo không tải được cảm biến độ sâu):
   ```bash
   brew install git-lfs   # Windows: tải tại https://git-lfs.com
   git lfs install
   ```
   Clone trước khi cài LFS thì chạy thêm `git lfs pull` trong thư mục dự án.
2. Mở Terminal / PowerShell tại thư mục muốn lưu dự án và gõ:
   ```bash
   git clone <link_repository_of_project>
   cd smart_eye
   ```
3. Tải các thư viện phụ thuộc:
   ```bash
   flutter pub get
   ```
4. Kiểm tra máy tính đã nhận diện điện thoại:
   ```bash
   flutter devices
   ```
5. Tiến hành chạy ứng dụng lên điện thoại:
   ```bash
   flutter run
   ```
6. Trên điện thoại, chọn **"Cho phép" (Allow)** khi được yêu cầu cấp quyền Camera.

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

- **🧪 Nút `Test UI` trên màn hình lỗi camera/loading khi model đã sẵn sàng**:
  - Bấm nút này để kích hoạt chế độ **Giả lập** (lặp mỗi 8 giây, chạy qua đúng pipeline tracker → rules → giọng nói):
    1. Xe máy phía trước to dần → *"Dừng lại! Có xe máy ngay phía trước."*
    2. Ghế ở giữa, người sát bên trái → *"Chậm lại. Có ghế ngay phía trước."*
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
- [ ] Hình camera và khung nhận diện tiếp tục cập nhật sau 10 lần về màn hình chính rồi quay lại
- [ ] Với bản debug/profile: chỉ số FPS, ms/p95 và RSS cập nhật; bản release ẩn thông số kỹ thuật
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

### Luồng xử lý thời gian thực
- Một isolate sống xuyên suốt phiên nhận diện giữ model, chuyển ảnh, chạy TFLite và lọc box; luồng giao diện chỉ nhận kết quả.
- Chỉ xử lý một frame tại một thời điểm, không xếp hàng frame cũ. Bộ đệm tensor được tái sử dụng; ảnh JPEG ghi nhớ được mã hóa ở isolate riêng khi cần.
- Chỉ cập nhật lớp khung nhận diện khi có kết quả; không rebuild cả màn hình camera mỗi frame.
- Luồng ảnh được dừng trước khi hủy camera khi app ra nền, mở lịch sử hoặc bật giả lập. Khi quay lại, camera và preview được tạo mới. Nếu luồng im lặng 4 giây, app thử mở lại một lần rồi hiện lỗi có nút thử lại.
- Kết quả đang chạy bị bỏ nếu camera, hướng máy hoặc màn hình đã thay đổi. Cảnh quá 750 ms kể từ lúc nhận frame được xóa, kể cả khi AI không trả thêm kết quả; cảnh báo đang chờ được cập nhật theo vật và mức nguy hiểm hiện tại.
- Bản debug/profile hiển thị FPS hoàn tất xử lý, độ trễ nhận kết quả trung bình/p95 của tối đa 120 mẫu và RSS. Độ trễ này chưa gồm camera thu ảnh, dựng giao diện hoặc âm thanh TTS thực sự phát ra.
- Các test bao phủ chuyển màu/quantization, giao tiếp isolate và đóng tài nguyên, vòng đời camera, tracker và thứ tự ngắt/phát giọng nói.

Kiểm tra trên điện thoại bằng `flutter run --profile`: xoay máy khi đang nhận diện, ra nền rồi quay lại nhiều lần, mở/đóng lịch sử và yêu cầu mô tả lúc có cảnh báo. Dùng Flutter DevTools để đo độ trễ/khung hình; unit test trên máy tính không thay thế phép đo hiệu năng hay kiểm tra delegate TFLite trên Android/iOS.

### Đánh giá model trên COCO (COCO128)
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

