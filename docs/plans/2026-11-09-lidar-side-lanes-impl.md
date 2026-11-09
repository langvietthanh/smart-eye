# Báo bên trống bằng LiDAR — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Khi có vật cản ở giữa, nối "Bên trái/phải trống", "Hai bên trống" hoặc "Hai bên có vật cản" vào câu cảnh báo, dựa hoàn toàn vào LiDAR.

**Architecture:** `LidarAnalysis.analyze` phân loại thêm hai làn bên 40 cm ngay trong lượt xử lý hiện có và trả về trong `LidarObstacle`. `SideStability` làm mượt trạng thái. `depth_alert.dart` tạo câu (rút gọn và nối phần hai bên). `camera_screen.dart` nối phần này vào cảnh báo LiDAR và cảnh báo YOLO khi vật ở giữa.

**Tech Stack:** Flutter/Dart, `flutter_test`, ARKit scene depth (iOS, đã có).

**Spec:** [2026-11-09-lidar-side-lanes.md](2026-11-09-lidar-side-lanes.md)

## Nền triển khai (cập nhật sau khi phiên "path-blockage" xong)

- Nhánh `feat/lidar-side-lanes` tách từ `feature/path-blockage` (`cdcff4f`). Nhánh này đã có `LidarScan(left, center, right)`, `analyzeScan()` (hành lang bên 0,35–1,05 m) và `PathBlockage` (cảnh báo kẹt cả 3 hướng).
- Task 1 sửa `analyzeScan`: gắn `SideState` vào `scan.center` (một `LidarObstacle`). `PathBlockage` và `scan.left/right` giữ nguyên.
- Hằng số 0,75 m đổi tên thành `laneOuter`, vì `sideOuter = 1.05` đã được dùng.
- Trục `side` dương là **bên trái** (đã có chú thích trong code).
- Dòng chẩn đoán LiDAR nối thêm `· trống: <câu bên trống | —>`, không dùng `T:/P:` để tránh trùng với dòng `Hướng: T✓ G✗ P✗` đã có.

## Global Constraints

- Chỉ LiDAR quyết định trạng thái hai bên; máy không có LiDAR không bao giờ nghe phần hai bên.
- Không có câu ra lệnh rẽ ("Đi chếch sang…").
- Làn bên: `|side|` trong (0,35; 0,75] m; đoạn xét `forward ∈ [d; max(d + 1, 2)]`; ô 0,5 m × 0,2 m; ≥ 10 điểm sàn mỗi ô.
- Câu chính xác:
  - `Dừng lại! Vật cản ngay trước mặt.`
  - `Chậm lại. Vật cản cách 1,5 mét.`
  - `Chậm lại. Có vật phía trước.`
  - Phần nối: `Bên trái trống.` / `Bên phải trống.` / `Hai bên trống.` / `Hai bên có vật cản.`
- Ổn định: sang `clear` cần 3 frame liên tiếp; sang `blocked` / `unknown` ngay lập tức.
- Cooldown và subject của `SpeechManager` giữ nguyên.
- Làm trên nhánh `feat/lidar-side-lanes`, không làm trên `main`.

## Review Focus

1. **Dữ liệu hai bên đã cũ:** LiDAR ngừng gửi frame (máy nóng, ARKit tạm dừng), nhưng YOLO vẫn cảnh báo. Không được nối trạng thái hai bên đã cũ hơn 500 ms (Task 5).
2. **Hướng trái/phải bị đảo:** sai dấu của trục `side` sẽ khiến app nói "Bên phải trống" khi bên phải bị chắn. Test `box in the right lane blocks right only` (Task 1) chốt chiều.
3. **Bục giảng ở làn bên:** mặt bục cao 20 cm không được coi là sàn, nên làn đó không bao giờ là `clear` (Task 1, test `platform in a side lane blocks it`).
4. **Cầm máy thấp hoặc nghiêng nhiều:** kết quả hai bên phải giống trường hợp cầm chuẩn (Task 1, test `side lanes do not depend on hold`).
5. **Vật YOLO nằm hai bên:** không nối phần hai bên vào cảnh báo về vật bên trái/phải, tránh câu kiểu "ghế bên phải… Bên phải trống" (Task 3, test `withSideClause leaves side objects alone`).

---

### Task 0: Tạo nhánh

