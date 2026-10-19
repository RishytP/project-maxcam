import AVFoundation
import CoreMedia
import Foundation

/// Live engine gauges published to the UI.
struct CameraStats: Equatable {
    var frameCounter: UInt64 = 0
    var droppedFrames: UInt64 = 0
    var currentFPS: Double = 0
    var isRecording = false
    var recordedDuration: TimeInterval = 0
    var thermalState: ProcessInfo.ThermalState = .nominal
    var isLowPowerModeEnabled = false
    var isThermallyConstrained = false
    var recordingStateMessage = ""
}

/// A snapshot of the operator's manual-control selections. Every value is
/// clamped against the active device when applied. White balance is expressed as
/// temperature/tint and converted to `WhiteBalanceGains` on apply.
struct ManualControls: Equatable, @unchecked Sendable {
    var iso: Float?
    var exposureDuration: CMTime?
    var exposureBias: Float?
    var focusPoint: CGPoint?
    var lensPosition: Float?
    var whiteBalanceMode: AVCaptureDevice.WhiteBalanceMode = .continuousAutoWhiteBalance
    var temperature: Float?
    var tint: Float?

    static var auto: ManualControls { ManualControls() }
}

/// Everything the engine knew at record time that is worth reporting.
struct RecordingSessionInfo: Equatable, Sendable {
    let url: URL
    let configurationSummary: String
    let startedAt: Date
    let endedAt: Date
    let duration: TimeInterval
    let droppedFrames: UInt64
    let totalFrames: UInt64
    let fileSizeBytes: Int64
    let finalizedCleanly: Bool

    var durationLabel: String { String(format: "%.1f", duration) }
}

/// Thread-safe capture engine.
///
/// AVFoundation objects (`AVCaptureSession`, `AVAssetWriter`, `AVCaptureDevice`)
/// are not `Sendable`, so the engine funnels every mutation through one serial
/// queue and publishes immutable snapshots. The sample-buffer callback runs on
/// `sampleQueue`; writer state is only ever touched there.
final class CameraEngine: NSObject, @unchecked Sendable {
    let capabilities: DeviceCapabilities

    let session = AVCaptureSession()
    let videoOutput = AVCaptureVideoDataOutput()

    /// Serializes configuration. Never blocked by the sample path.
    private let configQueue = DispatchQueue(label: "com.maxcam.engine.config")
    /// The `AVCaptureVideoDataOutput` callback queue and sole owner of writer state.
    private let sampleQueue = DispatchQueue(label: "com.maxcam.engine.sample")

    // --- Sample-queue confined state -------------------------------------
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var writerSessionStarted = false
    private var isRecording = false
    private var recordStartTime: CMTime = .invalid
    private var lastSampleTimestamp: CMTime = .invalid
    private var totalSampleCount: UInt64 = 0
    private var currentFileURL: URL?
    private var recordingStartDate: Date?
    private var activeConfiguration: RecordingConfiguration?
    private var frameCounter: UInt64 = 0
    private var droppedFrameCount: UInt64 = 0
    private var fpsWindowStart: CMTime = .invalid
    private var fpsWindowFrames: UInt64 = 0
    private var currentFPS: Double = 0

    // --- Config-queue confined state -------------------------------------
    private var configuredFormat: CameraFormatInfo?
    private var selectedColorSpace: AVCaptureColorSpace?
    private var activeDeviceInput: AVCaptureDeviceInput?

    // MARK: - Init

    override init() {
        self.capabilities = DeviceCapabilities.current()
        super.init()
        session.sessionPreset = .inputPriority
        videoOutput.alwaysDiscardsLateVideoFrames = true
        // `videoSettings` is deliberately left at its default here. The pixel
        // format is chosen in `configureVideoOutputPixelFormat()` once the
        // output is attached and `availableVideoPixelFormatTypes` is populated;
        // setting an unsupported format before then can raise.
        videoOutput.setSampleBufferDelegate(self, queue: sampleQueue)
    }

    // MARK: - Lifecycle

    func requestAndStart(preferredDeviceID: String?, completion: @escaping (Error?) -> Void) {
        Task { [weak self] in
            guard let self else { return }
            let error = await self.startSession(preferredDeviceID: preferredDeviceID)
            completion(error)
        }
    }

