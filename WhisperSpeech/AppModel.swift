import Combine
import Foundation
import SwiftData
import os
import AppKit


private struct DictationPersistencePayload {
    let record: DictationFinalizedRecord
    let sourceBundleIdentifier: String?
    let sourceAppName: String?
    let sourceAppIcon: NSImage?
}

@MainActor
final class AppModel: ObservableObject {
    private static let logger = Logger(subsystem: "com.eclipsestudio.kleio", category: "app-model")
    var configuration: AppConfiguration
    let coordinator: DictationCoordinator
    let sessionManager: SessionManager
    @Published private(set) var accessibilityPermissionGranted = true
    private let historyModelContext: ModelContext?
    private let dictionaryStore: DictionaryStore?

    @Published private(set) var hotkeyActive = true
    private let hotkeyManager: HotkeyManager
    private let macTextInjector: TextInjector
    private let permissionService = AccessibilityPermissionService()
    private let dictationSoundEffectService = MacDictationSoundEffectService()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var defaultCenterObservers: [NSObjectProtocol] = []
    private var dictationPillController: MacDictationPillController?
    private var lastReconnectProbeAt = Date.distantPast
    private var pendingMacDeactivationSoundWorkItem: DispatchWorkItem?
    private var hasActiveListeningSession = false
    private var lastObservedDictationStatus: DictationStatus = .idle
    private var appDidFinishLaunchingObserver: NSObjectProtocol?
    private var hasFinishedLaunchingApp = false
    private var pendingInitialAppVisibilityMode: AppVisibilityMode?

    private var cancellables = Set<AnyCancellable>()
    private var learnedVocabularyWorkItem: DispatchWorkItem?
    private var terminationObserver: NSObjectProtocol?
    private var pendingPersistencePayloads: [DictationPersistencePayload] = []
    private var pendingPersistenceDrainWorkItem: DispatchWorkItem?
    private var consecutivePersistFailures = 0
    // Keep history persistence outside the processing-to-idle pill shrink window.
    private let macPersistenceDeferral: TimeInterval = 0.52

    init(
        configuration: AppConfiguration,
        sessionManager: SessionManager,
        modelContainer: ModelContainer? = nil
    ) {
        self.configuration = configuration
        self.sessionManager = sessionManager
        self.historyModelContext = modelContainer?.mainContext
        self.dictionaryStore = modelContainer.map {
            DictionaryStore(
                modelContext: $0.mainContext,
                configuration: configuration,
                localOnlyProfileID: sessionManager.localOnlyProfileID
            )
        }

        let websocketClient = RealtimeWebSocketClient()
        let audioCaptureService = AudioCaptureService()
        let textInjector = TextInjector(permissionService: permissionService)
        self.macTextInjector = textInjector
        self.coordinator = DictationCoordinator(
            configuration: configuration,
            websocketClient: websocketClient,
            audioCaptureService: audioCaptureService,
            textInjector: textInjector
        )
        self.hotkeyManager = HotkeyManager(shortcut: configuration.keyboardShortcut)

        coordinator.onFinalizedDictation = { [weak self] record in
            self?.enqueuePersistence(record: record)
        }
        coordinator.onAuthorizationRejected = { [weak self] in
            self?.refreshBackendAuthTokenAfterAuthorizationRejection()
        }
        dictionaryStore?.bootstrap()
        dictionaryStore?.currentOwnerProfileID = sessionManager.currentOwnerProfileID
        if let dictionaryStore {
            sessionManager.attach(dictionaryStore: dictionaryStore)
        }
        sessionManager.clearLocalHistoryHandler = { [weak self] ownerProfileID in
            self?.clearLocalHistory(for: ownerProfileID)
        }
        coordinator.customVocabularyProvider = { [weak self] in
            guard let self else { return [] }
            let manual = self.dictionaryStore?.activeVocabularyPayload(limit: 200) ?? self.configuration.customVocabulary
            return Self.mergedVocabulary(manual: manual, learned: self.configuration.learnedVocabulary)
        }
        coordinator.dictationPromptAppendixProvider = { [weak self] in
            self?.dictionaryStore?.cleanupPromptAppendix(limit: 40)
        }
        bindConfiguration()
        bindSessionState()
        installTerminationPersistenceFlushHook()
        migrateLegacyHistoryScopeIfNeeded()
        bindMacDictationSoundEffects()
    }

