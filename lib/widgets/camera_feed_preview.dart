import 'package:camera/camera.dart';
import 'package:flutter/widgets.dart';

import '../services/camera_feed.dart';

/// A newly opened native camera always gets a fresh preview element/texture.
class CameraFeedPreview extends StatelessWidget {
  const CameraFeedPreview({super.key, required this.feed});

  final CameraFeed feed;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: ValueListenableBuilder<CameraController?>(
      valueListenable: feed,
      builder: (_, controller, _) => controller == null
          ? const ColoredBox(color: Color(0xFF000000))
          : CameraPreview(controller, key: ObjectKey(controller)),
    ),
  );
}
