import Combine
import Foundation
import AppKit

enum DictationStatus: Equatable {
    case idle
    case listening
    case processing
    case error(String)

}

/// Distinguishes a normal dictation session from a "revise selected text by voice"
/// (transform) session. The two share the exact same audio-capture/websocket/finalize
/// pipeline — this only affects which prompt is sent to the cleanup backend and
/// whether the result is persisted to dictation history (see `startTransform(selectedText:)`).
private enum DictationSessionMode: Equatable {
    case dictation
    case transformSelection
}

enum ConnectionRefreshPolicy {
    static func shouldDefer(for status: DictationStatus) -> Bool {
        switch status {
        case .listening, .processing:
            return true
        case .idle, .error:
            return false
        }
    }
}

enum DictationTransportFailurePolicy {
    static func shouldSurfaceAsDictationError(
        status: DictationStatus,
        isCapturing: Bool,
        streamingSessionState: String
    ) -> Bool {
        if isCapturing { return true }

        switch status {
        case .listening, .processing:
            return true
        case .idle, .error:
            // An already-shown error must not be re-raised by every idle reconnect
            // attempt — that kept a stale "Socket is not connected" on screen forever.
            return streamingSessionState != "idle"
        }
    }
}

protocol TextInjecting {
    func inject(text: String)
}

struct DictationFinalizedRecord: Sendable {
    enum Stage: Sendable {
        case canonicalCleaned
        // A session that failed before producing canonical text. The stored finalText is the
        // best raw/partial transcript so the user's words are not lost; auto-learn is skipped.
        case failedRawFallback
    }

    let sessionID: String
    let stage: Stage
    let timestamp: Date
    let finalText: String
    let rawText: String
    let outputPresetRawValue: String
    let audioDuration: TimeInterval
    let wordCount: Int
    let wordsPerMinute: Double
    let requestedSourceLanguageModeRawValue: String
    let requestedSourceLanguageCode: String?
    let resolvedSourceLanguageCode: String?
    let outputLanguageCode: String?
    let didTranslate: Bool
    let providerRouteRawValue: String?
}

struct DictationNotice: Equatable, Sendable {
    let id: String
    let text: String
}

struct DictationTransportMetadata: Equatable, Sendable {
    let requestedSourceLanguageModeRawValue: String
    let requestedSourceLanguageCode: String?
    let resolvedSourceLanguageCode: String?
    let outputLanguageCode: String?
    let didTranslate: Bool
    let providerRouteRawValue: String?
}

struct DictationOutputPayload: Equatable, Sendable {
    let sessionID: String
    let text: String
    let isCanonical: Bool
    let metadata: DictationTransportMetadata
}

private enum DictationSessionDeliveryMode: Sendable {
    case liveProvisional
    case finalOnly
}

/// Thread-safe one-shot flag so the audio-processing queue can report the first observed chunk
/// back to the MainActor exactly once, without a per-chunk hop (M-11).
private final class AudioChunkObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var observed = false

    /// Returns true only on the first call.
    func markObservedIfNeeded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !observed else { return false }
        observed = true
        return true
    }
}

private struct SessionServerMetadata: Sendable {
    var requestedSourceLanguageModeRawValue: String?
    var requestedSourceLanguageCode: String?
    var resolvedSourceLanguageCode: String?
    var outputLanguageCode: String?
    var didTranslate: Bool?
    var providerRouteRawValue: String?
}

@MainActor
final class DictationCoordinator: ObservableObject {
    @Published private(set) var status: DictationStatus = .idle
    @Published private(set) var connectionState: RealtimeConnectionState = .disconnected
    @Published private(set) var liveText = ""
    @Published private(set) var lastFinalText = ""
    @Published private(set) var lastFinalOutput: DictationOutputPayload?
    @Published private(set) var lastLatencyMs: Int = 0
    @Published private(set) var lastNotice: DictationNotice?
    @Published private(set) var liveInputLevel: Double = 0

    private let configuration: AppConfiguration
    private let websocketClient: RealtimeWebSocketClient
    private let audioCaptureService: AudioCaptureService
    private let textInjector: TextInjecting

