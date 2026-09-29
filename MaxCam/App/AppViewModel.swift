import Foundation
import SwiftUI

/// A tiny view-model that drives the engine from the SwiftUI layer without
/// coupling the engine to SwiftUI.
@MainActor
final class AppViewModel: ObservableObject {
    let engine: CameraEngine

    @Published var capabilities: DeviceCapabilities
    @Published var configurations: [RecordingConfiguration] = []
    @Published var stats = CameraStats()
    @Published var isReady = false
    @Published var lastError: String?

    @Published var selectedConfiguration: RecordingConfiguration?
    @Published var preferredLens: String?

    private var statsTimer: Timer?

    init(engine: CameraEngine) {
        self.engine = engine
        self.capabilities = engine.capabilities
    }

    func start() {
        engine.requestAndStart(preferredDeviceID: preferredLens) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.lastError = error.localizedDescription
                } else {
                    self.isReady = true
                    self.rebuildConfigurations()
                    if self.selectedConfiguration == nil {
                        self.selectedConfiguration = self.configurations.first
                    }
                    self.beginStatsPolling()
                }
            }
        }
    }

    private func rebuildConfigurations() {
        configurations = CapabilityMatrix.configurations(
            devices: capabilities.cameras,
            preferredDeviceID: preferredLens,
            supportedCodecs: EncoderCapabilities.current().movieFileCodecs
        )
    }

    func stop() {
        statsTimer?.invalidate()
        engine.stopSession()
    }

    func setLens(_ deviceID: String?) {
        preferredLens = deviceID
        capabilities = engine.capabilities
        rebuildConfigurations()
        selectedConfiguration = configurations.first
    }

    func selectConfiguration(_ config: RecordingConfiguration) {
        selectedConfiguration = config
        guard let info = capabilityFormat(for: config) else { return }
        do {
            try engine.applyFormat(info, colorSpace: config.colorSpace)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func toggleRecording() {
        guard let config = selectedConfiguration else { return }
        if stats.isRecording {
            engine.stopRecording { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    switch result {
                    case .success(let info):
                        print("Recording finished: \(info.url) \(info.durationLabel)s \(info.fileSizeBytes) bytes")
                    case .failure(let error):
                        self.lastError = error.localizedDescription
                    }
                }
            }
        } else {
            let url = Self.makeOutputURL()
            do {
                try engine.startRecording(to: url, configuration: config)
                stats.isRecording = true
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func capabilityFormat(for config: RecordingConfiguration) -> CameraFormatInfo? {
        let preferred = preferredLens ?? capabilities.rearCameras.first?.uniqueID
        let camera = capabilities.rearCameras.first { $0.uniqueID == preferred }
        return camera?.formats.first { $0.dimensions == config.resolution }
    }

    private func beginStatsPolling() {
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stats = self.engine.stats
            }
        }
    }

    private static func makeOutputURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("MAXCAM-\(formatter.string(from: Date())).mov")
    }
}