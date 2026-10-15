import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// The outcome of a completed transcription, ready to be persisted into dictation history via
/// `AppModel.persistImportedAudioEntry`. Never injected into any app — import is history-only.
struct AudioImportResult {
    let finalText: String
    let rawText: String?
    let audioDuration: TimeInterval
    let wordCount: Int
    let sourceLabel: String
}

enum AudioImportOutcome {
    case success(AudioImportResult)
    case cancelled
    case failure(Error)
}

enum AudioImportError: LocalizedError {
    case unreadableFile
    case emptyAudio
    case fileTooLarge
    case conversionFailed
    case noTranscript
    case timedOut
    case authorizationRejected
    case server(String)

    var errorDescription: String? {
        switch self {
        case .unreadableFile:
            return "Kleio couldn't open that audio file."
        case .emptyAudio:
            return "That audio file doesn't contain any audio to transcribe."
        case .fileTooLarge:
            return "That audio file is too long to import."
        case .conversionFailed:
            return "Kleio couldn't prepare that audio file for transcription."
        case .noTranscript:
            return "Kleio didn't receive a transcript for that audio."
        case .timedOut:
            return "Transcribing that audio took too long and timed out."
        case .authorizationRejected:
            return "Kleio's sign-in expired. Sign in again and retry the import."
        case .server(let message):
            return message
        }
    }
}

/// Lets the user pick an audio file, transcribes it through an isolated websocket session (its
/// own `RealtimeWebSocketClient`, never the shared one `DictationCoordinator` owns), and hands
/// back a result for history only. This never touches `TextInjector` — imported audio is never
/// pasted/typed into any app.
@MainActor
final class AudioImportService {
    // `AudioImportService()` is constructed ad hoc at the call site with nothing else holding a
    // reference to it (see MacAnalyticsWindowView's "Import Audio" action), so this registry is
    // what keeps `self` alive for the life of the NSOpenPanel + websocket round trip. Entries are
    // removed the moment `finish` fires, so nothing leaks once an import completes.
    private static var retainedInstances: [ObjectIdentifier: AudioImportService] = [:]

    private var completion: ((AudioImportOutcome) -> Void)?
    private var activeSession: AudioImportTranscriptionSession?

