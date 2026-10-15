import Foundation

final class AppIdentityStore {
    private enum DefaultsKey {
        static let didCompleteWelcomeFlow = "auth.welcome.didComplete"
        static let localProfileID = "auth.local.profileID"
        static let uploadDeviceSummariesEnabled = "auth.privacy.uploadDeviceSummariesEnabled"
    }

    // The account flag predates the macOS-only app and lives in this named suite;
    // the suite name and key must stay byte-identical so existing installs keep it.
    private enum SharedDefaults {
        static let suiteName = "group.com.eclipsestudio.whisperspeech"
        static let hasAuthenticatedAccount = "auth.session.hasAuthenticatedAccount"
    }

    private let defaults: UserDefaults
    private let sharedDefaults: UserDefaults
    private let keychain: KeychainStore

    init(
        defaults: UserDefaults = .standard,
        sharedDefaults: UserDefaults = UserDefaults(suiteName: SharedDefaults.suiteName) ?? .standard,
        keychain: KeychainStore = KeychainStore()
    ) {
        self.defaults = defaults
        self.sharedDefaults = sharedDefaults
        self.keychain = keychain
    }

    var stableDeviceID: String {
        if let existing = keychain.string(for: .stableDeviceID), !existing.isEmpty {
            return existing
        }

        let next = UUID().uuidString.lowercased()
        keychain.set(next, for: .stableDeviceID)
        return next
    }

    var didCompleteWelcomeFlow: Bool {
        get { defaults.bool(forKey: DefaultsKey.didCompleteWelcomeFlow) }
        set { defaults.set(newValue, forKey: DefaultsKey.didCompleteWelcomeFlow) }
    }

    var localProfileID: String {
        if let existing = defaults.string(forKey: DefaultsKey.localProfileID), !existing.isEmpty {
            return existing
        }

        let next = "local-\(UUID().uuidString.lowercased())"
        defaults.set(next, forKey: DefaultsKey.localProfileID)
        return next
    }

    var uploadDeviceSummariesEnabled: Bool {
        get { defaults.bool(forKey: DefaultsKey.uploadDeviceSummariesEnabled) }
        set { defaults.set(newValue, forKey: DefaultsKey.uploadDeviceSummariesEnabled) }
    }

    var hasAuthenticatedAccount: Bool {
        get { sharedDefaults.bool(forKey: SharedDefaults.hasAuthenticatedAccount) }
        set { sharedDefaults.set(newValue, forKey: SharedDefaults.hasAuthenticatedAccount) }
    }
}
