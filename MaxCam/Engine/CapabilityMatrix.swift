import AVFoundation
import CoreMedia
import Foundation

/// Chroma subsampling of the encoded stream.
enum ChromaFormat: String, Equatable, Sendable {
    case yuv420 = "4:2:0"
    case yuv422 = "4:2:2"
    case yuv444 = "4:4:4"

    var displayName: String { rawValue }
}

/// How a recording is produced.
enum RecordingPipeline: String, Equatable, Sendable {
    /// HEVC written by `AVAssetWriter` from `AVCaptureVideoDataOutput` buffers.
    case hevc
    /// A ProRes variant written in place by `AVCaptureMovieFileOutput`.
    case proResMovieFile
    /// ProRes RAW. Only ever produced when the system advertises the codec.
    case proResRAW

    var displayName: String {
        switch self {
        case .hevc: return "HEVC"
        case .proResMovieFile: return "ProRes"
        case .proResRAW: return "ProRes RAW"
        }
    }
}

/// A validated, selectable recording configuration.
///
/// Instances are only produced by `CapabilityMatrix`, which cross-checks the
/// device's real format ranges, color spaces and advertised codecs, so the UI
/// can trust that everything it shows is genuinely available.
struct RecordingConfiguration: Identifiable, Equatable, @unchecked Sendable {
    let id: UUID
    let pipeline: RecordingPipeline
    let resolution: CMVideoDimensions
    let frameRate: Double
    let colorSpace: AVCaptureColorSpace
    let codec: AVVideoCodecType
    let bitDepth: Int
    let chroma: ChromaFormat
    let isAppleLog2: Bool
    let isAppleLog: Bool
    let isHDR: Bool
    /// True when the underlying format scans a square sensor area, i.e. true
    /// sensor-format Open Gate rather than a cropped frame.
    let isOpenGate: Bool
    /// Source format the configuration was derived from.
    let sourceFormatID: String

    var width: Int { Int(resolution.width) }
    var height: Int { Int(resolution.height) }

    var resolutionLabel: String { "\(width) x \(height)" }

    var colorLabel: String {
        if isAppleLog2 { return "Apple Log 2" }
        if isAppleLog { return "Apple Log" }
        return colorSpace.displayName
    }

    var summary: String {
        let gate = isOpenGate ? " OPEN GATE" : ""
        return "\(resolutionLabel)\(gate) \(Int(frameRate.rounded()))fps \(codec.rawValue) \(pipeline.displayName) \(colorLabel) \(bitDepth)-bit \(chroma.displayName)"
    }

    /// Written out by hand because `CMVideoDimensions` is an imported C struct
    /// and does not conform to `Equatable`, so the synthesised version would not
    /// compile. The comparison uses the meaningful value fields.
    static func == (lhs: RecordingConfiguration, rhs: RecordingConfiguration) -> Bool {
        lhs.id == rhs.id
            && lhs.pipeline == rhs.pipeline
            && lhs.width == rhs.width
            && lhs.height == rhs.height
            && lhs.frameRate == rhs.frameRate
            && lhs.colorSpace.rawValue == rhs.colorSpace.rawValue
            && lhs.codec.rawValue == rhs.codec.rawValue
            && lhs.bitDepth == rhs.bitDepth
            && lhs.chroma == rhs.chroma
            && lhs.isAppleLog2 == rhs.isAppleLog2
            && lhs.isAppleLog == rhs.isAppleLog
            && lhs.isHDR == rhs.isHDR
            && lhs.isOpenGate == rhs.isOpenGate
            && lhs.sourceFormatID == rhs.sourceFormatID
    }
}

/// Builds the authoritative capability matrix from the discovered devices.
///
/// Every entry derives from a real format's `videoSupportedFrameRateRanges`,
/// `supportedColorSpaces` and the codecs the system actually advertises.
enum CapabilityMatrix {

    struct Inputs {
        let devices: [CameraDeviceInfo]
        let preferredDeviceID: String?
        /// Codecs advertised by `AVCaptureMovieFileOutput`, which is what the
        /// ProRes (and ProRes RAW) paths depend on.
        let movieFileCodecs: [AVVideoCodecType]
    }

    static func configurations(_ inputs: Inputs) -> [RecordingConfiguration] {
        guard let camera = pick(inputs.devices, inputs.preferredDeviceID) else { return [] }

        let proResFamily = proResCodecs(from: inputs.movieFileCodecs)
        var configs: [RecordingConfiguration] = []

        for formatInfo in camera.formats {
            let width = Int(formatInfo.dimensions.width)
            let height = Int(formatInfo.dimensions.height)
            guard width > 0, height > 0, max(width, height) >= 1280 else { continue }

            let frameRates = frameRateOptions(
                min: formatInfo.minFrameRate,
                max: formatInfo.maxFrameRate
            )
            guard !frameRates.isEmpty else { continue }

            for fps in frameRates {
                for colorSpace in colorChoices(for: formatInfo) {
                    configs.append(makeHEVCConfig(
                        formatInfo: formatInfo,
                        colorSpace: colorSpace,
                        frameRate: fps
                    ))

                    if let proResCodec = bestProResCodec(proResFamily, frameRate: fps) {
                        configs.append(makeProResConfig(
                            formatInfo: formatInfo,
                            colorSpace: colorSpace,
                            frameRate: fps,
                            codec: proResCodec
                        ))
                    }
                }
            }
        }

        return dedupe(configs)
    }