    private static let chunkFrameCount = 4096 // ~256ms of 16kHz mono audio per audio_chunk message.
    // Read from the nonisolated decode path (decodeAndResample runs off the main actor), so this
    // must opt out of the class's default MainActor isolation too.
    nonisolated private static let importOutputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )

    func presentAndImport(completion: @escaping (AudioImportOutcome) -> Void) {
        self.completion = completion
        Self.retainedInstances[ObjectIdentifier(self)] = self

        let panel = NSOpenPanel()
        panel.title = "Import Audio"
        panel.message = "Choose an audio file to transcribe into your dictation history."
        panel.prompt = "Import"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio, .mp3, .wav, .aiff, .mpeg4Audio]

        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                self.finish(.cancelled)
                return
            }
            self.beginImport(for: url)
        }
    }

    private func beginImport(for url: URL) {
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let decoded = try Self.decodeAndResample(fileURL: url)
                await self?.startTranscription(decoded: decoded, sourceURL: url)
            } catch {
                await self?.finish(.failure(error))
            }
        }
    }

    private func startTranscription(decoded: DecodedAudio, sourceURL: URL) {
        let sourceLabel = sourceURL.deletingPathExtension().lastPathComponent
        let clientSessionID = UUID().uuidString
        let sessionStartMessage = Self.buildSessionStartMessage(sampleRate: decoded.sampleRate, clientSessionID: clientSessionID)
        let pcmChunks = Self.chunk(decoded.pcmData, frameCount: Self.chunkFrameCount)
        let backendURLString = AppConfiguration.shared.backendURL
        let authToken = AppConfiguration.shared.authToken

        let session = AudioImportTranscriptionSession(
            clientSessionID: clientSessionID,
            audioDuration: decoded.duration,
            sourceLabel: sourceLabel,
            completion: { [weak self] outcome in
                // The session runs its network I/O off-main; hop back to MainActor here so the
                // caller can safely update @State from the completion handler.
                Task { @MainActor in
                    self?.finish(outcome)
                }
            }
        )
        activeSession = session
        session.start(
            sessionStartMessage: sessionStartMessage,
            pcmChunks: pcmChunks,
            backendURLString: backendURLString,
            authToken: authToken
        )
    }

    private func finish(_ outcome: AudioImportOutcome) {
        guard let completion else { return }
        self.completion = nil
        activeSession = nil
        Self.retainedInstances[ObjectIdentifier(self)] = nil
        completion(outcome)
    }

    // Mirrors DictationCoordinator.buildSessionStartMessage() (Core/Dictation/DictationCoordinator.swift
    // ~L254 and its per-session snapshot assignment ~L459) so an import respects the user's current
    // output preset, cleanup model, and language settings exactly like a live dictation would.
    private static func buildSessionStartMessage(sampleRate: Int, clientSessionID: String) -> ClientMessage {
        let configuration = AppConfiguration.shared
        let prompt = DictationPrompt.prompt(for: configuration.outputPreset)
        let appVersion =
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            ?? "0"
        let requestedSourceLanguageCode = configuration.sourceLanguageMode == .explicit
            ? DictationLanguageCatalog.normalize(code: configuration.sourceLanguageCode)
            : nil
        let explicitOutputLanguageCode =
            DictationLanguageCatalog.normalize(code: configuration.outputLanguageCode)
            ?? DictationLanguageCatalog.defaultExplicitOutputLanguageCode

        return ClientMessage.sessionStart(
            prompt: prompt,
            promptProfile: configuration.outputPreset.serverProfileKey,
            cleanupModel: configuration.cleanupModel.rawValue,
            sourceLanguageMode: configuration.sourceLanguageMode.rawValue,
            sourceLanguage: requestedSourceLanguageCode,
            outputLanguage: configuration.outputLanguageMode == .matchSource
                ? DictationOutputLanguageMode.matchSource.rawValue
                : explicitOutputLanguageCode,
            sampleRate: sampleRate,
            customVocabulary: configuration.customVocabulary,
            privacyModeEnabled: configuration.privacyModeEnabled,
            improvementSharingEnabled: configuration.improvementSharingEnabled,
            clientAppVersion: appVersion,
            clientLocale: Locale.current.identifier,
            clientPlatform: "macos",
            clientSessionID: clientSessionID
        )
    }

    private struct DecodedAudio {
        let pcmData: Data
        let duration: TimeInterval
        let sampleRate: Int
    }

    // Runs off the main actor (invoked from a detached Task) — file I/O and audio conversion for
    // an arbitrary-length file shouldn't block the UI.
    nonisolated private static func decodeAndResample(fileURL: URL) throws -> DecodedAudio {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: fileURL)
        } catch {
            throw AudioImportError.unreadableFile
        }

        let inputFormat = file.processingFormat
        let frameCount = file.length
        guard frameCount > 0, inputFormat.sampleRate > 0 else {
            throw AudioImportError.emptyAudio
        }
        guard frameCount <= Int64(UInt32.max) else {
            throw AudioImportError.fileTooLarge
        }
        let duration = Double(frameCount) / inputFormat.sampleRate

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            throw AudioImportError.conversionFailed
        }
        do {
            try file.read(into: inputBuffer)
        } catch {
            throw AudioImportError.unreadableFile
        }
        guard inputBuffer.frameLength > 0 else {
            throw AudioImportError.emptyAudio
        }

        guard let outputFormat = importOutputFormat else {
            throw AudioImportError.conversionFailed
        }
        let pcmData = try convert(inputBuffer: inputBuffer, inputFormat: inputFormat, to: outputFormat)
        guard !pcmData.isEmpty else {
            throw AudioImportError.emptyAudio
        }

        return DecodedAudio(pcmData: pcmData, duration: duration, sampleRate: Int(outputFormat.sampleRate))
    }

    // Adapts AudioCaptureService.convert(buffer:with:to:) (Core/Dictation/AudioCaptureService.swift
    // ~L589) for a whole-file one-shot buffer instead of a small live tap buffer: that live version
    // pulls its converter's input block exactly once because a small ~1024-frame tap buffer always
    // fits the output capacity it computes in one pass. A decoded file buffer can be many seconds
    // long, so here we drain the converter in a loop instead of assuming a single call empties it.
    nonisolated private static func convert(
        inputBuffer: AVAudioPCMBuffer,
        inputFormat: AVAudioFormat,
        to outputFormat: AVAudioFormat
    ) throws -> Data {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioImportError.conversionFailed
        }

        var outputData = Data()
        var suppliedInput = false

        while true {
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 65_536) else {
                throw AudioImportError.conversionFailed
            }
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                if suppliedInput {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                suppliedInput = true
                outStatus.pointee = .haveData
                return inputBuffer
            }

            if let conversionError {
                throw conversionError
            }

            switch status {
            case .haveData:
                guard outputBuffer.frameLength > 0, let pointer = outputBuffer.int16ChannelData?.pointee else {
                    return outputData
                }
                let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
                outputData.append(Data(bytes: pointer, count: byteCount))
            case .inputRanDry, .endOfStream:
                return outputData
            case .error:
                throw conversionError ?? AudioImportError.conversionFailed
            @unknown default:
                return outputData
            }
        }
    }

    nonisolated private static func chunk(_ data: Data, frameCount: Int) -> [Data] {
        let byteSize = frameCount * MemoryLayout<Int16>.size // mono Int16 PCM
        guard byteSize > 0, !data.isEmpty else { return [] }
        var chunks: [Data] = []
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: byteSize, limitedBy: data.endIndex) ?? data.endIndex
            chunks.append(data.subdata(in: offset..<end))
            offset = end
        }
        return chunks
    }
}

