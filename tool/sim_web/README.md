# Smart Eye mô phỏng (không cần iPhone)

Chạy **code thật** của app (phân tích LiDAR, `WalkState` vòng qua vật có ghi
nhớ ARKit, chọn câu nói, `SpeechManager`) trên một lớp học ảo, trong trình
duyệt. Một iPhone ảo ray-cast ảnh độ sâu giống ARKit (256×192, kèm pose), người
ảo làm theo lời app: dừng, bước ngang, xoay, đi thẳng. Câu nói được đọc bằng
giọng của trình duyệt.

Không mô phỏng: YOLO (không có ảnh camera), MiDaS, rung, theo dõi tầm nhìn,
dẫn đường bằng giọng nói. `lib/sim_driver.dart` chép lại thứ tự xử lý LiDAR
của `CameraScreen`; sửa màn hình camera thì sửa cả ở đây.

```bash
cd tool/sim_web
flutter test          # các kịch bản chạy tự động
./build.sh            # ra build/web, đưa lên host tĩnh bất kỳ
python3 -m http.server -d build/web 8080   # chạy thử ở http://localhost:8080
```
