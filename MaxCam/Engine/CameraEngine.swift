import AVFoundation
import CoreMedia
import Foundation

/// Runtime gauge values published to the UI on every camera frame.
struct CameraStats: Equatable, Sendable {
    var frameCounter: UInt64 = 0
    var droppedFrames: UInt64 = 0
    var currentFPS: Double = 0
    var isRecording = false
    var recordedDuration: TimeInterval = 0
    var thermalState: ProcessInfo.ThermalState = .nominal
    var recordingStateMessage: String = ""
}

/// A snapshot of the user's current manual-control selections, all clamped
/// against the active device at apply time. White balance is expressed as
/// temperature/tint; the engine converts to `WhiteBalanceGains` on apply.
struct ManualControls: Equatable, Sendable {
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
    let endedAt: Date?
    let duration: TimeInterval
    let droppedFrames: UInt64
    let totalFrames: UInt64
    let fileSizeBytes: Int64

    var durationLabel: String {
        String(format: "%.1f", duration)
    }
}

/// Thread-safe capture engine. AVFoundation objects (`AVCaptureSession`,
/// `AVAssetWriter`, `AVCaptureDevice`) are not Sendable, so the engine serializes
/// all mutations onto an internal queue and publishes immutable snapshots.
/// This matches the architecture camera apps use and avoids actor-isolation
/// friction for framework callbacks.
final class CameraEngine: NSObject, @unchecked Sendable {
    let capabilities: DeviceCapabilities

    let session = AVCaptureSession()
    let videoOutput = AVCaptureVideoDataOutput()

    // All mutable state below is confined to `queue`.
    private let queue = DispatchQueue(label: "com.maxcam.engine")
    private let sampleQueue = DispatchQueue(label: "com.maxcam.sample")

    private var configuredFormat: CameraFormatInfo?
    private var selectedColorSpace: AVCaptureColorSpace?

    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var isRecording = false
    private var recordStartTime: CMTime = .invalid
    private var currentFileURL: URL?
    private var recordingStartDate: Date?
    private var activeRecordingConfiguration: RecordingConfiguration?

    private var frameCounter: UInt64 = 0
    private var droppedFrameCount: UInt64 = 0
    private var totalSampleCount: UInt64 = 0
    private var lastSampleTimestamp: CMTime = .invalid
    private var fpsTrackerWindow: [(CMTime, UInt64)] = []

    // MARK: - Init

