# Thông tin bên trống khi gặp vật cản (LiDAR) — Thiết kế

Ngày: 2026-11-09 · Trạng thái: đã duyệt thiết kế, chưa triển khai

## 1. Tóm tắt yêu cầu

- Khi LiDAR (hoặc YOLO) cảnh báo vật cản **ở giữa**, app cho biết bên trái / phải có trống không.
- **Chỉ mô tả, không ra lệnh**: "Bên phải trống", không "Đi chếch sang phải". Người dùng tự quyết.
- **Chỉ dùng LiDAR** (iPhone 12 Pro trở lên). Máy không LiDAR giữ nguyên hành vi hiện tại.
- **Gắn vào câu cảnh báo có sẵn**, không phát câu riêng; câu cảnh báo được rút gọn.
- "Trống" = làn rộng **40 cm** sát hành lang giữa (`|side|` 0,35–0,75 m) không có vật cản, trong đoạn từ `d` đến `max(d + 1, 2)` mét (`d` = khoảng cách vật cản giữa), **và** LiDAR nhìn thấy trọn làn (mép ngoài gần nhất nằm trong khung hình) **và** mọi ô 0,5 m × 20 cm đều thấy mặt sàn. (Sửa sau khi kiểm tra góc nhìn — xem D11.)
- **Chỉ nói khi chắc chắn**: bên nào chưa rõ thì không nhắc.
- Bối cảnh dùng chính: demo trong lớp học (dãy bàn, bục giảng) và hành lang, bằng iPhone 12 Pro.

**Không làm:** câu ra lệnh rẽ; dùng YOLO/MiDaS để kết luận "trống"; thêm hướng đi vào mô tả cảnh; thay đổi câu cảnh báo MiDaS.

## 2. Giả định

1. Làn bên chỉ được coi là trống khi thấy đủ điểm sàn trong mọi đoạn 0,5 m — không có điểm ≠ trống.
2. Đoạn sát chân (dưới `d − 0,5`) nằm ngoài góc nhìn LiDAR ở chế độ portrait nên không khẳng định gì về nó.
3. Tính trong cùng lượt `analyze` trên isolate LiDAR (~10 Hz), không làm giảm tần số.
4. Đổi trạng thái sang **trống** cần 3 frame liên tiếp; sang **chắn/chưa rõ** cần 1 frame.
5. Cooldown speech giữ nguyên; chỉ đổi trạng thái hai bên không làm app nói lại.
6. Dữ liệu xử lý hoàn toàn trên máy, không lưu, không gửi đi.

## 3. Decision log

