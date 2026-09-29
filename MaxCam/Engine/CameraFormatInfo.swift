import AVFoundation
import Foundation

/// A device-agnostic description of a single `AVCaptureDevice.Format`,
/// normalizing every capability the public AVFoundation APIs expose for display.
///
/// Wraps a non-Sendable `AVCaptureDevice.Format` for read-only actor-safe
/// snapshotting; never mutated after construction.
struct CameraFormatInfo: Identifiable, @unchecked Sendable {
    let format: AVCaptureDevice.Format
    let dimensions: CMVideoDimensions
    let mediaSubType: OSType
    let minFrameRate: Double
    let maxFrameRate: Double
    let fieldOfView: Double
    let isVideoHDRSupported: Bool
    let isGlobalToneMappingSupported: Bool
    let lensAperture: Float?
    let supportedColorSpaces: [AVCaptureColorSpace]
    let supportsDynamicAspectRatios: Bool
    let dynamicAspectRatioLabels: [String]

    init(format: AVCaptureDevice.Format) {
        self.format = format
        let desc = format.formatDescription
        self.dimensions = CMVideoFormatDescriptionGetDimensions(desc)
        self.mediaSubType = CMFormatDescriptionGetMediaSubType(desc as! CMFormatDescription)
        self.minFrameRate = format.videoSupportedFrameRateRanges.map { $0.minFrameRate }.min() ?? 0
        self.maxFrameRate = format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
        self.fieldOfView = format.videoFieldOfView
        if #available(iOS 17.0, *) {
            self.isVideoHDRSupported = format.isVideoHDRSupported
            self.isGlobalToneMappingSupported = format.isGlobalToneMappingSupported
            self.lensAperture = format.lensAperture
        } else {
            self.isVideoHDRSupported = false
            self.isGlobalToneMappingSupported = false
            self.lensAperture = nil
        }
        self.supportedColorSpaces = Array(format.supportedColorSpaces)
        // Dynamic aspect ratio is an iOS 26 API. We store only availability-safe
        // derived values so this type compiles against the iOS 17 deployment
        // target; the SDK types are only touched inside the #available branch.
        if #available(iOS 26.0, *) {
            self.supportsDynamicAspectRatios = !format.supportedDynamicAspectRatios.isEmpty
            self.dynamicAspectRatioLabels = format.supportedDynamicAspectRatios.map(Self.aspectRatioLabel)
        } else {
            self.supportsDynamicAspectRatios = false
            self.dynamicAspectRatioLabels = []
        }
    }

    var id: String {
        "\(dimensions.width)x\(dimensions.height)-\(fourCCString(mediaSubType))-\(Int(maxFrameRate))"
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
        fourCCString(mediaSubType)
    }

    var isWideColor: Bool {
        supportedColorSpaces.contains { $0 == .p3D65 }
            || mediaSubType & 0xFFFFFF00 == 0x62363400
    }

    var bitDepthGuess: Int? {
        switch mediaSubType {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            return 10
        case kCVPixelFormatType_420YpCbCr10v210BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10v210BiPlanarFullRange:
            return 10
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_32BGRA,
             kCVPixelFormatType_32ARGB:
            return 8
        case kCVPixelFormatType_Lossless_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_Lossless_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange,
             kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarFullRange:
            return 10
        default:
            return nil
        }
    }

    var colorSpaceLabels: [String] {
        supportedColorSpaces.map { $0.displayName }
    }

    var aspectRatioLabels: [String] {
        dynamicAspectRatioLabels
    }

    /// Named helper for the iOS 26 aspect-ratio SDK type; referenced only from
    /// inside an `#available(iOS 26.0, *)` branch.
    @available(iOS 26.0, *)
    private static func aspectRatioLabel(_ ratio: AVCaptureDevice.AspectRatio) -> String {
        switch ratio {
        case .ratio16x9: return "16:9"
        case .ratio4x3: return "4:3"
        case .ratio1x1: return "1:1"
        case .ratio9x16: return "9:16"
        case .ratio3x4: return "3:4"
        default: return "ratio"
        }
    }

    var diagnosticLines: [String] {
        var lines = [
            "Format: \(resolutionLabel)",
            "Media subtype: \(mediaSubTypeLabel) (\(String(format: "0x%08X", mediaSubType)))",
            "FPS: \(frameRateLabel)",
            "FOV: \(String(format: "%.1f", fieldOfView))",
            "Video HDR: \(isVideoHDRSupported ? "YES" : "no")",
            "Global tone mapping: \(isGlobalToneMappingSupported ? "YES" : "no")",
        ]
        if let aperture = lensAperture {
            lines.append("Lens aperture: f/\(String(format: "%.1f", aperture)))")
        }
        if let depth = bitDepthGuess {
            lines.append("Bit depth (fourCC guess): \(depth)-bit")
        } else {
            lines.append("Bit depth (fourCC guess): unknown")
        }
        lines.append("Color spaces: \(colorSpaceLabels.isEmpty ? "-" : colorSpaceLabels.joined(separator: ", ")))")
        if !dynamicAspectRatioLabels.isEmpty {
            lines.append("Dynamic aspect ratios: \(dynamicAspectRatioLabels.joined(separator: ", ")))")
        }
        return lines
    }
}

extension AVCaptureColorSpace {
    var displayName: String {
        switch self {
        case .sRGB: return "sRGB"
        case .p3D65: return "P3-D65"
        case .appleLog: return "Apple Log"
        case .hlgBT2020: return "HLG BT.2020"
        default:
            if #available(iOS 26.0, *) {
                if self == .appleLog2 { return "Apple Log 2" }
            }
            return "raw \(rawValue)"
        }
    }
}

private func fourCCString(_ code: OSType) -> String {
    let bytes: [UInt8] = [
        UInt8((code >> 24) & 0xFF),
        UInt8((code >> 16) & 0xFF),
        UInt8((code >> 8) & 0xFF),
        UInt8(code & 0xFF),
    ]
    return String(bytes: bytes, encoding: .ascii) ?? String(format: "0x%08X", code)
}