/// Owns one isolated, one-shot `RealtimeWebSocketClient` for a single buffered transcription —
/// never the shared client `DictationCoordinator` drives, so an import can never corrupt or steal
/// an in-progress live dictation. Plain class + lock (not an actor/MainActor type) to mirror
/// RealtimeWebSocketClient's and AudioCaptureService's own concurrency style in this codebase:
/// `RealtimeWebSocketClient` already serializes its delegate callbacks on its own `stateQueue`, so
/// this only needs to guard the handful of fields it also mutates from its own timer queue.
private final class AudioImportTranscriptionSession: NSObject, RealtimeWebSocketClientDelegate {
    private let websocketClient = RealtimeWebSocketClient()
    private let clientSessionID: String
    private let audioDuration: TimeInterval
    private let sourceLabel: String
    private let completion: (AudioImportOutcome) -> Void

    private let stateLock = NSLock()
    private var didFinish = false
    private var pendingRawText: String?
    private var canonicalFallbackWorkItem: DispatchWorkItem?
    private var overallTimeoutWorkItem: DispatchWorkItem?
    private let timerQueue = DispatchQueue(label: "audio-import.session.timers")

    // The live path streams partials as they arrive; a buffered import has no such signal, so
    // give the backend a bounded grace window after a raw (non-canonical) final to still produce
    // the cleaned/canonical version before falling back to the raw transcript for both fields.
    private let canonicalFallbackDelay: TimeInterval = 8
    private let overallTimeout: TimeInterval = 60

    init(
        clientSessionID: String,
        audioDuration: TimeInterval,
        sourceLabel: String,
        completion: @escaping (AudioImportOutcome) -> Void
    ) {
        self.clientSessionID = clientSessionID
        self.audioDuration = audioDuration
        self.sourceLabel = sourceLabel
        self.completion = completion
        super.init()
        websocketClient.delegate = self
    }

    func start(sessionStartMessage: ClientMessage, pcmChunks: [Data], backendURLString: String, authToken: String) {
        do {
            try websocketClient.configure(backendURLString: backendURLString, authToken: authToken)
        } catch {
            finish(.failure(error))
            return
        }

        websocketClient.connectIfNeeded()
        websocketClient.send(sessionStartMessage)
        // No realtime pacing needed — this is a buffered/offline transcription, so chunks go out
        // back-to-back. RealtimeWebSocketClient itself buffers audio_chunk/session_end messages
        // until the server acknowledges session_start, preserving order.
        for chunk in pcmChunks {
            websocketClient.send(.audioChunk(data: chunk.base64EncodedString(), clientSessionID: clientSessionID))
        }
        websocketClient.send(.sessionEnd(clientSessionID: clientSessionID))

        scheduleOverallTimeout()
    }

    // MARK: - RealtimeWebSocketClientDelegate

    func websocketClient(_ client: RealtimeWebSocketClient, didUpdate state: RealtimeConnectionState) {
        // Import has no live UI to reflect connection state into; no-op.
    }

