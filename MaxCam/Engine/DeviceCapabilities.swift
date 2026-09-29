import AVFoundation
import Darwin
import UIKit

/// One camera (AVCaptureDevice) with all of its formats, normalized for the UI.
struct CameraDeviceInfo: Identifiable, Sendable {
    let uniqueID: String
    let position: AVCaptureDevice.Position
    let deviceType: AVCaptureDevice.DeviceType
    let hasFlash: Bool
    let isConnected: Bool
    let lensAperture: Float?
    let formats: [CameraFormatInfo]

    var id: String { uniqueID }

    var displayName: String {
        switch deviceType {
        case AVCaptureDevice.DeviceType.builtInWideAngleCamera:
            return "Wide"
        case AVCaptureDevice.DeviceType.builtInUltraWideCamera:
            return "Ultra Wide"
        case AVCaptureDevice.DeviceType.builtInTelephotoCamera:
            return "Telephoto"
        case AVCaptureDevice.DeviceType.builtInDualCamera:
            return "Dual (Wide + Tele)"
        case AVCaptureDevice.DeviceType.builtInDualWideCamera:
            return "Dual Wide"
        case AVCaptureDevice.DeviceType.builtInTripleCamera:
            return "Triple"
        case AVCaptureDevice.DeviceType.builtInLiDARDepthCamera:
            return "LiDAR"
        default:
            return deviceType.rawValue
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
}

/// The runtime capability tree for the physical device. Nothing here is
/// assumed: every field is populated from AVFoundation queries.
///
/// Read-only snapshot produced on the main thread before actors consume it;
/// marked Sendable because its contents never mutate after construction.
struct DeviceCapabilities: @unchecked Sendable {
    let modelID: String
    let systemVersion: String
    let osBuild: String
    let screenScale: CGFloat
    let hasCameraAccess: Bool
    let cameras: [CameraDeviceInfo]

    var rearCameras: [CameraDeviceInfo] {
        cameras.filter { $0.position == .back }
    }

    /// Formats shared by every rear camera (all-current-device agreement).
    var commonRearFormats: [CameraFormatInfo] {
        guard let first = rearCameras.first else { return [] }
        return first.formats.filter { f in
            rearCameras.allSatisfy { camera in
                camera.formats.contains { candidate in
                    candidate.dimensions == f.dimensions &&
                    candidate.mediaSubType == f.mediaSubType &&
                    candidate.maxFrameRate == f.maxFrameRate
                }
            }
        }
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

        let cameras = discovery.devices.map { device in
            let formats = device.formats.map(CameraFormatInfo.init)
            return CameraDeviceInfo(
                uniqueID: device.uniqueID,
                position: device.position,
                deviceType: device.deviceType,
                hasFlash: device.hasFlash,
                isConnected: device.isConnected,
                lensAperture: nil,
                formats: formats
            )
        }

        let modelID = DeviceCapabilities.hardwareModelIdentifier
        let systemVersion = UIDevice.current.systemVersion

        return DeviceCapabilities(
            modelID: modelID,
            systemVersion: systemVersion,
            osBuild: ProcessInfo.processInfo.operatingSystemVersionString,
            screenScale: UIScreen.main.scale,
            hasCameraAccess: AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
            cameras: cameras
        )
    }

    /// Hardware model identifier ("iPhone17,1", "iPhone15,2", ...) via the
    /// public Darwin `sysctlbyname` interface. Falls back to `hw.model` when
    /// the machine key is unavailable.
    private static var hardwareModelIdentifier: String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return UIDevice.current.model }
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        let identifier = String(cString: machine)
        guard !identifier.isEmpty else { return UIDevice.current.model }
        return identifier
    }
}