    private var transcriptAssembler = TranscriptAssembler()
    private var currentSessionStartTimeMs: Int64 = 0
    private var firstResponseTimestampMs: Int64?
    private var activeDictationStartDate: Date?
    private var lastAudioDurationSeconds: TimeInterval = 0
    private var pendingRawFinalText = ""
    private var didEmitCanonicalResult = false
    private var currentSessionMode: DictationSessionMode = .dictation
    private var currentFinalizationSessionID = UUID().uuidString
    private var currentOutputPresetSnapshot: DictationOutputPreset = .default
    private var currentDeliveryMode: DictationSessionDeliveryMode = .liveProvisional
    private var currentRequestedSourceLanguageModeSnapshot: DictationSourceLanguageMode = .auto
    private var currentRequestedSourceLanguageCodeSnapshot: String?
    private var currentOutputLanguageModeSnapshot: DictationOutputLanguageMode = .explicit
    private var currentExplicitOutputLanguageCodeSnapshot = DictationLanguageCatalog.defaultExplicitOutputLanguageCode
    private var currentSessionMetadata = SessionServerMetadata()
    private var gracefulStopTask: Task<Void, Never>?
    private var finalizationWatchdogTask: Task<Void, Never>?
    private var hasPendingConnectionRefresh = false
    private var processingStartedAt: Date?
    // Trailing-capture floor: after a stop request we keep the mic tap live briefly so the
    // input node can deliver its last buffered frames (the user's final word) before we stop.
    // Kept as a floor rather than a fixed wait so perceived stop latency is bounded (M-10).
    private let trailingCaptureFloorNs: UInt64 = 250_000_000
    private let audioDrainTimeout: TimeInterval = 0.25
    // The bundled local connector uploads the completed recording after release.
    // Remote streaming backends retain their existing short finalization deadline.
    private var finalizationWatchdogDelayNs: UInt64 {
        let host = URL(string: configuration.backendURL)?.host ?? ""
        return ["localhost", "127.0.0.1", "[::1]"].contains(host) ? 65_000_000_000 : 8_000_000_000
    }
    private let staleProcessingRetryThreshold: TimeInterval = 5
    private var didInjectTextForCurrentSession = false
    private var suppressInboundMessagesUntilNextSessionStart = false
    private var didObserveSessionAudioChunk = false
    /// The current `.error` came from losing the websocket (not the server rejecting the
    /// dictation), so a successful reconnect resolves it.
    private var errorIsTransportRelated = false
    private var isRecoveringLiveSession = false
    private var liveSessionRecoveryAttempts = 0
    private let maxLiveSessionRecoveryAttempts = 2
    var customVocabularyProvider: (() -> [String])?
    var dictationPromptAppendixProvider: (() -> String?)?

    var onFinalizedDictation: ((DictationFinalizedRecord) -> Void)?
    /// Invoked when the backend rejected auth (policy violation). The owner should
    /// force-refresh the auth token so reconfiguration lifts the reconnect suppression (H-14).
    var onAuthorizationRejected: (() -> Void)?

