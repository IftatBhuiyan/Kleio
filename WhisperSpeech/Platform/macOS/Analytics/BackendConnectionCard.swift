import SwiftUI

/// Connection settings stay local; provider API keys belong in the user's connector.
struct BackendConnectionCard: View {
    @ObservedObject private var configuration = AppConfiguration.shared
    @State private var endpoint = ""
    @State private var token = ""
    @State private var message: String?

    var body: some View {
        KleioCard {
            VStack(alignment: .leading, spacing: 12) {
                KleioSectionTitle("Your connection")
                Text("Connect your own Kleio-compatible backend. Audio and transcripts are sent to that server and its configured providers.")
                    .font(.system(size: 12))
                    .foregroundStyle(KleioPalette.secondary)
                TextField("WebSocket URL", text: $endpoint)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Backend WebSocket URL")
                SecureField("Backend access token", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Backend access token")
                HStack {
                    KleioSecondaryButton(title: "Save connection", systemImage: "checkmark") {
                        let url = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                        do {
                            try RealtimeWebSocketClient().configure(backendURLString: url, authToken: token)
                            configuration.backendAuthTokenOverride = token
                            configuration.backendURL = url
                            message = "Saved. Start dictation to connect. The access token is stored in Keychain."
                        } catch {
                            message = "Use wss:// with a hostname, or ws:// on localhost. Credentials must go in the token field."
                        }
                    }
                    Spacer()
                }
                if let message {
                    Text(message).font(.system(size: 12)).foregroundStyle(KleioPalette.secondary)
                }
                Text("The bundled local connector uses ws://127.0.0.1:8080. Set its API key on your Mac, then paste its KLEIO_ACCESS_TOKEN here. An API account may have separate usage charges.")
                    .font(.system(size: 11))
                    .foregroundStyle(KleioPalette.secondary)
            }
        }
        .onAppear {
            endpoint = configuration.backendURL
            token = configuration.backendAuthTokenOverride
        }
    }
}