    private func startSession(preferredDeviceID: String?) async -> Error? {
        guard await requestCameraAccess() else { return CameraEngineError.cameraAccessDenied }

        guard let camera = capabilities.cameras.first(where: { $0.uniqueID == preferredDeviceID })
                ?? capabilities.rearCameras.first
                ?? capabilities.cameras.first,
              let device = AVCaptureDevice(uniqueID: camera.uniqueID) else {
            return CameraEngineError.noCameraFound
        }

        var configurationError: Error?
        configQueue.sync {
            session.beginConfiguration()
            defer { session.commitConfiguration() }

            // The video data output is configured by the engine, not by a
            // session preset, so the preset must not fight the active format.
            if session.canSetSessionPreset(.inputPriority) {
                session.sessionPreset = .inputPriority
            }
            // Never let the session silently rewrite the color space we choose.
            session.automaticallyConfiguresCaptureDeviceForWideColor = false

            if activeDeviceInput == nil {
                guard let input = try? AVCaptureDeviceInput(device: device),
                      session.canAddInput(input) else {
                    configurationError = CameraEngineError.sessionConfigurationFailed
                    return
                }
                session.addInput(input)
                activeDeviceInput = input
            }
            if !session.outputs.contains(videoOutput) {
                guard session.canAddOutput(videoOutput) else {
                    configurationError = CameraEngineError.sessionConfigurationFailed
                    return
                }
                session.addOutput(videoOutput)
            }

            // Pick the highest-quality format the device offers rather than the
            // arbitrary first entry, then fall back to anything usable.
            if let best = Self.bestDefaultFormat(in: camera) {
                try? applyLocked(device: device, format: best, colorSpace: best.defaultColorSpace)
                configureVideoOutputPixelFormat()
            }
        }

        if let configurationError { return configurationError }

        session.startRunning()
        CameraEngineLog.info("Camera started: \(camera.displayName) (\(camera.uniqueID))")
        return nil
    }

    func stopSession() {
        configQueue.sync {
            if session.isRunning { session.stopRunning() }
        }
    }

    func addMicrophoneIfAvailable() {
        configQueue.sync {
            guard let mic = AVCaptureDevice.default(for: .audio),
                  let input = try? AVCaptureDeviceInput(device: mic) else { return }
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            if session.canAddInput(input) { session.addInput(input) }
        }
    }

    private func requestCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// Highest-resolution non-square-binned format with the widest color support.
    private static func bestDefaultFormat(in camera: CameraDeviceInfo) -> CameraFormatInfo? {
        camera.formats
            .filter { $0.dimensions.width > 0 && $0.dimensions.height > 0 }
            .max { lhs, rhs in
                let lhsScore = score(lhs)
                let rhsScore = score(rhs)
                return lhsScore < rhsScore
            }
    }

    private static func score(_ format: CameraFormatInfo) -> Int {
        var score = Int(format.dimensions.width) * Int(format.dimensions.height)
        if format.supportsAppleLog2 { score += 40_000_000 }
        if format.supportsAppleLog { score += 20_000_000 }
        if format.isVideoHDRSupported { score += 5_000_000 }
        if format.bitDepthGuess == 10 { score += 1_000_000 }
        return score
    }

    // MARK: - Format and color space

    @discardableResult
    func applyFormat(_ info: CameraFormatInfo, colorSpace: AVCaptureColorSpace) throws -> Bool {
        try configQueue.sync {
            guard let device = activeDevice() else { throw CameraEngineError.noCameraFound }
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            try applyLocked(device: device, format: info, colorSpace: colorSpace)
            configureVideoOutputPixelFormat()
            return true
        }
    }