    init(
        configuration: AppConfiguration,
        websocketClient: RealtimeWebSocketClient,
        audioCaptureService: AudioCaptureService,
        textInjector: TextInjecting
    ) {
        self.configuration = configuration
        self.websocketClient = websocketClient
        self.audioCaptureService = audioCaptureService
        self.textInjector = textInjector
        self.websocketClient.delegate = self
        self.audioCaptureService.levelHandler = { [weak self] level, _ in
            Task { @MainActor [weak self] in
                self?.handleAudioLevel(level)
            }
        }
        self.audioCaptureService.onCaptureInterruptedWhileListening = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleCaptureInterruptedWhileListening()
            }
        }
    }

    private func handleCaptureInterruptedWhileListening() {
        // An audio interruption or route/config change invalidated the live capture. Give up the
        // current session cleanly, preserving any raw text via the failure-recovery path (M-24/M-25).
        guard status == .listening || status == .processing else { return }
        recoverFromStalledFinalization(
            message: "Dictation was interrupted. Kleio reset the session so you can start again."
        )
    }

    private var lastLiveInputLevelPublishAt: TimeInterval = 0
    private let liveInputLevelPublishIntervalSeconds: TimeInterval = 1.0 / 15.0

    private func handleAudioLevel(_ level: Double) {
        // Throttle to ~15Hz so SwiftUI isn't invalidated ~47×/s while dictating (M-11).
        // Always publish a zero (end-of-session / silence) immediately.
        let now = Date().timeIntervalSince1970
        if level > 0, now - lastLiveInputLevelPublishAt < liveInputLevelPublishIntervalSeconds {
            return
        }
        lastLiveInputLevelPublishAt = now
        liveInputLevel = level
    }

    private func markObservedSessionAudioChunk(for sessionID: String) {
        guard sessionID == currentFinalizationSessionID else { return }
        didObserveSessionAudioChunk = true
    }

    private func resetSpeechActivity() {
        // No-op while dictation now relies on transport/audibility outcomes
        // instead of local heuristics.
    }

    /// - Parameter promptOverride: When non-nil, sent verbatim as the session prompt,
    ///   bypassing the outputPreset/appendix composition below entirely. Used by
    ///   `startTransform(selectedText:)` to send a "revise this text" instruction
    ///   instead of the normal dictation cleanup prompt.
    private func buildSessionStartMessage(promptOverride: String? = nil) -> ClientMessage {
        let activeVocabulary = customVocabularyProvider?() ?? configuration.customVocabulary
        let sessionPrompt: String
        if let promptOverride {
            sessionPrompt = promptOverride
        } else {
            let basePrompt = DictationPrompt.prompt(for: configuration.outputPreset)
            let promptAppendix = dictationPromptAppendixProvider?()?.trimmingCharacters(in: .whitespacesAndNewlines)
            sessionPrompt = [basePrompt, promptAppendix]
                .compactMap { value in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }
                .joined(separator: "\n\n")
        }
        let appVersion =
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            ?? "0"
        let clientPlatform = "macos"

        return ClientMessage.sessionStart(
            prompt: sessionPrompt,
            promptProfile: configuration.outputPreset.serverProfileKey,
            cleanupModel: configuration.cleanupModel.rawValue,
            sourceLanguageMode: configuration.sourceLanguageMode.rawValue,
            sourceLanguage: currentRequestedSourceLanguageCodeSnapshot,
            outputLanguage: configuration.outputLanguageMode == .matchSource
                ? DictationOutputLanguageMode.matchSource.rawValue
                : currentExplicitOutputLanguageCodeSnapshot,
            sampleRate: audioCaptureService.sampleRate,
            customVocabulary: activeVocabulary,
            privacyModeEnabled: configuration.privacyModeEnabled,
            improvementSharingEnabled: configuration.improvementSharingEnabled,
            clientAppVersion: appVersion,
            clientLocale: Locale.current.identifier,
            clientPlatform: clientPlatform,
            clientSessionID: currentFinalizationSessionID
        )
    }

    func warmConnection() {
        // Warming before sign-in has produced a token only earns a "Missing Firebase
        // bearer token" rejection. The token's arrival triggers
        // refreshConnectionConfiguration(), which warms the connection then.
        guard !configuration.authToken.isEmpty else { return }
        do {
            try websocketClient.configure(
                backendURLString: configuration.backendURL,
                authToken: configuration.authToken
            )
            websocketClient.connectIfNeeded()
        } catch {
            status = DictationStatusReducer.reduce(from: status, event: .failure(error.localizedDescription))
        }
    }

    func refreshConnectionConfiguration() {
        guard !ConnectionRefreshPolicy.shouldDefer(for: status) else {
            hasPendingConnectionRefresh = true
            return
        }
        hasPendingConnectionRefresh = false
        websocketClient.disconnect()
        warmConnection()
    }

    private var isActivelyDictatingOrFinalizing: Bool {
        ConnectionRefreshPolicy.shouldDefer(for: status)
    }

    private func applyPendingConnectionRefreshIfNeeded() {
        guard hasPendingConnectionRefresh else { return }
        guard !isActivelyDictatingOrFinalizing else { return }
        hasPendingConnectionRefresh = false
        websocketClient.disconnect()
        warmConnection()
    }

    private func reconnectAfterResetIfNeeded() {
        if hasPendingConnectionRefresh {
            applyPendingConnectionRefreshIfNeeded()
        } else {
            warmConnection()
        }
    }

    func startDictation(macAudioOutputMuteDelay: TimeInterval = 0) {
        currentSessionMode = .dictation
        _ = beginDictationSession(macAudioOutputMuteDelay: macAudioOutputMuteDelay, promptOverride: nil)
    }

    /// Starts a "revise selected text by voice" session: the user's next utterance is
    /// treated as an instruction to apply to `selectedText`, not as new dictation
    /// content. Reuses the exact same audio-capture/websocket/finalize pipeline as
    /// `startDictation()` — only the prompt sent to the cleanup backend differs, and the
    /// resulting text is injected (replacing the still-active selection) but NOT saved
    /// to dictation history. Returns false (and starts nothing) if a session is already
    /// active, mirroring `startDictation()`'s own guard.
    func startTransform(selectedText: String) -> Bool {
        currentSessionMode = .transformSelection
        let prompt = """
        You are revising a piece of text based on a short spoken instruction from the user.

        ORIGINAL TEXT TO REVISE:
        \"\"\"
        \(selectedText)
        \"\"\"

        The transcript that follows is the user's SPOKEN INSTRUCTION describing the change they want — it is not text to insert, it is an instruction to apply to the ORIGINAL TEXT above. Apply it and output ONLY the fully revised text: no preamble, no explanation, no quotation marks, no commentary. If the instruction is ambiguous, make the most reasonable interpretation and still output only the revised text.
        """
        let didStart = beginDictationSession(macAudioOutputMuteDelay: 0, promptOverride: prompt)
        if !didStart {
            // Nothing started; don't leave a stray transform mode hanging around.
            currentSessionMode = .dictation
        }
        return didStart
    }

    /// Shared session-start bookkeeping for both `startDictation()` and
    /// `startTransform(selectedText:)` — state resets, websocket session-start, and
    /// audio capture start. `promptOverride`, when non-nil, is threaded through to
    /// `buildSessionStartMessage(promptOverride:)` in place of the normal
    /// outputPreset-derived prompt. Returns false (starting nothing) if a session is
    /// already active.
    private func beginDictationSession(macAudioOutputMuteDelay: TimeInterval, promptOverride: String?) -> Bool {
        // Recover a session stuck in .processing (the only pre-guard side effect):
        // this can flip status to .error so a fresh session can start below.
        if case .processing = status,
           let processingStartedAt,
           Date().timeIntervalSince(processingStartedAt) >= staleProcessingRetryThreshold {
            recoverFromStalledFinalization(
                message: "Finalization timed out. Kleio reset the session so you can start again."
            )
        }

        // Run the status guard BEFORE cancelling the graceful-stop task / watchdog, so a
        // re-press during the 400ms stop window can't strand the mic hot with no watchdog (C-1).
        let canStartDictation: Bool
        switch status {
        case .idle, .error:
            canStartDictation = true
        case .listening, .processing:
            canStartDictation = false
        }
        guard canStartDictation else { return false }

        gracefulStopTask?.cancel()
        gracefulStopTask = nil
        cancelFinalizationWatchdog()

        resetMacInjectionState()
        suppressInboundMessagesUntilNextSessionStart = false
        didObserveSessionAudioChunk = false
        isRecoveringLiveSession = false
        liveSessionRecoveryAttempts = 0
        websocketClient.markStreamingSessionCompleted()
        resetSpeechActivity()
        transcriptAssembler.reset()
        liveText = ""
        lastFinalText = ""
        lastFinalOutput = nil
        lastNotice = nil
        liveInputLevel = 0
        firstResponseTimestampMs = nil
        pendingRawFinalText = ""
        didEmitCanonicalResult = false
        currentFinalizationSessionID = UUID().uuidString
        currentOutputPresetSnapshot = configuration.outputPreset
        currentDeliveryMode = configuration.usesFastEnglishLivePath ? .liveProvisional : .finalOnly
        currentRequestedSourceLanguageModeSnapshot = configuration.sourceLanguageMode
        currentRequestedSourceLanguageCodeSnapshot = configuration.sourceLanguageMode == .explicit
            ? DictationLanguageCatalog.normalize(code: configuration.sourceLanguageCode)
            : nil
        currentOutputLanguageModeSnapshot = configuration.outputLanguageMode
        currentExplicitOutputLanguageCodeSnapshot =
            DictationLanguageCatalog.normalize(code: configuration.outputLanguageCode)
            ?? DictationLanguageCatalog.defaultExplicitOutputLanguageCode
        currentSessionMetadata = SessionServerMetadata(
            requestedSourceLanguageModeRawValue: currentRequestedSourceLanguageModeSnapshot.rawValue,
            requestedSourceLanguageCode: currentRequestedSourceLanguageCodeSnapshot,
            resolvedSourceLanguageCode: currentRequestedSourceLanguageCodeSnapshot,
            outputLanguageCode: DictationLanguageCatalog.resolvedOutputLanguageCode(
                outputMode: currentOutputLanguageModeSnapshot,
                explicitOutputLanguageCode: currentExplicitOutputLanguageCodeSnapshot,
                sourceMode: currentRequestedSourceLanguageModeSnapshot,
                explicitSourceLanguageCode: currentRequestedSourceLanguageCodeSnapshot ?? DictationLanguageCatalog.defaultExplicitSourceLanguageCode,
                resolvedSourceLanguageCode: currentRequestedSourceLanguageCodeSnapshot
            ),
            didTranslate: false,
            providerRouteRawValue: configuration.usesFastEnglishLivePath
                ? DictationProviderRoute.deepgramLive.rawValue
                : DictationProviderRoute.groqWhisperBuffered.rawValue
        )
        currentSessionStartTimeMs = nowInMs()
        activeDictationStartDate = Date()
        lastAudioDurationSeconds = 0
        errorIsTransportRelated = false
        status = DictationStatusReducer.reduce(from: status, event: .startListening)

        let sessionStart = buildSessionStartMessage(promptOverride: promptOverride)
        websocketClient.send(sessionStart)

        // Capture immutable per-session values so the audio-processing queue can build and send
        // audio_chunk messages directly, without a per-chunk MainActor hop (M-11). The websocket
        // client is now thread-safe (C-2). A one-shot flag reports the first observed chunk back
        // to the MainActor (used by mac silent-session detection).
        let sessionID = currentFinalizationSessionID
        let client = websocketClient
        let observedFirstChunk = AudioChunkObservationFlag()
        do {
            try audioCaptureService.startCapturing(
                chunkHandler: { [weak self] pcmChunk, _ in
                    let message = ClientMessage.audioChunk(
                        data: pcmChunk.base64EncodedString(),
                        clientSessionID: sessionID
                    )
                    client.send(message)
                    if observedFirstChunk.markObservedIfNeeded() {
                        Task { @MainActor [weak self] in
                            self?.markObservedSessionAudioChunk(for: sessionID)
                        }
                    }
                },
                duckOthersOnMac: configuration.dictationAudioDuckingEnabled,
                audioFocusActivationDelayOnMac: macAudioOutputMuteDelay
            )
            if let focusIssue = audioCaptureService.consumeMacAudioFocusIssue() {
                lastNotice = DictationNotice(id: UUID().uuidString, text: focusIssue.noticeText)
            }
        } catch {
            print("[dictation] start capture failed: \(error.localizedDescription)")
            lastNotice = DictationNotice(id: UUID().uuidString, text: error.localizedDescription)
            status = DictationStatusReducer.reduce(from: status, event: .failure(error.localizedDescription))
            liveInputLevel = 0
        }
        return true
    }

    func stopDictation() {
        guard status == .listening else { return }
        if !didObserveSessionAudioChunk {
            abortSilentSessionAndRearm()
            return
        }
        status = DictationStatusReducer.reduce(from: status, event: .stopListening)
        liveInputLevel = 0
        processingStartedAt = Date()
        scheduleFinalizationWatchdog()
        guard gracefulStopTask == nil else { return }

        gracefulStopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: trailingCaptureFloorNs)
            guard !Task.isCancelled else { return }

            let didDrainPendingAudio = await audioCaptureService.finishTransmittingAndStopCapturing(
                drainTimeout: audioDrainTimeout
            )
            if !didDrainPendingAudio {
                print(
                    "[dictation] audio drain timed out before session_end " +
                    "client_session_id=\(currentFinalizationSessionID)"
                )
            }

            if let activeDictationStartDate {
                lastAudioDurationSeconds = max(0, Date().timeIntervalSince(activeDictationStartDate))
            }
            activeDictationStartDate = nil

            websocketClient.send(.sessionEnd(clientSessionID: currentFinalizationSessionID))
            gracefulStopTask = nil
        }
    }

    private func applyPartial(_ text: String) {
        let snapshot = transcriptAssembler.applyPartial(text)
        liveText = snapshot.bestText
        updateLatencyIfNeeded()
    }

    private func ingestServerMetadata(from message: ServerMessage) {
        if let sourceLanguageMode = message.sourceLanguageMode {
            currentSessionMetadata.requestedSourceLanguageModeRawValue = sourceLanguageMode
        }
        if let sourceLanguage = DictationLanguageCatalog.normalize(code: message.sourceLanguage) {
            currentSessionMetadata.requestedSourceLanguageCode = sourceLanguage
        }
        if let resolvedSourceLanguage = DictationLanguageCatalog.normalize(code: message.resolvedSourceLanguage) {
            currentSessionMetadata.resolvedSourceLanguageCode = resolvedSourceLanguage
        }
        if let outputLanguage = DictationLanguageCatalog.normalize(code: message.outputLanguage) {
            currentSessionMetadata.outputLanguageCode = outputLanguage
        }
        if let didTranslate = message.didTranslate {
            currentSessionMetadata.didTranslate = didTranslate
        }
        if let providerRoute = message.providerRoute {
            currentSessionMetadata.providerRouteRawValue = providerRoute
        }
    }

    private func resolvedTransportMetadata() -> DictationTransportMetadata {
        let requestedSourceMode =
            currentSessionMetadata.requestedSourceLanguageModeRawValue
            ?? currentRequestedSourceLanguageModeSnapshot.rawValue
        let requestedSourceLanguageCode =
            currentSessionMetadata.requestedSourceLanguageCode
            ?? currentRequestedSourceLanguageCodeSnapshot
        let resolvedSourceLanguageCode =
            currentSessionMetadata.resolvedSourceLanguageCode
            ?? requestedSourceLanguageCode
        let outputLanguageCode =
            currentSessionMetadata.outputLanguageCode
            ?? DictationLanguageCatalog.resolvedOutputLanguageCode(
                outputMode: currentOutputLanguageModeSnapshot,
                explicitOutputLanguageCode: currentExplicitOutputLanguageCodeSnapshot,
                sourceMode: currentRequestedSourceLanguageModeSnapshot,
                explicitSourceLanguageCode: currentRequestedSourceLanguageCodeSnapshot ?? DictationLanguageCatalog.defaultExplicitSourceLanguageCode,
                resolvedSourceLanguageCode: resolvedSourceLanguageCode
            )
        let didTranslate =
            currentSessionMetadata.didTranslate
            ?? {
                guard let outputLanguageCode else { return false }
                guard let resolvedSourceLanguageCode else { return false }
                return outputLanguageCode != resolvedSourceLanguageCode
            }()
        let providerRouteRawValue =
            currentSessionMetadata.providerRouteRawValue
            ?? (currentDeliveryMode == .liveProvisional
                ? DictationProviderRoute.deepgramLive.rawValue
                : DictationProviderRoute.groqWhisperBuffered.rawValue)

        return DictationTransportMetadata(
            requestedSourceLanguageModeRawValue: requestedSourceMode,
            requestedSourceLanguageCode: requestedSourceLanguageCode,
            resolvedSourceLanguageCode: resolvedSourceLanguageCode,
            outputLanguageCode: outputLanguageCode,
            didTranslate: didTranslate,
            providerRouteRawValue: providerRouteRawValue
        )
    }

    private func applyFinal(_ text: String, rawText: String?, isCanonical: Bool) {
        let rawTranscript = (rawText ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
        if isCanonical {
            finalizeCanonicalOutput(finalText: text, rawText: rawTranscript)
            return
        }

        pendingRawFinalText = rawTranscript
        let snapshot = transcriptAssembler.applyFinal(text)
        liveText = snapshot.bestText
        updateLatencyIfNeeded()
    }

    private func applyCanonicalResult(original rawText: String, corrected finalText: String) {
        finalizeCanonicalOutput(finalText: finalText, rawText: rawText)
    }

    private func finalizeCanonicalOutput(finalText: String, rawText: String) {
        guard !didEmitCanonicalResult else { return }
        cancelFinalizationWatchdog()

        let resolvedRawText = rawText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ? pendingRawFinalText : rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeRawText = pendingRawFinalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !activeRawText.isEmpty {
            guard normalizedTranscriptKey(resolvedRawText) == normalizedTranscriptKey(activeRawText) else {
                return
            }
        }

        let canonicalText = HistoryVocabularyLearner.restoreCasing(
            finalText.trimmingCharacters(in: .whitespacesAndNewlines),
            terms: configuration.learnedVocabulary
        )
        guard !canonicalText.isEmpty else { return }

        let transportMetadata = resolvedTransportMetadata()

        pendingRawFinalText = resolvedRawText
        liveText = canonicalText
        lastFinalText = canonicalText
        lastFinalOutput = DictationOutputPayload(
            sessionID: currentFinalizationSessionID,
            text: canonicalText,
            isCanonical: true,
            metadata: transportMetadata
        )
        // No separate clipboard write: the injector manages the pasteboard itself
        // (concealed + restored for ⌘V, untouched for direct AX insertion). Writing
        // partials/finals here logged every few words into clipboard managers and
        // replaced the user's clipboard.
        injectMacTextIfNeeded(canonicalText)

        // Transform ("revise selected text by voice") sessions are not dictation
        // content — skip persisting them to history, and don't let this session's
        // mode leak into the next shortcut press.
        if currentSessionMode == .dictation {
            emitFinalizedRecord(
                for: canonicalText,
                rawText: resolvedRawText,
                stage: .canonicalCleaned,
                metadata: transportMetadata
            )
        }
        currentSessionMode = .dictation
        didEmitCanonicalResult = true
        processingStartedAt = nil
        websocketClient.markStreamingSessionCompleted()
        status = DictationStatusReducer.reduce(from: status, event: .finalTextReceived)
        updateLatencyIfNeeded()
        applyPendingConnectionRefreshIfNeeded()
    }

    private func updateLatencyIfNeeded() {
        if firstResponseTimestampMs == nil {
            firstResponseTimestampMs = nowInMs()
            lastLatencyMs = Int((firstResponseTimestampMs ?? 0) - currentSessionStartTimeMs)
        }
    }

    private func nowInMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private func emitFinalizedRecord(
        for finalText: String,
        rawText: String,
        stage: DictationFinalizedRecord.Stage,
        metadata: DictationTransportMetadata
    ) {
        guard !finalText.isEmpty else { return }
        let duration = max(lastAudioDurationSeconds, 0.1)
        let wordCount = countWords(in: finalText)
        let wordsPerMinute = duration > 0 ? (Double(wordCount) / duration) * 60 : 0
        onFinalizedDictation?(
            DictationFinalizedRecord(
                sessionID: currentFinalizationSessionID,
                stage: stage,
                timestamp: Date(),
                finalText: finalText,
                rawText: rawText,
                outputPresetRawValue: currentOutputPresetSnapshot.rawValue,
                audioDuration: duration,
                wordCount: wordCount,
                wordsPerMinute: wordsPerMinute,
                requestedSourceLanguageModeRawValue: metadata.requestedSourceLanguageModeRawValue,
                requestedSourceLanguageCode: metadata.requestedSourceLanguageCode,
                resolvedSourceLanguageCode: metadata.resolvedSourceLanguageCode,
                outputLanguageCode: metadata.outputLanguageCode,
                didTranslate: metadata.didTranslate,
                providerRouteRawValue: metadata.providerRouteRawValue
            )
        )
    }

    /// Persist the best available raw/partial transcript when a session gives up before
    /// producing canonical text, so the user's words are never lost. No-ops when the session
    /// already emitted a canonical result or when there is genuinely no captured text.
    private func persistFailedSessionTranscriptIfNeeded() {
        guard !didEmitCanonicalResult else { return }
        let rawFallback = pendingRawFinalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let liveFallback = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
        let recoveredText = rawFallback.isEmpty ? liveFallback : rawFallback
        guard !recoveredText.isEmpty else { return }

        didEmitCanonicalResult = true
        // Same history-skip rule as the success path: a failed transform session
        // shouldn't get saved to history as a garbled "recovered" dictation.
        if currentSessionMode == .dictation {
            emitFinalizedRecord(
                for: recoveredText,
                rawText: recoveredText,
                stage: .failedRawFallback,
                metadata: resolvedTransportMetadata()
            )
        }
        currentSessionMode = .dictation
    }

    private func countWords(in text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    private func normalizedTranscriptKey(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func attemptLiveSessionRecovery() {
        guard didObserveSessionAudioChunk else {
            abortSilentSessionAndRearm()
            return
        }
        guard liveSessionRecoveryAttempts < maxLiveSessionRecoveryAttempts else {
            recoverFromStalledFinalization(message: "Dictation connection dropped repeatedly. Please retry.")
            return
        }

        liveSessionRecoveryAttempts += 1
        isRecoveringLiveSession = true
        suppressInboundMessagesUntilNextSessionStart = false
        lastNotice = DictationNotice(
            id: UUID().uuidString,
            text: "Dictation connection dropped. Reconnecting..."
        )
        websocketClient.prepareForSessionRecovery()
        websocketClient.send(buildSessionStartMessage())
    }

    private func handleFailure(_ message: String) {
        cancelFinalizationWatchdog()
        errorIsTransportRelated = false
        if isNoSpeechError(message) {
            gracefulStopTask?.cancel()
            gracefulStopTask = nil
            resetSpeechActivity()
            audioCaptureService.stopCapturing()
            activeDictationStartDate = nil
            lastAudioDurationSeconds = 0
            resetMacInjectionState()
            suppressInboundMessagesUntilNextSessionStart = false
            transcriptAssembler.reset()
            liveText = ""
            lastFinalText = ""
            lastFinalOutput = nil
            pendingRawFinalText = ""
            didEmitCanonicalResult = false
            processingStartedAt = nil
            liveInputLevel = 0
            websocketClient.markStreamingSessionCompleted()
            status = DictationStatusReducer.reduce(from: status, event: .noSpeechDetected)
            lastNotice = nil
            applyPendingConnectionRefreshIfNeeded()
            return
        }

        if status == .listening && !isRecoveringLiveSession {
            attemptLiveSessionRecovery()
            return
        }

        suppressInboundMessagesUntilNextSessionStart = false
        resetSpeechActivity()
        // Stop capture so a server error mid-listening can't leave the mic hot and chunks
        // streaming, mirroring the transport-failure path (H-15).
        gracefulStopTask?.cancel()
        gracefulStopTask = nil
        audioCaptureService.stopCapturing()
        persistFailedSessionTranscriptIfNeeded()
        activeDictationStartDate = nil
        processingStartedAt = nil
        liveInputLevel = 0
        websocketClient.markStreamingSessionCompleted()
        status = DictationStatusReducer.reduce(from: status, event: .failure(message))
        applyPendingConnectionRefreshIfNeeded()
    }

    private func isNoSpeechError(_ message: String) -> Bool {
        let normalizedMessage = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedMessage.isEmpty else { return false }

        let backendURL = configuration.backendURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matchesDeepgramEmptyTranscript = backendURL.contains("deepgram")
            && normalizedMessage.contains("empty transcript")

        return matchesDeepgramEmptyTranscript
            || normalizedMessage.contains("empty transcript")
            || normalizedMessage.contains("no speech detected")
            || normalizedMessage.contains("received no audio")
    }

    private func shouldSuppressInboundMessage(_ message: ServerMessage) -> Bool {
        guard suppressInboundMessagesUntilNextSessionStart else { return false }
        switch message.type {
        case .sessionStarted, .partialText, .finalText, .transcriptCorrection, .notice, .error:
            return true
        case .pong:
            return false
        }
    }

    private func abortSilentSessionAndRearm() {
        gracefulStopTask?.cancel()
        gracefulStopTask = nil
        cancelFinalizationWatchdog()
        resetSpeechActivity()
        resetMacInjectionState()
        suppressInboundMessagesUntilNextSessionStart = true
        audioCaptureService.stopCapturing()
        activeDictationStartDate = nil
        lastAudioDurationSeconds = 0
        transcriptAssembler.reset()
        liveText = ""
        lastFinalText = ""
        lastFinalOutput = nil
        lastNotice = nil
        pendingRawFinalText = ""
        didEmitCanonicalResult = false
        processingStartedAt = nil
        liveInputLevel = 0
        isRecoveringLiveSession = false
        liveSessionRecoveryAttempts = 0
        websocketClient.markStreamingSessionCompleted()
        websocketClient.disconnect()
        connectionState = .disconnected
        status = .idle
        reconnectAfterResetIfNeeded()
    }

    private func scheduleFinalizationWatchdog() {
        finalizationWatchdogTask?.cancel()
        finalizationWatchdogTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: finalizationWatchdogDelayNs)
            guard !Task.isCancelled else { return }
            guard case .processing = status else {
                cancelFinalizationWatchdog()
                return
            }

            recoverFromStalledFinalization(
                message: "Finalization timed out. Please try dictating again."
            )
        }
    }

    private func cancelFinalizationWatchdog() {
        finalizationWatchdogTask?.cancel()
        finalizationWatchdogTask = nil
    }

    private func recoverFromStalledFinalization(message: String) {
        gracefulStopTask?.cancel()
        gracefulStopTask = nil
        cancelFinalizationWatchdog()
        resetSpeechActivity()
        resetMacInjectionState()
        suppressInboundMessagesUntilNextSessionStart = false
        audioCaptureService.stopCapturing()
        persistFailedSessionTranscriptIfNeeded()
        activeDictationStartDate = nil
        lastAudioDurationSeconds = 0
        transcriptAssembler.reset()
        liveText = ""
        lastFinalOutput = nil
        pendingRawFinalText = ""
        didEmitCanonicalResult = false
        processingStartedAt = nil
        websocketClient.markStreamingSessionCompleted()
        websocketClient.disconnect()
        connectionState = .disconnected
        status = .error(message)
        lastNotice = DictationNotice(id: UUID().uuidString, text: message)
        reconnectAfterResetIfNeeded()
    }

    private func injectMacTextIfNeeded(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !didInjectTextForCurrentSession, !trimmedText.isEmpty else { return }

        textInjector.inject(text: trimmedText)
        didInjectTextForCurrentSession = true
    }

    private func resetMacInjectionState() {
        didInjectTextForCurrentSession = false
    }
}

