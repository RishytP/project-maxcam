import AVFoundation
import CoreMedia
import XCTest

@testable import MaxCam

/// Unit tests for the pure capability logic. These exercise the real code paths
/// in `CapabilityMatrix`, `CameraFormatInfo` and `DiagnosticsExport`; none of
/// them require a physical camera, so they run in CI.
final class CapabilityGateTests: XCTestCase {

    // MARK: - Frame rate derivation

    func testFrameRateOptionsIncludeCinemaRatesInsideRange() {
        let rates = CapabilityMatrix.frameRateOptions(min: 1, max: 60)
        XCTAssertTrue(rates.contains(23.976))
        XCTAssertTrue(rates.contains(24))
        XCTAssertTrue(rates.contains(25))
        XCTAssertTrue(rates.contains(29.97))
        XCTAssertTrue(rates.contains(30))
        XCTAssertTrue(rates.contains(60))
        XCTAssertFalse(rates.contains(120), "120 fps is outside a 1-60 range")
    }

    func testFrameRateOptionsKeep23976DistinctFrom24() {
        let rates = CapabilityMatrix.frameRateOptions(min: 1, max: 60)
        XCTAssertEqual(rates.filter { $0 == 23.976 }.count, 1)
        XCTAssertEqual(rates.filter { $0 == 24 }.count, 1)
        XCTAssertNotEqual(23.976, 24)
    }

    func testFrameRateOptionsRespectNarrowRange() {
        let rates = CapabilityMatrix.frameRateOptions(min: 24, max: 30)
        XCTAssertEqual(rates, [24, 25, 29.97, 30])
    }

    func testFrameRateOptionsFallBackWhenRangeHasNoCandidate() {
        // A hypothetical 31-32 fps range has no cinema rate in it.
        let rates = CapabilityMatrix.frameRateOptions(min: 31, max: 32)
        XCTAssertEqual(rates, [31])
    }

    // MARK: - ProRes gating

    func testProResCodecsAreOrderedBestFirst() {
        let advertised: [AVVideoCodecType] = [.proRes422LT, .proRes422HQ, .proRes422]
        let ordered = CapabilityMatrix.proResCodecs(from: advertised)
        XCTAssertEqual(ordered, [.proRes422HQ, .proRes422, .proRes422LT])
    }

    func testProResCodecsEmptyWhenNothingAdvertised() {
        XCTAssertTrue(CapabilityMatrix.proResCodecs(from: [.hevc, .h264]).isEmpty)
    }

    func testProResIsWithheldAboveThirtyFPS() {
        XCTAssertNil(CapabilityMatrix.bestProResCodec([.proRes422HQ], frameRate: 60))
        XCTAssertNil(CapabilityMatrix.bestProResCodec([.proRes422HQ], frameRate: 120))
    }

    func testProResOfferedAtAndBelowThirtyFPS() {
        XCTAssertEqual(CapabilityMatrix.bestProResCodec([.proRes422HQ], frameRate: 30), .proRes422HQ)
        XCTAssertEqual(CapabilityMatrix.bestProResCodec([.proRes422HQ], frameRate: 23.976), .proRes422HQ)
    }

    func testProResRAWIsNotReportedAsStandardProRes() {
        // `aprn` is ProRes RAW. It must never be treated as a ProRes 422 codec.
        let encoder = EncoderCapabilities(movieFileCodecs: [AVVideoCodecType(rawValue: "aprn")])
        XCTAssertFalse(encoder.supportsProRes)
        XCTAssertTrue(encoder.supportsProResRAW)
    }

    func testEncoderCapabilitiesDetectHEVCAndProRes() {
        let encoder = EncoderCapabilities(movieFileCodecs: [.hevc, .proRes422HQ])
        XCTAssertTrue(encoder.supportsHEVC)
        XCTAssertTrue(encoder.supportsProRes)
        XCTAssertFalse(encoder.supportsH264)
    }

    // MARK: - FourCC handling

    func testFourCCStringRoundTripsPrintableCodes() {
        // 'hvc1' == 0x68766331
        XCTAssertEqual(CameraFormatInfo.fourCCString(0x68766331), "hvc1")
        XCTAssertEqual(CameraFormatInfo.fourCCString(0x78343230), "x420")
    }

