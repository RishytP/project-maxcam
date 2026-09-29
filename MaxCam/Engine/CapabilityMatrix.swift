import AVFoundation
import Foundation

/// A validated, selectable recording configuration. Instances are only
/// produced by `CapabilityMatrix` after cross-checking every AVFoundation
/// capability surface, so the UI can trust that what it shows works.
struct RecordingConfiguration: Identifiable, Equatable, Sendable {
    enum Pipeline: String, Equatable, Sendable {
        case nativeProRes
        case photoRawProRes
        case hevc

        var displayName: String {
            switch self {
            case .nativeProRes: return "ProRes"
            case .photoRawProRes: return "ProRes RAW (photo)"
            case .hevc: return "HEVC"
            }
        }
    }

    let id: UUID
    let pipeline: Pipeline
    let resolution: CMVideoDimensions
    let frameRate: Double
    let colorSpace: AVCaptureColorSpace
    let codec: AVVideoCodecType
    let bitDepth: Int?
    let usesProResRAW: Bool
    let isAppleLog2: Bool
    let isAppleLog: Bool
    let isHDR: Bool

    var resolutionLabel: String {
        "\(resolution.width) x \(resolution.height)"
    }

    var summary: String {
        let color = isAppleLog2 ? "LOG2" : (isAppleLog ? "LOG" : colorSpace.displayName)
        return "\(resolutionLabel) \(Int(frameRate))fps \(codec.rawValue) \(pipeline.displayName) \(color)"
    }
}

/// Builds the authoritative capability matrix from the discovered devices.
/// Every entry is derived from a real format's `videoSupportedFrameRateRanges`,
/// `supportedColorSpaces`, and the video data output's advertised codecs.
enum CapabilityMatrix {
    /// Builds every valid config from the discovery result.
    static func configurations(
        devices: [CameraDeviceInfo],
        preferredDeviceID: String?,
        fallbackFrameRate: Double = 0,
        supportedCodecs: [AVVideoCodecType] = [.hevc]
    ) -> [RecordingConfiguration] {
        guard let camera = pick(devices, preferredDeviceID) else { return [] }
        var configs: [RecordingConfiguration] = []

        let proResHQ = supportedCodecs.contains(.proRes422HQ)

        // A ProRes 4444 / XQ pipeline would need gating on chroma support and
        // is not offered to avoid silent misuse; we only expose the 10-bit 422
        // family that ProRes on iPhone records natively.

        for formatInfo in camera.formats {
            let width = formatInfo.dimensions.width
            let height = formatInfo.dimensions.height
            guard width > 0, height > 0 else { continue }

            // Skip tiny formats that are clearly not "cine" (e.g. ultra-small
            // scan modes used for specific lenses or preview-only modes).
            guard max(width, height) >= 1920 else { continue }

            var frameRates = frameRateOptions(
                min: formatInfo.minFrameRate,
                max: formatInfo.maxFrameRate,
                fallback: fallbackFrameRate
            )
            // 25fps is a common cinema frame rate; ensure it shows up when the
            // range covers it.
            if !frameRates.contains(25), formatInfo.minFrameRate <= 25, formatInfo.maxFrameRate >= 25 {
                frameRates.append(25)
                frameRates.sort()
            }

            let colorSpaces = formatInfo.supportedColorSpaces
            let canLog2 = colorSpaces.contains(where: { $0.isLog2 })
            let canLog = colorSpaces.contains(where: { $0.isLog1 })
            let canWide = colorSpaces.contains(where: { $0.isWideColorSpace })
            let canSDR = colorSpaces.contains { $0 == .sRGB }

            for fps in frameRates {
                // A high dynamic range (HLG, HDR) config: only when the format
                // actually declares video HDR support.
                if formatInfo.isVideoHDRSupported && colorSpaces.contains(where: { $0 == .hlgBT2020 }) {
                    configs.append(RecordingConfiguration(
                        id: UUID(),
                        pipeline: .hevc,
                        resolution: formatInfo.dimensions,
                        frameRate: fps,
                        colorSpace: .hlgBT2020,
                        codec: .hevc,
                        bitDepth: 10,
                        usesProResRAW: false,
                        isAppleLog2: false,
                        isAppleLog: false,
                        isHDR: true
                    ))
                }

                // SDR / wide / log configurations. Only create a "Log2" one when
                // the format really supports Apple Log 2.
                var colorChoices: [AVCaptureColorSpace] = []
                if #available(iOS 26.0, *), canLog2 {
                    colorChoices.append(.appleLog2)
                }
                if canLog && !canLog2 {
                    colorChoices.append(.appleLog)
                }
                if canWide {
                    colorChoices.append(.p3D65)
                }
                if canSDR {
                    colorChoices.append(.sRGB)
                }

                for cs in colorChoices {
                    let isLog2 = cs.isLog2
                    configs.append(RecordingConfiguration(
                        id: UUID(),
                        pipeline: .hevc,
                        resolution: formatInfo.dimensions,
                        frameRate: fps,
                        colorSpace: cs,
                        codec: .hevc,
                        bitDepth: 10,
                        usesProResRAW: false,
                        isAppleLog2: isLog2,
                        isAppleLog: cs == .appleLog && !isLog2,
                        isHDR: false
                    ))

                    // Native ProRes recording (Phase 7): only offered when the
                    // device advertises a ProRes codec. ProRes on iPhone is
                    // capped at 30 fps by the silicon encoder; we honor that
                    // rather than offering unsupportable combinations.
                    if proResHQ && fps <= 30 {
                        configs.append(RecordingConfiguration(
                            id: UUID(),
                            pipeline: .nativeProRes,
                            resolution: formatInfo.dimensions,
                            frameRate: fps,
                            colorSpace: cs,
                            codec: .proRes422HQ,
                            bitDepth: 10,
                            usesProResRAW: false,
                            isAppleLog2: isLog2,
                            isAppleLog: cs == .appleLog && !isLog2,
                            isHDR: false
                        ))
                    }
                }
            }
        }