    func start() {
        #if DEBUG
        DictationCoreSelfTests.runIfNeeded()
        HistoryVocabularyLearner.runSelfTests()
        MacPlatformSelfTests.runIfNeeded()
        #endif
        sessionManager.start()
        enforceHistoryRetention()
        scheduleLearnedVocabularyRefresh()
        // Ages entries past the window as days roll over, even with the app left open.
        NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.enforceHistoryRetention() }
        }
        scheduleInitialMacAppVisibilityModeApplication()
        coordinator.warmConnection()
        hotkeyManager.onPressBegan = { [weak self] in
            Task { @MainActor [weak self] in
                // Overlap connection/token warm-up with the hold-vs-tap window.
                self?.coordinator.warmConnection()
            }
        }
        hotkeyManager.onStartDictation = { [weak self] in
            Task { @MainActor [weak self] in
                self?.startMacDictation()
                self?.syncMacHotkeyStateWithCoordinator()
            }
        }
        hotkeyManager.onStopDictation = { [weak self] in
            Task { @MainActor [weak self] in
                self?.coordinator.stopDictation()
                self?.syncMacHotkeyStateWithCoordinator()
            }
        }
        hotkeyManager.onActiveStateChanged = { [weak self] active in
            Task { @MainActor [weak self] in
                self?.hotkeyActive = active
            }
        }
        hotkeyManager.start()
        macTextInjector.onInjectionResult = { [weak self] result in
            Task { @MainActor [weak self] in
                self?.handleMacInjectionResult(result)
            }
        }
        if dictationPillController == nil {
            dictationPillController = MacDictationPillController(
                configuration: configuration,
                coordinator: coordinator,
                onToggle: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.toggleDictationFromFloatingPill()
                    }
                },
                recentTranscriptsProvider: { [weak self] in
                    // Sub-ms, synchronous, @MainActor fetch of the last 3 transcripts for
                    // the pill's hover recents card. Mirrors
                    // ContentView.fetchMacHistorySnapshot's legacy-owner-scope merge so a
                    // pre-migration ""-owner history still shows up here.
                    guard let self, let historyModelContext = self.historyModelContext else { return [] }
                    let ownerID = self.currentOwnerProfileID
                    func fetchRecentEntries(ownerID: String) -> [DictationHistoryEntry] {
                        var descriptor = FetchDescriptor<DictationHistoryEntry>(
                            predicate: #Predicate<DictationHistoryEntry> { entry in
                                entry.ownerProfileID == ownerID
                            },
                            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
                        )
                        descriptor.fetchLimit = 3
                        return (try? historyModelContext.fetch(descriptor)) ?? []
                    }
                    var entries = fetchRecentEntries(ownerID: ownerID)
                    if self.includesLegacyHistoryOwnerScope {
                        entries.append(contentsOf: fetchRecentEntries(ownerID: ""))
                    }
                    return entries
                        .sorted { $0.timestamp > $1.timestamp }
                        .prefix(3)
                        .map { entry in
                            PillTranscriptItem(
                                id: String(describing: entry.persistentModelID),
                                text: entry.cleanedDisplayText,
                                timestamp: entry.timestamp,
                                appName: entry.sourceAppName,
                                iconPNGData: entry.sourceAppIconPNGData
                            )
                        }
                },
                pasteTranscript: { [weak self] text in
                    self?.pasteTranscriptFromPill(text)
                }
            )
        }
        dictationPillController?.start()
        refreshAccessibilityPermissionStatus(promptIfNeeded: true)
        installReconnectHooks()
    }


    func refreshAccessibilityPermissionStatus(promptIfNeeded: Bool) {
        let isTrusted = permissionService.requestIfNeeded(prompt: promptIfNeeded)
        accessibilityPermissionGranted = isTrusted
        if !isTrusted, promptIfNeeded {
            permissionService.openSystemSettings()
        }
    }

    private func installReconnectHooks() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.triggerReconnectProbe(reason: "wake")
                }
            }
        )

        workspaceObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.sessionDidBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.triggerReconnectProbe(reason: "session active")
                }
            }
        )

        // The accessibility permission @Published value goes stale after the user grants it in
        // System Settings; re-check whenever the app becomes active (M-4).
        defaultCenterObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshAccessibilityPermissionStatus(promptIfNeeded: false)
                }
            }
        )
    }

    private func triggerReconnectProbe(reason: String) {
        let now = Date()
        guard now.timeIntervalSince(lastReconnectProbeAt) > 5 else { return }
        lastReconnectProbeAt = now
        print("[app] Reconnect probe: \(reason)")
        // Force-refresh the Firebase token first: on wake the cached token may have expired
        // during sleep, and a stale token makes the backend close with policyViolation which
        // then buffers session_start forever. Refreshing lifts the reconnect suppression (H-14).
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.sessionManager.refreshBackendAuthTokenIfSignedIn(forceRefresh: true)
            self.coordinator.warmConnection()
        }
    }

    private func bindMacDictationSoundEffects() {
        coordinator.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.handleMacDictationStatusTransition(status)
            }
            .store(in: &cancellables)
    }

    private func handleMacDictationStatusTransition(_ status: DictationStatus) {
        let previousStatus = lastObservedDictationStatus

        if status == .listening && previousStatus != .listening {
            hasActiveListeningSession = true
            cancelPendingMacDeactivationSound()
        } else if previousStatus == .listening && status != .listening {
            playMacDeactivationSoundIfNeeded(for: status)
            hasActiveListeningSession = false
        }

        syncMacHotkeyStateWithCoordinator()
        lastObservedDictationStatus = status
    }

    private func syncMacHotkeyStateWithCoordinator() {
        hotkeyManager.syncDictationActiveState(coordinator.status == .listening)
    }

    private func startMacDictation() {
        cancelPendingMacDeactivationSound()
        // Best-effort background token refresh. Note: while a session is .listening the
        // config-change refresh is deferred (ConnectionRefreshPolicy), so this does NOT fix a
        // token that expired mid-idle — the wake / session-active reconnect probe (which runs at
        // .idle and reconfigures directly) is what covers the "slept, came back, dictate" case
        // (H-14). This refresh primarily keeps the token warm for the *next* idle probe.
        Task { @MainActor [weak self] in
            await self?.sessionManager.refreshBackendAuthTokenIfSignedIn(forceRefresh: false)
        }
        // Transform mode: if the frontmost app has a live text selection when the
        // shortcut engages, treat this as "revise this text by voice" instead of a
        // normal dictation. Falls through to normal dictation if declined (e.g. no
        // addressable selection, or a session is already active).
        if let selectedText = macTextInjector.currentSelectionSnapshot(), !selectedText.isEmpty {
            if coordinator.startTransform(selectedText: selectedText) {
                return
            }
        }
        let macAudioOutputMuteDelay = playMacActivationSoundIfNeeded()
        coordinator.startDictation(macAudioOutputMuteDelay: macAudioOutputMuteDelay)
    }

    /// Persists a finished audio-import transcription as a normal history entry —
    /// same shape live dictation produces, so it's browsable/clickable identically.
    /// Imported audio is never injected into any app; this only writes history.
    func persistImportedAudioEntry(
        finalText: String,
        rawText: String?,
        audioDuration: TimeInterval,
        wordCount: Int,
        sourceLabel: String
    ) {
        guard let historyModelContext else { return }
        let wordsPerMinute = audioDuration > 0 ? (Double(wordCount) / audioDuration) * 60.0 : 0
        let entry = DictationHistoryEntry(
            ownerProfileID: currentOwnerProfileID,
            // Prefixed so analytics can keep imported files out of dictation stats.
            sessionID: DictationHistoryEntry.importedAudioSessionPrefix + UUID().uuidString,
            timestamp: .now,
            finalText: finalText,
            rawText: rawText,
            outputPresetRawValue: configuration.outputPreset.rawValue,
            audioDuration: audioDuration,
            wordCount: wordCount,
            wordsPerMinute: wordsPerMinute,
            sourceAppName: sourceLabel
        )
        historyModelContext.insert(entry)
        try? historyModelContext.save()
        NotificationCenter.default.post(name: .dictationHistoryDidChange, object: nil)
    }

    private func playMacActivationSoundIfNeeded() -> TimeInterval {
        guard configuration.dictationSoundEffectsEnabled else { return 0 }
        let activationDuration = dictationSoundEffectService.playActivation()
        return min(max(activationDuration + 0.02, 0), 0.25)
    }

    private func playMacDeactivationSoundIfNeeded(for status: DictationStatus) {
        guard hasActiveListeningSession, configuration.dictationSoundEffectsEnabled else { return }

        switch status {
        case .idle:
            dictationSoundEffectService.playDeactivation()
        case .processing, .error:
            scheduleMacDeactivationSound()
        case .listening:
            break
        }
    }

    private func scheduleMacDeactivationSound() {
        cancelPendingMacDeactivationSound()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard configuration.dictationSoundEffectsEnabled else { return }
            guard coordinator.status != .listening else { return }
            dictationSoundEffectService.playDeactivation()
            pendingMacDeactivationSoundWorkItem = nil
        }

        pendingMacDeactivationSoundWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: workItem)
    }

    private func cancelPendingMacDeactivationSound() {
        pendingMacDeactivationSoundWorkItem?.cancel()
        pendingMacDeactivationSoundWorkItem = nil
    }

    private func toggleDictationFromFloatingPill() {
        switch coordinator.status {
        case .listening:
            coordinator.stopDictation()
        case .idle, .error:
            startMacDictation()
        case .processing:
            break
        }
        syncMacHotkeyStateWithCoordinator()
    }

    /// Pastes a transcript selected from the pill's hover recents card. Routes
    /// through the same injector as live dictation so it inherits AX-direct
    /// insertion, concealed ⌘V + clipboard restore, secure-input fallbacks, and the
    /// degraded-path pill notices (handled by `handleMacInjectionResult`).
    func pasteTranscriptFromPill(_ text: String) {
        macTextInjector.inject(text: text)
    }

    private func refreshBackendAuthTokenAfterAuthorizationRejection() {
        Task { @MainActor [weak self] in
            await self?.sessionManager.refreshBackendAuthTokenIfSignedIn(forceRefresh: true)
        }
    }

    private func bindConfiguration() {
        configuration.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        configuration.$keyboardShortcut
            .receive(on: DispatchQueue.main)
            .sink { [weak self] shortcut in
                self?.hotkeyManager.updateShortcut(shortcut)
            }
            .store(in: &cancellables)

        configuration.$appVisibilityMode
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                self?.handleMacAppVisibilityModeUpdate(mode)
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(configuration.$backendURL, configuration.$authToken)
            .dropFirst()
            .removeDuplicates { lhs, rhs in
                lhs.0 == rhs.0 && lhs.1 == rhs.1
            }
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.coordinator.refreshConnectionConfiguration()
            }
            .store(in: &cancellables)
    }

    private func bindSessionState() {
        // Menu-bar icon and dashboard read only coordinator.status and connectionState through
        // appModel, so forward those transitions alone (H-22). Forwarding every coordinator change re-rendered the
        // whole dashboard and menu-bar scene on each live-text partial and 15 Hz level tick.
        Publishers.Merge(
            coordinator.$status.removeDuplicates().dropFirst().map { _ in () },
            coordinator.$connectionState.removeDuplicates().dropFirst().map { _ in () }
        )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        sessionManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        sessionManager.$currentSession
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.dictionaryStore?.currentOwnerProfileID = self.sessionManager.currentOwnerProfileID
                self.migrateLegacyHistoryScopeIfNeeded()
            }
            .store(in: &cancellables)
    }

    var currentOwnerProfileID: String {
        sessionManager.currentOwnerProfileID
    }

    var includesLegacyHistoryOwnerScope: Bool {
        currentOwnerProfileID == sessionManager.localOnlyProfileID
    }

    private func migrateLegacyHistoryScopeIfNeeded() {
        guard let historyModelContext else { return }
        guard currentOwnerProfileID == sessionManager.localOnlyProfileID else { return }

        let entries = (try? historyModelContext.fetch(FetchDescriptor<DictationHistoryEntry>())) ?? []
        var didMutate = false
        for entry in entries where entry.ownerProfileID.isEmpty {
            entry.ownerProfileID = sessionManager.localOnlyProfileID
            didMutate = true
        }

        if didMutate {
            try? historyModelContext.save()
        }
    }

    /// Dictations that the given retention window would delete (both owner scopes).
    func historyCountPastRetention(_ retention: HistoryRetention, now: Date = .now) -> Int {
        guard let historyModelContext, let cutoff = retention.cutoff(now: now) else { return 0 }
        let owners = historyOwnerScopes()
        return owners.reduce(0) { total, ownerID in
            let descriptor = FetchDescriptor<DictationHistoryEntry>(
                predicate: #Predicate { entry in
                    entry.ownerProfileID == ownerID && entry.timestamp < cutoff
                }
            )
            return total + ((try? historyModelContext.fetchCount(descriptor)) ?? 0)
        }
    }

    /// Every saved dictation for the current account (both owner scopes).
    func historyTotalCount() -> Int {
        guard let historyModelContext else { return 0 }
        return historyOwnerScopes().reduce(0) { total, ownerID in
            let descriptor = FetchDescriptor<DictationHistoryEntry>(
                predicate: #Predicate { $0.ownerProfileID == ownerID }
            )
            return total + ((try? historyModelContext.fetchCount(descriptor)) ?? 0)
        }
    }

    /// Deletes transcripts older than the configured retention window. Idempotent; runs at
    /// launch and when the calendar day changes.
    func enforceHistoryRetention(now: Date = .now) {
        guard let historyModelContext, let cutoff = configuration.historyRetention.cutoff(now: now) else { return }
        var deleted = 0
        for ownerID in historyOwnerScopes() {
            let descriptor = FetchDescriptor<DictationHistoryEntry>(
                predicate: #Predicate { entry in
                    entry.ownerProfileID == ownerID && entry.timestamp < cutoff
                }
            )
            guard let stale = try? historyModelContext.fetch(descriptor), !stale.isEmpty else { continue }
            stale.forEach(historyModelContext.delete)
            deleted += stale.count
        }
        guard deleted > 0 else { return }
        do {
            try historyModelContext.save()
            print("[history] retention removed \(deleted) dictations older than \(configuration.historyRetention.displayName)")
            postDictationHistoryDidChange()
        } catch {
            print("[history] retention save failed: \(error)")
        }
    }

    /// Removes every local dictation for the current account, including legacy unscoped rows.
    func deleteAllLocalHistory() {
        for ownerID in historyOwnerScopes() {
            clearLocalHistory(for: ownerID)
        }
    }

    private func historyOwnerScopes() -> [String] {
        includesLegacyHistoryOwnerScope ? [currentOwnerProfileID, ""] : [currentOwnerProfileID]
    }

    private func clearLocalHistory(for ownerProfileID: String) {
        guard let historyModelContext else { return }

        do {
            let descriptor = FetchDescriptor<DictationHistoryEntry>(
                predicate: #Predicate { entry in
                    entry.ownerProfileID == ownerProfileID
                }
            )
            let entries = try historyModelContext.fetch(descriptor)
            guard !entries.isEmpty else { return }

            for entry in entries {
                historyModelContext.delete(entry)
            }

            try historyModelContext.save()
            postDictationHistoryDidChange()
        } catch {
            print("[app] Failed to clear local dictation history for \(ownerProfileID): \(error)")
        }
    }

    private func postDictationHistoryDidChange() {
        // The macOS dashboard observes this to refresh its 120-row history snapshot (C-3).
        // The name is only defined for macOS (the iOS UI uses @Query and needs no notification).
        NotificationCenter.default.post(name: .dictationHistoryDidChange, object: nil)
        scheduleLearnedVocabularyRefresh()
    }

    /// Manual terms first, then learned ones, case-insensitively de-duplicated.
    static func mergedVocabulary(manual: [String], learned: [String]) -> [String] {
        var seen = Set<String>()
        var merged: [String] = []
        for term in manual + learned {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            merged.append(trimmed)
        }
        return Array(merged.prefix(240))
    }

    private func scheduleLearnedVocabularyRefresh() {
        learnedVocabularyWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refreshLearnedVocabulary() }
        }
        learnedVocabularyWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    /// Re-learns from the last `HistoryVocabularyLearner.windowDays` days. Runs off the
    /// dictation hot path, a few seconds after history changes.
    func refreshLearnedVocabulary(now: Date = .now) {
        guard let historyModelContext,
              let start = Calendar.current.date(byAdding: .day, value: -HistoryVocabularyLearner.windowDays, to: now)
        else { return }
        var entries: [DictationHistoryEntry] = []
        for ownerID in historyOwnerScopes() {
            let descriptor = FetchDescriptor<DictationHistoryEntry>(
                predicate: #Predicate { $0.ownerProfileID == ownerID && $0.timestamp >= start }
            )
            entries += (try? historyModelContext.fetch(descriptor)) ?? []
        }
        let learned = HistoryVocabularyLearner.learn(
            from: entries,
            suppressed: Set(configuration.suppressedLearnedVocabulary.map { $0.lowercased() }),
            alreadyLearned: Set(configuration.learnedVocabulary.map { $0.lowercased() })
        )
        guard learned != configuration.learnedVocabulary else { return }
        HistoryVocabularyLearner.synchronizeSpellChecker(
            previous: Set(configuration.learnedVocabulary),
            current: Set(learned)
        )
        #if DEBUG
        print("[vocab] learned \(learned.count) terms: \(learned.joined(separator: ", "))")
        #endif
        configuration.learnedVocabulary = learned
    }

    /// Removes a learned term and keeps it from coming back.
    func removeLearnedVocabulary(_ term: String) {
        let key = term.lowercased()
        let previous = Set(configuration.learnedVocabulary)
        configuration.learnedVocabulary.removeAll { $0.lowercased() == key }
        HistoryVocabularyLearner.synchronizeSpellChecker(
            previous: previous,
            current: Set(configuration.learnedVocabulary)
        )
        if !configuration.suppressedLearnedVocabulary.contains(where: { $0.lowercased() == key }) {
            configuration.suppressedLearnedVocabulary.append(term)
        }
    }

    private func matchesCurrentOwnerScope(ownerProfileID: String) -> Bool {
        ownerProfileID == currentOwnerProfileID
            || (ownerProfileID.isEmpty && currentOwnerProfileID == sessionManager.localOnlyProfileID)
    }

    private func scheduleInitialMacAppVisibilityModeApplication() {
        pendingInitialAppVisibilityMode = configuration.appVisibilityMode

        if NSApplication.shared.isRunning {
            hasFinishedLaunchingApp = true
            applyPendingInitialMacAppVisibilityModeIfNeeded()
            return
        }

        guard appDidFinishLaunchingObserver == nil else { return }
        appDidFinishLaunchingObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: NSApplication.shared,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.hasFinishedLaunchingApp = true
                self.applyPendingInitialMacAppVisibilityModeIfNeeded()
            }
        }
    }

    private func handleMacAppVisibilityModeUpdate(_ mode: AppVisibilityMode) {
        if hasFinishedLaunchingApp || NSApplication.shared.isRunning {
            hasFinishedLaunchingApp = true
            pendingInitialAppVisibilityMode = nil
            applyMacAppVisibilityMode(mode)
        } else {
            pendingInitialAppVisibilityMode = mode
        }
    }

    private func applyPendingInitialMacAppVisibilityModeIfNeeded() {
        if let observer = appDidFinishLaunchingObserver {
            NotificationCenter.default.removeObserver(observer)
            appDidFinishLaunchingObserver = nil
        }
        guard let mode = pendingInitialAppVisibilityMode else { return }
        pendingInitialAppVisibilityMode = nil
        applyMacAppVisibilityMode(mode)
    }

    private func applyMacAppVisibilityMode(_ mode: AppVisibilityMode) {
        let targetPolicy: NSApplication.ActivationPolicy = mode == .menuBarOnly ? .accessory : .regular
        let app = NSApplication.shared
        guard app.activationPolicy() != targetPolicy else { return }
        app.setActivationPolicy(targetPolicy)
        if targetPolicy == .regular {
            app.activate(ignoringOtherApps: false)
        }
    }

    private func installTerminationPersistenceFlushHook() {
        // The persistence drain is deferred (0.52s on macOS); a quick quit could otherwise
        // drop the last dictation and its dictionary learning. Flush synchronously on
        // termination (M-22).
        let terminationNotification = NSApplication.willTerminateNotification
        terminationObserver = NotificationCenter.default.addObserver(
            forName: terminationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushPendingPersistenceImmediately()
            }
        }
    }

    private func flushPendingPersistenceImmediately() {
        pendingPersistenceDrainWorkItem?.cancel()
        pendingPersistenceDrainWorkItem = nil
        drainPendingPersistenceQueue()
    }

    private func enqueuePersistence(record: DictationFinalizedRecord) {
        pendingPersistencePayloads.append(makePersistencePayload(for: record))
        schedulePersistenceDrainIfNeeded()
    }

    private func makePersistencePayload(for record: DictationFinalizedRecord) -> DictationPersistencePayload {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        return DictationPersistencePayload(
            record: record,
            sourceBundleIdentifier: frontmostApp?.bundleIdentifier,
            sourceAppName: frontmostApp?.localizedName,
            sourceAppIcon: frontmostApp?.icon
        )
    }

    private func schedulePersistenceDrainIfNeeded() {
        guard pendingPersistenceDrainWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingPersistenceDrainWorkItem = nil
            self.drainPendingPersistenceQueue()
        }

        pendingPersistenceDrainWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + macPersistenceDeferral, execute: workItem)
    }

    private func drainPendingPersistenceQueue() {
        while !pendingPersistencePayloads.isEmpty {
            let payload = pendingPersistencePayloads.removeFirst()
            persist(payload: payload)
        }
    }

    private func persist(payload: DictationPersistencePayload) {
        let record = payload.record
        guard let historyModelContext else { return }
        let sourceBundleIdentifier = payload.sourceBundleIdentifier
        let sourceAppName = payload.sourceAppName
        let sourceAppIconPNGData = cachedIconPNGData(
            for: payload.sourceAppIcon,
            bundleIdentifier: sourceBundleIdentifier
        )
        let isFailedRawFallback: Bool
        switch record.stage {
        case .canonicalCleaned:
            isFailedRawFallback = false
        case .failedRawFallback:
            isFailedRawFallback = true
        }
        let failureNote = isFailedRawFallback
            ? "Recovered raw transcript — this session didn't finish cleanup."
            : nil
        do {
            let sessionID = record.sessionID
            let ownerProfileID = currentOwnerProfileID
            let descriptor = FetchDescriptor<DictationHistoryEntry>(
                predicate: #Predicate { entry in
                    entry.sessionID == sessionID && entry.ownerProfileID == ownerProfileID
                }
            )
            let existingEntry = try historyModelContext.fetch(descriptor).first
            let entry = existingEntry ?? DictationHistoryEntry(
                ownerProfileID: ownerProfileID,
                sessionID: record.sessionID,
                timestamp: record.timestamp,
                finalText: record.finalText,
                rawText: record.rawText,
                outputPresetRawValue: record.outputPresetRawValue,
                audioDuration: record.audioDuration,
                wordCount: record.wordCount,
                wordsPerMinute: record.wordsPerMinute,
                requestedSourceLanguageModeRawValue: record.requestedSourceLanguageModeRawValue,
                requestedSourceLanguageCode: record.requestedSourceLanguageCode,
                resolvedSourceLanguageCode: record.resolvedSourceLanguageCode,
                outputLanguageCode: record.outputLanguageCode,
                didTranslate: record.didTranslate,
                providerRouteRawValue: record.providerRouteRawValue,
                sourceAppBundleIdentifier: sourceBundleIdentifier,
                sourceAppName: sourceAppName,
                sourceAppIconPNGData: sourceAppIconPNGData,
                failureNote: failureNote
            )
            if existingEntry == nil {
                historyModelContext.insert(entry)
            }

            entry.ownerProfileID = ownerProfileID
            entry.sessionID = record.sessionID
            entry.finalText = record.finalText
            entry.rawText = record.rawText
            entry.outputPresetRawValue = record.outputPresetRawValue
            entry.audioDuration = record.audioDuration
            entry.wordCount = record.wordCount
            entry.wordsPerMinute = record.wordsPerMinute
            entry.requestedSourceLanguageModeRawValue = record.requestedSourceLanguageModeRawValue
            entry.requestedSourceLanguageCode = record.requestedSourceLanguageCode
            entry.resolvedSourceLanguageCode = record.resolvedSourceLanguageCode
            entry.outputLanguageCode = record.outputLanguageCode
            entry.didTranslate = record.didTranslate
            entry.providerRouteRawValue = record.providerRouteRawValue
            entry.sourceAppBundleIdentifier = sourceBundleIdentifier
            entry.sourceAppName = sourceAppName
            entry.sourceAppIconPNGData = sourceAppIconPNGData
            entry.failureNote = failureNote

            try historyModelContext.save()
            consecutivePersistFailures = 0
            postDictationHistoryDidChange()
        } catch {
            Self.logger.error("history persist failed: \(error.localizedDescription, privacy: .public)")
            consecutivePersistFailures += 1
            if consecutivePersistFailures >= 2 {
                dictationPillController?.showTransientNotice(
                    "History couldn't be saved — recent dictations may be missing."
                )
            }
        }
    }

    // One small (64 px) encode per app instead of a full-resolution multi-rep
    // TIFF→PNG conversion per dictation (MAC-OPEN-06).
    private var iconDataCache: [String: Data] = [:]

    private func cachedIconPNGData(for icon: NSImage?, bundleIdentifier: String?) -> Data? {
        guard let icon else { return nil }
        let key = bundleIdentifier ?? "unknown"
        if let cached = iconDataCache[key] {
            return cached
        }
        let encoded = icon.downscaledPNGData(maxDimension: 64)
        if let encoded {
            iconDataCache[key] = encoded
        }
        return encoded
    }

    private func handleMacInjectionResult(_ result: TextInjectionResult) {
        switch result {
        case .injected, .injectedDirect:
            break
        case .clipboardOnlySecureInput:
            dictationPillController?.showTransientNotice(
                "Copied to clipboard — press ⌘V to paste (secure input is on)."
            )
        case .clipboardOnlyAccessibilityDenied:
            dictationPillController?.showTransientNotice(
                "Copied to clipboard — grant Accessibility to auto-insert."
            )
        }
    }

    deinit {
        pendingPersistenceDrainWorkItem?.cancel()
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        let hotkeyManager = hotkeyManager
        let workspaceObservers = workspaceObservers
        let defaultCenterObservers = defaultCenterObservers
        let appDidFinishLaunchingObserver = appDidFinishLaunchingObserver
        Task { @MainActor in
            hotkeyManager.stop()
            for observer in workspaceObservers {
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
            }
            for observer in defaultCenterObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = appDidFinishLaunchingObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}

private extension NSImage {
    func pngData() -> Data? {
        guard let tiffData = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// Renders the image into a small fixed-size bitmap so history rows don't carry
    /// full-resolution multi-rep app icons.
    func downscaledPNGData(maxDimension: CGFloat) -> Data? {
        let targetSize = NSSize(width: maxDimension, height: maxDimension)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(maxDimension),
            pixelsHigh: Int(maxDimension),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return pngData()
        }
        bitmap.size = targetSize
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return pngData()
        }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )
        return bitmap.representation(using: .png, properties: [:])
    }
}
