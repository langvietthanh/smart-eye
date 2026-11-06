import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// What the camera screen needs to know about the currently open camera,
/// whichever backend (the `camera` plugin or ARKit) produced it. Two handles
/// are equal when they refer to the same opened camera session.
abstract interface class FeedHandle {
  int get sensorOrientation;
  bool get isFrontCamera;
  DeviceOrientation get deviceOrientation;
  bool get isInitialized;
}

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
  int get sensorOrientation => controller.description.sensorOrientation;
  @override
  bool get isFrontCamera =>
      controller.description.lensDirection == CameraLensDirection.front;
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
