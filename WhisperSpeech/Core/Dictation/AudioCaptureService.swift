import AVFoundation
import Foundation
import AudioToolbox
import CoreAudio

enum AudioCaptureError: LocalizedError {
    case inputUnavailable
    case microphoneBusy
    case failedToConfigureSession

    var errorDescription: String? {
        switch self {
        case .inputUnavailable:
            return "Microphone input is unavailable."
        case .microphoneBusy:
            return "Kleio couldn't start dictation because the microphone is busy or unavailable right now."
        case .failedToConfigureSession:
            return "Failed to configure the audio session."
        }
    }
}

enum MacDictationAudioFocusIssue: Equatable {
    case duckingUnavailable
    case microphoneBusy

    var noticeText: String {
        switch self {
        case .duckingUnavailable:
            return "Kleio couldn't mute other audio for this dictation, but transcription will still work."
        case .microphoneBusy:
            return "Kleio couldn't start dictation because the microphone is busy or unavailable right now."
        }
    }
}

enum MacDictationAudioFocusState: Equatable {
    case disabled
    case arming
    case active
    case degraded(MacDictationAudioFocusIssue)
    case blocked(MacDictationAudioFocusIssue)
}

enum MacDictationAudioFocusStateMachine {
    static func startRequested(duckingEnabled: Bool) -> MacDictationAudioFocusState {
        duckingEnabled ? .arming : .disabled
    }

    static func duckingSetupFailed() -> MacDictationAudioFocusState {
        .degraded(.duckingUnavailable)
    }

    static func captureStarted(
        from state: MacDictationAudioFocusState,
        duckingEnabled: Bool
    ) -> MacDictationAudioFocusState {
        guard duckingEnabled else { return .disabled }
        switch state {
        case .arming:
            return .active
        case .degraded:
            return state
        case .active, .blocked, .disabled:
            return state
        }
    }

    static func captureFailed(issue: MacDictationAudioFocusIssue) -> MacDictationAudioFocusState {
        .blocked(issue)
    }

    static func stop() -> MacDictationAudioFocusState {
        .disabled
    }
}

final class AudioCaptureService {
    typealias ChunkHandler = @Sendable (Data, Int64) -> Void
    typealias LevelHandler = @Sendable (Double, Int64) -> Void

    enum PlatformAudioSessionProfile {
        case warmKeepAlive
        case capturing
    }