| # | Quyết định | Phương án khác | Lý do |
|---|---|---|---|
| D1 | Mô tả bên trống, không ra lệnh | Ra lệnh rẽ; tuỳ độ tin cậy | Người dùng giữ quyền quyết định; tránh dẫn vào chỗ model bỏ sót (lý do `d002bff` đã gỡ "Đi chếch sang…") |
| D2 | Chỉ LiDAR | MiDaS + YOLO; chỉ YOLO | Chỉ LiDAR đo được khoảng trống thật theo mét; nhóm demo bằng iPhone 12 Pro |
| D3 | Nối vào câu cảnh báo, rút gọn câu | Câu nói riêng; thêm vào mô tả cảnh | Không tăng số lần nói; câu ngắn dễ nghe |
| D4 | Ngoài "một bên trống": chỉ nói khi chắc chắn | Luôn nói đủ hai bên kèm "chưa rõ"; chỉ nói bên trống | Câu ngắn, không đưa thông tin mơ hồ |
| D5 | Trống tới quá vật cản 1 m (tối thiểu 2 m) | Cố định 2 m / 3 m | Đi lách qua thì vượt được vật cản |
| D6 | Mở rộng `LidarAnalysis.analyze` (phương án A) | Lớp `SideLaneAnalysis` riêng; occupancy grid | Dùng lại điểm 3D đã tính, ít code, dễ test; grid là YAGNI |
| D7 | Bắt buộc thấy mặt sàn liền mạch mới là trống | Chỉ cần không có điểm vật cản | Vùng ngoài khung hình / hố / bậc xuống không có điểm nào nhưng không trống |
| D8 | Nối `sideClause` cả vào cảnh báo YOLO khi vật ở giữa | Chỉ cảnh báo LiDAR | Khi YOLO đã gọi tên vật, câu LiDAR bị bỏ → mất thông tin hai bên |
| D9 | Câu nguy hiểm: "Dừng lại! Vật cản ngay trước mặt." | Giữ "Có vật cản ngay phía trước." | Ngắn hơn |
| D10 | Hiện trạng thái hai bên trên dòng debug LiDAR | Không hiện | Lớp xem được app đang thấy gì; nhóm dùng để chỉnh ngưỡng |
| D11 | Làn 40 cm (0,35–0,75 m), xét từ `d`, ô 0,5 m × 20 cm + kiểm tra mép ngoài trong khung hình | Làn 70 cm từ `d − 0,5` (bản đầu); giữ 70 cm và nới cảnh báo lên 3 m | Cầm dọc LiDAR chỉ thấy ngang ~0,5 × z: làn 70 cm chỉ nhìn trọn khi z ≥ 2,1 m nên gần như luôn "chưa rõ"; làn 40 cm nhìn trọn khi d ≥ ~1,5 m. Đếm điểm sàn tổng không đủ — phần làn ngoài khung hình vẫn có thể giấu vật |
| D12 | `SideState` đặt trong `models/scene_info.dart`; `HazardAlert` thêm `pos` | Đặt trong `lidar_analysis.dart`; dò vị trí từ câu | Tránh service phụ thuộc chéo; `_handleAlert` cần biết vật YOLO có ở giữa không |
| D13 | Câu "ngay trước mặt" áp dụng cho cả cảnh báo nguy hiểm MiDaS | Chỉ đổi cho LiDAR | `depthAlertText` dùng chung; câu ngắn hơn ở mọi máy |

## 4. Thiết kế

### 4.1 Phân tích làn bên — `lib/services/lidar_analysis.dart`

```dart
enum SideState { clear, blocked, unknown }

class LidarObstacle extends LidarReading {
  const LidarObstacle(this.distance,
      {this.left = SideState.unknown, this.right = SideState.unknown});
  final double distance;
  final SideState left, right;
}
```

Hằng số mới: `sideOuter = 0.75`, `sidePastObstacle = 1.0`, `sideMinDepth = 2.0`, `sideBin = 0.5`, `sideCell = 0.2`, `sideFloorPoints = 10`.

Sau khi có vật cản giữa ở `d`, duyệt lại các điểm đã có (`forwards`, `heights`, `sides`):

- Bỏ điểm ngoài `|side| ∈ (0,35; 0,75]` hoặc ngoài `forward ∈ [d; max(d + 1, 2)]`.
- `low ≤ height ≤ headroom` → điểm vật cản của làn.
- `|height − floor| ≤ floorMargin` → điểm sàn, cộng vào ô (đoạn 0,5 m × dải 20 cm) tương ứng.

Kết luận: điểm vật cản ≥ `needed` → **blocked**; ngược lại nếu điểm mép ngoài gần nhất của làn (`side = ±0,75`, `forward = d`, trên mặt sàn) chiếu vào nằm trong ảnh **và** mọi ô có ≥ `sideFloorPoints` điểm sàn → **clear**; còn lại → **unknown**. `LidarClear` / `LidarUnknown` không mang thông tin hai bên.

### 4.2 Ổn định — `SideStability` (cạnh `LidarWarning`)

Mỗi bên giữ trạng thái đã chấp nhận + ứng viên + streak. Sang `clear` cần 3 frame liên tiếp; sang `blocked` / `unknown` ngay. `LidarClear`, `LidarUnknown` hoặc `reset()` → hai bên `unknown`.