    // MARK: - Color spaces

    private static func colorChoices(for formatInfo: CameraFormatInfo) -> [AVCaptureColorSpace] {
        var choices: [AVCaptureColorSpace] = []
        // Apple Log 2 first: it is the highest-quality log the device offers.
        // The symbol itself is iOS 26-only, so it is only named inside the
        // availability guard even though the runtime check already passed.
        if formatInfo.supportsAppleLog2 {
            if #available(iOS 26.0, *) {
                choices.append(.appleLog2)
            }
        }
        if formatInfo.supportsAppleLog {
            choices.append(.appleLog)
        }
        if formatInfo.supportedColorSpaces.contains(.HLG_BT2020), formatInfo.isVideoHDRSupported {
            choices.append(.HLG_BT2020)
        }
        if formatInfo.supportedColorSpaces.contains(.P3_D65) {
            choices.append(.P3_D65)
        }
        if formatInfo.supportedColorSpaces.contains(.sRGB) {
            choices.append(.sRGB)
        }
        return choices
    }

    // MARK: - Configuration builders

    private static func makeHEVCConfig(
        formatInfo: CameraFormatInfo,
        colorSpace: AVCaptureColorSpace,
        frameRate: Double
    ) -> RecordingConfiguration {
        // The HEVC path consumes 10-bit buffers whenever the pipeline can carry
        // them, which the log and HDR color spaces always can. SDR P3/sRGB is
        // still recorded 10-bit so gradients survive the encode.
        RecordingConfiguration(
            id: UUID(),
            pipeline: .hevc,
            resolution: formatInfo.dimensions,
            frameRate: frameRate,
            colorSpace: colorSpace,
            codec: .hevc,
            bitDepth: 10,
            chroma: .yuv420,
            isAppleLog2: colorSpace.isAppleLog2,
            isAppleLog: colorSpace == .appleLog,
            isHDR: colorSpace == .HLG_BT2020,
            isOpenGate: formatInfo.isOpenGateCapable,
            sourceFormatID: formatInfo.id
        )
    }

    private static func makeProResConfig(
        formatInfo: CameraFormatInfo,
        colorSpace: AVCaptureColorSpace,
        frameRate: Double,
        codec: AVVideoCodecType
    ) -> RecordingConfiguration {
        RecordingConfiguration(
            id: UUID(),
            pipeline: .proResMovieFile,
            resolution: formatInfo.dimensions,
            frameRate: frameRate,
            colorSpace: colorSpace,
            codec: codec,
            bitDepth: 10,
            chroma: .yuv422,
            isAppleLog2: colorSpace.isAppleLog2,
            isAppleLog: colorSpace == .appleLog,
            isHDR: colorSpace == .HLG_BT2020,
            isOpenGate: formatInfo.isOpenGateCapable,
            sourceFormatID: formatInfo.id
        )
    }

    // MARK: - Codec selection

    /// Ordered best-first so the highest quality ProRes the device advertises is
    /// the one offered.
    private static let proResPreference: [AVVideoCodecType] = [
        .proRes4444,
        .proRes422HQ,
        .proRes422,
        .proRes422LT,
        .proRes422Proxy,
    ]

    static func proResCodecs(from advertised: [AVVideoCodecType]) -> [AVVideoCodecType] {
        proResPreference.filter { advertised.contains($0) }
    }

    /// ProRes on iPhone is capped at 30 fps by the hardware encoder, so higher
    /// frame rates simply get no ProRes option rather than an unsupportable one.
    static func bestProResCodec(
        _ available: [AVVideoCodecType],
        frameRate: Double
    ) -> AVVideoCodecType? {
        guard frameRate <= 30.0 + 0.01 else { return nil }
        return available.first
    }

    // MARK: - Helpers

    private static func pick(_ devices: [CameraDeviceInfo], _ preferred: String?) -> CameraDeviceInfo? {
        if let preferred, let match = devices.first(where: { $0.uniqueID == preferred }) {
            return match
        }
        return devices.first { $0.position == .back } ?? devices.first
    }

    /// The cinema frame rates that fall inside the format's real range. Values
    /// are exact: no rounding, so 23.976 stays distinct from 24.
    static let candidateFrameRates: [Double] = [
        23.976, 24, 25, 29.97, 30, 47.952, 48, 50, 59.94, 60, 100, 119.88, 120, 240,
    ]

    static func frameRateOptions(min: Double, max: Double) -> [Double] {
        let tolerance = 0.01
        var rates = candidateFrameRates.filter { $0 >= min - tolerance && $0 <= max + tolerance }
        if rates.isEmpty {
            rates = [min]
        }
        return rates
    }

    private static func dedupe(_ configs: [RecordingConfiguration]) -> [RecordingConfiguration] {
        var seen = Set<String>()
        var out: [RecordingConfiguration] = []
        for config in configs {
            let key = "\(config.pipeline.rawValue)|\(config.width)x\(config.height)|"
                + "\(config.frameRate)|\(config.colorSpace.rawValue)|\(config.codec.rawValue)"
            if seen.insert(key).inserted {
                out.append(config)
            }
        }
        return out
    }
}

extension AVCaptureColorSpace {
    var isAppleLog2: Bool {
        guard #available(iOS 26.0, *) else { return false }
        return self == .appleLog2
    }
}
