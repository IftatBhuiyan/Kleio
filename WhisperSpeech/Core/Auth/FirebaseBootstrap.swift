import FirebaseCore
import Foundation

enum FirebaseBootstrap {
    private static var didConfigure = false

    static func configureIfNeeded() {
        guard !didConfigure else { return }
        // Accounts are optional. Public builds ship without a Firebase project.
        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
              let options = FirebaseOptions(contentsOfFile: path) else { return }
        if FirebaseApp.app() == nil { FirebaseApp.configure(options: options) }
        didConfigure = true
    }

    static var isConfigured: Bool { FirebaseApp.app() != nil }
}