- [ ] **Step 1:** `git checkout -b feat/lidar-side-lanes`
- [ ] **Step 2:** `flutter test`. Expected: tất cả test PASS trên nhánh mới. Đây là mốc đối chiếu; nếu đã có test FAIL thì ghi lại tên test.

---

### Task 1: Phân tích làn bên trong `LidarAnalysis`

**Files:**
- Modify: `lib/models/scene_info.dart` (thêm `SideState`)
- Modify: `lib/services/lidar_analysis.dart`
- Test: `test/lidar_analysis_test.dart`

**Interfaces:**
- Produces:
  - `enum SideState { clear, blocked, unknown }` trong `lib/models/scene_info.dart`.
  - `LidarObstacle(double distance, {SideState left = SideState.unknown, SideState right = SideState.unknown})` có thêm hai field `left` và `right`.
  - Hằng số trên `LidarAnalysis`: `sideOuter = 0.75`, `sidePastObstacle = 1.0`, `sideMinDepth = 2.0`, `sideBin = 0.5`, `sideCell = 0.2`, `sideFloorPoints = 10`.

- [ ] **Step 1: Thêm tham số `holes` cho `render()` trong test**

`render({..., List<(double x0, double z0, double x1, double z1)> holes = const []})`: nếu điểm tia chạm mặt sàn, `(origin + t·dir)` có `(x, z)` nằm trong một hố, thì bỏ phần sàn đó (`t = null` cho sàn; box vẫn được xét bình thường). Thêm helper `Box chair(double z) => Box(-0.25, 0, z, 0.25, 0.9, z + 0.4);`. Ghế chỉ rộng 50 cm để vùng sàn bị ghế che khuất phía sau không lấn vào làn bên.

- [ ] **Step 2: Viết test thất bại (group `side lanes`)**

```dart
LidarObstacle obstacleOf(LidarReading r) {
  expect(r, isA<LidarObstacle>());
  return r as LidarObstacle;
}

test('free floor beside a chair is clear on both sides', () {
  final r = obstacleOf(LidarAnalysis().analyze(render(boxes: [chair(1.8)])));
  expect(r.distance, closeTo(1.8, 0.1));
  expect(r.left, SideState.clear);
  expect(r.right, SideState.clear);
});

test('box in the right lane blocks right only', () {
  final r = obstacleOf(LidarAnalysis().analyze(render(
      boxes: [chair(1.8), const Box(0.4, 0, 1.9, 0.7, 0.8, 2.3)])));
  expect(r.right, SideState.blocked);
  expect(r.left, SideState.clear);
});

test('a full-width wall blocks both lanes', () {
  final r = obstacleOf(LidarAnalysis().analyze(render(boxes: [wall(1.8)])));
  expect(r.left, SideState.blocked);
  expect(r.right, SideState.blocked);
});

test('lanes outside the view are unknown when the obstacle is close', () {
  final r = obstacleOf(LidarAnalysis().analyze(render(boxes: [chair(0.9)])));
  expect(r.left, SideState.unknown);
  expect(r.right, SideState.unknown);
});

test('a hole in the left lane floor makes it unknown, never clear', () {
  final r = obstacleOf(LidarAnalysis().analyze(render(
      // Hố phủ trọn một đoạn 0,5 m của làn trái (giống bậc xuống)
      boxes: [chair(1.8)], holes: [(-0.8, 2.2, -0.36, 3.0)])));
  expect(r.left, SideState.unknown);
  expect(r.right, SideState.clear);
});

test('platform in a side lane blocks it', () {
  final r = obstacleOf(LidarAnalysis().analyze(render(
      boxes: [chair(1.8), const Box(-3, 0, 1.6, -0.36, 0.2, 4)])));
  expect(r.left, SideState.blocked);
});

test('side lanes do not depend on hold', () {
  for (final f in [
    render(pitchDeg: 25, boxes: [chair(1.8)]),
    render(cameraHeight: 1.0, boxes: [chair(1.8)]),
  ]) {
    final r = obstacleOf(LidarAnalysis().analyze(f));
    expect((r.left, r.right), (SideState.clear, SideState.clear));
  }
});
```

Trong `render()`, `x > 0` là bên phải người dùng. Test `box in the right lane…` là test quyết định chiều của trục `side`.

- [ ] **Step 3:** `flutter test test/lidar_analysis_test.dart`. Expected: FAIL vì `SideState` chưa được định nghĩa.