    /// Picks the highest-precision pixel format the output can actually deliver
    /// for the active format. `availableVideoPixelFormatTypes` is only
    /// meaningful once the format has been applied.
    private func configureVideoOutputPixelFormat() {
        let available = videoOutput.availableVideoPixelFormatTypes
        let chosen = Self.preferredPixelFormats.first { available.contains($0) }
            ?? available.first
            ?? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: chosen]
        CameraEngineLog.info(
            "Video output pixel format: \(CameraFormatInfo.fourCCString(chosen))"
        )
    }

    private static let preferredPixelFormats: [OSType] = [
        kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
        kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_32BGRA,
    ]

    /// Applies format, frame-rate-compatible settings and color space.
    /// Caller must hold the device's configuration lock.
    private func applyLocked(
        device: AVCaptureDevice,
        format: CameraFormatInfo,
        colorSpace: AVCaptureColorSpace
    ) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        if device.activeFormat != format.format {
            device.activeFormat = format.format
        }

        // The documented, reliable way to test color-space support for the
        // active format. `AVCaptureDevice` has no `isColorSpaceSupported` method.
        if device.activeFormat.supportedColorSpaces.contains(colorSpace) {
            device.activeColorSpace = colorSpace
        } else if device.activeFormat.supportedColorSpaces.contains(.sRGB) {
            device.activeColorSpace = .sRGB
        }

        configuredFormat = format
        selectedColorSpace = device.activeColorSpace
    }

    func setColorSpace(_ colorSpace: AVCaptureColorSpace) throws {
        try configQueue.sync {
            guard let device = activeDevice(), let current = configuredFormat else {
                throw CameraEngineError.noCameraFound
            }
            guard current.format.supportedColorSpaces.contains(colorSpace) else {
                throw CameraEngineError.invalidConfiguration
            }
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.activeColorSpace = colorSpace
            selectedColorSpace = colorSpace
        }
    }

    // MARK: - Frame rate

    /// Pins the device to a specific frame rate. A rate outside every advertised
    /// range is rejected rather than silently ignored.
    func applyFrameRate(_ frameRate: Double) throws {
        try configQueue.sync {
            guard let device = activeDevice() else { throw CameraEngineError.noCameraFound }
            guard let range = device.activeFormat.videoSupportedFrameRateRanges.first(where: {
                frameRate >= $0.minFrameRate - 0.01 && frameRate <= $0.maxFrameRate + 0.01
            }) else {
                throw CameraEngineError.frameRateNotSupported(frameRate)
            }
            // Durations are quantised by the range, so derive them from it.
            let duration = CMTime(value: 1, timescale: CMTimeScale((frameRate * 1000).rounded()))
            let clamped = min(max(duration, range.minFrameDuration), range.maxFrameDuration)

            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.activeVideoMinFrameDuration = clamped
            device.activeVideoMaxFrameDuration = clamped
        }
    }

    // MARK: - Manual controls

    func applyManualControls(_ controls: ManualControls) throws {
        try configQueue.sync {
            guard let device = activeDevice() else { throw CameraEngineError.noCameraFound }
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            let format = device.activeFormat
            let iso = controls.iso.map { min(max($0, format.minISO), format.maxISO) }
            let duration = controls.exposureDuration.map {
                Self.clampDuration($0, to: format.minExposureDuration, format.maxExposureDuration)
            }

            if device.isExposureModeSupported(.custom), let iso, let duration {
                device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
            } else if device.isExposureModeSupported(.continuousAutoExposure), controls.iso == nil {
                device.exposureMode = .continuousAutoExposure
            }

            if let bias = controls.exposureBias {
                let clamped = min(max(bias, device.minExposureTargetBias), device.maxExposureTargetBias)
                device.setExposureTargetBias(clamped, completionHandler: nil)
            }

            if let point = controls.focusPoint, device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
            }
            if let lens = controls.lensPosition {
                let clamped = min(max(lens, 0), 1)
                if device.isFocusModeSupported(.locked) {
                    device.setFocusModeLocked(lensPosition: clamped, completionHandler: nil)
                }
            } else if device.isFocusModeSupported(.continuousAutoFocus), controls.focusPoint == nil {
                device.focusMode = .continuousAutoFocus
            }

            if let temperature = controls.temperature {
                let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                    temperature: temperature,
                    tint: controls.tint ?? 0
                )
                let gains = Self.cappedGains(
                    device.deviceWhiteBalanceGains(for: values),
                    maxGain: device.maxWhiteBalanceGain
                )
                if device.isWhiteBalanceModeSupported(.locked) {
                    device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                }
            } else if device.isWhiteBalanceModeSupported(controls.whiteBalanceMode) {
                device.whiteBalanceMode = controls.whiteBalanceMode
            }
        }
    }

    private static func cappedGains(
        _ gains: AVCaptureDevice.WhiteBalanceGains,
        maxGain: Float
    ) -> AVCaptureDevice.WhiteBalanceGains {
        var capped = gains
        capped.redGain = min(max(capped.redGain, 1), maxGain)
        capped.greenGain = min(max(capped.greenGain, 1), maxGain)
        capped.blueGain = min(max(capped.blueGain, 1), maxGain)
        return capped
    }

    private static func clampDuration(_ duration: CMTime, to low: CMTime, _ high: CMTime) -> CMTime {
        if duration.seconds < low.seconds { return low }
        if duration.seconds > high.seconds { return high }
        return duration
    }

    // MARK: - Recording

    /// Starts an HEVC recording. Writer state lives on `sampleQueue` so the
    /// sample callback never races with setup or teardown.
    func startRecording(
        to url: URL,
        configuration: RecordingConfiguration
    ) throws {
        try applyFormat(
            try formatInfo(for: configuration),
            colorSpace: configuration.colorSpace
        )
        try applyFrameRate(configuration.frameRate)

        let settings = Self.makeWriterSettings(configuration: configuration)

        try sampleQueue.sync {
            guard !isRecording else { throw CameraEngineError.recordingInProgress }

            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }

            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw CameraEngineError.writerUnavailable }
            writer.add(input)

            guard writer.startWriting() else { throw CameraEngineError.writerUnavailable }

            self.writer = writer
            self.writerInput = input
            self.writerSessionStarted = false
            self.isRecording = true
            self.currentFileURL = url
            self.recordingStartDate = Date()
            self.activeConfiguration = configuration
            self.recordStartTime = .invalid
            self.lastSampleTimestamp = .invalid
            self.totalSampleCount = 0
            self.droppedFrameCount = 0
            CameraEngineLog.info("Recording started: \(url.lastPathComponent)")
        }
    }

    func stopRecording(completion: @escaping (Result<RecordingSessionInfo, Error>) -> Void) {
        sampleQueue.async { [weak self] in
            guard let self else { return }
            guard self.isRecording, let writer, let input = self.writerInput else {
                completion(.failure(CameraEngineError.notRecording))
                return
            }

            self.isRecording = false
            input.markAsFinished()
            let snapshot = self.sessionSnapshot(finalizedCleanly: true)

            writer.finishWriting { [weak self] in
                guard let self else { return }
                let clean = writer.status == .completed
                let info = RecordingSessionInfo(
                    url: snapshot.url,
                    configurationSummary: snapshot.configurationSummary,
                    startedAt: snapshot.startedAt,
                    endedAt: Date(),
                    duration: snapshot.duration,
                    droppedFrames: snapshot.droppedFrames,
                    totalFrames: snapshot.totalFrames,
                    fileSizeBytes: Self.fileSize(at: snapshot.url),
                    finalizedCleanly: clean
                )
                self.sampleQueue.async {
                    self.writer = nil
                    self.writerInput = nil
                    self.writerSessionStarted = false
                    self.currentFileURL = nil
                    self.recordingStartDate = nil
                    self.activeConfiguration = nil
                    self.recordStartTime = .invalid
                }
                if clean {
                    completion(.success(info))
                } else {
                    CameraEngineLog.error("Writer finished with status \(writer.status.rawValue)")
                    completion(.success(info))
                }
            }
        }
    }

    /// Captures everything the engine knows before the writer is torn down.
    /// Must be called on `sampleQueue`.
    private func sessionSnapshot(finalizedCleanly: Bool) -> RecordingSessionInfo {
        let url = currentFileURL ?? URL(fileURLWithPath: "")
        let duration: TimeInterval
        if lastSampleTimestamp.isValid, recordStartTime.isValid {
            duration = max(0, lastSampleTimestamp.seconds - recordStartTime.seconds)
        } else {
            duration = 0
        }
        return RecordingSessionInfo(
            url: url,
            configurationSummary: activeConfiguration?.summary ?? "unknown",
            startedAt: recordingStartDate ?? Date(),
            endedAt: Date(),
            duration: duration,
            droppedFrames: droppedFrameCount,
            totalFrames: totalSampleCount,
            fileSizeBytes: Self.fileSize(at: url),
            finalizedCleanly: finalizedCleanly
        )
    }

    private static func fileSize(at url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }

    private static func makeWriterSettings(configuration: RecordingConfiguration) -> [String: Any] {
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitRate(for: configuration),
            AVVideoExpectedSourceFrameRateKey: Int(configuration.frameRate.rounded()),
            AVVideoMaxKeyFrameIntervalKey: Int(configuration.frameRate.rounded()) * 2,
        ]
        // No profile constant is set: VideoToolbox picks a profile that can
        // carry the requested 10-bit buffers, and the hard-coded "Main10 auto
        // level" spellings are not reliably present across SDKs.

        return [
            AVVideoCodecKey: configuration.codec.rawValue,
            AVVideoWidthKey: configuration.width,
            AVVideoHeightKey: configuration.height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: colorProperties(for: configuration),
        ]
    }

    /// Color metadata that honestly describes the encoded master. Log masters
    /// are tagged BT.2020 primaries/matrix with no transfer-function claim,
    /// because no public SMI string describes Apple's log curve. Tagging them
    /// Rec.709 or HLG would misrepresent the file.
    private static func colorProperties(for configuration: RecordingConfiguration) -> [String: Any] {
        switch configuration.colorSpace {
        case .appleLog:
            return logProperties()
        case .hlgBT2020:
            return [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ]
        case .p3D65:
            return [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ]
        default:
            if #available(iOS 26.0, *), configuration.colorSpace == .appleLog2 {
                return logProperties()
            }
            return [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ]
        }
    }

    private static func logProperties() -> [String: Any] {
        [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
        ]
    }

    /// Bitrate scaled for 10-bit 4:2:0 at the requested resolution and rate.
    private static func bitRate(for configuration: RecordingConfiguration) -> Int {
        let pixels = Double(configuration.width) * Double(configuration.height)
        let bitsPerPixel = 0.15
        let raw = pixels * bitsPerPixel * configuration.frameRate
        return max(20_000_000, Int(raw))
    }

    private func formatInfo(for configuration: RecordingConfiguration) throws -> CameraFormatInfo {
        let deviceID = configQueue.sync { activeDeviceInput?.device.uniqueID }
        let candidates = capabilities.cameras
            .filter { deviceID == nil || $0.uniqueID == deviceID }
            .flatMap(\.formats)
        guard let match = candidates.first(where: {
            $0.dimensions.sameResolution(as: configuration.resolution)
                && $0.maxFrameRate + 0.01 >= configuration.frameRate
                && $0.supportedColorSpaces.contains(configuration.colorSpace)
        }) ?? candidates.first(where: { $0.dimensions.sameResolution(as: configuration.resolution) }) else {
            throw CameraEngineError.invalidConfiguration
        }
        return match
    }

    // MARK: - Diagnostics

    var currentFormatInfo: CameraFormatInfo? {
        configQueue.sync { configuredFormat }
    }

    var selectedColorSpaceValue: AVCaptureColorSpace? {
        configQueue.sync { selectedColorSpace }
    }

    /// True only when the active format scans a square sensor area.
    var isOpenGateActive: Bool {
        configQueue.sync { configuredFormat?.isOpenGateCapable ?? false }
    }

    var stats: CameraStats {
        var stats = sampleQueue.sync { () -> CameraStats in
            var value = CameraStats()
            value.frameCounter = frameCounter
            value.droppedFrames = droppedFrameCount
            value.currentFPS = currentFPS
            value.isRecording = isRecording
            if isRecording, lastSampleTimestamp.isValid, recordStartTime.isValid {
                value.recordedDuration = max(0, lastSampleTimestamp.seconds - recordStartTime.seconds)
            }
            return value
        }
        let processInfo = ProcessInfo.processInfo
        stats.thermalState = processInfo.thermalState
        stats.isLowPowerModeEnabled = processInfo.isLowPowerModeEnabled
        stats.isThermallyConstrained = processInfo.thermalState == .serious
            || processInfo.thermalState == .critical
        return stats
    }

    private func activeDevice() -> AVCaptureDevice? {
        if let device = activeDeviceInput?.device { return device }
        return capabilities.rearCameras.first.flatMap { AVCaptureDevice(uniqueID: $0.uniqueID) }
    }
}