### 4.3 Câu nói — `lib/services/depth_alert.dart`

| Tình huống | Câu |
|---|---|
| Nguy hiểm (< 1 m) | `Dừng lại! Vật cản ngay trước mặt.` |
| Chú ý, LiDAR | `Chậm lại. Vật cản cách 1,5 mét.` |
| Chú ý, MiDaS | `Chậm lại. Có vật phía trước.` (giữ nguyên) |

`sideClause(left, right)` nối vào cuối:

- Một bên trống → `Bên trái trống.` / `Bên phải trống.`
- Hai bên trống → `Hai bên trống.`
- Hai bên chắn → `Hai bên có vật cản.`
- Còn lại → không nối.

### 4.4 Nối dây — `lib/screens/camera_screen.dart`

- `_onLidarReading`: cập nhật `SideStability`, truyền trạng thái ổn định vào `_announceDepth`; thêm `· T:<…> P:<…>` vào `_lidarStatus`.
- `_handleAlert`: khi đang dùng LiDAR và vật YOLO ở **giữa**, nối `sideClause` sau `alert.message`. Vật ở hai bên thì không nối. Tách thành hàm thuần để test.
- Cooldown và subject speech giữ nguyên.

## 5. Trường hợp biên

| Trường hợp | Hành vi |
|---|---|
| Vật cản `d < ~1,5` m (gồm mọi cảnh báo nguy hiểm < 1 m) | Mép ngoài làn ngoài khung hình → unknown → không nói hai bên |
| Tường/bàn trong làn bên | blocked |
| Bậc xuống / hố ở làn bên | Thiếu điểm sàn → unknown, không bao giờ clear |
| Bục giảng ở làn bên (cao ~20 cm > `floorMargin`) | blocked |
| Khe cạnh vật cản hẹp hơn 40 cm | blocked |
| Vật cản giữa rộng hơn hành lang 70 cm | "Trống" chỉ nghĩa là có thêm 40 cm cạnh hành lang, không chứng minh lách qua được vật rộng |
| Mất tracking / quá nóng / che lens | `LidarUnknown` → hai bên unknown |
| Kính, cửa kính | LiDAR đo kém — giới hạn đã biết, tránh khi demo |

Rủi ro sẵn có (ngoài phạm vi): lối đi giữa dãy bàn hẹp hơn ~75 cm làm hành lang giữa 70 cm chạm mép bàn → cảnh báo liên tục. Trước demo nên đo và kê rộng lối đi.

## 6. Kiểm thử

Unit test (`test/lidar_analysis_test.dart`, dùng `render()` tổng hợp):

1. Ghế rộng 60 cm ở giữa cách 1,8 m, hai bên chỉ có sàn → `left == right == clear`.
2. Thêm hộp ở làn phải → `right == blocked`, `left == clear`.
3. Ghế giữa cách 0,9 m → hai bên `unknown` (mép làn ngoài khung hình).
4. Hố trên sàn ở làn trái → `left == unknown`.
5. Nghiêng 20° / cầm thấp hơn → kết quả không đổi.
6. `SideStability`: 3 frame để sang clear, 1 frame sang blocked, `reset()`.
7. `depthAlertText` + `sideClause`: đủ bảng câu ở 4.3.
8. Hàm nối câu YOLO: vật giữa có nối, vật bên không nối.

Thử thực tế (bổ sung vào `INDOOR-TEST-PROTOCOL.md`, iPhone 12 Pro):

1. Ghế chắn lối đi giữa hai dãy bàn → "Hai bên có vật cản".
2. Ghế cuối dãy, bên kia trống → "Bên X trống".
3. Hành lang, ba lô hoặc người đứng giữa → "Bên X trống".
4. Đi về phía bục giảng → cảnh báo bậc lên; làn có bục không bao giờ "trống".
