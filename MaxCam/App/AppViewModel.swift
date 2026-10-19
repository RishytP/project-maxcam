import AVFoundation
import Combine
import Foundation

/// Bridges the camera engine to SwiftUI without coupling the engine to it.
@MainActor
final class AppViewModel: ObservableObject {
    let engine: CameraEngine

    @Published private(set) var capabilities: DeviceCapabilities
    @Published private(set) var configurations: [RecordingConfiguration] = []
    @Published private(set) var stats = CameraStats()
    @Published private(set) var isReady = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastRecording: RecordingSessionInfo?
    @Published private(set) var encoder: EncoderCapabilities
    @Published private(set) var raw: RawCapabilityProbe

    @Published var selectedConfiguration: RecordingConfiguration?
    @Published var preferredLensID: String?

    // Manual controls. `nil` means "auto" for that parameter.
    @Published var manualISO: Float?
    @Published var manualShutterDenominator: Int?
    @Published var manualTemperature: Float?
    @Published var manualTint: Float?

    var isAutoExposure: Bool { manualISO == nil && manualShutterDenominator == nil }

    /// Real ISO range of the active format, or nil before one is applied.
    var isoRange: ClosedRange<Float>? { engine.isoRange() }

    /// Shutter speeds the active format genuinely supports, as 1/n.
    var shutterDenominators: [Int] { engine.supportedShutterDenominators() }

    private var statsTimer: Timer?

    init(engine: CameraEngine) {
        self.engine = engine
        self.capabilities = engine.capabilities
        self.encoder = EncoderCapabilities.current()
        self.raw = RawCapabilityProbe.current()
        self.preferredLensID = engine.capabilities.rearCameras.first?.uniqueID
    }

    // MARK: - Lifecycle

    func start() {
        guard !isReady else { return }
        engine.requestAndStart(preferredDeviceID: preferredLensID) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.lastError = error.localizedDescription
                    return
                }
                self.isReady = true
                self.rebuildConfigurations()
                self.selectedConfiguration = self.configurations.first
                self.beginStatsPolling()
            }
        }
    }

    func stop() {
        statsTimer?.invalidate()
        statsTimer = nil
        engine.stopSession()
    }

    // MARK: - Configuration

    private func rebuildConfigurations() {
        configurations = CapabilityMatrix.configurations(
            CapabilityMatrix.Inputs(
                devices: capabilities.cameras,
                preferredDeviceID: preferredLensID,
                movieFileCodecs: encoder.movieFileCodecs
            )
        )
    }

    func setLens(_ deviceID: String?) {
        preferredLensID = deviceID
        rebuildConfigurations()
        selectedConfiguration = configurations.first
        if let config = selectedConfiguration {
            selectConfiguration(config)
        }
    }

    func selectConfiguration(_ config: RecordingConfiguration) {
        selectedConfiguration = config
        guard let info = formatInfo(for: config) else {
            lastError = CameraEngineError.invalidConfiguration.localizedDescription
            return
        }
        do {
            try engine.applyFormat(info, colorSpace: config.colorSpace)
            try engine.applyFrameRate(config.frameRate)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Finds the real format behind a configuration, preferring an exact
    /// frame-rate and color-space match.
    private func formatInfo(for config: RecordingConfiguration) -> CameraFormatInfo? {
        let camera = capabilities.cameras.first { $0.uniqueID == preferredLensID }
            ?? capabilities.rearCameras.first
            ?? capabilities.cameras.first
        guard let camera else { return nil }

        return camera.formats.first {
            $0.id == config.sourceFormatID
        } ?? camera.formats.first {
            $0.dimensions.sameResolution(as: config.resolution)
                && $0.supportedColorSpaces.contains(config.colorSpace)
                && $0.maxFrameRate + 0.01 >= config.frameRate
        } ?? camera.formats.first {
            $0.dimensions.sameResolution(as: config.resolution)
        }
    }

    /// Configurations grouped for the format picker, best quality first.
    struct PipelineGroup: Identifiable {
        let title: String
        let configurations: [RecordingConfiguration]
        var id: String { title }
    }

    var configurationsByPipeline: [PipelineGroup] {
        Dictionary(grouping: configurations) { $0.pipeline.displayName }
            .map { title, configs in
                PipelineGroup(
                    title: title,
                    configurations: configs.sorted { lhs, rhs in
                        if lhs.height != rhs.height { return lhs.height > rhs.height }
                        if lhs.frameRate != rhs.frameRate { return lhs.frameRate < rhs.frameRate }
                        return lhs.bitDepth > rhs.bitDepth
                    }
                )
            }
            .sorted { $0.title < $1.title }
    }

    // MARK: - Recording

    func toggleRecording() {
        guard let config = selectedConfiguration else { return }
        if stats.isRecording {
            engine.stopRecording { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    switch result {
                    case .success(let info):
                        self.lastRecording = info
                        if !info.finalizedCleanly {
                            self.lastError = CameraEngineError.finalizationIncomplete.localizedDescription
                        }
                    case .failure(let error):
                        self.lastError = error.localizedDescription
                    }
                }
            }
        } else {
            do {
                try engine.startRecording(to: Self.makeOutputURL(), configuration: config)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    // MARK: - Manual controls

    /// Pushes the current manual selections to the device. Exposure needs both
    /// ISO and shutter to enter custom mode, so partial selections keep the
    /// device in auto until both are present.
    func applyManualControls() {
        var controls = ManualControls.auto
        if let iso = manualISO, let denominator = manualShutterDenominator, denominator > 0 {
            controls.iso = iso
            controls.exposureDuration = CMTime(value: 1, timescale: CMTimeScale(denominator))
        }
        if let temperature = manualTemperature {
            controls.temperature = temperature
            controls.tint = manualTint ?? 0
        }
        do {
            try engine.applyManualControls(controls)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setAutoExposure() {
        manualISO = nil
        manualShutterDenominator = nil
        applyManualControls()
    }

    /// Tap-to-focus at a point in the capture device's normalized coordinate
    /// space (already converted by the preview layer).
    func focus(at devicePoint: CGPoint) {
        var controls = ManualControls.auto
        controls.focusPoint = devicePoint
        if let iso = manualISO, let denominator = manualShutterDenominator, denominator > 0 {
            controls.iso = iso
            controls.exposureDuration = CMTime(value: 1, timescale: CMTimeScale(denominator))
        }
        if let temperature = manualTemperature {
            controls.temperature = temperature
            controls.tint = manualTint ?? 0
        }
        do {
            try engine.applyManualControls(controls)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Polling

    private func beginStatsPolling() {
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.stats = self.engine.stats
            }
        }
    }

    private static func makeOutputURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return directory.appendingPathComponent("MAXCAM-\(formatter.string(from: Date())).mov")
    }
}