// MARK: - Sample buffer delegate

extension CameraEngine: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        frameCounter &+= 1
        lastSampleTimestamp = timestamp
        if !recordStartTime.isValid { recordStartTime = timestamp }

        if !fpsWindowStart.isValid {
            fpsWindowStart = timestamp
            fpsWindowFrames = 0
        }
        fpsWindowFrames &+= 1
        let window = timestamp.seconds - fpsWindowStart.seconds
        if window >= 0.5 {
            currentFPS = Double(fpsWindowFrames) / window
            fpsWindowStart = timestamp
            fpsWindowFrames = 0
        }

        guard isRecording, let writer, let input = writerInput else { return }

        if !writerSessionStarted {
            writer.startSession(atSourceTime: timestamp)
            writerSessionStarted = true
        }

        // `expectsMediaDataInRealTime` makes `append` non-blocking, but a stalled
        // encoder can still report "not ready". Dropping the frame and counting
        // it is correct for a live capture; blocking the callback would not be.
        guard input.isReadyForMoreMediaData else {
            droppedFrameCount &+= 1
            return
        }
        if input.append(sampleBuffer) {
            totalSampleCount &+= 1
        } else {
            droppedFrameCount &+= 1
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        droppedFrameCount &+= 1
    }
}

// MARK: - Default color space