extension DictationCoordinator: RealtimeWebSocketClientDelegate {
    nonisolated func websocketClient(_ client: RealtimeWebSocketClient, didUpdate state: RealtimeConnectionState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.connectionState = state
            // A connection error is resolved once we're connected again; leaving it up
            // would report a problem that no longer exists.
            if state == .connected, self.errorIsTransportRelated, case .error = self.status {
                self.errorIsTransportRelated = false
                self.status = DictationStatusReducer.reduce(from: self.status, event: .reset)
            }
        }
    }

    nonisolated func websocketClient(_ client: RealtimeWebSocketClient, didReceive message: ServerMessage) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard !shouldSuppressInboundMessage(message) else { return }
            switch message.type {
            case .sessionStarted:
                ingestServerMetadata(from: message)
                isRecoveringLiveSession = false
                liveSessionRecoveryAttempts = 0
            case .partialText:
                if let text = message.text {
                    applyPartial(text)
                }
            case .finalText:
                ingestServerMetadata(from: message)
                if let text = message.text {
                    applyFinal(text, rawText: message.rawText, isCanonical: message.isCanonical ?? false)
                } else {
                    websocketClient.markStreamingSessionCompleted()
                    status = DictationStatusReducer.reduce(from: status, event: .finalTextReceived)
                    applyPendingConnectionRefreshIfNeeded()
                }
            case .transcriptCorrection:
                ingestServerMetadata(from: message)
                if let original = message.original, let corrected = message.corrected {
                    applyCanonicalResult(original: original, corrected: corrected)
                }
            case .notice:
                if let messageText = message.message?.trimmingCharacters(in: .whitespacesAndNewlines), !messageText.isEmpty {
                    lastNotice = DictationNotice(id: UUID().uuidString, text: messageText)
                }
            case .error:
                let errorMessage = message.message ?? "Unknown backend error."
                // An error while nothing is being dictated (e.g. the warm connection being
                // rejected) is connection housekeeping, not a failed dictation.
                guard DictationTransportFailurePolicy.shouldSurfaceAsDictationError(
                    status: status,
                    isCapturing: audioCaptureService.isCapturing,
                    streamingSessionState: websocketClient.latestDiagnosticSnapshot().streamingSessionState
                ) else {
                    print("[dictation] backend error while idle (not surfaced): \(errorMessage)")
                    return
                }
                handleFailure(errorMessage)
            case .pong:
                break
            }
        }
    }

    nonisolated func websocketClientDidRejectAuthorization(_ client: RealtimeWebSocketClient) {
        Task { @MainActor [weak self] in
            self?.onAuthorizationRejected?()
        }
    }

    nonisolated func websocketClient(_ client: RealtimeWebSocketClient, didFail error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let diagnosticSnapshot = client.latestDiagnosticSnapshot()
            print(
                "[dictation] websocket failure " +
                "error=\(error.localizedDescription) " +
                "connection_state=\(diagnosticSnapshot.connectionState) " +
                "streaming_state=\(diagnosticSnapshot.streamingSessionState) " +
                "connection_id=\(diagnosticSnapshot.currentConnectionID ?? "nil") " +
                "client_session_id=\(diagnosticSnapshot.currentClientSessionID ?? "nil") " +
                "awaiting_ack=\(diagnosticSnapshot.awaitingSessionStartAcknowledgement) " +
                "pending_transport=\(diagnosticSnapshot.pendingTransportMessageCount) " +
                "pending_streaming=\(diagnosticSnapshot.pendingStreamingMessageCount) " +
                "drop_until_next_start=\(diagnosticSnapshot.dropStreamingMessagesUntilNextSessionStart) " +
                "close_code=\(diagnosticSnapshot.lastCloseCode.map(String.init) ?? "nil") " +
                "close_reason=\(diagnosticSnapshot.lastCloseReason ?? "nil") " +
                "capture_running=\(audioCaptureService.isCapturing) " +
                "engine_running=\(audioCaptureService.isEngineRunning) " +
                "pending_connection_refresh=\(hasPendingConnectionRefresh)"
            )
            if status == .listening && didObserveSessionAudioChunk && !isRecoveringLiveSession {
                gracefulStopTask?.cancel()
                gracefulStopTask = nil
                attemptLiveSessionRecovery()
                return
            }
            gracefulStopTask?.cancel()
            gracefulStopTask = nil
            guard DictationTransportFailurePolicy.shouldSurfaceAsDictationError(
                status: status,
                isCapturing: audioCaptureService.isCapturing,
                streamingSessionState: diagnosticSnapshot.streamingSessionState
            ) else {
                websocketClient.markStreamingSessionCompleted()
                applyPendingConnectionRefreshIfNeeded()
                return
            }
            audioCaptureService.stopCapturing()
            activeDictationStartDate = nil
            handleFailure("Lost connection to the Kleio server. Try again in a moment.")
            // Cleared automatically once the connection is back (see didUpdate).
            errorIsTransportRelated = true
        }
    }
}
