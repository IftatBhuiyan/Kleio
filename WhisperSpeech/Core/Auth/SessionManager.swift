import AuthenticationServices
import Combine
import CryptoKit
import FirebaseAuth
import FirebaseCore
import Foundation
import Security
import os
#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

@MainActor
final class SessionManager: ObservableObject {
    private static let logger = Logger(subsystem: "com.eclipsestudio.kleio", category: "session")

    private func sendVerificationEmail(to user: User) async {
        do {
            try await user.sentEmailVerification()
        } catch {
            Self.logger.error("verification email failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    private enum ActionContext {
        case generic
        case deleteAccount
    }

    @Published private(set) var phase: SessionPhase = .launching
    @Published private(set) var currentSession: AccountSessionSnapshot?
    @Published private(set) var syncState: AccountSyncState = .idle
    @Published private(set) var isBusy = false
    @Published var lastErrorMessage: String?

    var clearLocalHistoryHandler: ((String) -> Void)?

    private let configuration: AppConfiguration
    private let identityStore: AppIdentityStore
    private let configuredAuth: Auth?
    private var auth: Auth { configuredAuth! }
    private var authStateHandle: AuthStateDidChangeListenerHandle?
    private var tokenRefreshTimer: Timer?
    private var accountSyncService: AccountSyncService?
    private var pendingAppleNonce: String?
    private var pendingAppleLinkOnly = false
    private var didStart = false

    init(
        configuration: AppConfiguration,
        identityStore: AppIdentityStore? = nil,
        auth: Auth? = nil
    ) {
        FirebaseBootstrap.configureIfNeeded()
        self.configuration = configuration
        self.identityStore = identityStore ?? AppIdentityStore()
        self.configuredAuth = auth ?? (FirebaseBootstrap.isConfigured ? Auth.auth() : nil)
    }

    func attach(dictionaryStore: DictionaryStore) {
        guard configuredAuth != nil else { return }
        accountSyncService = AccountSyncService(
            configuration: configuration,
            dictionaryStore: dictionaryStore,
            identityStore: identityStore
        ) { [weak self] state in
            guard let self else { return }
            self.syncState = state
            self.objectWillChange.send()
        }
    }

    func start() {
        guard !didStart else { return }
        didStart = true

        guard configuredAuth != nil else {
            identityStore.hasAuthenticatedAccount = false
            syncState = .localOnly
            phase = .ready(nil)
            return
        }

        FirebaseBootstrap.configureIfNeeded()

        authStateHandle = auth.addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor [weak self] in
                self?.handleAuthStateChange(user)
            }
        }

        if auth.currentUser == nil {
            identityStore.hasAuthenticatedAccount = false
            phase = .needsOnboarding
        } else {
            handleAuthStateChange(auth.currentUser)
        }
    }

    func signInWithEmail(email: String, password: String) async {
        await perform {
            _ = try await self.auth.signedIn(email: email, password: password)
            self.identityStore.didCompleteWelcomeFlow = true
        }
    }

    func createAccountWithEmail(email: String, password: String) async {
        await perform {
            let credential = EmailAuthProvider.credential(withEmail: email, password: password)

            if let currentUser = self.auth.currentUser {
                if currentUser.isAnonymous || !self.hasEmailProvider {
                    let result = try await currentUser.linked(with: credential)
                    await self.sendVerificationEmail(to: result.user)
                } else {
                    let result = try await self.auth.createdUser(email: email, password: password)
                    await self.sendVerificationEmail(to: result.user)
                }
            } else {
                let result = try await self.auth.createdUser(email: email, password: password)
                await self.sendVerificationEmail(to: result.user)
            }

            self.identityStore.didCompleteWelcomeFlow = true
        }
    }

    func linkPassword(email: String, password: String) async {
        await perform {
            guard let currentUser = self.auth.currentUser else {
                throw SessionManagerError.noCurrentUser
            }
            let credential = EmailAuthProvider.credential(withEmail: email, password: password)
            _ = try await currentUser.linked(with: credential)
        }
    }

