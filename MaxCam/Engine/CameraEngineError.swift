import AVFoundation
import Foundation
import OSLog

// Platform warnings emitted by the camera engine, keyed for the UI.
enum CameraEngineError: Error, LocalizedError, Equatable {
    case cameraAccessDenied
    case noCameraFound
    case sessionConfigurationFailed
    case invalidConfiguration
    case recordingInProgress
    case notRecording
    case writerUnavailable
    case finalizationIncomplete

    var errorDescription: String? {
        switch self {
        case .cameraAccessDenied:
            return "Camera access was denied. Enable it in Settings to continue."
        case .noCameraFound:
            return "No rear camera is available on this device."
        case .sessionConfigurationFailed:
            return "The capture session could not be configured."
        case .invalidConfiguration:
            return "The selected recording configuration is not valid for this device."
        case .recordingInProgress:
            return "Recording is already in progress."
        case .notRecording:
            return "Recording is not in progress."
        case .writerUnavailable:
            return "The media writer became unavailable."
        case .finalizationIncomplete:
            return "Recording stopped but the file was not finalized cleanly."
        }
    }
}

enum CameraEngineLog {
    private static let log = Logger(subsystem: "com.maxcam", category: "camera")

    static func info(_ message: String) { log.info("\(message, privacy: .public)") }
    static func error(_ message: String) { log.error("\(message, privacy: .public)") }
    static func fault(_ message: String) { log.fault("\(message, privacy: .public)") }
}