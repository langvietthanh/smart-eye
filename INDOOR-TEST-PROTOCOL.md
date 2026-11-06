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
| 1 | Ghế ở giữa lối đi, tiến thẳng tới | Khoảng cách lúc bắt đầu rung, lúc nói "Chú ý", lúc nói "Dừng lại" |
| 2 | Ghế lệch trái / lệch phải | App có nói đúng phía không |
| 3 | Bàn thấp và rộng (bàn trà) | Có báo không, báo ở khoảng cách nào |
| 4 | Thùng carton, ba lô dưới sàn | **Model COCO không nhận ra**: ghi nhận là bỏ sót |
| 5 | Đi thẳng vào tường hoặc cửa | **Model COCO không nhận ra**: ghi nhận là bỏ sót |
| 6 | Tắt đèn phòng | Có nói "Quá tối" trong ~1 giây không |
| 7 | Lấy tay che camera | Có nói "Quá tối" hoặc "Camera không hoạt động" không |
| 8 | Cầm máy chĩa xuống sàn, rồi chĩa lên trần | Có nhắc "Nâng máy lên" / "Hạ máy xuống" không |
| 9 | Phòng có 4–6 vật, đi từ cửa tới đích | Số lần va chạm (người quan sát chặn trước), số lần báo nhầm |

## Bảng ghi
`ngày · máy · kịch bản · lần · khoảng cách rung đầu tiên (m) · khoảng cách "Dừng lại" (m) · bỏ sót? · báo nhầm? · ghi chú`

## Tiêu chí đạt (đề xuất, chỉnh sau lần đo đầu)
- Kịch bản 1–3: "Dừng lại" ở ≥ 1,0 m với tốc độ đi chậm, 5/5 lần.
- Kịch bản 6–8: cảnh báo trong ≤ 2 giây, 5/5 lần.
- Kịch bản 4–5 sẽ **không đạt** cho tới khi có model độ sâu. Đây là lý do bắt buộc dùng gậy.

Sau khi có số đo, chỉnh các ngưỡng trong `lib/services/visual_proximity.dart` (mức gần/trung bình) và `lib/services/sight_monitor.dart` (độ tối, góc nghiêng).