    func sendPasswordReset(email: String) async {
        await perform {
            try await self.auth.sentPasswordReset(email: email)
        }
    }

    func signOutToLocalMode() async {
        await perform {
            let ownerProfileIDToClear = self.currentSession?.uid
            self.accountSyncService?.stop()
            self.stopTokenRefreshTimer()
            self.configuration.setSessionAuthToken("")
            self.lastErrorMessage = nil

            #if canImport(GoogleSignIn)
            GIDSignIn.sharedInstance.signOut()
            #endif

            try self.auth.signOut()
            if let ownerProfileIDToClear {
                self.clearLocalHistoryHandler?(ownerProfileIDToClear)
            }
            self.handleAuthStateChange(nil)
        }
    }

    func deleteCurrentAccount() async {
        await perform(context: .deleteAccount) {
            guard let currentUser = self.auth.currentUser else {
                throw SessionManagerError.noCurrentUser
            }
            guard let session = self.currentSession else {
                throw SessionManagerError.noCurrentUser
            }
            let ownerProfileIDToClear = session.uid
            try self.ensureDeleteAccountSessionIsFresh(for: currentUser)
            self.accountSyncService?.stop()
            self.stopTokenRefreshTimer()
            self.configuration.setSessionAuthToken("")
            try await self.accountSyncService?.deleteRemoteAccountData(for: session)
            try await currentUser.deleted()
            self.clearLocalHistoryHandler?(ownerProfileIDToClear)
            self.handleAuthStateChange(nil)
        }
    }

    #if canImport(GoogleSignIn)
    func signInWithGoogle(linkOnly: Bool = false) async {
        await perform {
            guard let clientID = FirebaseApp.app()?.options.clientID else {
                throw SessionManagerError.missingGoogleClientID
            }

            let signIn = GIDSignIn.sharedInstance
            signIn.configuration = GIDConfiguration(clientID: clientID)

            guard let presenter = PlatformPresentationResolver.keyWindow() else {
                throw SessionManagerError.missingPresentationAnchor
            }
            let result = try await signIn.signIn(withPresenting: presenter)

            guard
                let idToken = result.user.idToken?.tokenString,
                !idToken.isEmpty
            else {
                throw SessionManagerError.missingIdentityToken
            }

            let credential = GoogleAuthProvider.credential(
                withIDToken: idToken,
                accessToken: result.user.accessToken.tokenString
            )
            try await self.applyProviderCredential(credential, linkOnly: linkOnly)
            self.identityStore.didCompleteWelcomeFlow = true
        }
    }
    #endif

    func configureAppleSignInRequest(_ request: ASAuthorizationAppleIDRequest, linkOnly: Bool = false) {
        let nonce = randomNonceString()
        pendingAppleNonce = nonce
        pendingAppleLinkOnly = linkOnly
        request.requestedScopes = [.fullName, .email]
        request.nonce = sha256(nonce)
    }

    func handleAppleSignInCompletion(_ result: Result<ASAuthorization, Error>) {
        Task {
            await perform {
                guard let nonce = self.pendingAppleNonce else {
                    throw SessionManagerError.missingIdentityToken
                }

                self.pendingAppleNonce = nil
                defer { self.pendingAppleLinkOnly = false }

                var authorization: ASAuthorization
                switch result {
                case .success(let resolvedAuthorization):
                    authorization = resolvedAuthorization
                case .failure(let error):
                    throw error
                }

                guard
                    let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                    let tokenData = credential.identityToken,
                    let tokenString = String(data: tokenData, encoding: .utf8)
                else {
                    throw SessionManagerError.missingIdentityToken
                }

                let firebaseCredential = OAuthProvider.appleCredential(
                    withIDToken: tokenString,
                    rawNonce: nonce,
                    fullName: credential.fullName
                )

                try await self.applyProviderCredential(firebaseCredential, linkOnly: self.pendingAppleLinkOnly)
                self.identityStore.didCompleteWelcomeFlow = true
            }
        }
    }

