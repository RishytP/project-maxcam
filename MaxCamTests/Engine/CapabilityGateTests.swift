import XCTest

@testable import MaxCam

/// Unit tests for capability gating logic and pure value types. These only
/// exercise Swift paths that need no AVCaptureDevice instances, so they run
/// in CI and on-device without a camera simulator.
final class CapabilityGateTests: XCTestCase {

    func testFormatLacksReason() {
        let gate = CapabilityGate.formatLacks(
            option: "Apple Log 2",
            requirement: "no appleLog2 in supportedColorSpaces"
        )
        XCTAssertTrue(gate.reason.contains("Apple Log 2"))
        XCTAssertTrue(gate.reason.contains("supportedColorSpaces"))
    }

    func testAllReasonsAreNonEmpty() {
        let gates = CapabilityGate.allCases
        for gate in gates {
            XCTAssertFalse(gate.reason.isEmpty, "expected a reason for \(gate)")
        }
    }

    func testReasonLabelsForSelection() {
        XCTAssertEqual(
            CapabilityGate.fpsOutOfRange.reason,
            "The selected frame rate is not inside the format's supported range."
        )
    }

    // Records a configuration summary that must clearly distinguish modes.
    func testRecordingSummaryDistinguishesLog2() {
        let log2 = mockConfiguration(isAppleLog2: true)
        let sdr = mockConfiguration(isAppleLog2: false)
        XCTAssertNotEqual(log2.summary, sdr.summary)
        XCTAssertTrue(log2.summary.contains("LOG2") || log2.summary.contains("HEVC"))
    }

    // Manual auto-equivalence so equality comparisons in UI tests are stable.
    func testManualControlsAutoIsReasonableDefault() {
        let controls = ManualControls.auto
        XCTAssertEqual(controls, ManualControls())
    }
}

private extension CapabilityGateTests {
    func mockConfiguration(isAppleLog2: Bool) -> RecordingConfiguration {
        RecordingConfiguration(
            id: UUID(),
            pipeline: .hevc,
            resolution: CMVideoDimensions(width: 3840, height: 2160),
            frameRate: 24,
            colorSpace: .appleLog,
            codec: .hevc,
            bitDepth: 10,
            usesProResRAW: false,
            isAppleLog2: isAppleLog2,
            isAppleLog: true,
            isHDR: false
        )
    }
}

// Provide a deterministic test list independent of the device.
private extension CapabilityGate {
    static var allCases: [CapabilityGate] {
        [
            .formatLacks(option: "x", requirement: "y"),
            .fpsOutOfRange,
            .noColorSpaceNamed("z"),
            .codecNotAdvertised("hvc1"),
            .hdrNotAdvertised,
            .thermalCritical,
            .missingDevice,
        ]
    }
}