        return dedupe(configs)
    }

    private static func pick(_ devices: [CameraDeviceInfo], _ preferred: String?) -> CameraDeviceInfo? {
        if let preferred, let match = devices.first(where: { $0.uniqueID == preferred }) {
            return match
        }
        return devices.first { $0.position == .back }
    }

    private static func frameRateOptions(min: Double, max: Double, fallback: Double) -> [Double] {
        var rates = Set<Double>()
        for f in [23.976, 24,  25,  29.97,  30,  47.95,  48,  59.94,  60,  120,  240] {
            if f >= min - 0.01 && f <= max + 0.01 { rates.insert(f) }
        }
        if fallback > 0, fallback >= min, fallback <= max { rates.insert(fallback) }
        var sorted = Array(rates).sorted()
        if sorted.isEmpty { sorted = [min] }
        return sorted
    }

    private static func dedupe(_ configs: [RecordingConfiguration]) -> [RecordingConfiguration] {
        var seen = Set<String>()
        var out: [RecordingConfiguration] = []
        for c in configs {
            let key = "\(c.pipeline)|\(c.width)x\(c.height)|\(c.frameRate)|\(c.colorSpace.rawValue)|\(c.codec.rawValue)"
            if seen.insert(key).inserted { out.append(c) }
        }
        return out
    }
}

extension RecordingConfiguration {
    var width: Int { Int(resolution.width) }
    var height: Int { Int(resolution.height) }
}

private extension AVCaptureColorSpace {
    var isLog2: Bool {
        if #available(iOS 26.0, *), self == .appleLog2 { return true }
        return false
    }
    var isLog1: Bool { self == .appleLog }
    var isWideColorSpace: Bool { self == .p3D65 }
}