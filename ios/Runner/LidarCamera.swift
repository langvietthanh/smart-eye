import ARKit
import Accelerate
import Flutter
import UIKit

/// ARKit camera with LiDAR scene depth for Smart Eye.
///
/// - Colour frames: `capturedImage` (YUV 420f, sensor landscape) scaled to
///   640×480 and sent as two planes; Dart builds a `CameraImage` from them and
///   rotates like an Android back camera (sensor orientation 90).
/// - Depth: `smoothedSceneDepth` (metres) + confidence + intrinsics scaled to
///   the depth resolution + world "up" in camera coordinates, ~10 Hz.
/// - Preview: a BGRA `FlutterTexture` in the same sensor orientation.
///
/// All ARKit work runs on `queue`; Flutter events are sent on the main thread.
final class LidarCameraPlugin: NSObject, FlutterPlugin, FlutterStreamHandler,
  ARSessionDelegate, FlutterTexture
{
  static let frameWidth = 640
  static let frameHeight = 480
  static let frameInterval: TimeInterval = 1.0 / 30
  static let depthInterval: TimeInterval = 0.1
  static let hotDepthInterval: TimeInterval = 0.2

  private let textures: FlutterTextureRegistry
  private let queue = DispatchQueue(label: "smart_eye.lidar")
  private var session: ARSession?
  private var sink: FlutterEventSink?
  private var textureId: Int64?

  // Touched only on `queue`.
  private var awaitingAck = false
  private var lastFrameAt: TimeInterval = 0
  private var lastDepthAt: TimeInterval = 0
  private var conversion = vImage_YpCbCrToARGB()
  private var conversionReady = false
  private var pool: CVPixelBufferPool?
  private let yPlane = UnsafeMutableRawPointer.allocate(
    byteCount: LidarCameraPlugin.frameWidth * LidarCameraPlugin.frameHeight, alignment: 64)
  private let uvPlane = UnsafeMutableRawPointer.allocate(
    byteCount: LidarCameraPlugin.frameWidth * LidarCameraPlugin.frameHeight / 2, alignment: 64)

  // Shared between `queue`, the main thread and the raster thread.
  private let previewLock = NSLock()
  private var preview: CVPixelBuffer?
  private var previewTextureId: Int64?

  // Main thread only.
  private var orientation = "portraitUp"

  init(textures: FlutterTextureRegistry) {
    self.textures = textures
    super.init()
  }

  deinit {
    yPlane.deallocate()
    uvPlane.deallocate()
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = LidarCameraPlugin(textures: registrar.textures())
    let methods = FlutterMethodChannel(
      name: "smart_eye/lidar", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: methods)
    let events = FlutterEventChannel(
      name: "smart_eye/lidar/events", binaryMessenger: registrar.messenger())
    events.setStreamHandler(instance)
  }

  static var isSupported: Bool {
    ARWorldTrackingConfiguration.isSupported
      && ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)
  }

  // MARK: - Method channel

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      result(Self.isSupported)
    case "start":
      guard Self.isSupported else {
        result(FlutterError(code: "Unsupported", message: "Máy không có LiDAR", details: nil))
        return
      }
      result(start())
    case "stop":
      stop()
      result(nil)
    case "ackFrame":
      queue.async { self.awaitingAck = false }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func start() -> Int64 {
    if session == nil {
      let session = ARSession()
      session.delegate = self
      session.delegateQueue = queue
      self.session = session
    }
    let id = textureId ?? textures.register(self)
    textureId = id
    previewLock.lock()
    previewTextureId = id
    previewLock.unlock()
    UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    NotificationCenter.default.addObserver(
      self, selector: #selector(orientationChanged),
      name: UIDevice.orientationDidChangeNotification, object: nil)
    orientationChanged()

    let config = ARWorldTrackingConfiguration()
    config.worldAlignment = .gravity
    config.frameSemantics = [.smoothedSceneDepth]
    queue.async {
      self.awaitingAck = false
      self.lastFrameAt = 0
      self.lastDepthAt = 0
    }
    session?.run(config, options: [.resetTracking, .removeExistingAnchors])
    return id
  }

  private func stop() {
    session?.pause()
    NotificationCenter.default.removeObserver(
      self, name: UIDevice.orientationDidChangeNotification, object: nil)
    UIDevice.current.endGeneratingDeviceOrientationNotifications()
    if let id = textureId {
      textures.unregisterTexture(id)
      textureId = nil
    }
    previewLock.lock()
    preview = nil
    previewTextureId = nil
    previewLock.unlock()
  }

  @objc private func orientationChanged() {
    // Same strings as camera_avfoundation; face up/down keep the last value.
    switch UIDevice.current.orientation {
    case .portrait: orientation = "portraitUp"
    case .portraitUpsideDown: orientation = "portraitDown"
    case .landscapeLeft: orientation = "landscapeLeft"
    case .landscapeRight: orientation = "landscapeRight"
    default: break
    }
  }

  // MARK: - Event channel

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  private func send(_ event: [String: Any]) {
    DispatchQueue.main.async {
      var event = event
      if event["type"] as? String == "frame" {
        event["orientation"] = self.orientation
        event["thermal"] = ProcessInfo.processInfo.thermalState.rawValue
      }
      self.sink?(event)
    }
  }

  // MARK: - ARSessionDelegate (on `queue`)

  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    let now = frame.timestamp
    if now - lastFrameAt >= Self.frameInterval {
      lastFrameAt = now
      sendColour(frame)
    }
    let thermal = ProcessInfo.processInfo.thermalState
    let interval = thermal == .serious ? Self.hotDepthInterval : Self.depthInterval
    if thermal != .critical, now - lastDepthAt >= interval {
      lastDepthAt = now
      sendDepth(frame, thermal: thermal)
    }
  }

  func session(_ session: ARSession, didFailWithError error: Error) {
    send(["type": "error", "message": error.localizedDescription])
  }

  func sessionWasInterrupted(_ session: ARSession) {
    send(["type": "interrupted"])
  }

  func sessionInterruptionEnded(_ session: ARSession) {
    send(["type": "resumed"])
  }

  // MARK: - Colour

  private func sendColour(_ frame: ARFrame) {
    let source = frame.capturedImage
    guard CVPixelBufferGetPlaneCount(source) == 2 else { return }
    CVPixelBufferLockBaseAddress(source, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }

    var srcY = planeBuffer(source, plane: 0)
    var srcUV = planeBuffer(source, plane: 1)
    let w = Self.frameWidth
    let h = Self.frameHeight
    var dstY = vImage_Buffer(
      data: yPlane, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
    var dstUV = vImage_Buffer(
      data: uvPlane, height: vImagePixelCount(h / 2), width: vImagePixelCount(w / 2),
      rowBytes: w)
    guard vImageScale_Planar8(&srcY, &dstY, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError,
      vImageScale_CbCr8(&srcUV, &dstUV, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError
    else { return }

    updatePreview(&dstY, &dstUV)

    if awaitingAck { return }
    awaitingAck = true
    send([
      "type": "frame",
      "width": w,
      "height": h,
      "y": FlutterStandardTypedData(bytes: Data(bytes: yPlane, count: w * h)),
      "yRow": w,
      "uv": FlutterStandardTypedData(bytes: Data(bytes: uvPlane, count: w * h / 2)),
      "uvRow": w,
    ])
  }

  private func planeBuffer(_ buffer: CVPixelBuffer, plane: Int) -> vImage_Buffer {
    vImage_Buffer(
      data: CVPixelBufferGetBaseAddressOfPlane(buffer, plane),
      height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(buffer, plane)),
      width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(buffer, plane)),
      rowBytes: CVPixelBufferGetBytesPerRowOfPlane(buffer, plane))
  }

  private func updatePreview(_ y: inout vImage_Buffer, _ uv: inout vImage_Buffer) {
    previewLock.lock()
    let textureId = previewTextureId
    previewLock.unlock()
    guard let textureId = textureId else { return }
    if !conversionReady {
      // capturedImage is full range (420f).
      var range = vImage_YpCbCrPixelRange(
        Yp_bias: 0, CbCr_bias: 128, YpRangeMax: 255, CbCrRangeMax: 255,
        YpMax: 255, YpMin: 0, CbCrMax: 255, CbCrMin: 0)
      guard
        vImageConvert_YpCbCrToARGB_GenerateConversion(
          kvImage_YpCbCrToARGBMatrix_ITU_R_601_4, &range, &conversion,
          kvImage420Yp8_CbCr8, kvImageARGB8888, vImage_Flags(kvImageNoFlags))
          == kvImageNoError
      else { return }
      conversionReady = true
    }
    if pool == nil {
      let attributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Self.frameWidth,
        kCVPixelBufferHeightKey as String: Self.frameHeight,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        kCVPixelBufferMetalCompatibilityKey as String: true,
      ]
      CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
    }
    guard let pool = pool else { return }
    var output: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess,
      let target = output
    else { return }
    CVPixelBufferLockBaseAddress(target, [])
    var dst = vImage_Buffer(
      data: CVPixelBufferGetBaseAddress(target),
      height: vImagePixelCount(Self.frameHeight),
      width: vImagePixelCount(Self.frameWidth),
      rowBytes: CVPixelBufferGetBytesPerRow(target))
    // ARGB → BGRA byte order.
    let permute: [UInt8] = [3, 2, 1, 0]
    let status = vImageConvert_420Yp8_CbCr8ToARGB8888(
      &y, &uv, &dst, &conversion, permute, 255, vImage_Flags(kvImageNoFlags))
    CVPixelBufferUnlockBaseAddress(target, [])
    guard status == kvImageNoError else { return }
    previewLock.lock()
    preview = target
    previewLock.unlock()
    DispatchQueue.main.async { self.textures.textureFrameAvailable(textureId) }
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    previewLock.lock()
    defer { previewLock.unlock() }
    guard let preview = preview else { return nil }
    return Unmanaged.passRetained(preview)
  }

  // MARK: - Depth

  private func sendDepth(_ frame: ARFrame, thermal: ProcessInfo.ThermalState) {
    guard let scene = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }
    let depthMap = scene.depthMap
    let width = CVPixelBufferGetWidth(depthMap)
    let height = CVPixelBufferGetHeight(depthMap)
    let depth = copyRows(depthMap, bytesPerPixel: 4, width: width, height: height)
    var confidence = Data(repeating: 2, count: width * height)
    if let confidenceMap = scene.confidenceMap,
      CVPixelBufferGetWidth(confidenceMap) == width,
      CVPixelBufferGetHeight(confidenceMap) == height
    {
      confidence = copyRows(confidenceMap, bytesPerPixel: 1, width: width, height: height)
    }

    let camera = frame.camera
    let k = camera.intrinsics  // column-major: [col][row]
    let sx = Double(width) / Double(camera.imageResolution.width)
    let sy = Double(height) / Double(camera.imageResolution.height)
    // World up (0,1,0) in camera coordinates = second row of the rotation.
    let t = camera.transform
    let up = [Double(t.columns.0.y), Double(t.columns.1.y), Double(t.columns.2.y)]
    var tracking = true
    if case .notAvailable = camera.trackingState { tracking = false }

    send([
      "type": "depth",
      "width": width,
      "height": height,
      "depth": FlutterStandardTypedData(bytes: depth),
      "confidence": FlutterStandardTypedData(bytes: confidence),
      "fx": Double(k.columns.0.x) * sx,
      "fy": Double(k.columns.1.y) * sy,
      "cx": Double(k.columns.2.x) * sx,
      "cy": Double(k.columns.2.y) * sy,
      "up": up,
      "tracking": tracking,
      "thermal": thermal.rawValue,
    ])
  }

  private func copyRows(_ buffer: CVPixelBuffer, bytesPerPixel: Int, width: Int, height: Int)
    -> Data
  {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let rowBytes = width * bytesPerPixel
    var data = Data(count: rowBytes * height)
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return data }
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    data.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
      guard let dst = out.baseAddress else { return }
      for row in 0..<height {
        memcpy(dst + row * rowBytes, base + row * stride, rowBytes)
      }
    }
    return data
  }
}