    var hasEmailProvider: Bool {
        currentSession?.hasProvider(.emailPassword) == true
    }

    var currentOwnerProfileID: String {
        guard let currentSession, !currentSession.isAnonymous else {
            return identityStore.localProfileID
        }
        return currentSession.uid
    }

    var localOnlyProfileID: String {
        identityStore.localProfileID
    }

    #if canImport(GoogleSignIn)
    func handleIncomingURL(_ url: URL) -> Bool {
        guard configuredAuth != nil else { return false }
        return GIDSignIn.sharedInstance.handle(url)
    }
    #else
    func handleIncomingURL(_ url: URL) -> Bool {
        false
    }
    #endif

    private func handleAuthStateChange(_ user: User?) {
        guard let user else {
            currentSession = nil
            identityStore.hasAuthenticatedAccount = false
            configuration.setSessionAuthToken("")
            stopTokenRefreshTimer()
            accountSyncService?.stop()
            syncState = .idle
            phase = .needsOnboarding
            return
        }

        if user.isAnonymous {
            currentSession = nil
            identityStore.hasAuthenticatedAccount = false
            configuration.setSessionAuthToken("")
            stopTokenRefreshTimer()
            accountSyncService?.stop()
            syncState = .idle
            try? auth.signOut()
            phase = .needsOnboarding
            return
        }

        let snapshot = makeSessionSnapshot(from: user)
        currentSession = snapshot
        identityStore.hasAuthenticatedAccount = true
        phase = .ready(snapshot)
        startTokenRefreshTimer()

        Task {
            await refreshBackendToken(forceRefresh: false)
            accountSyncService?.start(for: snapshot)
        }
    }

    /// Force-refreshes the Firebase ID token used as the websocket Bearer token.
    /// Safe to call on wake, before starting dictation, or on a backend policy-violation
    /// close: the resulting token change lifts the client's reconnect suppression via
    /// AppConfiguration's authToken publisher (H-14). No-ops when signed out/anonymous.
    func refreshBackendAuthTokenIfSignedIn(forceRefresh: Bool = true) async {
        guard let currentSession, !currentSession.isAnonymous else { return }
        await refreshBackendToken(forceRefresh: forceRefresh)
    }

    private func refreshBackendToken(forceRefresh: Bool) async {
        guard let user = auth.currentUser else {
            configuration.setSessionAuthToken("")
            return
        }

        do {
            configuration.setSessionAuthToken(
                try await user.refreshedIDToken(forceRefresh: forceRefresh)
            )
        } catch {
            configuration.setSessionAuthToken("")
            lastErrorMessage = friendlyMessage(for: error, context: .generic)
        }
    }

    private func applyProviderCredential(_ credential: AuthCredential, linkOnly: Bool) async throws {
        if let currentUser = auth.currentUser {
            if linkOnly || currentUser.isAnonymous {
                do {
                    _ = try await currentUser.linked(with: credential)
                    return
                } catch {
                    let nsError = error as NSError
                    let authError = AuthErrorCode(rawValue: nsError.code)
                    if currentUser.isAnonymous,
                       authError == .credentialAlreadyInUse || authError == .emailAlreadyInUse {
                        _ = try await auth.signedIn(with: credential)
                        return
                    }
                    throw error
                }
            }
        }

        _ = try await auth.signedIn(with: credential)
    }

    private func makeSessionSnapshot(from user: User) -> AccountSessionSnapshot {
        let providerIDs = user.providerData
            .map(\.providerID)
            .filter { !$0.isEmpty }
        return AccountSessionSnapshot(
            uid: user.uid,
            email: user.email,
            displayName: user.displayName,
            isEmailVerified: user.isEmailVerified,
            isAnonymous: user.isAnonymous,
            providerIDs: providerIDs,
            deviceID: identityStore.stableDeviceID
        )
    }

