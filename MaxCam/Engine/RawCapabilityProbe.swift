import AVFoundation
import Foundation

/// What the still-image pipeline will actually deliver as RAW.
///
/// Phase 8 asks whether Bayer/RAW sensor data reaches third-party apps. The
/// honest answer is: only as still photos, and only through
/// `AVCapturePhotoOutput`. There is no public API that delivers Bayer video
/// frames to an `AVCaptureVideoDataOutput`, so this probe exists to report the
/// photo-side truth rather than to fake a RAW video path.
///
/// The probe is deliberately read-only and cheap: it builds a throwaway
/// session with the photo output attached, reads the advertised formats, and
/// tears it down. Apple requires the output to be connected to a session with a
/// video source before `availableRawPhotoPixelFormatTypes` is populated.
struct RawCapabilityProbe: @unchecked Sendable {
    let isAppleProRAWSupported: Bool
    /// Four-character codes for every RAW pixel format the output advertises.
    let rawPixelFormatCodes: [OSType]
    let bayerPixelFormatCodes: [OSType]
    let appleProRAWPixelFormatCodes: [OSType]

    var hasAnyRaw: Bool { !rawPixelFormatCodes.isEmpty }
    var hasBayerRaw: Bool { !bayerPixelFormatCodes.isEmpty }

    /// True only when the system will hand us a true Bayer mosaic frame. This
    /// is what "RAW" means in the brief, and it is distinct from Apple ProRAW,
    /// which is a processed container.
    var supportsRawStillCapture: Bool { hasBayerRaw }

    var reportLine: String {
        guard hasAnyRaw else {
            return "none advertised (device or current configuration does not expose RAW photo formats)"
        }
        let codes = rawPixelFormatCodes.map(CameraFormatInfo.fourCCString).joined(separator: ", ")
        return "\(codes) | Apple ProRAW supported: \(isAppleProRAWSupported ? "YES" : "no")"
    }

    /// Probes the hardware. Returns an all-false result when no video device is
    /// available, which is the correct answer on a device with no camera.
    static func current() -> RawCapabilityProbe {
        guard let device = AVCaptureDevice.default(for: .video) else {
            return RawCapabilityProbe(
                isAppleProRAWSupported: false,
                rawPixelFormatCodes: [],
                bayerPixelFormatCodes: [],
                appleProRAWPixelFormatCodes: []
            )
        }

        let session = AVCaptureSession()
        let output = AVCapturePhotoOutput()
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
        }
        guard session.canAddOutput(output) else {
            return RawCapabilityProbe(
                isAppleProRAWSupported: false,
                rawPixelFormatCodes: [],
                bayerPixelFormatCodes: [],
                appleProRAWPixelFormatCodes: []
            )
        }
        session.addOutput(output)

        // Only meaningful once the output is attached to a session with a video
        // source, which is why the read happens here and not earlier.
        let formats = output.availableRawPhotoPixelFormatTypes
        return RawCapabilityProbe(
            isAppleProRAWSupported: output.isAppleProRAWSupported,
            rawPixelFormatCodes: formats,
            bayerPixelFormatCodes: formats.filter { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) },
            appleProRAWPixelFormatCodes: formats.filter { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }
        )
    }
}
