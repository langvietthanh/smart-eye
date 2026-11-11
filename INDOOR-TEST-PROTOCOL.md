# Thử nghiệm đi trong phòng nhiều vật cản

Mục tiêu: đo xem app báo **kịp** và **không bỏ sót** khi người dùng nhắm mắt đi trong phòng. App chỉ hỗ trợ, **luôn dùng kèm gậy dò đường** và luôn có người đi kèm khi thử.

## Chuẩn bị an toàn
- Vật cản mềm hoặc nhẹ: thùng carton, gối, ghế nhựa. Không dùng kính, vật sắc cạnh, cầu thang.
- Một người quan sát đi cạnh, có quyền hô "Dừng" bất cứ lúc nào.
- Dán vạch trên sàn mỗi 0,5 m dọc lối đi để đọc khoảng cách lúc app báo.
- Build `flutter run --profile` trên máy thật, ghi tên máy và hệ điều hành.

## Kịch bản (mỗi kịch bản 5 lần)
| # | Bố trí | Ghi lại |
|---|---|---|
| 1 | Ghế ở giữa lối đi, tiến thẳng tới | Khoảng cách lúc bắt đầu rung, lúc nói "Chậm lại", lúc nói "Dừng lại" |
| 2 | Ghế lệch trái / lệch phải | App có nói đúng phía không |
| 3 | Bàn thấp và rộng (bàn trà) | Có báo không, báo ở khoảng cách nào |
| 4 | Thùng carton, ba lô dưới sàn | COCO không nhận ra; chỉ model độ sâu báo *"Vật cản ngay trước mặt"*. Ghi khoảng cách lúc báo |
| 5 | Đi thẳng vào tường hoặc cửa | Chỉ model độ sâu báo. Ghi khoảng cách lúc rung đầu tiên và lúc *"Dừng lại"* |
| 5b | **Bậc bục giảng**: đi tới bục cao 15–20 cm (có tường/bảng phía sau), rồi đứng trên bục đi về mép | Bậc lên: khoảng cách lúc nói *"Chú ý, phía trước có bậc lên"* và *"Dừng lại! Bậc lên ngay phía trước"*. Mép bục: khoảng cách lúc nói *"Dừng lại! Có bậc xuống phía trước"*. Thử cả bậc thấp ~10 cm (dự kiến bỏ sót) |
| 6 | Tắt đèn phòng | Có nói "Quá tối" trong ~1 giây không |
| 7 | Lấy tay che camera | Có nói "Quá tối" hoặc "Camera không hoạt động" không |
| 8 | Cầm máy chĩa xuống sàn, rồi chĩa lên trần | Có cảnh báo "Dừng lại! Máy đang chĩa xuống sàn..." / "...chĩa lên cao..." không |
| 9 | Phòng có 4–6 vật, đi từ cửa tới đích | Số lần va chạm (người quan sát chặn trước), số lần báo nhầm |
| 10 | **Bên trống (chỉ iPhone có LiDAR)**: ghế chắn lối đi giữa hai dãy bàn, đứng cách ~2 m | Câu nghe được (mong đợi *"…Hai bên có vật cản."*) và đuôi `trống:` trên dòng LiDAR |
| 11 | Ghế cuối dãy bàn, phía bên kia trống, đứng cách ~2 m | Mong đợi *"Chậm lại. Vật cản cách 2 mét. Đi chéo sang X."* về phía trống; ghi bên nào và có đúng không |
| 12 | Hành lang: ba lô hoặc một bạn đứng giữa, đứng cách ~2 m | Mong đợi *"…Đi chéo sang phải."* (hai bên trống thì luôn chọn phải) |
| 13 | Đi về phía bục giảng, bục nằm lệch một bên | Cảnh báo bậc lên vẫn có; app **không bao giờ** bảo đi chéo về phía có bục |

## Dẫn đường bằng giọng nói (mỗi kịch bản 5 lần)
Giữ lâu màn hình, nghe "tít" rồi nói *"đi đến ghế"*. Ghi câu nghe được và có tới trước ghế không.

