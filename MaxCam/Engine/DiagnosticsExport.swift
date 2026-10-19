import AVFoundation
import Foundation
import UIKit

/// Builds the complete, human-readable capability report used for on-device
/// support debugging and by the unit tests.
struct DiagnosticsExport {
    let deviceModel: String
    let systemVersion: String
    let osVersionString: String
    let buildNumber: String
    let cameraAccess: Bool
    let cameras: [CameraDeviceInfo]
    let encoderCodecs: [String]
    let videoPixelFormatTypes: [String]
    let rawPhotoFormats: String
    let thermalState: String
    let featureFlags: [String: Bool]

    var report: String {
        var lines: [String] = []
        lines.append("MaxCam Diagnostics")
        lines.append(String(repeating: "=", count: 18))
        lines.append("Device: \(deviceModel)")
        lines.append("iOS: \(systemVersion) (\(osVersionString), build \(buildNumber))")
        lines.append("Camera access: \(cameraAccess ? "granted" : "denied")")
        lines.append("Thermal state: \(thermalState)")
        lines.append("")

        lines.append("Encoders advertised by AVCaptureMovieFileOutput: "
            + (encoderCodecs.isEmpty ? "none" : encoderCodecs.joined(separator: ", ")))
        lines.append("AVCaptureVideoDataOutput pixel formats: "
            + (videoPixelFormatTypes.isEmpty ? "none" : videoPixelFormatTypes.joined(separator: ", ")))
        lines.append("RAW still photo formats (AVCapturePhotoOutput): " + rawPhotoFormats)
        lines.append("")

        for camera in cameras {
            lines.append("Camera [\(camera.positionLabel)] \(camera.displayName) (\(camera.uniqueID))")
            lines.append("  Type: \(camera.deviceType.rawValue)")
            lines.append("  Constituents: \(camera.constituentLabel)")
            lines.append("  Flash: \(camera.hasFlash ? "yes" : "no")")
            lines.append("  Connected: \(camera.isConnected ? "yes" : "no")")
            if let aperture = camera.lensAperture {
                lines.append("  Lens aperture: f/\(String(format: "%.1f", aperture))")
            }
            lines.append("  Formats: \(camera.formats.count)")
            for format in camera.formats {
                lines.append("    - \(format.diagnosticLines.joined(separator: " | "))")
            }
            lines.append("")
        }

        lines.append("Feature flags:")
        for (key, value) in featureFlags.sorted(by: { $0.key < $1.key }) {
            lines.append("  \(key): \(value ? "YES" : "no")")
        }
        return lines.joined(separator: "\n")
    }

    static func current() -> DiagnosticsExport {
        let capabilities = DeviceCapabilities.current()
        let encoder = EncoderCapabilities.current()
        let raw = RawCapabilityProbe.current()
        let pixelFormats = AVCaptureVideoDataOutput().availableVideoPixelFormatTypes
            .map(CameraFormatInfo.fourCCString)

        return DiagnosticsExport(
            deviceModel: capabilities.modelID,
            systemVersion: UIDevice.current.systemVersion,
            osVersionString: ProcessInfo.processInfo.operatingSystemVersionString,
            buildNumber: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
            cameraAccess: AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
            cameras: capabilities.cameras,
            encoderCodecs: encoder.movieFileCodecs.map(\.rawValue),
            videoPixelFormatTypes: pixelFormats,
            rawPhotoFormats: raw.reportLine,
            thermalState: ProcessInfo.processInfo.thermalState.displayName,
            featureFlags: [
                "ProRes encoder advertised": encoder.supportsProRes,
                "ProRes RAW encoder advertised": encoder.supportsProResRAW,
                "HEVC encoder advertised": encoder.supportsHEVC,
                "Has rear cameras": !capabilities.rearCameras.isEmpty,
                "Any Apple Log color space": capabilities.allFormats.contains { $0.supportsAppleLog },
                "Any Apple Log 2 color space": capabilities.hasAppleLog2,
                "Any Open Gate (square sensor) format": capabilities.hasOpenGateCapableFormat,
                "Any dynamic aspect ratio format": capabilities.allFormats.contains { $0.supportsDynamicAspectRatios },
                "Any HDR-capable format": capabilities.allFormats.contains { $0.isVideoHDRSupported },
                "Bayer RAW still capture": raw.supportsRawStillCapture,
                "Apple ProRAW still capture": raw.isAppleProRAWSupported
                    && !raw.appleProRAWPixelFormatCodes.isEmpty,
                "Bayer video frames (public API)": false,
            ]
        )
    }
}