    func websocketClient(_ client: RealtimeWebSocketClient, didReceive message: ServerMessage) {
        switch message.type {
        case .finalText:
            handleFinalText(text: message.text, rawText: message.rawText, isCanonical: message.isCanonical ?? false)
        case .transcriptCorrection:
            guard let original = message.original, let corrected = message.corrected else { return }
            let trimmedCorrected = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedCorrected.isEmpty else { return }
            finish(.success(makeResult(finalText: trimmedCorrected, rawText: original)))
        case .error:
            finish(.failure(AudioImportError.server(message.message ?? "The transcription service reported an error.")))
        case .sessionStarted, .partialText, .notice, .pong:
            break
        }
    }

    func websocketClient(_ client: RealtimeWebSocketClient, didFail error: Error) {
        finish(.failure(error))
    }

    func websocketClientDidRejectAuthorization(_ client: RealtimeWebSocketClient) {
        finish(.failure(AudioImportError.authorizationRejected))
    }

    // MARK: - Message handling

    private func handleFinalText(text: String?, rawText: String?, isCanonical: Bool) {
        let trimmedText = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedText, !trimmedText.isEmpty else {
            // A finalText frame with no text is an end-of-stream marker in the live protocol. If
            // we already captured a raw transcript, that's the best we'll get — use it for both
            // fields per the fallback rule (no distinct raw field available). Otherwise there's
            // genuinely nothing to import.
            if let fallback = stateLock.withLock({ pendingRawText }), !fallback.isEmpty {
                finish(.success(makeResult(finalText: fallback, rawText: fallback)))
            } else {
                finish(.failure(AudioImportError.noTranscript))
            }
            return
        }

        if isCanonical {
            let trimmedRaw = rawText?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackRaw = stateLock.withLock { pendingRawText }
            let resolvedRaw = (trimmedRaw?.isEmpty == false ? trimmedRaw : nil) ?? fallbackRaw ?? trimmedText
            finish(.success(makeResult(finalText: trimmedText, rawText: resolvedRaw)))
        } else {
            stateLock.withLock { pendingRawText = rawText ?? trimmedText }
            scheduleCanonicalFallback()
        }
    }

    private func scheduleCanonicalFallback() {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard let fallback = self.stateLock.withLock({ self.pendingRawText }), !fallback.isEmpty else { return }
            self.finish(.success(self.makeResult(finalText: fallback, rawText: fallback)))
        }
        stateLock.withLock {
            canonicalFallbackWorkItem?.cancel()
            canonicalFallbackWorkItem = workItem
        }
        timerQueue.asyncAfter(deadline: .now() + canonicalFallbackDelay, execute: workItem)
    }

    private func scheduleOverallTimeout() {
        let workItem = DispatchWorkItem { [weak self] in
            self?.finish(.failure(AudioImportError.timedOut))
        }
        stateLock.withLock { overallTimeoutWorkItem = workItem }
        timerQueue.asyncAfter(deadline: .now() + overallTimeout, execute: workItem)
    }

    private func makeResult(finalText: String, rawText: String?) -> AudioImportResult {
        let cleanedFinal = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedRaw = rawText?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AudioImportResult(
            finalText: cleanedFinal,
            rawText: (cleanedRaw?.isEmpty == false) ? cleanedRaw : nil,
            audioDuration: audioDuration,
            wordCount: Self.countWords(in: cleanedFinal),
            sourceLabel: sourceLabel
        )
    }

    // Mirrors DictationCoordinator.countWords(in:) (Core/Dictation/DictationCoordinator.swift ~L776)
    // so imported word counts (and the derived words-per-minute in AppModel.persistImportedAudioEntry)
    // use the exact same convention as live dictation history entries.
    private static func countWords(in text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    private func finish(_ outcome: AudioImportOutcome) {
        let shouldProceed = stateLock.withLock { () -> Bool in
            guard !didFinish else { return false }
            didFinish = true
            return true
        }
        guard shouldProceed else { return }

        let (timeoutItem, fallbackItem) = stateLock.withLock { (overallTimeoutWorkItem, canonicalFallbackWorkItem) }
        timeoutItem?.cancel()
        fallbackItem?.cancel()

        websocketClient.markStreamingSessionCompleted()
        websocketClient.disconnect()

        completion(outcome)
    }
}