| # | Bố trí | Câu mong đợi |
|---|---|---|
| D1 | Ghế cách ~4 m, lệch phải | *"Đang tìm ghế…"* → *"Thấy ghế ở hướng 1 giờ, còn xa."* → *"Lệch phải."* tới khi xoay đúng → *"Thẳng rồi."* → *"Gần hơn rồi."* / *"Sắp tới."* → *"Đã tới. Ghế ngay trước mặt. Dò bằng gậy."*. Câu cảnh báo xen vào về chính ghế (xem dưới bảng) thì ghi lại, không tính là trượt |
| D2 | Đang dẫn, một bạn đi ngang che ghế | Không nói gì trong ~1,5 giây; che lâu hơn → *"Mất dấu ghế. Đứng yên, xoay người chậm."*; thấy lại → *"Thấy lại ghế, …"* |
| D3 | Đi sát tới khi ghế tụt khỏi đáy khung | *"Ghế ngay trước mặt, rất gần. Dò bằng gậy."* (không báo mất dấu) |
| D4 | Thùng carton chắn giữa đường tới ghế | Cảnh báo vật cản thùng vẫn được nói và ngắt lời dẫn; ghế (đích) không bị model nhận dạng báo *"Dừng lại! Có ghế…"* chỉ vì đang đi tới nó. Câu LiDAR / độ sâu về ghế (xem dưới bảng) thì ghi lại, không tính là trượt |
| D5 | Nói *"đi đến cửa"* (model chưa có lớp cửa) | *"Chưa nhận ra được cửa. Có thể tìm: …"* và không bắt đầu dẫn |

Cảnh báo về ghế đích vẫn có thể xuất hiện (D1, D4) — ghi lại câu và khoảng cách, **không** đánh trượt kịch bản:
- Máy có LiDAR: LiDAR không biết vật nào là đích, nên có thể nói câu *"Chậm lại. Vật cản cách 2 mét…"* khi còn ~2 m và *"Dừng lại!…"* khi dưới 1 m.
- Model độ sâu (MiDaS) có thể nói *"Vật cản ngay trước mặt"* khi tới sát ghế.

Thêm: nói *"dừng"* giữa chừng → *"Đã dừng dẫn đường."*; không nói gì → *"Không nghe rõ. Giữ lâu để nói lại."*

## Bảng ghi
`ngày · máy · kịch bản · lần · khoảng cách rung đầu tiên (m) · khoảng cách "Dừng lại" (m) · bỏ sót? · báo nhầm? · ghi chú`

## Tiêu chí đạt (đề xuất, chỉnh sau lần đo đầu)
- Kịch bản 1–3: "Dừng lại" ở ≥ 1,0 m với tốc độ đi chậm, 5/5 lần.
- Kịch bản 6–8: cảnh báo trong ≤ 2 giây, 5/5 lần.
- Kịch bản 4–5: "Dừng lại" ở ≥ 1,0 m, 4/5 lần.
- Kịch bản 5b: báo bậc (lên hoặc xuống) trước ≥ 1,0 m, 4/5 lần; ghi riêng số lần báo nhầm "bậc" trên sàn phẳng có thảm hoặc vạch kẻ. Độ sâu chỉ là tương đối nên đây là kịch bản cần chỉnh ngưỡng nhiều nhất.
- Kịch bản 10–13: không lần nào báo "trống" sai (bên đó thật ra có vật, hố hoặc bục), 5/5 lần. Khi vật cản gần hơn ~1,5 m app **không** nói hai bên — đúng thiết kế, vì LiDAR không nhìn thấy trọn hai làn. Nếu kịch bản 11–12 không bao giờ báo trống ở ~2 m, ghi đuôi `trống:` và giảm `laneFloorPoints` trong `lib/services/lidar_analysis.dart`; không nới điều kiện khác.
- Vật nhỏ dưới sàn (dây điện, giày) và mặt kính vẫn có thể bị bỏ sót: **vẫn bắt buộc dùng gậy**.

Sau khi có số đo, chỉnh các ngưỡng trong `lib/services/visual_proximity.dart` (mức gần/trung bình), `lib/services/depth_analysis.dart` (`caution`, `danger`, vùng ảnh) và `lib/services/sight_monitor.dart` (độ tối, góc nghiêng). Bật overlay debug để xem AI fps khi chạy song song hai model.
