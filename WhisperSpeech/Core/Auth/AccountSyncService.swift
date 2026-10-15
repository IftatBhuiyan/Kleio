import Combine
import CryptoKit
import FirebaseFirestore
import Foundation
import os

@MainActor
final class AccountSyncService {
    private static let logger = Logger(subsystem: "com.eclipsestudio.kleio", category: "account-sync")
    private let firestore: Firestore
    private let configuration: AppConfiguration
    private let dictionaryStore: DictionaryStore
    private let identityStore: AppIdentityStore
    private let deviceInfoProvider: () -> [String: Any]
    private let stateDidChange: (AccountSyncState) -> Void

    private var currentUserID: String?
    private var settingsListener: ListenerRegistration?
    private var privacyListener: ListenerRegistration?
    private var dictionaryListener: ListenerRegistration?
    private var bootstrapSyncTask: Task<Void, Never>?
    private var bootstrapSyncGeneration = UUID()
    private var settingsSyncTask: Task<Void, Never>?
    private var dictionarySyncTask: Task<Void, Never>?
    private var isApplyingRemoteSettings = false
    private var isApplyingRemoteDictionary = false
    private var lastPushedSettingsSnapshot: CloudAccountSettingsSnapshot?
    private var lastPushedPrivacySnapshot: CloudPrivacySettingsSnapshot?
    private var lastPushedTermsByID: [String: CloudDictionaryTermSnapshot] = [:]
    private var cancellables = Set<AnyCancellable>()

    init(
        firestore: Firestore = Firestore.firestore(),
        configuration: AppConfiguration,
        dictionaryStore: DictionaryStore,
        identityStore: AppIdentityStore,
        stateDidChange: @escaping (AccountSyncState) -> Void
    ) {
        self.firestore = firestore
        self.configuration = configuration
        self.dictionaryStore = dictionaryStore
        self.identityStore = identityStore
        self.stateDidChange = stateDidChange
        self.deviceInfoProvider = {
            var data: [String: Any] = [
                "deviceID": identityStore.stableDeviceID,
                "platform": AccountSyncService.platformName,
                "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
                "buildNumber": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
            ]

            let processInfo = ProcessInfo.processInfo
            data["osVersion"] = processInfo.operatingSystemVersionString
            data["deviceModel"] = Host.current().localizedName ?? "Mac"

            return data
        }
    }

    func start(for session: AccountSessionSnapshot) {
        stop()

        guard !session.isAnonymous else {
            stateDidChange(.localOnly)
            return
        }

        currentUserID = session.uid
        stateDidChange(.syncing)

        let bootstrapSyncGeneration = UUID()
        self.bootstrapSyncGeneration = bootstrapSyncGeneration
        bootstrapSyncTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.ensureBaseDocuments(for: session)
                try self.ensureBootstrapTaskCanContinue(for: session.uid)
                try await self.mergeRemoteState(for: session.uid)
                try self.ensureBootstrapTaskCanContinue(for: session.uid)
                self.startListeners(for: session.uid)
                self.bindLocalObservers(for: session.uid)
                try self.ensureBootstrapTaskCanContinue(for: session.uid)
                try await self.pushCurrentState(for: session.uid)
                try self.ensureBootstrapTaskCanContinue(for: session.uid)
                self.stateDidChange(.synced)
            } catch is CancellationError {
                return
            } catch {
                self.stateDidChange(.failed(self.presentableSyncMessage(for: error)))
            }

