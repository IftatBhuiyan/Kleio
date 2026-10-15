import AuthenticationServices
import SwiftUI
#if canImport(GoogleSignIn)
import GoogleSignIn
#endif
#if canImport(GoogleSignInSwift)
import GoogleSignInSwift
#endif

struct AccountGoogleButton: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AccountAuthButtonLabel(
                title: title,
                foreground: colorScheme == .dark ? .black : .white
            ) {
                AccountGoogleLogoMark()
            }
        }
        .buttonStyle(AccountOnboardingFilledButtonStyle())
        .accessibilityLabel(title)
    }
}

struct AccountEmailButton: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AccountAuthButtonLabel(
                title: title,
                foreground: colorScheme == .dark ? .black : .white
            ) {
                Image(systemName: "envelope.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(colorScheme == .dark ? .black : .white)
                    .frame(width: AccountAuthButtonMetrics.iconFrame, height: AccountAuthButtonMetrics.iconFrame)
            }
        }
        .buttonStyle(AccountOnboardingFilledButtonStyle())
        .accessibilityLabel(title)
    }
}

struct AccountAppleButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var coordinator = AccountAppleSignInCoordinator()

    let title: String
    let onRequest: (ASAuthorizationAppleIDRequest) -> Void
    let onCompletion: (Result<ASAuthorization, Error>) -> Void

    var body: some View {
        Button {
            coordinator.start(onRequest: onRequest, onCompletion: onCompletion)
        } label: {
            AccountAuthButtonLabel(
                title: title,
                foreground: colorScheme == .dark ? .black : .white,
                iconSpacing: 8
            ) {
                Image(systemName: "applelogo")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(colorScheme == .dark ? .black : .white)
                    .frame(width: 22, height: 22)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .frame(height: AccountAuthButtonMetrics.height)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(colorScheme == .dark ? Color.white : Color.black)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.18),
                    lineWidth: 1.5
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityLabel(title)
    }
}

private final class AccountAppleSignInCoordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var controller: ASAuthorizationController?
    private var completion: ((Result<ASAuthorization, Error>) -> Void)?
    private var anchor: ASPresentationAnchor?
    private var isRequestInProgress = false

    @MainActor
    func start(
        onRequest: (ASAuthorizationAppleIDRequest) -> Void,
        onCompletion: @escaping (Result<ASAuthorization, Error>) -> Void
    ) {
        guard !isRequestInProgress else {
            return
        }

        guard let anchor = resolvePresentationAnchor() else {
            onCompletion(.failure(SessionManagerError.missingPresentationAnchor))
            return
        }

        let request = ASAuthorizationAppleIDProvider().createRequest()
        onRequest(request)

        let controller = ASAuthorizationController(authorizationRequests: [request])
        self.anchor = anchor
        self.completion = onCompletion
        self.controller = controller
        self.isRequestInProgress = true
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    @MainActor
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        finish(with: .success(authorization))
    }

    @MainActor
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        finish(with: .failure(error))
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        precondition(anchor != nil, "Apple Sign-In requires a presentation anchor")
        return anchor!
    }

    @MainActor
    private func resolvePresentationAnchor() -> ASPresentationAnchor? {
        PlatformPresentationResolver.keyWindow()
    }

    private func finish(with result: Result<ASAuthorization, Error>) {
        completion?(result)
        completion = nil
        controller = nil
        anchor = nil
        isRequestInProgress = false
    }
}

private enum AccountAuthButtonMetrics {
    static let height: CGFloat = 64
    static let titleFontSize: CGFloat = 20
    static let titleSpacing: CGFloat = 10
    static let iconFrame: CGFloat = 20
}

private struct AccountAuthButtonLabel<Icon: View>: View {
    let title: String
    let foreground: Color
    var iconSpacing: CGFloat = AccountAuthButtonMetrics.titleSpacing
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        HStack(spacing: iconSpacing) {
            icon()
            Text(title)
                .font(.system(size: AccountAuthButtonMetrics.titleFontSize, weight: .semibold, design: .rounded))
                .foregroundStyle(foreground)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

struct AccountOnboardingFilledButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 18)
            .frame(height: AccountAuthButtonMetrics.height)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(buttonBackground.opacity(configuration.isPressed ? 0.9 : 1))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(buttonBorder, lineWidth: 1.5)
            }
    }

    private var buttonBackground: Color {
        colorScheme == .dark ? .white : .black
    }

    private var buttonBorder: Color {
        colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.18)
    }
}

struct AccountPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 18)
            .frame(height: 56)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(AccountTheme.accent.opacity(configuration.isPressed ? 0.82 : 0.96))
            )
    }
}

private struct AccountGoogleLogoMark: View {
    var body: some View {
        if let image = AccountGoogleBranding.logoImage {
            image
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: AccountAuthButtonMetrics.iconFrame, height: AccountAuthButtonMetrics.iconFrame)
        } else {
            Text("G")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.blue, .green, .orange, .red],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: AccountAuthButtonMetrics.iconFrame, height: AccountAuthButtonMetrics.iconFrame)
        }
    }
}

private enum AccountGoogleBranding {
    static var logoImage: Image? {
        guard let url = googleResourceURL(named: "google", withExtension: "png") else {
            return nil
        }

        guard let nsImage = NSImage(contentsOfFile: url.path) else {
            return nil
        }
        return Image(nsImage: nsImage)
    }

    private static func googleResourceURL(named name: String, withExtension ext: String) -> URL? {
        #if canImport(GoogleSignIn)
        let bundleNames = ["GoogleSignIn_GoogleSignIn", "GoogleSignIn"]

        for bundleName in bundleNames {
            if let mainPath = Bundle.main.path(forResource: bundleName, ofType: "bundle"),
               let bundle = Bundle(path: mainPath),
               let url = bundle.url(forResource: name, withExtension: ext) {
                return url
            }

            let classBundle = Bundle(for: GIDSignIn.self)
            if let classPath = classBundle.path(forResource: bundleName, ofType: "bundle"),
               let bundle = Bundle(path: classPath),
               let url = bundle.url(forResource: name, withExtension: ext) {
                return url
            }
        }
        #endif

        return nil
    }
}
