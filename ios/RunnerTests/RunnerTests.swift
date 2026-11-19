import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  func testColourAckDoesNotBypassTheAICadence() {
    var gate = LidarColourEventGate(interval: LidarCameraPlugin.colourEventInterval)
    XCTAssertTrue(gate.admit(at: 0))
    gate.acknowledge()
    XCTAssertFalse(gate.admit(at: 0.1))
    XCTAssertTrue(gate.admit(at: 0.15))
  }

  func testSlowColourConsumerDropsOldFramesWithoutCatchUpBurst() {
    var gate = LidarColourEventGate(interval: LidarCameraPlugin.colourEventInterval)
    XCTAssertTrue(gate.admit(at: 0))
    XCTAssertFalse(gate.admit(at: 1))
    XCTAssertFalse(gate.admit(at: 5))
    gate.acknowledge()
    XCTAssertTrue(gate.admit(at: 5.01))
    gate.acknowledge()
    XCTAssertFalse(gate.admit(at: 5.02))
  }

  func testColourGateResetReleasesOutstandingAckAndCaptureTimestamp() {
    var gate = LidarColourEventGate(interval: LidarCameraPlugin.colourEventInterval)
    XCTAssertTrue(gate.admit(at: 10))
    gate.reset()
    XCTAssertTrue(gate.admit(at: 0))
  }

  func testThirtyFPSPreviewCadenceDoesNotFloodAIColourEvents() {
    var gate = LidarColourEventGate(interval: LidarCameraPlugin.colourEventInterval)
    var capturedTimes: [TimeInterval] = []
    for frame in 0..<60 {
      let at = Double(frame) / 30
      if gate.admit(at: at) {
        capturedTimes.append(at)
        gate.acknowledge()
      }
    }
    XCTAssertGreaterThanOrEqual(capturedTimes.count, 10)
    XCTAssertLessThanOrEqual(capturedTimes.count, 14)
    for index in 1..<capturedTimes.count {
      XCTAssertGreaterThanOrEqual(
        capturedTimes[index] - capturedTimes[index - 1],
        LidarCameraPlugin.colourEventInterval)
    }
  }

}