    override init() {
        self.capabilities = DeviceCapabilities.current()
        super.init()
        session.sessionPreset = .high
        videoOutput.alwaysDiscardsLateVideoFrames = false
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        ]
        videoOutput.setSampleBufferDelegate(self, queue: sampleQueue)
    }

    // MARK: - Setup

    func requestAndStart(preferredDeviceID: String?, completion: @escaping (Error?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            Task { await self._requestAndStart(preferredDeviceID: preferredDeviceID, completion: completion) }
        }
    }

    private func requestCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    private func _requestAndStart(preferredDeviceID: String?, completion: @escaping (Error?) -> Void) async {
        let auth = await requestCameraAccess()
        guard auth else {
            completion(CameraEngineError.cameraAccessDenied)
            return
        }
        guard let camera = capabilities.cameras.first(where: { $0.uniqueID == preferredDeviceID })
                ?? capabilities.rearCameras.first else {
            completion(CameraEngineError.noCameraFound)
            return
        }
        guard let device = AVCaptureDevice(uniqueID: camera.uniqueID) else {
            completion(CameraEngineError.noCameraFound)
            return
        }

        session.beginConfiguration()
        if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
        }
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        if let anyFormat = camera.formats.first {
            try? applyFormat(anyFormat, colorSpace: anyFormat.supportedColorSpaces.first ?? .sRGB)
        }
        session.commitConfiguration()
        session.startRunning()
        CameraEngineLog.info("Camera started: \(camera.displayName)")
        completion(nil)
    }

    func stopSession() {
        queue.async { [weak self] in
            guard let self else { return }
            self.session.stopRunning()
        }
    }

    func addMicrophoneIfAvailable() {
        queue.async { [weak self] in
            guard let self else { return }
            guard let mic = AVCaptureDevice.default(for: .audio),
                  let input = try? AVCaptureDeviceInput(device: mic),
                  self.session.canAddInput(input) else { return }
            self.session.beginConfiguration()
            self.session.addInput(input)
            self.session.commitConfiguration()
        }
    }

    // MARK: - Format Selection

    @discardableResult
    func applyFormat(_ info: CameraFormatInfo, colorSpace: AVCaptureColorSpace) throws -> Bool {
        guard let device = activeDevice() else { throw CameraEngineError.noCameraFound }
        guard info.supportedColorSpaces.contains(colorSpace) else {
            throw CameraEngineError.invalidConfiguration
        }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        _ = info.format
        device.activeFormat = info.format
        if device.isColorSpaceSupported(colorSpace) {
            device.activeColorSpace = colorSpace
        }
        configuredFormat = info
        selectedColorSpace = colorSpace
        return true
    }

    func setColorSpace(_ colorSpace: AVCaptureColorSpace) throws {
        guard let current = configuredFormat, let device = activeDevice() else { throw CameraEngineError.noCameraFound }
        guard current.supportedColorSpaces.contains(colorSpace) else { throw CameraEngineError.invalidConfiguration }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeColorSpace = colorSpace
        selectedColorSpace = colorSpace
    }

    // MARK: - Manual Controls

    func applyManualControls(_ controls: ManualControls) throws {
        guard let device = activeDevice() else { throw CameraEngineError.noCameraFound }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        let minISO = device.activeFormat.minISO
        let maxISO = device.activeFormat.maxISO
        let iso = controls.iso.map { min(max($0, minISO), maxISO) } ?? device.iso
        let duration = controls.exposureDuration.map { clampDuration($0, to: device.activeFormat.minExposureDuration...device.activeFormat.maxExposureDuration) }

        if device.isExposureModeSupported(.custom) {
            device.setExposureModeCustom(.custom, iso: iso, duration: duration ?? device.exposureDuration) { _ in }
        }
        if let bias = controls.exposureBias {
            let clamped = min(max(bias, device.minExposureTargetBias), device.maxExposureTargetBias)
            device.setExposureTargetBias(clamped) { _ in }
        }
        if let point = controls.focusPoint, device.isFocusPointOfInterestSupported {
            device.focusPointOfInterest = point
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
        }
        if let lens = controls.lensPosition {
            device.setFocusModeLocked(lensPosition: lens) { _ in }
        }
        if let temperature = controls.temperature {
            let gains = device.deviceWhiteBalanceGains(for: AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                temperature: temperature,
                tint: controls.tint ?? 0
            ))
            let g = cappedGains(gains, for: device)
            if device.isWhiteBalanceModeSupported(.locked) {
                device.setWhiteBalanceModeLocked(with: g) { _ in }
            }
        } else if device.isWhiteBalanceModeSupported(controls.whiteBalanceMode) {
            device.whiteBalanceMode = controls.whiteBalanceMode
        }
    }

    private func cappedGains(
        _ gains: AVCaptureDevice.WhiteBalanceGains,
        for device: AVCaptureDevice
    ) -> AVCaptureDevice.WhiteBalanceGains {
        let maxGain = device.maxWhiteBalanceGain
        var g = gains
        g.redGain = clamp(g.redGain, max: maxGain)
        g.greenGain = clamp(g.greenGain, max: maxGain)
        g.blueGain = clamp(g.blueGain, max: maxGain)
        return g
    }

    private func clamp(_ value: Float, max maxValue: Float) -> Float {
        min(max(value, 1), maxValue)
    }

    private func clampDuration(_ duration: CMTime, to range: ClosedRange<CMTime>) -> CMTime {
        if duration.seconds < range.lowerBound.seconds { return range.lowerBound }
        if duration.seconds > range.upperBound.seconds { return range.upperBound }
        return duration
    }

    // MARK: - Recording

    func startRecording(to url: URL, configuration: RecordingConfiguration) throws {
        // Start must happen on the sample queue so that the writer state is
        // only ever touched by the sample buffer delegate's queue.
        try sampleQueue.sync {
            try _startRecordingInPlace(to: url, configuration: configuration)
        }
    }

    private func _startRecordingInPlace(to url: URL, configuration: RecordingConfiguration) throws {
        guard let device = activeDevice() else { throw CameraEngineError.noCameraFound }
        guard let current = configuredFormat else { throw CameraEngineError.invalidConfiguration }

        try applyFormat(current, colorSpace: configuration.colorSpace)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings = makeWriterSettings(configuration: configuration)

        // Pro Video Storage (iOS 27+): opt in only if the system supports it.
        if #available(iOS 27.0, *) {
            if AVCaptureMovieFileOutput().isProVideoStorageSupported {
                writer.usesProVideoStorage = true
            }
        }

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        writerInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(writerInput) else { throw CameraEngineError.writerUnavailable }
        writer.add(writerInput)

        guard writer.startWriting() else {
            throw CameraEngineError.writerUnavailable
        }

        isRecording = true
        sessionStarted = false
        self.writer = writer
        self.writerInput = writerInput
        currentFileURL = url
        recordingStartDate = Date()
        activeRecordingConfiguration = configuration
        recordStartTime = .invalid
        CameraEngineLog.info("Recording started: \(url.lastPathComponent)")
    }

    private func makeWriterSettings(configuration: RecordingConfiguration) -> [String: Any] {
        let width = Int(configuration.resolution.width)
        let height = Int(configuration.resolution.height)

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitRateFor(resolution: configuration.resolution, frameRate: configuration.frameRate)
        ]
        if configuration.codec == .hevc {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelHEVCMain10AutoLevel
        }

        // Color properties reflect the actual capture color space. Apple Log
        // uses BT.2020 primaries with a proprietary log transfer curve. We keep
        // primaries/matrix honest. For HLG we tag HLG. For Log we deliberately
        // omit a transfer tag (VideoToolbox has no public "Apple Log" SMI and
        // tagging the file HLG or Rec.709 would misrepresent the master).
        var colorProps: [String: Any] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]

        // Apple Log, Apple Log 2, and HLG all live in BT.2020 containers.
        // The boolean flags avoid referencing the iOS 26-only enum case
        // unconditionally on older deployment targets.
        if configuration.isAppleLog2 || configuration.isAppleLog {
            colorProps[AVVideoColorPrimariesKey] = AVVideoColorPrimaries_ITU_R_2020
            colorProps.removeValue(forKey: AVVideoTransferFunctionKey)
            colorProps[AVVideoYCbCrMatrixKey] = AVVideoYCbCrMatrix_ITU_R_2020
        } else if configuration.isHDR {
            colorProps[AVVideoColorPrimariesKey] = AVVideoColorPrimaries_ITU_R_2020
            colorProps[AVVideoTransferFunctionKey] = AVVideoTransferFunction_ITU_R_2100_HLG
            colorProps[AVVideoYCbCrMatrixKey] = AVVideoYCbCrMatrix_ITU_R_2020
        } else if configuration.colorSpace == .p3D65 {
            colorProps[AVVideoColorPrimariesKey] = AVVideoColorPrimaries_P3_D65
            colorProps[AVVideoTransferFunctionKey] = AVVideoTransferFunction_ITU_R_709_2
            colorProps[AVVideoYCbCrMatrixKey] = AVVideoYCbCrMatrix_ITU_R_709_2
        }

        return [
            AVVideoCodecKey: configuration.codec.rawValue,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: colorProps,
        ]
    }

    private func bitRateFor(resolution: CMVideoDimensions, frameRate: Double) -> Int {
        let megapixels = Double(resolution.width) * Double(resolution.height)
        let bitrate = megapixels * 3.0 * frameRate
        return max(12_000_000, Int(bitrate))
    }

    func stopRecording(completion: @escaping (Result<RecordingSessionInfo, Error>) -> Void) {
        sampleQueue.async { [weak self] in
            guard let self, self.isRecording, let writer, let writerInput else {
                completion(.failure(CameraEngineError.notRecording))
                return
            }
            self.isRecording = false
            writerInput.markAsFinished()
            writer.finishWriting { [weak self] in
                guard let self else { return }
                let info = self.buildSessionInfo(
                    finishedOK: writer.status == .completed
                )
                completion(.success(info))
            }
        }
    }

    private func buildSessionInfo(finishedOK: Bool) -> RecordingSessionInfo {
        var fileSize: Int64 = 0
        var validURL: URL?
        if let url = currentFileURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let number = attrs[.size] as? NSNumber {
            fileSize = number.int64Value
            validURL = url
        }

        let duration: TimeInterval
        if finishedOK, lastSampleTimestamp.isValid, recordStartTime.isValid {
            duration = max(0, lastSampleTimestamp.seconds - recordStartTime.seconds)
        } else {
            duration = 0
        }

        let info = RecordingSessionInfo(
            url: validURL ?? URL(fileURLWithPath: ""),
            configurationSummary: activeRecordingConfiguration?.summary ?? "unknown",
            startedAt: recordingStartDate ?? Date(),
            endedAt: Date(),
            duration: duration,
            droppedFrames: droppedFrameCount,
            totalFrames: totalSampleCount,
            fileSizeBytes: fileSize
        )

        writer = nil
        writerInput = nil
        sessionStarted = false
        currentFileURL = nil
        recordingStartDate = nil
        activeRecordingConfiguration = nil
        recordStartTime = .invalid
        return info
    }

    // MARK: - Open Gate / Dynamic Aspect Ratio

    /// Set the crop ratio on the device's active format (iOS 26+).
    /// Returns whether the request was accepted.
    @discardableResult
    @available(iOS 26.0, *)
    func setDynamicAspectRatio(_ ratio: AVCaptureDevice.AspectRatio) -> Bool {
        guard let device = activeDevice() else { return false }
        do {
            try device.lockForConfiguration()
        } catch {
            return false
        }
        defer { device.unlockForConfiguration() }
        let supported = device.activeFormat.supportedDynamicAspectRatios
        guard supported.contains(ratio) else { return false }
        device.setDynamicAspectRatio(ratio) { _ in
            // First buffer timestamp for the new crop. The recorder can use
            // this seam to split clips at the aspect-ratio change.
        }
        return true
    }

    var isOpenGateActive: Bool {
        guard let format = configuredFormat else { return false }
        let dims = format.dimensions
        let isSquare = dims.width == dims.height
        // On iOS 26+ the true full-sensor scan is a square format that also
        // supports dynamic aspect ratios (the floating crop is applied over the
        // whole sensor). On older systems a square dimension is the only signal.
        return isSquare || (dims.width % 4032 == 0 && format.supportsDynamicAspectRatios)
    }

    // MARK: - Diagnostics

    var currentFormatInfo: CameraFormatInfo? { configuredFormat }

    var selectedColorSpaceValue: AVCaptureColorSpace? { selectedColorSpace }

    var stats: CameraStats {
        var s = CameraStats()
        s.frameCounter = frameCounter
        s.droppedFrames = droppedFrameCount
        s.currentFPS = recentFPS
        s.isRecording = isRecording
        if lastSampleTimestamp.isValid, recordStartTime.isValid, isRecording {
            s.recordedDuration = lastSampleTimestamp.seconds - recordStartTime.seconds
        }
        s.thermalState = ProcessInfo.processInfo.thermalState
        return s
    }

    private var recentFPS: Double {
        guard let first = fpsTrackerWindow.first, let last = fpsTrackerWindow.last else { return 0 }
        let span = last.0.seconds - first.0.seconds
        guard span > 0 else { return 0 }
        return Double(last.1 - first.1) / span
    }

    private func activeDevice() -> AVCaptureDevice? {
        if let input = session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first {
            return input.device
        }
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
        process(sampleBuffer: sampleBuffer, timestamp: timestamp)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        droppedFrameCount &+= 1
    }

    private func process(sampleBuffer: CMSampleBuffer, timestamp: CMTime) {
        frameCounter &+= 1
        if !recordStartTime.isValid { recordStartTime = timestamp }
        lastSampleTimestamp = timestamp

        fpsTrackerWindow.append((timestamp, frameCounter))
        let cutoff = timestamp.seconds - 1.0
        while let first = fpsTrackerWindow.first, first.0.seconds < cutoff {
            fpsTrackerWindow.removeFirst()
        }
        if fpsTrackerWindow.count > 256 { fpsTrackerWindow.removeFirst(128) }

        guard isRecording, let writer, let writerInput else { return }

        // startSession must run at the first sample's timestamp.
        if !sessionStarted {
            writer.startSession(atSourceTime: timestamp)
            sessionStarted = true
        }

        while !writerInput.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.001)
        }
        if writerInput.append(sampleBuffer) {
            totalSampleCount &+= 1
        } else {
            droppedFrameCount &+= 1
        }
    }
}