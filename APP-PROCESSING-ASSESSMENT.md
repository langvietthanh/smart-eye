# Đánh giá xử lý Smart Eye — 18/10/2026

## Nhận xét hiện tại

App đã có pipeline chạy trên thiết bị, tách xử lý AI khỏi luồng giao diện, không xếp hàng frame cũ và tái sử dụng bộ đệm. Đây là nền tảng phù hợp cho ứng dụng hỗ trợ nhận biết vật thể. Tuy nhiên, chất lượng model và cách suy luận từ ảnh 2D vẫn giới hạn độ tin cậy: app chưa đo được khoảng cách theo mét, chưa xác định được một lối đi thực sự an toàn, và chưa được kiểm chứng hiệu năng trên điện thoại trong lượt sửa này.

Không thêm dataset hoặc thay model. Các số precision/recall trên COCO128 đã ghi trong README là kết quả cũ của dự án, không phải phép đánh giá mới và không chứng minh độ chính xác của cảnh báo khi đi đường.

## Vấn đề đã xử lý trong mã

| Vấn đề | Thay đổi và giới hạn |
|---|---|
| Về màn hình chính rồi vào lại mất camera | Dừng subscription ảnh trước khi dispose controller; tuần tự hóa đóng/mở; tìm lại camera sau mỗi lần mở; ưu tiên camera sau; preview có key theo controller mới. Tự thử lại một lần nếu luồng ảnh im lặng 4 giây, sau đó hiện nút thử lại. Kiểm thử bằng camera platform giả; cần xác nhận trên máy từng bị lỗi. |
| Báo dừng quá muộn | Giảm khoảng lấy mẫu từ 250 xuống 150 ms; cho phép xác nhận vật lớn chắn phía trước sau 2 frame liên tiếp đều đạt confidence ≥ 0.4. Dùng box quan sát mới nhất để đánh giá thay vì chờ box làm mượt. |
| Chỉ cảnh báo khi đã chiếm quá nhiều khung hình | Nhắc chú ý từ mức trung bình; xét diễn biến kích thước qua ít nhất 3 mẫu, kể cả khi người dùng tiến về vật đứng yên. Có thể báo dừng trước ngưỡng gần nếu tốc độ tăng kích thước dự báo vượt ngưỡng hình ảnh trong 0,8 giây. Đây không phải thời gian tới va chạm. |
| Câu báo mơ hồ, khoảng cách không đúng | Câu báo gồm hành động, vật và phía: “Dừng lại! Ghế ngay phía trước.” Bỏ khẳng định “2 mét” và chỉ dẫn đi về phía trống chưa được xác minh. Mức gần chỉ mang tính tương đối. |
| Giọng cảnh báo phải chờ | Caution bỏ thời gian đợi im lặng 2 giây, vẫn đợi native TTS hoàn tất lệnh stop để tránh câu mới bị lệnh stop cũ hủy. Xóa lời đang chờ khi vật hoặc mức nguy hiểm đổi. |
| Cảnh cũ còn được dùng lúc AI chậm | Bỏ kết quả quá 750 ms; bộ hẹn giờ độc lập xóa cảnh sau tuổi này kể cả khi AI chưa trả thêm frame. Không phát cảnh báo mới từ track vừa mất quan sát. |

Các ngưỡng kích thước hiện tại là heuristic: vào mức gần ở 45%, mức trung bình ở 20%, có hysteresis. Vật thấp và rộng ở phần dưới ảnh được xét thêm chiều rộng. Lịch sử biến đổi kích thước tách khỏi điều kiện vị trí để việc dịch chuyển box xuống dưới không tự biến thành “đang gần hơn”. Biển báo và đèn giao thông không mặc nhiên là vật cản lối đi. Các ngưỡng cần thử nghiệm thực địa; kích thước vật thật, góc cầm máy, cắt mất box và rung máy vẫn có thể gây báo nhầm hoặc bỏ sót.

## Tốc độ và tải xử lý

- Trần lấy mẫu AI: khoảng **6,7 lần/giây** theo khoảng tối thiểu 150 ms. Chỉ chạy một frame mỗi lúc. Đây là giới hạn cấu hình, không phải FPS đã đo trên điện thoại.
- Với nhịp lý tưởng, thời gian từ quan sát đầu đến lần xác nhận thứ ba giảm từ **500 xuống 300 ms**; trường hợp xác nhận sớm hai frame là **150 ms**. Các số này chưa gồm chờ frame đầu, xử lý model, lập lịch và TTS.
- Native interpreter yêu cầu 4 luồng; có đường thử delegate và fallback CPU. Chạy trong isolate giúp giao diện không bị chặn, nhưng không loại bỏ chi phí CPU, nhiệt và pin.
- Nâng trần lấy mẫu từ 4 lên 6,7 làm số lượt AI có thể tăng khoảng 67% khi máy đủ nhanh. Vì vậy không thể kết luận lượt sửa cảnh báo này tiết kiệm pin hơn chỉ từ việc tối ưu chuyển ảnh.
- Có thống kê từng công đoạn: tiền xử lý, copy input, inference, hậu xử lý, toàn bộ worker, gửi/nhận kết quả và chênh lệch lập lịch. Mỗi cửa sổ giữ tối đa 120 mẫu; không tích lũy vô hạn.
- Overlay debug/profile hiển thị FPS hoàn tất, độ trễ nhận kết quả trung bình/p95, lần inference gần nhất và RSS. Thời gian nhận kết quả tính từ `DetectorService.detect` đến lúc trả về; chưa bao gồm thu ảnh camera, tracker, paint hay lúc loa phát âm. FPS này cũng có thể bao gồm kết quả sau đó bị màn hình loại vì quá tuổi.