extension CameraFormatInfo {
    /// The best color space this format supports, preferring log.
    var defaultColorSpace: AVCaptureColorSpace {
        if supportsAppleLog2 { return AVCaptureColorSpace.appleLog2Value }
        if supportsAppleLog { return .appleLog }
        if supportedColorSpaces.contains(.hlgBT2020) { return .hlgBT2020 }
        if supportedColorSpaces.contains(.p3D65) { return .p3D65 }
        return .sRGB
    }
}

/// Manual-control helpers built from the real ranges AVFoundation reports for
/// the active format. Nothing is invented: if the hardware has no discrete ISO
/// or shutter steps, the helpers fall back to a bounded sweep.
extension CameraEngine {
    static let standardShutterDenominators: [Int] = [
        24, 25, 30, 48, 50, 60, 96, 100, 120, 125, 180, 240, 250, 360, 480, 500,
        720, 960, 1000, 1500, 2000, 3000, 4000, 6000, 8000,
    ]

    /// The format's ISO range for the active device, if a format is applied.
    func isoRange() -> ClosedRange<Float>? {
        guard let format = currentFormatInfo?.format else { return nil }
        return format.minISO...format.maxISO
    }

    /// Shutter speeds the active format can actually reach, expressed as
    /// 1/denominator. Always includes the format's own limits.
    func supportedShutterDenominators() -> [Int] {
        guard let format = currentFormatInfo?.format else { return [] }
        let minSeconds = format.minExposureDuration.seconds
        let maxSeconds = format.maxExposureDuration.seconds
        guard minSeconds > 0, maxSeconds > 0 else { return [] }

        var values = Set(Self.standardShutterDenominators.filter { denominator in
            let seconds = 1.0 / Double(denominator)
            return seconds >= minSeconds - 1e-9 && seconds <= maxSeconds + 1e-9
        })
        values.insert(max(1, Int((1.0 / minSeconds).rounded())))
        values.insert(max(1, Int((1.0 / maxSeconds).rounded())))
        return values.sorted()
    }
}

extension AVCaptureColorSpace {
    /// `appleLog2` cannot be named outside an `#available` block on an iOS 17
    /// deployment target, so callers go through this accessor.
    static var appleLog2Value: AVCaptureColorSpace {
        if #available(iOS 26.0, *) {
            return .appleLog2
        }
        return .appleLog
    }
}
