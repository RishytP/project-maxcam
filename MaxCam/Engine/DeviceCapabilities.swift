import AVFoundation
import Darwin
import Foundation
import UIKit

/// One camera (`AVCaptureDevice`) with every format it exposes, normalized for
/// display. Built from a runtime discovery session, never from a model table.
struct CameraDeviceInfo: Identifiable, @unchecked Sendable {
    let uniqueID: String
    let position: AVCaptureDevice.Position
    let deviceType: AVCaptureDevice.DeviceType
    let hasFlash: Bool
    let isConnected: Bool
    /// The device's fixed lens aperture (f-number), when the hardware reports one.
    let lensAperture: Float?
    let constituentDeviceTypes: [AVCaptureDevice.DeviceType]
    let formats: [CameraFormatInfo]

    var id: String { uniqueID }

    var displayName: String {
        switch deviceType {
        case .builtInWideAngleCamera: return "Wide"
        case .builtInUltraWideCamera: return "Ultra Wide"
        case .builtInTelephotoCamera: return "Telephoto"
        case .builtInDualCamera: return "Dual (Wide + Tele)"
        case .builtInDualWideCamera: return "Dual Wide"
        case .builtInTripleCamera: return "Triple"
        case .builtInLiDARDepthCamera: return "LiDAR"
        case .builtInTrueDepthCamera: return "TrueDepth"
        default: return deviceType.rawValue
        }
    }

    var positionLabel: String {
        switch position {
        case .back: return "Rear"
        case .front: return "Front"
        case .unspecified: return "Unspecified"
        default: return "Other"
        }
    }

    var constituentLabel: String {
        constituentDeviceTypes.isEmpty
            ? "physical lens"
            : constituentDeviceTypes.map { $0.rawValue }.joined(separator: " + ")
    }
}

/// The runtime capability tree for the physical device.
///
/// Every field is populated from AVFoundation queries; nothing is assumed from
/// the marketing name of the phone. The snapshot is produced once on the main
/// thread and then read-only.
struct DeviceCapabilities: @unchecked Sendable {
    let modelID: String
    let systemVersion: String
    let osVersionString: String
    let screenScale: CGFloat
    let hasCameraAccess: Bool
    let cameras: [CameraDeviceInfo]

    var rearCameras: [CameraDeviceInfo] {
        cameras.filter { $0.position == .back }
    }

    var allFormats: [CameraFormatInfo] {
        cameras.flatMap(\.formats)
    }

    /// True when any discovered format genuinely scans a square sensor area.
    var hasOpenGateCapableFormat: Bool {
        allFormats.contains { $0.isOpenGateCapable }
    }

    var hasAppleLog2: Bool {
        allFormats.contains { $0.supportsAppleLog2 }
    }

    static func current() -> DeviceCapabilities {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInUltraWideCamera,
                .builtInWideAngleCamera,
                .builtInTelephotoCamera,
                .builtInDualCamera,
                .builtInDualWideCamera,
                .builtInTripleCamera,
                .builtInLiDARDepthCamera,
                .builtInTrueDepthCamera,
            ],
            mediaType: .video,
            position: .unspecified
        )

        let cameras: [CameraDeviceInfo] = discovery.devices.map { device in
            let formats = device.formats.map {
                CameraFormatInfo(format: $0, deviceUniqueID: device.uniqueID)
            }
            return CameraDeviceInfo(
                uniqueID: device.uniqueID,
                position: device.position,
                deviceType: device.deviceType,
                hasFlash: device.hasFlash,
                isConnected: device.isConnected,
                lensAperture: device.lensAperture,
                constituentDeviceTypes: device.constituentDevices.map(\.deviceType),
                formats: formats
            )
        }

        return DeviceCapabilities(
            modelID: hardwareModelIdentifier,
            systemVersion: UIDevice.current.systemVersion,
            osVersionString: ProcessInfo.processInfo.operatingSystemVersionString,
            screenScale: UIScreen.main.scale,
            hasCameraAccess: AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
            cameras: cameras
        )
    }

    /// Hardware model identifier ("iPhone17,1", "iPhone15,2", ...) via the
    /// public Darwin `sysctlbyname` interface. Falls back to `hw.model`.
    private static var hardwareModelIdentifier: String {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else {
            return UIDevice.current.model
        }
        var machine = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &machine, &size, nil, 0) == 0 else {
            return UIDevice.current.model
        }
        let identifier = String(cString: machine)
        return identifier.isEmpty ? UIDevice.current.model : identifier
    }
}