- [ ] **Step 4: Cài đặt**

Thêm `SideState` vào `scene_info.dart` và thêm `left`/`right` vào `LidarObstacle`. Trong `analyze`, sau khi đã có khoảng cách vật cản giữa `d` (dòng `hits[needed - 1]`), gọi `_lane(sign, d, …)` cho `sign = -1` (trái) và `sign = +1` (phải), dùng lại `forwards`, `heights`, `sides`, `count`, `floor`, `low` và các vector `f*0`, `s*`, `u*` đã có.

```text
end = max(d + sidePastObstacle, sideMinDepth)
bins = ceil((end - d) / sideBin); cells = bins × 2  (dải 0,35–0,55 và 0,55–0,75)
for each point: s = sign * sides[i]
  if s <= halfWidth || s > sideOuter || forward < d || forward > end: skip
  if low <= height <= headroom: obstacles++
  else if |height - floor| <= floorMargin: floorCount[cell]++
if obstacles >= needed → blocked
corner = forward̂·d + sidê·(sign·sideOuter) + up·floor   (vector trong hệ camera)
visible = corner.z < 0 && 0 <= cx + fx·corner.x/(-corner.z) < width
                       && 0 <= cy - fy·corner.y/(-corner.z) < height
if visible && every floorCount[cell] >= sideFloorPoints → clear
else unknown
```

Nếu test chiều trái/phải FAIL vì bị đảo ngược, đổi dấu `sign` khi gán kết quả (trái ↔ phải). Không đổi vector `side` vì hành lang giữa đang dùng nó.

- [ ] **Step 5:** `flutter test test/lidar_analysis_test.dart`. Expected: tất cả PASS, gồm cả các test cũ.

- [ ] **Step 6: Commit**

```bash
git add lib/models/scene_info.dart lib/services/lidar_analysis.dart test/lidar_analysis_test.dart docs/plans/2026-11-09-lidar-side-lanes.md docs/plans/2026-11-09-lidar-side-lanes-impl.md
git commit -m "feat: classify LiDAR side lanes beside a centre obstacle"
```

---

### Task 2: `SideStability`

**Files:**
- Modify: `lib/services/lidar_analysis.dart` (đặt cạnh `LidarWarning`)
- Test: `test/lidar_analysis_test.dart`

**Interfaces:**
- Consumes: `LidarReading`, `LidarObstacle.left/right`, `SideState` (Task 1).
- Produces:
  - `class SideStability { static const clearFrames = 3; ({SideState left, SideState right}) update(LidarReading r); void reset(); }`
  - Giá trị khởi tạo và giá trị sau `reset()` đều là `(unknown, unknown)`.

- [ ] **Step 1: Viết test thất bại (group `side stability`)**

```dart
const both = LidarObstacle(1.5, left: SideState.clear, right: SideState.clear);
const rightBlocked =
    LidarObstacle(1.5, left: SideState.clear, right: SideState.blocked);

test('clear needs three frames in a row', () {
  final s = SideStability();
  expect(s.update(both), (left: SideState.unknown, right: SideState.unknown));
  expect(s.update(both).left, SideState.unknown);
  expect(s.update(both), (left: SideState.clear, right: SideState.clear));
});

test('blocked takes effect at once', () {
  final s = SideStability();
  for (var i = 0; i < 3; i++) s.update(both);
  expect(s.update(rightBlocked), (left: SideState.clear, right: SideState.blocked));
});

test('a broken clear streak starts over', () {
  final s = SideStability();
  s.update(both); s.update(both); s.update(rightBlocked);
  expect(s.update(both).right, SideState.unknown);
});

test('clear or unknown readings and reset drop both sides', () {
  final s = SideStability();
  for (var i = 0; i < 3; i++) s.update(both);
  expect(s.update(const LidarClear()), (left: SideState.unknown, right: SideState.unknown));
  for (var i = 0; i < 3; i++) s.update(both);
  expect(s.update(const LidarUnknown()).left, SideState.unknown);
  for (var i = 0; i < 3; i++) s.update(both);
  s.reset();
  expect(s.update(both).left, SideState.unknown);
});
```

