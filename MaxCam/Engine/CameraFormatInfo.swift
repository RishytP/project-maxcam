import AVFoundation
import CoreMedia
import Foundation

/// `CMVideoDimensions` is an imported C struct and does not conform to
/// `Equatable`, so resolution comparisons go through this helper.
extension CMVideoDimensions {
    func sameResolution(as other: CMVideoDimensions) -> Bool {
        width == other.width && height == other.height
    }
}

/// A device-agnostic, read-only snapshot of a single `AVCaptureDevice.Format`.
///
/// `AVCaptureDevice.Format` is not `Sendable`, so the engine snapshots every
/// value it needs at discovery time and keeps the framework object itself only
/// for the moment the format is applied to a device. Nothing here is inferred:
/// each field is read from AVFoundation.
struct CameraFormatInfo: Identifiable, @unchecked Sendable {
    let format: AVCaptureDevice.Format
    let deviceUniqueID: String
    let dimensions: CMVideoDimensions
    let mediaSubType: OSType
    let minFrameRate: Double
    let maxFrameRate: Double
    let fieldOfView: Double
    let isVideoHDRSupported: Bool
    let isGlobalToneMappingSupported: Bool
    let supportedColorSpaces: [AVCaptureColorSpace]
    let dynamicAspectRatioLabels: [String]
    /// True only when the format scans a full square sensor area.
    let isSquareSensorScan: Bool

    init(format: AVCaptureDevice.Format, deviceUniqueID: String) {
        self.format = format
        self.deviceUniqueID = deviceUniqueID

        let description = format.formatDescription
        self.dimensions = CMVideoFormatDescriptionGetDimensions(description)
        self.mediaSubType = CMFormatDescriptionGetMediaSubType(description)

        let ranges = format.videoSupportedFrameRateRanges
        self.minFrameRate = ranges.map(\.minFrameRate).min() ?? 0
        self.maxFrameRate = ranges.map(\.maxFrameRate).max() ?? 0
        self.fieldOfView = Double(format.videoFieldOfView)
        self.isVideoHDRSupported = format.isVideoHDRSupported
        self.isGlobalToneMappingSupported = format.isGlobalToneMappingSupported
        self.supportedColorSpaces = format.supportedColorSpaces

        let width = CMVideoFormatDescriptionGetDimensions(description).width
        let height = CMVideoFormatDescriptionGetDimensions(description).height
        self.isSquareSensorScan = width == height

        // Dynamic aspect ratio is iOS 26-only, and the SDK type
        // `AVCaptureDevice.AspectRatio` cannot be named at all from a lower
        // deployment target, so the whole probe lives inside an `@available`
        // helper that older systems never call.
        self.dynamicAspectRatioLabels = CameraFormatInfo.dynamicAspectRatioLabels(for: format)
    }

    @available(iOS 26.0, *)
    private static func labelsForDynamicAspectRatios(
        _ ratios: [AVCaptureDevice.AspectRatio]
    ) -> [String] {
        // `AspectRatio` imports as a raw-representable struct, not an enum, so
        // it is matched with `==` rather than a switch.
        ratios.map { ratio in
            if ratio == .ratio16x9 { return "16:9" }
            if ratio == .ratio4x3 { return "4:3" }
            if ratio == .ratio1x1 { return "1:1" }
            if ratio == .ratio9x16 { return "9:16" }
            if ratio == .ratio3x4 { return "3:4" }
            return ratio.rawValue
        }
    }

    private static func dynamicAspectRatioLabels(for format: AVCaptureDevice.Format) -> [String] {
        guard #available(iOS 26.0, *) else { return [] }
        return labelsForDynamicAspectRatios(format.supportedDynamicAspectRatios)
    }

    var id: String {
        "\(deviceUniqueID)|\(dimensions.width)x\(dimensions.height)|\(mediaSubTypeLabel)|\(Int(maxFrameRate))"
    }

    var resolutionLabel: String {
        "\(dimensions.width) x \(dimensions.height)"
    }

    var frameRateLabel: String {
        minFrameRate == maxFrameRate
            ? "\(Int(minFrameRate))"
            : "\(Int(minFrameRate))-\(Int(maxFrameRate))"
    }

    var mediaSubTypeLabel: String {
        Self.fourCCString(mediaSubType)
    }

    var supportsDynamicAspectRatios: Bool {
        !dynamicAspectRatioLabels.isEmpty
    }

    /// Reported as true sensor-format Open Gate only when the format scans a
    /// square sensor area. Everything else is a conventional crop.
    var isOpenGateCapable: Bool {
        isSquareSensorScan
    }

    var isWideColor: Bool {
        supportedColorSpaces.contains { $0 == .P3_D65 }
    }

    var supportsAppleLog: Bool {
        supportedColorSpaces.contains { $0 == .appleLog }
    }

    var supportsAppleLog2: Bool {
        guard #available(iOS 26.0, *) else { return false }
        return supportedColorSpaces.contains { $0 == .appleLog2 }
    }

    /// Bit depth inferred from the format's four-character pixel format code.
    /// This describes the *sensor output* format, not the encoder bit depth,
    /// which is selected separately.
    var bitDepthGuess: Int? {
        switch mediaSubType {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
            return 10
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_32BGRA,
             kCVPixelFormatType_32ARGB:
            return 8
        default:
            return nil
        }
    }

    var colorSpaceLabels: [String] {
        supportedColorSpaces.map(\.displayName)
    }

    var diagnosticLines: [String] {
        var lines = [
            "Format: \(resolutionLabel)",
            "Media subtype: \(mediaSubTypeLabel) (\(String(format: "0x%08X", mediaSubType)))",
            "FPS: \(frameRateLabel)",
            "FOV: \(String(format: "%.1f", fieldOfView)) deg",
            "Video HDR: \(isVideoHDRSupported ? "YES" : "no")",
            "Global tone mapping: \(isGlobalToneMappingSupported ? "YES" : "no")",
            "Bit depth (fourCC): \(bitDepthGuess.map { "\($0)-bit" } ?? "unknown")",
            "Color spaces: \(colorSpaceLabels.isEmpty ? "-" : colorSpaceLabels.joined(separator: ", "))",
            "Open Gate (square sensor scan): \(isOpenGateCapable ? "YES" : "no")",
        ]
        if !dynamicAspectRatioLabels.isEmpty {
            lines.append("Dynamic aspect ratios: \(dynamicAspectRatioLabels.joined(separator: ", "))")
        }
        return lines
    }

    /// Converts a CoreMedia four-character code to its printable spelling.
    static func fourCCString(_ code: OSType) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else {
            return String(format: "0x%08X", code)
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

extension AVCaptureColorSpace {
    var displayName: String {
        switch self {
        case .sRGB: return "sRGB"
        case .P3_D65: return "P3-D65"
        case .appleLog: return "Apple Log"
        case .HLG_BT2020: return "HLG BT.2020"
        default:
            if #available(iOS 26.0, *), self == .appleLog2 {
                return "Apple Log 2"
            }
            return "raw \(rawValue)"
        }
    }
}
