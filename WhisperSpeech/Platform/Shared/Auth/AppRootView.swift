import SwiftUI

struct AppRootView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        accountRoot
    }

    @ViewBuilder
    private var accountRoot: some View {
        switch appModel.sessionManager.phase {
        case .launching:
            AccountLaunchView()
        case .needsOnboarding:
            AccountWelcomeView()
        case .ready:
            ContentView()
        }
    }
}


private struct AccountLaunchView: View {
    var body: some View {
        ZStack {
            AccountTheme.background
                .ignoresSafeArea()

            VStack(spacing: 18) {
                AccountWordmark()
                ProgressView()
                    .controlSize(.large)
                    .tint(AccountTheme.title)
                Text("Preparing your private dictation workspace")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(AccountTheme.subtitle)
            }
            .padding(32)
        }
    }
}

struct AccountWelcomeView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var path: [AccountAuthRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            GeometryReader { geometry in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        AccountWordmark()
                            .padding(.top, geometry.size.height > 820 ? 94 : 76)

                        Spacer(minLength: geometry.size.height > 820 ? 138 : 112)

                        headlineText
                            .frame(maxWidth: 560)

                        Spacer(minLength: geometry.size.height > 820 ? 92 : 74)

                        VStack(spacing: 16) {
                            #if canImport(GoogleSignIn)
                            AccountGoogleButton(title: "Continue with Google") {
                                Task {
                                    await appModel.sessionManager.signInWithGoogle()
                                }
                            }
                            #endif

                            AccountAppleButton(title: "Continue with Apple") {
                                appModel.sessionManager.configureAppleSignInRequest($0)
                            } onCompletion: {
                                appModel.sessionManager.handleAppleSignInCompletion($0)
                            }

                            AccountEmailButton(title: "Continue with Email") {
                                path.append(.email(mode: .signIn))
                            }
                        }
                        .frame(maxWidth: 520)

                        if let lastErrorMessage = visibleErrorMessage {
                            Text(lastErrorMessage)
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(AccountTheme.error)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 520)
                                .padding(.top, 24)
                        }

                        Spacer(minLength: geometry.size.height > 820 ? 96 : 76)

                        AccountLegalFooter()
                            .padding(.bottom, 36)
                    }
                    .padding(.horizontal, 30)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
                .background(AccountTheme.background.ignoresSafeArea())
            }
            .navigationDestination(for: AccountAuthRoute.self) { route in
                switch route {
                case .email(let mode):
                    AccountEmailAuthView(initialMode: mode)
                        .environmentObject(appModel)
                }
            }
        }
        .overlay {
            if appModel.sessionManager.isBusy {
                AccountBusyOverlay()
            }
        }
    }

    private var visibleErrorMessage: String? {
        filteredErrorMessage(appModel.sessionManager.lastErrorMessage)
    }

    private var headlineText: some View {
        (
            Text("Start ")
                .foregroundStyle(AccountTheme.title)
            + Text("typing")
                .foregroundStyle(AccountTheme.brandGold)
            + Text(" faster\nwith your ")
                .foregroundStyle(AccountTheme.title)
            + Text("voice")
                .foregroundStyle(AccountTheme.brandGold)
        )
        .font(.system(size: 32, weight: .regular, design: .serif))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AccountLegalFooter: View {
    var body: some View {
        Text("By continuing, you agree to the Terms of Service and Privacy Policy.")
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(AccountTheme.subtitle)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
    }
}

private func filteredErrorMessage(_ message: String?) -> String? {
    guard let message else { return nil }

    let normalized = message.lowercased()
    if normalized.contains("user canceled the sign-in flow")
        || normalized.contains("user cancelled the sign-in flow")
        || normalized.contains("authorizationerror error 1001")
    {
        return nil
    }

    return message
}

struct AccountEmailAuthView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: AccountEmailAuthField?
    @State private var mode: EmailAuthMode
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""

    init(initialMode: EmailAuthMode) {
        _mode = State(initialValue: initialMode == .linkPassword ? .createAccount : initialMode)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(AccountTheme.title)
                            .frame(width: 54, height: 54)
                            .background(AccountTheme.inputBackground, in: Circle())
                            .overlay {
                                Circle()
                                    .stroke(AccountTheme.border, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }

                AccountWordmark()
                    .padding(.top, 4)

                VStack(spacing: 12) {
                    Text("Use email instead")
                        .font(.system(size: 38, weight: .regular, design: .serif))
                        .foregroundStyle(AccountTheme.title)
                        .multilineTextAlignment(.center)

                    Text("Sign in to your existing account or create a new one. You can switch modes at any time below.")
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(AccountTheme.subtitle)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 620)

                VStack(alignment: .leading, spacing: 18) {
                    Picker("Mode", selection: $mode) {
                        Text("Sign In").tag(EmailAuthMode.signIn)
                        Text("Create Account").tag(EmailAuthMode.createAccount)
                    }
                    .pickerStyle(.segmented)

                    VStack(spacing: 12) {
                        accountField(
                            title: "Email",
                            prompt: "name@example.com",
                            text: $email,
                            field: .email
                        )

                        accountSecureField(
                            title: "Password",
                            prompt: mode == .signIn ? "Enter your password" : "Choose a password",
                            text: $password,
                            field: .password
                        )

                        if mode == .createAccount {
                            accountSecureField(
                                title: "Confirm Password",
                                prompt: "Type your password again",
                                text: $confirmPassword,
                                field: .confirmPassword
                            )
                        }
                    }

                    if mode == .signIn {
                        Button("Send Password Reset Email") {
                            Task {
                                await appModel.sessionManager.sendPasswordReset(
                                    email: normalizedEmail
                                )
                            }
                        }
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(AccountTheme.subtitle)
                        .disabled(normalizedEmail.isEmpty)
                    }

                    Button {
                        submit()
                    } label: {
                        Text(mode.submitTitle)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AccountPrimaryButtonStyle())
                    .disabled(!canSubmit)

                    if let error = visibleErrorMessage {
                        Text(error)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(AccountTheme.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(24)
                .frame(maxWidth: 560)
                .background(AccountTheme.cardBackground, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(AccountTheme.border, lineWidth: 1)
                }

                Spacer(minLength: 28)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .background(AccountTheme.background.ignoresSafeArea())
        .onAppear {
            if focusedField == nil {
                focusedField = .email
            }
        }
        .onChange(of: mode) { _, _ in
            confirmPassword = ""
        }
    }

    private var visibleErrorMessage: String? {
        filteredErrorMessage(appModel.sessionManager.lastErrorMessage)
    }

    private var normalizedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        guard !normalizedEmail.isEmpty, password.count >= 6 else { return false }
        switch mode {
        case .signIn:
            return true
        case .createAccount, .linkPassword:
            return password == confirmPassword
        }
    }

    @ViewBuilder
    private func accountField(
        title: String,
        prompt: String,
        text: Binding<String>,
        field: AccountEmailAuthField
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(AccountTheme.title)
            TextField(prompt, text: text)
                .autocorrectionDisabled()
                .focused($focusedField, equals: field)
                .padding(.horizontal, 16)
                .frame(height: 54)
                .background(AccountTheme.inputBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(AccountTheme.border, lineWidth: 1)
                }
        }
    }

    @ViewBuilder
    private func accountSecureField(
        title: String,
        prompt: String,
        text: Binding<String>,
        field: AccountEmailAuthField
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(AccountTheme.title)
            SecureField(prompt, text: text)
                .focused($focusedField, equals: field)
                .padding(.horizontal, 16)
                .frame(height: 54)
                .background(AccountTheme.inputBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(AccountTheme.border, lineWidth: 1)
                }
        }
    }

    private func submit() {
        Task {
            switch mode {
            case .signIn:
                await appModel.sessionManager.signInWithEmail(
                    email: normalizedEmail,
                    password: password
                )
            case .createAccount, .linkPassword:
                await appModel.sessionManager.createAccountWithEmail(
                    email: normalizedEmail,
                    password: password
                )
            }
        }
    }
}

private struct AccountBusyOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
            ProgressView()
                .controlSize(.large)
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}

struct AccountWordmark: View {
    var body: some View {
        HStack(spacing: 14) {
            Image("Kleio.icon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 46, height: 46)
                .foregroundStyle(AccountTheme.brandGold)
            Text("Kleio")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(AccountTheme.title)
        }
    }
}

enum AccountTheme {
    static var background: LinearGradient {
        return LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                Color(nsColor: .underPageBackgroundColor)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let inputBackground = Color(nsColor: .textBackgroundColor)

    static let border = Color.primary.opacity(0.08)
    static let title = Color.primary
    static let subtitle = Color.secondary
    static let accent = Color.accentColor
    static let brandGold = Color(red: 0.78, green: 0.63, blue: 0.24)
    static let success = Color.green
    static let error = Color.red
}

private enum AccountEmailAuthField: Hashable {
    case email
    case password
    case confirmPassword
}
