import Foundation

enum AccountProvider: String, CaseIterable, Identifiable, Sendable {
    case apple = "apple.com"
    case google = "google.com"
    case emailPassword = "password"
    case anonymous = "anonymous"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple:
            return "Apple"
        case .google:
            return "Google"
        case .emailPassword:
            return "Email"
        case .anonymous:
            return "Local Only"
        }
    }
}

enum AccountSyncState: Equatable {
    case idle
    case localOnly
    case syncing
    case synced
    case failed(String)

}

enum EmailAuthMode: Equatable {
    case signIn
    case createAccount
    case linkPassword

    var title: String {
        switch self {
        case .signIn:
            return "Sign In with Email"
        case .createAccount:
            return "Create Email Account"
        case .linkPassword:
            return "Continue with Email"
        }
    }

    var submitTitle: String {
        switch self {
        case .signIn:
            return "Sign In"
        case .createAccount:
            return "Create Account"
        case .linkPassword:
            return "Continue"
        }
    }
}

enum AccountAuthRoute: Hashable {
    case email(mode: EmailAuthMode)
}

struct AccountSessionSnapshot: Equatable, Sendable {
    let uid: String
    let email: String?
    let displayName: String?
    let isEmailVerified: Bool
    let isAnonymous: Bool
    let providerIDs: [String]
    let deviceID: String

    var providers: [AccountProvider] {
        let mapped = providerIDs.compactMap(AccountProvider.init(rawValue:))
        if isAnonymous {
            return [.anonymous]
        }
        return mapped.sorted { $0.displayName < $1.displayName }
    }

    var primaryLabel: String {
        if let displayName, !displayName.isEmpty {
            return displayName
        }
        if let email, !email.isEmpty {
            return email
        }
        if isAnonymous {
            return "Local-only mode"
        }
        return "Account"
    }

    /// First word of the display name, for greetings. Never derived from the email
    /// address — greeting someone by "jane.doe@gmail.com" reads as broken.
    var firstName: String? {
        guard let displayName else { return nil }
        let first = displayName.split(separator: " ").first.map(String.init)
        return (first?.isEmpty == false) ? first : nil
    }

    func hasProvider(_ provider: AccountProvider) -> Bool {
        if provider == .anonymous {
            return isAnonymous
        }
        return providerIDs.contains(provider.rawValue)
    }
}

enum SessionPhase: Equatable {
    case launching
    case needsOnboarding
    case ready(AccountSessionSnapshot?)
}

enum SessionManagerError: LocalizedError {
    case missingIdentityToken
    case missingGoogleClientID
    case missingPresentationAnchor
    case unsupportedCredential
    case noCurrentUser
    case requiresRecentSignInForDeletion

    var errorDescription: String? {
        switch self {
        case .missingIdentityToken:
            return "We couldn't verify the account with the identity provider."
        case .missingGoogleClientID:
            return "Google Sign-In is not configured correctly in this app build."
        case .missingPresentationAnchor:
            return "Kleio couldn't find a valid window to present the sign-in flow."
        case .unsupportedCredential:
            return "This sign-in credential is not supported."
        case .noCurrentUser:
            return "No active account session is available."
        case .requiresRecentSignInForDeletion:
            return "Please sign in again before deleting this account."
        }
    }
}