    func testFourCCStringFallsBackToHexForBinaryCodes() {
        // A leading 0x00 byte is not printable.
        XCTAssertEqual(CameraFormatInfo.fourCCString(0x00000001), "0x00000001")
    }

    // MARK: - RecordingConfiguration labelling

    func testLog2SummaryIsDistinctAndLabelledHonestly() {
        let log2 = makeConfiguration(colorSpace: .appleLog, isAppleLog2: true, isAppleLog: false)
        let log = makeConfiguration(colorSpace: .appleLog, isAppleLog2: false, isAppleLog: true)
        XCTAssertTrue(log2.summary.contains("Apple Log 2"))
        XCTAssertTrue(log.summary.contains("Apple Log"))
        XCTAssertFalse(log.summary.contains("Apple Log 2"))
        XCTAssertNotEqual(log2.summary, log.summary)
    }

    func testOpenGateIsReflectedInSummary() {
        let gated = makeConfiguration(isOpenGate: true)
        XCTAssertTrue(gated.summary.contains("OPEN GATE"))
        let cropped = makeConfiguration(isOpenGate: false)
        XCTAssertFalse(cropped.summary.contains("OPEN GATE"))
    }

    func testSummaryReportsBitDepthAndChroma() {
        let config = makeConfiguration(bitDepth: 10, chroma: .yuv420)
        XCTAssertTrue(config.summary.contains("10-bit"))
        XCTAssertTrue(config.summary.contains("4:2:0"))
    }

    func testColorLabelPrefersLogNaming() {
        XCTAssertEqual(makeConfiguration(isAppleLog2: true, isAppleLog: false).colorLabel, "Apple Log 2")
        XCTAssertEqual(makeConfiguration(isAppleLog2: false, isAppleLog: true).colorLabel, "Apple Log")
        XCTAssertEqual(
            makeConfiguration(colorSpace: .sRGB, isAppleLog2: false, isAppleLog: false).colorLabel,
            "sRGB"
        )
    }

    // MARK: - Error descriptions

    func testFrameRateErrorNamesTheRate() {
        let error = CameraEngineError.frameRateNotSupported(120)
        XCTAssertEqual(error.errorDescription, "120 fps is not supported by the active format.")
    }

