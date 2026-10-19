import AVFoundation
import Foundation

/// Answers "can this device do X, and if not, why not?" using only what the
/// runtime reports. Every disabled feature in the UI carries one of these
/// reasons so nothing is ever silently withheld.
struct CapabilityGate: @unchecked Sendable {
    enum Feature: String, CaseIterable, Sendable {
        case appleLog = "Apple Log"
        case appleLog2 = "Apple Log 2"
        case openGate = "Open Gate (full sensor)"
        case proRes = "ProRes"
        case proResRAW = "ProRes RAW"
        case hdr = "HDR (HLG)"
        case dynamicAspectRatio = "Dynamic aspect ratio"
        case wideColor = "Wide color (P3-D65)"
        case rawStill = "RAW still capture (Bayer)"
        case proRAWStill = "Apple ProRAW still capture"
    }

    let capabilities: DeviceCapabilities
    let encoder: EncoderCapabilities
    let raw: RawCapabilityProbe

    init(
        capabilities: DeviceCapabilities,
        encoder: EncoderCapabilities,
        raw: RawCapabilityProbe
    ) {
        self.capabilities = capabilities
        self.encoder = encoder
        self.raw = raw
    }

    struct Verdict: Sendable {
        let feature: Feature
        let isAvailable: Bool
        let reason: String
    }

    func verdict(for feature: Feature) -> Verdict {
        switch feature {
        case .appleLog:
            return verdict(
                feature,
                available: capabilities.allFormats.contains { $0.supportsAppleLog },
                unavailable: "No discovered format lists Apple Log in supportedColorSpaces."
            )
        case .appleLog2:
            return verdict(
                feature,
                available: capabilities.hasAppleLog2,
                unavailable: "No discovered format lists Apple Log 2 in supportedColorSpaces."
            )
        case .openGate:
            return verdict(
                feature,
                available: capabilities.hasOpenGateCapableFormat,
                unavailable: "No discovered format scans a square sensor area, so only cropped video is available."
            )
        case .proRes:
            return verdict(
                feature,
                available: encoder.supportsProRes,
                unavailable: "AVCaptureMovieFileOutput advertises no ProRes 422/4444 codec on this device."
            )
        case .proResRAW:
            return verdict(
                feature,
                available: encoder.supportsProResRAW,
                unavailable: "AVCaptureMovieFileOutput does not advertise the ProRes RAW codec (aprn)."
            )
        case .hdr:
            return verdict(
                feature,
                available: capabilities.allFormats.contains { $0.isVideoHDRSupported },
                unavailable: "No discovered format reports isVideoHDRSupported."
            )
        case .dynamicAspectRatio:
            return verdict(
                feature,
                available: capabilities.allFormats.contains { $0.supportsDynamicAspectRatios },
                unavailable: "No discovered format reports supportedDynamicAspectRatios."
            )
        case .wideColor:
            return verdict(
                feature,
                available: capabilities.allFormats.contains { $0.isWideColor },
                unavailable: "No discovered format lists P3-D65 in supportedColorSpaces."
            )
        case .rawStill:
            return verdict(
                feature,
                available: raw.supportsRawStillCapture,
                unavailable: "AVCapturePhotoOutput advertises no Bayer RAW pixel format. "
                    + "No public API delivers Bayer video frames either, so RAW is not offered."
            )
        case .proRAWStill:
            return verdict(
                feature,
                available: raw.isAppleProRAWSupported && !raw.appleProRAWPixelFormatCodes.isEmpty,
                unavailable: "AVCapturePhotoOutput does not advertise an Apple ProRAW pixel format "
                    + "(isAppleProRAWSupported is false or the format list is empty)."
            )
        }
    }

    var allVerdicts: [Verdict] {
        Feature.allCases.map(verdict(for:))
    }

    private func verdict(_ feature: Feature, available: Bool, unavailable: String) -> Verdict {
        Verdict(
            feature: feature,
            isAvailable: available,
            reason: available ? "Supported by the active device." : unavailable
        )
    }
}
