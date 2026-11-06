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
| 4 | Thùng carton, ba lô dưới sàn | COCO không nhận ra; chỉ model độ sâu báo *"Có vật cản ngay phía trước"*. Ghi khoảng cách lúc báo |
| 5 | Đi thẳng vào tường hoặc cửa | Chỉ model độ sâu báo. Ghi khoảng cách lúc rung đầu tiên và lúc *"Dừng lại"* |
| 6 | Tắt đèn phòng | Có nói "Quá tối" trong ~1 giây không |
| 7 | Lấy tay che camera | Có nói "Quá tối" hoặc "Camera không hoạt động" không |
| 8 | Cầm máy chĩa xuống sàn, rồi chĩa lên trần | Có cảnh báo "Dừng lại! Máy đang chĩa xuống sàn..." / "...chĩa lên cao..." không |
| 9 | Phòng có 4–6 vật, đi từ cửa tới đích | Số lần va chạm (người quan sát chặn trước), số lần báo nhầm |

## Bảng ghi
`ngày · máy · kịch bản · lần · khoảng cách rung đầu tiên (m) · khoảng cách "Dừng lại" (m) · bỏ sót? · báo nhầm? · ghi chú`

## Tiêu chí đạt (đề xuất, chỉnh sau lần đo đầu)
- Kịch bản 1–3: "Dừng lại" ở ≥ 1,0 m với tốc độ đi chậm, 5/5 lần.
- Kịch bản 6–8: cảnh báo trong ≤ 2 giây, 5/5 lần.
- Kịch bản 4–5: "Dừng lại" ở ≥ 1,0 m, 4/5 lần. Độ sâu chỉ là tương đối nên đây là kịch bản cần chỉnh ngưỡng nhiều nhất.
- Vật nhỏ dưới sàn (dây điện, giày) và mặt kính vẫn có thể bị bỏ sót: **vẫn bắt buộc dùng gậy**.

Sau khi có số đo, chỉnh các ngưỡng trong `lib/services/visual_proximity.dart` (mức gần/trung bình), `lib/services/depth_analysis.dart` (`caution`, `danger`, vùng ảnh) và `lib/services/sight_monitor.dart` (độ tối, góc nghiêng). Bật overlay debug để xem AI fps khi chạy song song hai model.