    private let engine = AVAudioEngine()
    private let silentPlayer = AVAudioPlayerNode()
    private let processingQueue = DispatchQueue(label: "dictation.audio.processing")
    private let processingGroup = DispatchGroup()
    private let processingStateLock = NSLock()
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)
    private var interruptionObserver: NSObjectProtocol?
    private var configurationChangeObserver: NSObjectProtocol?
    /// Fired (on the main thread) when an interruption begins mid-capture so the owning layer
    /// can end the dictation session cleanly rather than silently dropping audio (M-24).
    var onCaptureInterruptedWhileListening: (@Sendable () -> Void)?
    private var silentBuffer: AVAudioPCMBuffer?
    private var shouldResumeKeepAliveOutput = false
    private var acceptsIncomingAudioBuffers = false
    private var pendingProcessingBufferCountStorage = 0
    private let macOutputMuteController = MacSystemOutputMuteController()
    private var pendingMacAudioFocusActivationWorkItem: DispatchWorkItem?
    private(set) var macAudioFocusState: MacDictationAudioFocusState = .disabled
    private var pendingMacAudioFocusIssue: MacDictationAudioFocusIssue?

    // These are read on the processing queue but written from the main/coordinator thread;
    // guard them under processingStateLock to avoid a data race (M-6).
    private var chunkHandlerStorage: ChunkHandler?
    private var levelHandlerStorage: LevelHandler?
    private var isTransmittingStorage = false
    private var chunkHandler: ChunkHandler? {
        get {
            processingStateLock.lock(); defer { processingStateLock.unlock() }
            return chunkHandlerStorage
        }
        set {
            processingStateLock.lock(); defer { processingStateLock.unlock() }
            chunkHandlerStorage = newValue
        }
    }
    var levelHandler: LevelHandler? {
        get {
            processingStateLock.lock(); defer { processingStateLock.unlock() }
            return levelHandlerStorage
        }
        set {
            processingStateLock.lock(); defer { processingStateLock.unlock() }
            levelHandlerStorage = newValue
        }
    }
    private var isTransmitting: Bool {
        get {
            processingStateLock.lock(); defer { processingStateLock.unlock() }
            return isTransmittingStorage
        }
        set {
            processingStateLock.lock(); defer { processingStateLock.unlock() }
            isTransmittingStorage = newValue
        }
    }
    private(set) var isCapturing = false

    var sampleRate: Int { Int(outputFormat?.sampleRate ?? 16_000) }
    var channels: Int { Int(outputFormat?.channelCount ?? 1) }
    var pendingProcessingBufferCount: Int { processingStateLock.withLock { pendingProcessingBufferCountStorage } }

    private var usesKeepAliveOutput: Bool { false }

    init() {
        beginObservingPlatformInterruptions()
        beginObservingEngineConfigurationChanges()
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        if let configurationChangeObserver {
            NotificationCenter.default.removeObserver(configurationChangeObserver)
        }
    }

    // Rebuild the capture graph when the engine's I/O configuration changes (e.g. AirPods
    // connect, mic unplug, sample-rate switch). A stale AVAudioConverter otherwise produces
    // silent or garbled dictation until a manual restart (M-25). Applies to both platforms.
    private func beginObservingEngineConfigurationChanges() {
        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleEngineConfigurationChange()
        }
    }

    private func handleEngineConfigurationChange() {
        logPlatformAudioSession(reason: "engine-configuration-change")
        let wasTransmitting = isTransmitting

        if wasTransmitting {
            // A route/format change mid-capture invalidates the converter and tap. End the live
            // session cleanly; the owning layer re-warms afterward (M-25).
            onCaptureInterruptedWhileListening?()
            return
        }

        // Idle-warm: the input format the converter/tap were built against may have changed.
        // Rebuild the tap + AVAudioConverter against the new format WITHOUT tearing down the
        // audio session/keepalive.
        rebuildWarmEngineAfterConfigurationChange()
    }

    private func rebuildWarmEngineAfterConfigurationChange() {
        guard engine.isRunning || canResumePreparedAudioGraph else { return }
        // Tear down just the engine graph (tap + nodes), keeping our warm-idle intent, then warm
        // again so a fresh converter is built against the new input format.
        silentPlayer.stop()
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning {
            engine.stop()
        }
        shouldResumeKeepAliveOutput = false
        silentBuffer = nil
        do {
            try warmEngine()
        } catch {
            print("[audio] failed to re-warm after configuration change: \(error.localizedDescription)")
            logPlatformAudioSession(reason: "engine-configuration-change-rewarm-failed")
        }
    }

    func startCapturing(
        chunkHandler: @escaping ChunkHandler,
        duckOthersOnMac: Bool = false,
        audioFocusActivationDelayOnMac: TimeInterval = 0
    ) throws {
        self.chunkHandler = chunkHandler
        prepareMacAudioFocusIfNeeded(duckingEnabled: duckOthersOnMac)

        if engine.isRunning {
            isCapturing = true
            isTransmitting = true
            setAcceptsIncomingAudioBuffers(true)
            activateMacAudioFocusIfNeeded(
                duckingEnabled: duckOthersOnMac,
                activationDelay: audioFocusActivationDelayOnMac
            )
            finalizeMacAudioFocusAfterSuccessfulStart(duckingEnabled: duckOthersOnMac)
            reconfigurePlatformAudioSessionIfNeeded(for: .capturing, reason: "start-capturing-fast-path")
            updateKeepAliveOutputPlayback(reason: "start-capturing-fast-path")
            logPlatformAudioSession(reason: "start-capturing-fast-path")
            return
        }

        if canResumePreparedAudioGraph {
            do {
                try resumePreparedEngine(reason: "start-capturing-warm-resume")
                isCapturing = true
                isTransmitting = true
                setAcceptsIncomingAudioBuffers(true)
                activateMacAudioFocusIfNeeded(
                    duckingEnabled: duckOthersOnMac,
                    activationDelay: audioFocusActivationDelayOnMac
                )
                finalizeMacAudioFocusAfterSuccessfulStart(duckingEnabled: duckOthersOnMac)
                updateKeepAliveOutputPlayback(reason: "start-capturing-warm-resume")
                logPlatformAudioSession(reason: "start-capturing-warm-resume")
                return
            } catch {
                print("[audio] failed to resume warmed engine for capture: \(error.localizedDescription)")
            }
        }

        guard let outputFormat else { throw AudioCaptureError.failedToConfigureSession }
        guard let inputNode = engine.inputNode as AVAudioInputNode? else {
            throw AudioCaptureError.inputUnavailable
        }

        try configurePlatformAudioSession(for: .capturing)

        let inputFormat = inputNode.inputFormat(forBus: 0)
        let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        if usesKeepAliveOutput {
            guard let silentBuffer = createSilentBuffer() else {
                throw AudioCaptureError.failedToConfigureSession
            }
            self.silentBuffer = silentBuffer
            shouldResumeKeepAliveOutput = true

            if !engine.attachedNodes.contains(silentPlayer) {
                engine.attach(silentPlayer)
            }
            engine.connect(silentPlayer, to: engine.mainMixerNode, format: silentBuffer.format)
        } else {
            silentBuffer = nil
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.enqueueBufferForProcessing(buffer, converter: converter, outputFormat: outputFormat)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            setAcceptsIncomingAudioBuffers(false)
            let captureError = classifyMacCaptureStartFailure(error)
            if let issue = captureError.macAudioFocusIssue {
                pendingMacAudioFocusIssue = issue
                macAudioFocusState = MacDictationAudioFocusStateMachine.captureFailed(issue: issue)
            }
            releaseMacCaptureGraph(reason: "start-capturing-failed")
            throw captureError
        }
        isCapturing = true
        isTransmitting = true
        setAcceptsIncomingAudioBuffers(true)
        activateMacAudioFocusIfNeeded(
            duckingEnabled: duckOthersOnMac,
            activationDelay: audioFocusActivationDelayOnMac
        )
        finalizeMacAudioFocusAfterSuccessfulStart(duckingEnabled: duckOthersOnMac)
        updateKeepAliveOutputPlayback(reason: "start-capturing-cold-start")
        logPlatformAudioSession(reason: "start-capturing-cold-start")
    }

    var isEngineRunning: Bool { engine.isRunning }

    func warmEngine() throws {
        guard !engine.isRunning else {
            logPlatformAudioSession(reason: "warm-engine-already-running")
            return
        }
        guard let outputFormat else { throw AudioCaptureError.failedToConfigureSession }
        guard let inputNode = engine.inputNode as AVAudioInputNode? else {
            throw AudioCaptureError.inputUnavailable
        }

        try configurePlatformAudioSession(for: .warmKeepAlive)

        let inputFormat = inputNode.inputFormat(forBus: 0)
        let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        if usesKeepAliveOutput {
            guard let silentBuffer = createSilentBuffer() else {
                throw AudioCaptureError.failedToConfigureSession
            }
            self.silentBuffer = silentBuffer
            shouldResumeKeepAliveOutput = true

            if !engine.attachedNodes.contains(silentPlayer) {
                engine.attach(silentPlayer)
            }
            engine.connect(silentPlayer, to: engine.mainMixerNode, format: silentBuffer.format)
        } else {
            silentBuffer = nil
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.enqueueBufferForProcessing(buffer, converter: converter, outputFormat: outputFormat)
        }

        engine.prepare()
        try engine.start()
        setAcceptsIncomingAudioBuffers(false)
        if usesKeepAliveOutput {
            updateKeepAliveOutputPlayback(reason: "warm-engine")
            print("[audio] engine warmed — running with silent player, not transmitting")
        } else {
            print("[audio] engine warmed — running without output keepalive")
        }
        logPlatformAudioSession(reason: "warm-engine")
    }

    func stopCapturing() {
        setAcceptsIncomingAudioBuffers(false)
        isCapturing = false
        isTransmitting = false
        levelHandler?(0, Int64(Date().timeIntervalSince1970 * 1000))
        releaseMacAudioFocus(reason: "stop-capturing")
        resetMacAudioFocusRuntime()
    }

    func finishTransmittingAndStopCapturing(drainTimeout: TimeInterval) async -> Bool {
        setAcceptsIncomingAudioBuffers(false)
        let didDrain = await waitForPendingProcessingDrain(timeout: drainTimeout)
        stopCapturing()
        return didDrain
    }

    func logPlatformAudioSession(reason: String) {
    }

    func consumeMacAudioFocusIssue() -> MacDictationAudioFocusIssue? {
        defer { pendingMacAudioFocusIssue = nil }
        return pendingMacAudioFocusIssue
    }

    private func updateKeepAliveOutputPlayback(reason: String) {
        guard usesKeepAliveOutput else {
            silentPlayer.stop()
            return
        }

        guard engine.isRunning, shouldResumeKeepAliveOutput, let silentBuffer else {
            if silentPlayer.isPlaying {
                silentPlayer.stop()
            }
            return
        }

        guard !isTransmitting else {
            if silentPlayer.isPlaying {
                silentPlayer.stop()
                logPlatformAudioSession(reason: "\(reason)-keepalive-stopped")
            }
            return
        }

        if silentPlayer.isPlaying {
            return
        }

        silentPlayer.stop()
        silentPlayer.scheduleBuffer(silentBuffer, at: nil, options: .loops, completionHandler: nil)
        silentPlayer.play()
    }

    private var canResumePreparedAudioGraph: Bool {
        shouldResumeKeepAliveOutput && silentBuffer != nil
    }

    private func resumePreparedEngine(reason: String) throws {
        guard canResumePreparedAudioGraph else {
            throw AudioCaptureError.failedToConfigureSession
        }
        guard !engine.isRunning else { return }
        try engine.start()
        logPlatformAudioSession(reason: "\(reason)-engine-resumed")
    }

    private func enqueueBufferForProcessing(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter?,
        outputFormat: AVAudioFormat
    ) {
        guard shouldAcceptIncomingAudioBuffers else { return }
        let processingGroup = self.processingGroup
        incrementPendingProcessingBufferCount()
        processingGroup.enter()
        processingQueue.async { [weak self] in
            defer {
                self?.decrementPendingProcessingBufferCount()
                processingGroup.leave()
            }
            guard let self else { return }
            // Snapshot cross-thread state once under the lock to avoid transmitting a chunk
            // after stop() flipped isTransmitting off mid-buffer (M-6).
            self.processingStateLock.lock()
            let transmitting = self.isTransmittingStorage
            let levelHandler = self.levelHandlerStorage
            let chunkHandler = self.chunkHandlerStorage
            self.processingStateLock.unlock()
            guard transmitting else { return }
            let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
            let level = self.normalizedLevel(from: buffer)
            levelHandler?(level, timestamp)
            guard let converted = self.convert(buffer: buffer, with: converter, to: outputFormat) else { return }
            chunkHandler?(converted, timestamp)
        }
    }

    private var shouldAcceptIncomingAudioBuffers: Bool {
        processingStateLock.withLock { acceptsIncomingAudioBuffers }
    }

    private func setAcceptsIncomingAudioBuffers(_ shouldAccept: Bool) {
        processingStateLock.withLock {
            acceptsIncomingAudioBuffers = shouldAccept
        }
    }

    private func incrementPendingProcessingBufferCount() {
        processingStateLock.withLock {
            pendingProcessingBufferCountStorage += 1
        }
    }

    private func decrementPendingProcessingBufferCount() {
        processingStateLock.withLock {
            pendingProcessingBufferCountStorage = max(0, pendingProcessingBufferCountStorage - 1)
        }
    }

    private func waitForPendingProcessingDrain(timeout: TimeInterval) async -> Bool {
        if pendingProcessingBufferCount == 0 {
            return true
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [processingGroup] in
                let didDrain = processingGroup.wait(timeout: .now() + timeout) == .success
                continuation.resume(returning: didDrain)
            }
        }
    }

    private func convert(buffer: AVAudioPCMBuffer, with converter: AVAudioConverter?, to format: AVAudioFormat) -> Data? {
        guard let converter else { return nil }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            return nil
        }

        var conversionError: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        let status = converter.convert(to: outputBuffer, error: &conversionError, withInputFrom: inputBlock)
        guard status == .haveData else { return nil }
        guard let int16Pointer = outputBuffer.int16ChannelData?.pointee else { return nil }

        let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
        return Data(bytes: int16Pointer, count: byteCount)
    }

    private func createSilentBuffer() -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1) else {
            return nil
        }
        let frameCapacity = AVAudioFrameCount(format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            return nil
        }
        buffer.frameLength = frameCapacity

        guard let channel = buffer.floatChannelData?.pointee else {
            return nil
        }

        for index in 0..<Int(frameCapacity) {
            channel[index] = 0
        }
        return buffer
    }

    private func normalizedLevel(from buffer: AVAudioPCMBuffer) -> Double {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        if let channel = buffer.floatChannelData?.pointee {
            var sumSquares: Float = 0
            for index in 0..<frameLength {
                let sample = channel[index]
                sumSquares += sample * sample
            }
            let rms = sqrt(sumSquares / Float(frameLength))
            return normalizeRMS(Double(rms))
        }

        if let channel = buffer.int16ChannelData?.pointee {
            var sumSquares: Double = 0
            for index in 0..<frameLength {
                let sample = Double(channel[index]) / Double(Int16.max)
                sumSquares += sample * sample
            }
            let rms = sqrt(sumSquares / Double(frameLength))
            return normalizeRMS(rms)
        }

        return 0
    }

    private func normalizeRMS(_ rms: Double) -> Double {
        let floorLevel = 0.003
        let ceilingLevel = 0.09
        let normalized = (rms - floorLevel) / (ceilingLevel - floorLevel)
        let clamped = max(0, min(normalized, 1))
        return pow(clamped, 0.62)
    }
}