    private func startTokenRefreshTimer() {
        stopTokenRefreshTimer()
        tokenRefreshTimer = Timer.scheduledTimer(withTimeInterval: 45 * 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refreshBackendToken(forceRefresh: true)
            }
        }
    }

    private func stopTokenRefreshTimer() {
        tokenRefreshTimer?.invalidate()
        tokenRefreshTimer = nil
    }

    private func perform(
        context: ActionContext = .generic,
        _ operation: @escaping @MainActor () async throws -> Void
    ) async {
        guard configuredAuth != nil else {
            lastErrorMessage = "Accounts are not configured in this build. Use your own backend in Settings."
            return
        }
        guard !isBusy else { return }
        isBusy = true
        lastErrorMessage = nil
        defer { isBusy = false }

        do {
            try await operation()
        } catch {
            guard !isDismissedAuthFlowError(error) else {
                lastErrorMessage = nil
                return
            }
            lastErrorMessage = friendlyMessage(for: error, context: context)
        }
    }

    private func ensureDeleteAccountSessionIsFresh(for user: User) throws {
        guard let lastSignInDate = user.metadata.lastSignInDate else { return }
        let freshnessWindow: TimeInterval = 5 * 60
        guard Date().timeIntervalSince(lastSignInDate) <= freshnessWindow else {
            throw SessionManagerError.requiresRecentSignInForDeletion
        }
    }

    private func friendlyMessage(for error: Error, context: ActionContext) -> String {
        let nsError = error as NSError
        if nsError.domain == AuthErrorDomain,
           let code = AuthErrorCode(rawValue: nsError.code) {
            switch code {
            case .wrongPassword, .invalidCredential:
                return "That email or password doesn’t look right."
            case .userNotFound:
                return "We couldn’t find an account for that email."
            case .emailAlreadyInUse:
                return "That email is already tied to another sign-in method."
            case .accountExistsWithDifferentCredential:
                return "This email already uses a different sign-in method. Sign in with that provider instead."
            case .networkError:
                return "Kleio couldn't reach the network. Try again in a moment."
            case .userTokenExpired:
                return "Your session expired. Please sign in again to continue."
            case .requiresRecentLogin:
                return "Please sign in again before deleting this account."
            case .adminRestrictedOperation, .operationNotAllowed:
                return "This Firebase sign-in method is disabled for the current project."
            default:
                return nsError.localizedDescription
            }
        }

        let normalized = nsError.localizedDescription.lowercased()
        if normalized.contains("missing or insufficient permissions")
            || normalized.contains("permission denied")
        {
            switch context {
            case .deleteAccount:
                return "Account deletion is temporarily unavailable. Your local data on this device is still safe."
            case .generic:
                return "Kleio couldn’t finish that account request right now. Please try again in a moment."
            }
        }

        return nsError.localizedDescription
    }

    private func isDismissedAuthFlowError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        let normalized = nsError.localizedDescription.lowercased()

        if nsError.domain == "com.apple.AuthenticationServices.AuthorizationError",
           nsError.code == 1001 {
            return true
        }

        if normalized.contains("user canceled the sign-in flow")
            || normalized.contains("user cancelled the sign-in flow")
            || normalized.contains("authorizationerror error 1001")
        {
            return true
        }

        return false
    }

    private func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = length

        while remainingLength > 0 {
            let randoms: [UInt8] = (0..<16).map { _ in
                var random: UInt8 = 0
                let status = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
                if status != errSecSuccess {
                    fatalError("Unable to generate nonce. OSStatus \(status)")
                }
                return random
            }

            randoms.forEach { random in
                if remainingLength == 0 {
                    return
                }

                if random < charset.count {
                    result.append(charset[Int(random)])
                    remainingLength -= 1
                }
            }
        }

        return result
    }

    private func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashedData = SHA256.hash(data: inputData)
        return hashedData.map { String(format: "%02x", $0) }.joined()
    }

    deinit {
        tokenRefreshTimer?.invalidate()
        if let authStateHandle {
            configuredAuth?.removeStateDidChangeListener(authStateHandle)
        }
    }
}