### Đo tiền xử lý trên máy phát triển

Phép đo dùng khung tổng hợp 640×480, xoay 90°, chuyển sang float32 NCHW 320×320; kiểm tra byte đầu ra giống bản gốc `0de7995`. Mỗi định dạng làm nóng 30 lượt rồi đo 3 lượt × 100 frame, lấy trung vị thời gian trung bình mỗi lượt. Đây là Flutter test/JIT trên Windows, chỉ đo chuyển ảnh, không chạy TFLite native hay TTS. Không tải dataset.

| Định dạng | Bản gốc | Đã tối ưu | Giảm thời gian chuyển ảnh |
|---|---:|---:|---:|
| YUV420 | 10,822 ms/frame | 8,489 ms/frame | 21,6% |
| BGRA | 4,845 ms/frame | 3,377 ms/frame | 30,3% |

Đo ngày 18/10/2026; cả hai bài đo đạt kiểm tra đầu ra tương đương. Không dùng benchmark này để suy ra FPS toàn app hoặc phần trăm tiết kiệm pin trên Android/iOS. Lần đo khác có thể dao động theo tải máy và JIT.

## RAM và dung lượng lưu trữ

| Thành phần | Số liệu / phạm vi |
|---|---|
| File model đang có | **3.465.959 byte ≈ 3,31 MiB**, đo trực tiếp từ asset. Đây không phải kích thước APK/IPA. |
| Input model | float32 `[1,3,320,320]`: **1.228.800 byte ≈ 1,17 MiB**. Bộ đệm Dart tái sử dụng và tensor input native là hai vùng riêng. |
| Output model | float32 `[1,84,2100]`: **705.600 byte ≈ 0,67 MiB**. Tên file có `int8` nhưng input/output thực tế là float32. |
| Cộng ba vùng I/O trên | Khoảng **3,02 MiB**; chưa gồm trọng số, tensor trung gian, delegate, camera, Flutter/Dart VM, bản sao tạm và JPEG. **Không phải tổng RAM app.** |
| Một ảnh camera 640×480, ví dụ | YUV420 đóng gói lý tưởng ≈ 0,44 MiB; BGRA ≈ 1,17 MiB. Thực tế phụ thuộc độ phân giải và stride thiết bị, số buffer native và bản sao truyền isolate. |
| Lịch sử | Dọn khi bắt đầu chuyến mới: tối đa 20 chuyến, loại chuyến hơn 30 ngày, tối đa 40 ảnh/chuyến. Bình thường tối đa 800 ảnh sau dọn thành công. Thumbnail cạnh dài 320 px, JPEG quality 70; dung lượng mỗi ảnh tùy cảnh. |
| JSONL | Chưa có hạn mức byte cho một chuyến dài; danh sách sự kiện khi mở lịch sử được nạp vào RAM. Đây là điểm cần theo dõi nếu dùng liên tục nhiều giờ/ngày. |

Chưa có điện thoại Android kết nối khi kiểm tra ADB. Vì vậy **chưa đo được** tổng RSS/PSS ổn định, CPU%, FPS thực tế, độ trễ đầu-cuối đến âm thanh, hao pin, nhiệt và dung lượng bản cài mới. Không thay các số này bằng kích thước model hoặc bộ đệm. RSS trong overlay là RAM tiến trình do hệ điều hành báo; không đồng nhất với PSS hoặc heap Dart.

## Kiểm chứng và bước đo trên máy thật

- **87 test đạt** bằng `flutter test --no-pub`: bao gồm 8 tình huống camera platform/preview, cảnh báo sớm, mất quan sát, thay đổi mức cảnh báo/vị trí khi native stop đang chờ, hết hạn cảnh và cửa sổ số liệu hiệu năng.
- `flutter analyze --no-pub --no-fatal-infos`: không có error/warning; còn 1 info có sẵn về tên `Recognition.dart`.
- Test camera xác nhận thứ tự stop stream → dispose → create, đổi preview và nhận frame từ controller mới. Đây là kiểm tra logic với platform giả, không phải kiểm thử camera vật lý.

Trên điện thoại đã gặp lỗi, chạy bản mới bằng `flutter run --profile` và ghi lại:

1. Model máy, hệ điều hành, loại build; làm nóng 30 giây, đo liên tục ít nhất 10 phút ở cảnh trong nhà và ngoài trời. Theo dõi FPS, mean/p95, RSS và biểu đồ CPU/memory; so sánh đầu và cuối để thấy tăng RAM hoặc giảm tốc do nhiệt.
2. Về màn hình chính rồi vào lại 10 lần, gồm lần quay lại ngay và sau 30 giây; xoay máy, mở/đóng lịch sử. Xác nhận preview và frame AI đều tiếp tục cập nhật.
3. Cho người hỗ trợ bố trí vật cố định rồi tiến lại từ xa, thử giữa/trái/phải, vật thấp/rộng và ánh sáng yếu. Ghi khoảng cách thật bằng thước để đánh giá thời điểm báo; app vẫn không công bố mét khi chưa có cơ chế đo/calibration.
4. Ghi cả lần báo sai, bỏ sót và thời điểm âm thanh bắt đầu. Chỉ số ms trên overlay chưa đo thời gian TTS này. Không dùng riêng số test hoặc benchmark chuyển ảnh để xác nhận khả năng dẫn đường.

Ưu tiên tiếp theo dựa trên kết quả đo là hiệu chỉnh ngưỡng theo máy/cách cầm, giới hạn dung lượng log cho chuyến dài và điều chỉnh nhịp AI theo tải/nhiệt. Model COCO hiện tại không có mọi loại nguy hiểm đường đi, chẳng hạn ổ gà; có luật trong code không đồng nghĩa model nhận diện được chúng.