private extension AudioCaptureError {
    var macAudioFocusIssue: MacDictationAudioFocusIssue? {
        switch self {
        case .microphoneBusy, .inputUnavailable:
            return .microphoneBusy
        case .failedToConfigureSession:
            return nil
        }
    }
}

private struct MacSystemOutputMuteSnapshot {
    let deviceID: AudioObjectID
    let muteValue: UInt32?
    let volumeScalar: Float32?
}

private final class MacSystemOutputMuteController {
    private var snapshot: MacSystemOutputMuteSnapshot?

    func engage() -> Bool {
        guard snapshot == nil else { return true }
        guard let deviceID = defaultOutputDeviceID() else { return false }

        let muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let priorMuteValue = readProperty(UInt32.self, for: deviceID, address: muteAddress)
        let priorVolumeScalar = readProperty(Float32.self, for: deviceID, address: volumeAddress)

        var didApplyMute = false
        if priorMuteValue != nil {
            didApplyMute = writeProperty(UInt32(1), for: deviceID, address: muteAddress)
        }

        var didApplyVolume = false
        if priorVolumeScalar != nil {
            didApplyVolume = writeProperty(Float32(0), for: deviceID, address: volumeAddress)
        }

        guard didApplyMute || didApplyVolume else { return false }

        snapshot = MacSystemOutputMuteSnapshot(
            deviceID: deviceID,
            muteValue: didApplyMute ? priorMuteValue : nil,
            volumeScalar: didApplyVolume ? priorVolumeScalar : nil
        )
        return true
    }