- [ ] **Step 2:** `flutter test test/lidar_analysis_test.dart`. Expected: FAIL vì `SideStability` chưa được định nghĩa.
- [ ] **Step 3: Cài đặt `SideStability`**: mỗi bên giữ `state`, `candidate` và `streak`. Ứng viên `clear` được chấp nhận khi `streak >= clearFrames`; mọi ứng viên khác được chấp nhận ngay và đưa streak về 0.
- [ ] **Step 4:** `flutter test test/lidar_analysis_test.dart`. Expected: PASS.
- [ ] **Step 5: Commit** `feat: smooth LiDAR side-lane states over frames`

---

### Task 3: Câu nói (`depth_alert.dart`)

**Files:**
- Modify: `lib/services/depth_alert.dart`
- Test: `test/depth_alert_test.dart`

**Interfaces:**
- Consumes: `SideState` (Task 1), `HPos` (đã có).
- Produces:
  - `String? sideClause(SideState left, SideState right)`
  - `String? depthAlertText({required AlertLevel depthLevel, AlertLevel? detectorLevel, double? metres, SideState left = SideState.unknown, SideState right = SideState.unknown})`
  - `String withSideClause(String message, {required HPos? pos, required SideState left, required SideState right})`: chỉ nối khi `pos == HPos.center`, nối bằng một dấu cách.

- [ ] **Step 1: Sửa test cũ và viết test mới**

Đổi các câu mong đợi trong `test/depth_alert_test.dart`:
- `'Dừng lại! Có vật cản ngay phía trước.'` → `'Dừng lại! Vật cản ngay trước mặt.'`
- `'Chậm lại. Vật cản phía trước, khoảng 1,5 mét.'` → `'Chậm lại. Vật cản cách 1,5 mét.'`
- `'…khoảng 2 mét.'` → `'Chậm lại. Vật cản cách 2 mét.'`

Sửa luôn tên các test cho khớp với câu mới. Không sửa `speech_manager_test.dart`, vì câu trong đó chỉ là dữ liệu mẫu.

```dart
group('sideClause', () {
  const c = SideState.clear, b = SideState.blocked, u = SideState.unknown;
  test('one side clear', () {
    expect(sideClause(c, b), 'Bên trái trống.');
    expect(sideClause(u, c), 'Bên phải trống.');
  });
  test('both clear / both blocked', () {
    expect(sideClause(c, c), 'Hai bên trống.');
    expect(sideClause(b, b), 'Hai bên có vật cản.');
  });
  test('nothing certain says nothing', () {
    expect(sideClause(u, u), isNull);
    expect(sideClause(b, u), isNull);
  });
});

test('LiDAR caution with a free right side', () {
  expect(
    depthAlertText(depthLevel: AlertLevel.caution, metres: 1.4,
        left: SideState.blocked, right: SideState.clear),
    'Chậm lại. Vật cản cách 1,5 mét. Bên phải trống.',
  );
});

test('withSideClause appends for a centre object', () {
  expect(
    withSideClause('Dừng lại! Có ghế ngay phía trước.',
        pos: HPos.center, left: SideState.clear, right: SideState.blocked),
    'Dừng lại! Có ghế ngay phía trước. Bên trái trống.',
  );
});

test('withSideClause leaves side objects alone', () {
  for (final pos in [HPos.left, HPos.right, null]) {
    expect(
      withSideClause('Chậm lại. Có ghế bên phải.',
          pos: pos, left: SideState.clear, right: SideState.clear),
      'Chậm lại. Có ghế bên phải.',
    );
  }
});
```

- [ ] **Step 2:** `flutter test test/depth_alert_test.dart`. Expected: FAIL.
- [ ] **Step 3: Cài đặt** đúng các câu đã ghi ở Global Constraints. Bỏ tham số `left`/`right` khi câu đầu là `null` (phần ức chế theo YOLO giữ nguyên).
- [ ] **Step 4:** `flutter test test/depth_alert_test.dart`. Expected: PASS.
- [ ] **Step 5: Commit** `feat: shorter depth alerts with side-lane clause`

---

### Task 4: `HazardAlert.pos`

**Files:**
- Modify: `lib/models/scene_info.dart` (`HazardAlert`)
- Modify: `lib/services/hazard_engine.dart:110-117`
- Test: `test/logic_test.dart`

**Interfaces:**
- Produces: `HazardAlert({..., HPos? pos})`, field `final HPos? pos`. `HazardEngine._decide` gán `pos: best.object.pos`.

