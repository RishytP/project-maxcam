import AVFoundation
import Foundation
import UIKit

/// Builds a complete, human-readable capability report for support debugging.
/// This powers the "Export diagnostics" share sheet and unit tests.
struct DiagnosticsExport {
    let deviceModel: String
    let systemVersion: String
    let osVersionString: String
    let buildNumber: String
    let cameraAccess: Bool
    let cameras: [CameraDeviceInfo]
    let encoderCodecs: [String]
    let featureFlags: [String: Bool]

    var report: String {
        var lines: [String] = []
        lines.append("MaxCam Diagnostics")
        lines.append("==================")
        lines.append("Device: \(deviceModel)")
        lines.append("iOS: \(systemVersion) (\(osVersionString), build \(buildNumber))")
        lines.append("Camera access: \(cameraAccess ? "granted" : "denied")")
        lines.append("")

        for camera in cameras {
            lines.append("Camera [\(camera.positionLabel)] \(camera.displayName) (\(camera.uniqueID))")
            lines.append("  Type: \(camera.deviceType.rawValue)")
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

        lines.append("Encoders advertised by AVCaptureMovieFileOutput: \(encoderCodecs.isEmpty ? "none" : encoderCodecs.joined(separator: ", "))")
        lines.append("")
        lines.append("Feature flags:")
        for (key, value) in featureFlags.sorted(by: { $0.key < $1.key }) {
            lines.append("  \(key): \(value ? "YES" : "no")")
        }
        return lines.joined(separator: "\n")
    }

    static func current() -> DiagnosticsExport {
        let capabilities = DeviceCapabilities.current()
        let encoder = EncoderCapabilities.current()

        let hasLog = capabilities.cameras.flatMap { $0.formats }.contains {
            $0.supportedColorSpaces.contains { $0 == .appleLog }
        }
        var hasLog2 = false
        if #available(iOS 26.0, *) {
            hasLog2 = capabilities.cameras.flatMap { $0.formats }.contains {
                $0.supportedColorSpaces.contains { $0 == .appleLog2 }
            }
        }

        return DiagnosticsExport(
            deviceModel: capabilities.modelID,
            systemVersion: UIDevice.current.systemVersion,
            osVersionString: ProcessInfo.processInfo.operatingSystemVersionString,
            buildNumber: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
            cameraAccess: AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
            cameras: capabilities.cameras,
            encoderCodecs: encoder.movieFileCodecs.map { $0.rawValue },
            featureFlags: [
                "ProRes encoder advertised": encoder.supportsProRes,
                "HEVC encoder advertised": encoder.supportsHEVC,
                "Has rear cameras": !capabilities.rearCameras.isEmpty,
                "Any Apple Log color space": hasLog,
                "Any Apple Log 2 color space": hasLog2,
            ]
        )
    }
}