    func release() {
        guard let snapshot else { return }

        let muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if let muteValue = snapshot.muteValue {
            _ = writeProperty(muteValue, for: snapshot.deviceID, address: muteAddress)
        }
        if let volumeScalar = snapshot.volumeScalar {
            _ = writeProperty(volumeScalar, for: snapshot.deviceID, address: volumeAddress)
        }

        self.snapshot = nil
    }

    private func defaultOutputDeviceID() -> AudioObjectID? {
        let address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return readProperty(AudioObjectID.self, for: AudioObjectID(kAudioObjectSystemObject), address: address)
    }

    private func readProperty<T>(
        _: T.Type,
        for objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) -> T? {
        var address = address
        guard AudioObjectHasProperty(objectID, &address) else { return nil }
        return withUnsafeTemporaryAllocation(of: T.self, capacity: 1) { buffer in
            guard let valuePointer = buffer.baseAddress else { return nil }
            var dataSize = UInt32(MemoryLayout<T>.size)
            let status = AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &dataSize,
                valuePointer
            )
            guard status == noErr else { return nil }
            return valuePointer.pointee
        }
    }

    private func writeProperty<T>(
        _ value: T,
        for objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) -> Bool {
        var address = address
        guard AudioObjectHasProperty(objectID, &address) else { return false }

        var isSettable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(objectID, &address, &isSettable) == noErr else { return false }
        guard isSettable.boolValue else { return false }

        var value = value
        return withUnsafeBytes(of: &value) { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            let status = AudioObjectSetPropertyData(
                objectID,
                &address,
                0,
                nil,
                UInt32(rawBuffer.count),
                baseAddress
            )
            return status == noErr
        }
    }
}