            if self.bootstrapSyncGeneration == bootstrapSyncGeneration {
                self.bootstrapSyncTask = nil
            }
        }
    }

    func stop() {
        currentUserID = nil
        bootstrapSyncGeneration = UUID()
        settingsListener?.remove()
        settingsListener = nil
        privacyListener?.remove()
        privacyListener = nil
        dictionaryListener?.remove()
        dictionaryListener = nil
        bootstrapSyncTask?.cancel()
        bootstrapSyncTask = nil
        settingsSyncTask?.cancel()
        settingsSyncTask = nil
        dictionarySyncTask?.cancel()
        dictionarySyncTask = nil
        cancellables.removeAll()
        dictionaryStore.onDidChange = nil
        lastPushedSettingsSnapshot = nil
        lastPushedPrivacySnapshot = nil
        lastPushedTermsByID = [:]
        stateDidChange(.idle)
    }

    func deleteRemoteAccountData(for session: AccountSessionSnapshot) async throws {
        guard !session.isAnonymous else { return }

        let userDocument = usersCollection.document(session.uid)

        try await deleteDocuments(in: userDocument.collection("dictionary"))
        try await deleteDocuments(in: userDocument.collection("settings"))
        try? await userDocument.collection("aggregates").document("account").deleteAsync()

        let deviceSnapshot = try await userDocument.collection("devices").getDocumentsAsync()
        for deviceDocument in deviceSnapshot.documents {
            let deviceReference = deviceDocument.reference
            try await deleteDocuments(in: deviceReference.collection("settings"))
            try await deleteDocuments(in: deviceReference.collection("summaries"))
            try await deleteDocuments(in: deviceReference.collection("metricsDaily"))
            try await deleteDocuments(in: deviceReference.collection("keyboardDogfoodEvents"))
            try await deviceReference.deleteAsync()
        }

        try await userDocument.deleteAsync()
    }

    private func ensureBaseDocuments(for session: AccountSessionSnapshot) async throws {
        let userDocument = usersCollection.document(session.uid)
        let deviceDocument = userDocument
            .collection("devices")
            .document(identityStore.stableDeviceID)

        async let existingUserSnapshot = userDocument.getDocumentAsync()
        async let existingDeviceSnapshot = deviceDocument.getDocumentAsync()

        let userSnapshot = try await existingUserSnapshot
        let deviceSnapshot = try await existingDeviceSnapshot
        let shouldSetCreatedAt = !userSnapshot.exists || userSnapshot.data()?["createdAt"] == nil
        let shouldSetFirstSeenAt = !deviceSnapshot.exists || deviceSnapshot.data()?["firstSeenAt"] == nil

        var userData: [String: Any] = [
            "schemaVersion": 1,
            "updatedAt": FieldValue.serverTimestamp(),
            "emailVerified": session.isEmailVerified,
            "providerIDs": session.providerIDs,
            "lastSeenAt": FieldValue.serverTimestamp()
        ]
        if shouldSetCreatedAt {
            // Preserve the original first-seen timestamp across later bootstrap syncs.
            userData["createdAt"] = FieldValue.serverTimestamp()
        }
        if let displayName = session.displayName, !displayName.isEmpty {
            userData["displayName"] = displayName
        }
        if let email = session.email, !email.isEmpty {
            userData["primaryEmail"] = email
        }
        try await userDocument.setDataAsync(userData, merge: true)

        try await pushPrivacySettings(for: session.uid)

        var deviceData = deviceInfoProvider()
        if shouldSetFirstSeenAt {
            deviceData["firstSeenAt"] = FieldValue.serverTimestamp()
        }
        deviceData["lastSeenAt"] = FieldValue.serverTimestamp()
        deviceData["schemaVersion"] = 1
        try await deviceDocument.setDataAsync(deviceData, merge: true)

        try await deviceDocument
            .collection("settings")
            .document("current")
            .setDataAsync([
                "cleanupModel": configuration.cleanupModel.rawValue,
                "dictationSoundEffectsEnabled": configuration.dictationSoundEffectsEnabled,
                "updatedAt": FieldValue.serverTimestamp()
            ], merge: true)
    }

    private func mergeRemoteState(for userID: String) async throws {
        let settingsDocument = try await usersCollection
            .document(userID)
            .collection("settings")
            .document("account")
            .getDocumentAsync()

        if let settingsData = settingsDocument.data(),
           let remoteSettings = CloudAccountSettingsSnapshot(documentData: settingsData) {
            applyRemoteSettings(remoteSettings)
        }

        let privacyDocument = try await usersCollection
            .document(userID)
            .collection("settings")
            .document("privacy")
            .getDocumentAsync()

        if let privacyData = privacyDocument.data(),
           let remotePrivacy = CloudPrivacySettingsSnapshot(documentData: privacyData) {
            applyRemotePrivacySettings(remotePrivacy)
        }

        let remoteTermsSnapshot = try await usersCollection
            .document(userID)
            .collection("dictionary")
            .getDocumentsAsync()

        let remoteTerms = remoteTermsSnapshot.documents.compactMap { document in
            CloudDictionaryTermSnapshot(documentData: document.data())
        }
        if !remoteTerms.isEmpty {
            isApplyingRemoteDictionary = true
            dictionaryStore.applyRemoteApprovedTerms(remoteTerms)
            isApplyingRemoteDictionary = false
        }
    }

    private func startListeners(for userID: String) {
        let userDocument = usersCollection.document(userID)
        settingsListener = userDocument
            .collection("settings")
            .document("account")
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                if let error {
                    self.handleListenerError(error, source: "settings")
                    return
                }
                guard let data = snapshot?.data(),
                      let remoteSettings = CloudAccountSettingsSnapshot(documentData: data) else { return }
                self.applyRemoteSettings(remoteSettings)
                self.stateDidChange(.synced)
            }

        privacyListener = userDocument
            .collection("settings")
            .document("privacy")
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                if let error {
                    self.handleListenerError(error, source: "privacy")
                    return
                }
                guard let data = snapshot?.data(),
                      let remotePrivacy = CloudPrivacySettingsSnapshot(documentData: data) else { return }
                self.applyRemotePrivacySettings(remotePrivacy)
                self.stateDidChange(.synced)
            }

        dictionaryListener = userDocument
            .collection("dictionary")
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                if let error {
                    self.handleListenerError(error, source: "dictionary")
                    return
                }
                guard let snapshot else { return }
                let terms = snapshot.documents.compactMap { document in
                    CloudDictionaryTermSnapshot(documentData: document.data())
                }
                for term in terms {
                    self.lastPushedTermsByID[self.documentID(for: term.normalizedKey)] = term
                }
                self.isApplyingRemoteDictionary = true
                self.dictionaryStore.applyRemoteApprovedTerms(terms)
                self.isApplyingRemoteDictionary = false
                self.stateDidChange(.synced)
            }
    }

    // Firestore listeners retry transient failures internally; latching `.failed` on the
    // first blip leaves a permanent stale error banner. Only terminal auth/permission
    // errors surface as failures.
    private func handleListenerError(_ error: Error, source: String) {
        let code = FirestoreErrorCode.Code(rawValue: (error as NSError).code)
        switch code {
        case .permissionDenied, .unauthenticated:
            stateDidChange(.failed(presentableSyncMessage(for: error)))
        default:
            Self.logger.error("transient \(source, privacy: .public) listener error: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func bindLocalObservers(for userID: String) {
        // No `.receive(on:)` here: `objectWillChange` fires synchronously while
        // `isApplyingRemoteSettings` is still true, so remote applies don't echo a push.
        // The debounced task below then reads the settled values and diffs against the
        // last-pushed snapshots, so unrelated published properties (auth token refresh,
        // vocabulary mirror) don't cause Firestore writes either.
        configuration.objectWillChange
            .sink { [weak self] _ in
                guard let self else { return }
                guard !self.isApplyingRemoteSettings else { return }
                self.scheduleSettingsSync(for: userID)
            }
            .store(in: &cancellables)

        dictionaryStore.onDidChange = { [weak self] in
            guard let self else { return }
            guard !self.isApplyingRemoteDictionary else { return }
            self.scheduleDictionarySync(for: userID)
        }
    }

    private func scheduleSettingsSync(for userID: String) {
        settingsSyncTask?.cancel()
        settingsSyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            let settingsSnapshot = CloudAccountSettingsSnapshot(configuration: self.configuration)
            let privacySnapshot = CloudPrivacySettingsSnapshot(
                configuration: self.configuration,
                uploadDeviceSummariesEnabled: self.identityStore.uploadDeviceSummariesEnabled
            )
            let settingsChanged = settingsSnapshot != self.lastPushedSettingsSnapshot
            let privacyChanged = privacySnapshot != self.lastPushedPrivacySnapshot
            guard settingsChanged || privacyChanged else { return }
            do {
                if settingsChanged {
                    try await self.pushSettings(for: userID)
                }
                if privacyChanged {
                    try await self.pushPrivacySettings(for: userID)
                }
                self.stateDidChange(.synced)
            } catch {
                self.stateDidChange(.failed(self.presentableSyncMessage(for: error)))
            }
        }
    }

    private func scheduleDictionarySync(for userID: String) {
        dictionarySyncTask?.cancel()
        dictionarySyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            do {
                try await self.pushDictionary(for: userID)
                self.stateDidChange(.synced)
            } catch {
                self.stateDidChange(.failed(self.presentableSyncMessage(for: error)))
            }
        }
    }

    private func pushCurrentState(for userID: String) async throws {
        try await pushSettings(for: userID)
        try await pushPrivacySettings(for: userID)
        try await pushDictionary(for: userID)
    }

    private func pushSettings(for userID: String) async throws {
        let snapshot = CloudAccountSettingsSnapshot(configuration: configuration)
        var documentData = snapshot.firestoreData
        documentData["schemaVersion"] = 1
        documentData["updatedAt"] = FieldValue.serverTimestamp()
        documentData["updatedByDeviceID"] = identityStore.stableDeviceID
        try await usersCollection
            .document(userID)
            .collection("settings")
            .document("account")
            .setDataAsync(documentData, merge: true)
        lastPushedSettingsSnapshot = snapshot
    }

    private func pushPrivacySettings(for userID: String) async throws {
        let snapshot = CloudPrivacySettingsSnapshot(
            configuration: configuration,
            uploadDeviceSummariesEnabled: identityStore.uploadDeviceSummariesEnabled
        )
        var documentData = snapshot.firestoreData
        documentData["schemaVersion"] = 1
        documentData["updatedAt"] = FieldValue.serverTimestamp()
        documentData["updatedByDeviceID"] = identityStore.stableDeviceID
        try await usersCollection
            .document(userID)
            .collection("settings")
            .document("privacy")
            .setDataAsync(documentData, merge: true)
        lastPushedPrivacySnapshot = snapshot
    }

    private func pushDictionary(for userID: String) async throws {
        let collection = usersCollection
            .document(userID)
            .collection("dictionary")
        let localTerms = dictionaryStore.cloudSyncedActiveTermsSnapshot()
        let localTermsByID = Dictionary(uniqueKeysWithValues: localTerms.map { (documentID(for: $0.normalizedKey), $0) })

        // Only write terms that changed since the last push, in batches (Firestore caps
        // a batch at 500 operations) instead of one round-trip per term.
        let dirtyTerms = localTermsByID.filter { lastPushedTermsByID[$0.key] != $0.value }
        guard !dirtyTerms.isEmpty else { return }

        let batchLimit = 450
        var iterator = dirtyTerms.makeIterator()
        var pendingChunk: [(String, CloudDictionaryTermSnapshot)] = []
        func flushChunk() async throws {
            guard !pendingChunk.isEmpty else { return }
            let batch = firestore.batch()
            for (documentID, term) in pendingChunk {
                var documentData = term.firestoreData
                documentData["schemaVersion"] = 1
                documentData["updatedAt"] = FieldValue.serverTimestamp()
                documentData["updatedByDeviceID"] = identityStore.stableDeviceID
                batch.setData(documentData, forDocument: collection.document(documentID), merge: true)
            }
            try await batch.commitAsync()
            for (documentID, term) in pendingChunk {
                lastPushedTermsByID[documentID] = term
            }
            pendingChunk.removeAll(keepingCapacity: true)
        }
        while let entry = iterator.next() {
            pendingChunk.append((entry.key, entry.value))
            if pendingChunk.count >= batchLimit {
                try await flushChunk()
            }
        }
        try await flushChunk()
    }

    private func applyRemoteSettings(_ snapshot: CloudAccountSettingsSnapshot) {
        // Remote is canonical once observed: record it as last-pushed so the debounced
        // local observer's diff can't echo it back to Firestore.
        lastPushedSettingsSnapshot = snapshot
        guard CloudAccountSettingsSnapshot(configuration: configuration) != snapshot else { return }
        isApplyingRemoteSettings = true

        if let preset = DictationOutputPreset(rawValue: snapshot.outputPresetRawValue) {
            configuration.outputPreset = preset
        }
        if let cleanupModel = CleanupModel(rawValue: snapshot.cleanupModelRawValue) {
            configuration.cleanupModel = cleanupModel
        }
        if let sourceLanguageMode = DictationSourceLanguageMode(rawValue: snapshot.sourceLanguageModeRawValue) {
            configuration.sourceLanguageMode = sourceLanguageMode
        }
        configuration.sourceLanguageCode = snapshot.sourceLanguageCode
        if let outputLanguageMode = DictationOutputLanguageMode(rawValue: snapshot.outputLanguageModeRawValue) {
            configuration.outputLanguageMode = outputLanguageMode
        }
        configuration.outputLanguageCode = snapshot.outputLanguageCode
        configuration.autoLearnDictionaryTermsEnabled = snapshot.autoLearnDictionaryTermsEnabled

        isApplyingRemoteSettings = false
    }

    private func applyRemotePrivacySettings(_ snapshot: CloudPrivacySettingsSnapshot) {
        let localSnapshot = CloudPrivacySettingsSnapshot(
            configuration: configuration,
            uploadDeviceSummariesEnabled: identityStore.uploadDeviceSummariesEnabled
        )
        lastPushedPrivacySnapshot = snapshot
        guard localSnapshot != snapshot else { return }

        isApplyingRemoteSettings = true
        configuration.privacyModeEnabled = snapshot.privacyModeEnabled
        configuration.improvementSharingEnabled = snapshot.privacyModeEnabled
            ? false
            : snapshot.improvementSharingEnabled
        identityStore.uploadDeviceSummariesEnabled = snapshot.uploadDeviceSummariesEnabled
        isApplyingRemoteSettings = false
    }

    private var usersCollection: CollectionReference {
        firestore.collection("users")
    }

    private func documentID(for normalizedKey: String) -> String {
        let digest = SHA256.hash(data: Data(normalizedKey.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func deleteDocuments(in collection: CollectionReference) async throws {
        let snapshot = try await collection.getDocumentsAsync()
        guard !snapshot.documents.isEmpty else { return }
        // Batched deletes: fewer round-trips and a smaller window for a mid-flight
        // failure to leave a partially-deleted account. Retrying the whole flow is
        // safe — deletes are idempotent.
        for chunk in stride(from: 0, to: snapshot.documents.count, by: 450) {
            let batch = firestore.batch()
            for document in snapshot.documents[chunk..<min(chunk + 450, snapshot.documents.count)] {
                batch.deleteDocument(document.reference)
            }
            try await batch.commitAsync()
        }
    }

    private func ensureBootstrapTaskCanContinue(for userID: String) throws {
        guard !Task.isCancelled, currentUserID == userID else {
            throw CancellationError()
        }
    }

    private func presentableSyncMessage(for error: Error) -> String {
        let message = error.localizedDescription
        let normalized = message.lowercased()

        if normalized.contains("missing or insufficient permissions")
            || normalized.contains("permission denied")
        {
            return "Account sync is temporarily unavailable. Your local data stays on this device."
        }

        if normalized.contains("network error") {
            return "Account sync couldn’t reach Firestore. Check the network and try again."
        }

        return message
    }

    private static var platformName: String {
        return "macos"
    }
}