    func testAllErrorDescriptionsAreNonEmpty() {
        let errors: [CameraEngineError] = [
            .cameraAccessDenied, .noCameraFound, .sessionConfigurationFailed,
            .invalidConfiguration, .recordingInProgress, .notRecording,
            .writerUnavailable, .finalizationIncomplete,
            .frameRateNotSupported(60), .colorSpaceNotSupported("Apple Log 2"),
        ]
        for error in errors {
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true, "missing text for \(error)")
        }
    }

    func testColorSpaceErrorNamesTheColorSpace() {
        let error = CameraEngineError.colorSpaceNotSupported("Apple Log 2")
        XCTAssertEqual(
            error.errorDescription,
            "The active format does not support the Apple Log 2 color space."
        )
    }

    // MARK: - Manual controls

    func testManualControlsDefaultIsAuto() {
        XCTAssertEqual(ManualControls.auto, ManualControls())
        XCTAssertNil(ManualControls.auto.iso)
        XCTAssertNil(ManualControls.auto.temperature)
    }

    func testThermalStateNames() {
        XCTAssertEqual(ProcessInfo.ThermalState.nominal.displayName, "nominal")
        XCTAssertEqual(ProcessInfo.ThermalState.serious.displayName, "serious")
        XCTAssertEqual(ProcessInfo.ThermalState.critical.displayName, "critical")
    }

    // MARK: - RAW still capture gating

    func testRawProbeWithNoBayerFormatsReportsNoRaw() {
        let probe = RawCapabilityProbe(
            isAppleProRAWSupported: false,
            rawPixelFormatCodes: [],
            bayerPixelFormatCodes: [],
            appleProRAWPixelFormatCodes: []
        )
        XCTAssertFalse(probe.hasAnyRaw)
        XCTAssertFalse(probe.supportsRawStillCapture)
        XCTAssertTrue(probe.reportLine.contains("none advertised"))
    }

    func testRawProbeDistinguishesBayerFromProRAW() {
        // Apple ProRAW is a processed container, not a Bayer mosaic. A probe
        // that advertises only ProRAW must not claim RAW still capture.
        let proRawOnly = RawCapabilityProbe(
            isAppleProRAWSupported: true,
            rawPixelFormatCodes: [0x70726F52],
            bayerPixelFormatCodes: [],
            appleProRAWPixelFormatCodes: [0x70726F52]
        )
        XCTAssertTrue(proRawOnly.hasAnyRaw)
        XCTAssertFalse(proRawOnly.supportsRawStillCapture)

        let bayer = RawCapabilityProbe(
            isAppleProRAWSupported: false,
            rawPixelFormatCodes: [0x72776120],
            bayerPixelFormatCodes: [0x72776120],
            appleProRAWPixelFormatCodes: []
        )
        XCTAssertTrue(bayer.supportsRawStillCapture)
    }

    func testRawProbeReportLineNamesFormatsWhenPresent() {
        let probe = RawCapabilityProbe(
            isAppleProRAWSupported: true,
            rawPixelFormatCodes: [0x72776120],
            bayerPixelFormatCodes: [0x72776120],
            appleProRAWPixelFormatCodes: []
        )
        XCTAssertTrue(probe.reportLine.contains("rwa "))
        XCTAssertTrue(probe.reportLine.contains("Apple ProRAW supported: YES"))
    }

    // MARK: - Capability gate

    func testGateReportsUnavailableRawWithReason() {
        let gate = CapabilityGate(
            capabilities: DeviceCapabilities.current(),
            encoder: EncoderCapabilities(movieFileCodecs: []),
            raw: RawCapabilityProbe(
                isAppleProRAWSupported: false,
                rawPixelFormatCodes: [],
                bayerPixelFormatCodes: [],
                appleProRAWPixelFormatCodes: []
            )
        )
        let verdict = gate.verdict(for: .rawStill)
        XCTAssertFalse(verdict.isAvailable)
        XCTAssertFalse(verdict.reason.isEmpty)
    }

    func testGateReportsAvailableBayerRaw() {
        let gate = CapabilityGate(
            capabilities: DeviceCapabilities.current(),
            encoder: EncoderCapabilities(movieFileCodecs: []),
            raw: RawCapabilityProbe(
                isAppleProRAWSupported: false,
                rawPixelFormatCodes: [0x72776120],
                bayerPixelFormatCodes: [0x72776120],
                appleProRAWPixelFormatCodes: []
            )
        )
        XCTAssertTrue(gate.verdict(for: .rawStill).isAvailable)
        XCTAssertFalse(gate.verdict(for: .proRAWStill).isAvailable)
    }

    func testEveryGateFeatureHasAVerdict() {
        let gate = CapabilityGate(
            capabilities: DeviceCapabilities.current(),
            encoder: EncoderCapabilities(movieFileCodecs: []),
            raw: RawCapabilityProbe.current()
        )
        XCTAssertEqual(gate.allVerdicts.count, CapabilityGate.Feature.allCases.count)
        for verdict in gate.allVerdicts {
            XCTAssertFalse(verdict.reason.isEmpty, "missing reason for \(verdict.feature)")
        }
    }

    // MARK: - Helpers

    private func makeConfiguration(
        colorSpace: AVCaptureColorSpace = .appleLog,
        bitDepth: Int = 10,
        chroma: ChromaFormat = .yuv420,
        isAppleLog2: Bool = false,
        isAppleLog: Bool = true,
        isOpenGate: Bool = false
    ) -> RecordingConfiguration {
        RecordingConfiguration(
            id: UUID(),
            pipeline: .hevc,
            resolution: CMVideoDimensions(width: 3840, height: 2160),
            frameRate: 24,
            colorSpace: colorSpace,
            codec: .hevc,
            bitDepth: bitDepth,
            chroma: chroma,
            isAppleLog2: isAppleLog2,
            isAppleLog: isAppleLog,
            isHDR: false,
            isOpenGate: isOpenGate,
            sourceFormatID: "test-format"
        )
    }
}