private extension AudioCaptureService {
    func prepareMacAudioFocusIfNeeded(duckingEnabled: Bool) {
        pendingMacAudioFocusActivationWorkItem?.cancel()
        pendingMacAudioFocusActivationWorkItem = nil
        pendingMacAudioFocusIssue = nil
        macAudioFocusState = MacDictationAudioFocusStateMachine.startRequested(
            duckingEnabled: duckingEnabled
        )
    }

    func activateMacAudioFocusIfNeeded(
        duckingEnabled: Bool,
        activationDelay: TimeInterval
    ) {
        guard duckingEnabled else { return }
        pendingMacAudioFocusActivationWorkItem?.cancel()
        pendingMacAudioFocusActivationWorkItem = nil

        guard activationDelay > 0 else {
            engageMacAudioFocusNowIfNeeded()
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.engageMacAudioFocusNowIfNeeded()
        }
        pendingMacAudioFocusActivationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + activationDelay, execute: workItem)
    }

    func engageMacAudioFocusNowIfNeeded() {
        pendingMacAudioFocusActivationWorkItem = nil
        guard macOutputMuteController.engage() else {
            macAudioFocusState = MacDictationAudioFocusStateMachine.duckingSetupFailed()
            pendingMacAudioFocusIssue = .duckingUnavailable
            print("[audio] failed to mute macOS output audio while dictating")
            return
        }
    }

    func finalizeMacAudioFocusAfterSuccessfulStart(duckingEnabled: Bool) {
        macAudioFocusState = MacDictationAudioFocusStateMachine.captureStarted(
            from: macAudioFocusState,
            duckingEnabled: duckingEnabled
        )
    }

    func classifyMacCaptureStartFailure(_ error: Error) -> AudioCaptureError {
        let nsError = error as NSError
        let message = [
            nsError.localizedDescription,
            nsError.localizedFailureReason,
            nsError.localizedRecoverySuggestion
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .joined(separator: " ")
        .lowercased()

        if message.contains("busy")
            || message.contains("in use")
            || message.contains("unavailable")
            || message.contains("no device")
            || message.contains("input")
            || message.contains("microphone")
        {
            return .microphoneBusy
        }

        return .failedToConfigureSession
    }

    func releaseMacCaptureGraph(reason: String) {
        engine.inputNode.removeTap(onBus: 0)
        silentPlayer.stop()
        if engine.isRunning {
            engine.stop()
        }
        chunkHandler = nil
        shouldResumeKeepAliveOutput = false
        silentBuffer = nil
        print("[audio] mac capture graph released (\(reason))")
    }

    func releaseMacAudioFocus(reason: String) {
        pendingMacAudioFocusActivationWorkItem?.cancel()
        pendingMacAudioFocusActivationWorkItem = nil
        macOutputMuteController.release()
        print("[audio] mac audio focus released (\(reason))")
    }

    func resetMacAudioFocusRuntime() {
        macAudioFocusState = MacDictationAudioFocusStateMachine.stop()
        pendingMacAudioFocusIssue = nil
    }
}

private extension AudioCaptureService {
    func beginObservingPlatformInterruptions() {}

    func configurePlatformAudioSession(for profile: PlatformAudioSessionProfile) throws {}

    func reconfigurePlatformAudioSessionIfNeeded(for profile: PlatformAudioSessionProfile, reason: String) {}
}
