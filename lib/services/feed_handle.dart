import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../utils/image_utils.dart';

/// What the camera screen needs to know about the currently open camera,
/// whichever backend (the `camera` plugin or ARKit) produced it. Two handles
/// are equal when they refer to the same opened camera session.
abstract interface class FeedHandle {
  DeviceOrientation get deviceOrientation;
  bool get isInitialized;

  /// Degrees to rotate delivered frames so the AI sees the world upright.
  int get frameRotation;
}

const deviceDegrees = {
  DeviceOrientation.portraitUp: 0,
  DeviceOrientation.landscapeLeft: 90,
  DeviceOrientation.portraitDown: 180,
  DeviceOrientation.landscapeRight: 270,
};

/// A camera backend owned by the screen: lifecycle plus its preview.
abstract interface class FrameSource {
  Future<void> setActive(bool active);
  Future<void> retry();
  Future<void> dispose();
  Widget buildPreview();
}

class CameraControllerHandle implements FeedHandle {
  const CameraControllerHandle(this.controller);
  final CameraController controller;

  @override
  int get frameRotation => ImageUtils.frameRotation(
    isIOS: Platform.isIOS,
    sensorOrientation: controller.description.sensorOrientation,
    deviceDegrees: deviceDegrees[deviceOrientation]!,
    frontCamera:
        controller.description.lensDirection == CameraLensDirection.front,
  );
  @override
  DeviceOrientation get deviceOrientation => controller.value.deviceOrientation;
  @override
  bool get isInitialized => controller.value.isInitialized;

  @override
  bool operator ==(Object other) =>
      other is CameraControllerHandle &&
      identical(other.controller, controller);

  @override
  int get hashCode => identityHashCode(controller);
}