- [ ] **Step 1: Viết test thất bại** trong `test/logic_test.dart`, dùng các helper `rec`, `centerBox` và `run` có sẵn:

```dart
test('alert carries the object position', () {
  final centre = run(ObjectTracker(), HazardEngine(),
      [rec('chair', 'ghế', 56, centerBox(0.6))]);
  expect(centre.alert!.pos, HPos.center);
  final left = run(ObjectTracker(), HazardEngine(),
      [rec('car', 'xe ô tô', 2, centerBox(0.6, cx: 60))]);
  expect(left.alert!.pos, HPos.left);
});
```
- [ ] **Step 2:** `flutter test test/logic_test.dart`. Expected: FAIL vì getter `pos` chưa được định nghĩa.
- [ ] **Step 3: Thêm field `pos` và gán giá trị** trong `_decide`.
- [ ] **Step 4:** `flutter test test/logic_test.dart`. Expected: PASS.
- [ ] **Step 5: Commit** `feat: carry object position on hazard alerts`

---

### Task 5: Nối dây trong `camera_screen.dart` và kịch bản demo

**Files:**
- Modify: `lib/screens/camera_screen.dart` (khoảng các dòng 127-131, 496, 675-725, 829-857)
- Modify: `INDOOR-TEST-PROTOCOL.md`

**Interfaces:**
- Consumes: `SideStability` (Task 2), `depthAlertText(left:, right:)` và `withSideClause` (Task 3), `HazardAlert.pos` (Task 4).

- [ ] **Step 1: Trạng thái.** Thêm các field `final SideStability _sideStability = SideStability();`, `({SideState left, SideState right}) _sides = (left: SideState.unknown, right: SideState.unknown);`, `int _sidesAtMs = -1;` và `static const _sideMaxAgeMs = 500;`. Ở chỗ đang gọi `_lidarWarning.reset()` (dòng 496), gọi thêm `_sideStability.reset()` và đặt `_sides` về `unknown`.
- [ ] **Step 2: `_onLidarReading`.** Đặt `_sides = _sideStability.update(reading); _sidesAtMs = _frameClock.elapsedMilliseconds;` trước khi thoát sớm vì `problem`. Nối vào `_lidarStatus` chuỗi `' · T:${_short(_sides.left)} P:${_short(_sides.right)}'`, trong đó `_short` trả `trống` / `chắn` / `?`. Truyền `_sides` vào `_announceDepth` → `depthAlertText(left:, right:)`.
- [ ] **Step 3: `_handleAlert`.** Tính `final text = _useLidar && _frameClock.elapsedMilliseconds - _sidesAtMs <= _sideMaxAgeMs ? withSideClause(alert.message, pos: alert.pos, left: _sides.left, right: _sides.right) : alert.message;` rồi dùng `text` cho cả `_eventLogger` và `_speech.say`.
- [ ] **Step 4: Kiểm tra tĩnh.** Chạy `flutter analyze`, expected: không có issue mới. Chạy `flutter test`, expected: tất cả PASS.
- [ ] **Step 5: Kịch bản demo.** Thêm vào `INDOOR-TEST-PROTOCOL.md` 4 kịch bản (iPhone 12 Pro). Mỗi kịch bản có cột "câu nghe được" và "dòng T:/P:":
  1. Ghế chắn lối đi giữa hai dãy bàn → "Hai bên có vật cản".
  2. Ghế cuối dãy, phía bên kia trống, đứng cách khoảng 2 m → "Bên X trống".
  3. Hành lang, ba lô hoặc người đứng giữa, cách khoảng 2 m → "Bên X trống".
  4. Đi về phía bục giảng → cảnh báo bậc lên; làn có bục không bao giờ hiện `trống`.

  Ghi chú thêm: khi vật cản gần hơn khoảng 1,5 m thì app không nói hai bên. Đây là hành vi đúng theo thiết kế.
- [ ] **Step 6: Thử trên iPhone 12 Pro** theo 4 kịch bản trên và ghi kết quả vào protocol. Nếu kịch bản 2 hoặc 3 không bao giờ hiện `trống` ở khoảng 2 m, ghi lại số trên dòng T:/P: và giảm `sideFloorPoints`. Không nới bất kỳ điều kiện nào khác.
- [ ] **Step 7: Commit** `feat: speak free side lanes with LiDAR obstacle alerts`
