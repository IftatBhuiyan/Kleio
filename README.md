# Kleio

Kleio is a native **macOS** dictation app focused on low-latency speech-to-text with real-time cleanup and universal text injection.

**GPL-3.0-only · macOS 15.6+ · bring your own provider.** No Eclipse account or paid Kleio subscription is required. The public build starts locally; connect your own API resources using the included connector or a compatible streaming backend.

Download builds from this repository's **Releases** page when available. Check the release's architecture, signing/notarization status, and SHA256 before installing. Source builds are supported below. The local connector transcribes after you release the shortcut; streaming previews require a streaming backend.

## What’s in this repo

One app target, `WhisperSpeech` (product **Kleio**, bundle id `com.EclipseStudio.Kleio`):

- menu bar / dock app with a global dictation hotkey and a floating dictation pill
- realtime streaming dictation with server-side cleanup styles
- Accessibility-based text insertion into the frontmost app
- a dashboard window: Overview, Dictations, Styles, Analytics, Settings

The iOS app, keyboard extension, and Live Activity were removed in October 2026; they remain in git history at or before commit `3e7a5551`.

## Tech stack

- **Swift + SwiftUI**
- **AVFoundation** (microphone capture)
- **URLSessionWebSocketTask** (realtime transport)
- **SwiftData** (local history persistence)
- CoreGraphics event tap (global hotkeys), Accessibility APIs (text injection)
- Optional Firebase Auth + Firestore (developer-configured accounts and settings sync; no Firebase project ships with public builds)

## Project structure

- `WhisperSpeech/Core/` — dictation pipeline, audio capture, websocket client, auth/sync, configuration
- `WhisperSpeech/Platform/macOS/` — dashboard, dictation pill, hotkeys, text injection, audio import
- `WhisperSpeech/Platform/Shared/Auth/` — sign-in flow
- `WhisperSpeech.xcodeproj/` — Xcode project
- `script/` — build/package helpers for a standalone `dist/Kleio.app`
- `connector/` — loopback-only adapter for your own OpenAI-compatible transcription/cleanup API

## Docs

- [Docs hub](./docs/README.md)
- [Dictation System Overview](./docs/App/DictationSystemOverview.md)
- [Dictation Manual Validation](./docs/App/DictationManualValidation.md)

## Backend

Start with [Use your own resources](./docs/App/OpenSourceSetup.md). Install Node.js 22+, configure `connector/.env` with your own API key and random backend access token, run `npm ci` and `npm start` in `connector/`, then save the endpoint and backend token in **Settings → Your connection**. No personal keys are distributed. API usage charges belong to the user; a ChatGPT subscription does not include API billing.

The default endpoint is `ws://127.0.0.1:8080`. Remote backends require `wss://`. Existing installations retain their saved endpoint; review it in Settings before dictating. The original Eclipse backend is not included or promised as a public service.

## Build & run (macOS)

1. Open `WhisperSpeech.xcodeproj` in Xcode.
2. Select the `WhisperSpeech` scheme.
3. Build and run on macOS.
4. Grant permissions when prompted / required:
   - Microphone
   - Accessibility (required for automated paste/text injection)

Command-line build (Xcode 26+, from the repository root):

```sh
xcodebuild -project WhisperSpeech.xcodeproj -scheme WhisperSpeech -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/kleio-build/dd CODE_SIGNING_ALLOWED=NO build
```

For a locally signed app use `CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=""` instead of `CODE_SIGNING_ALLOWED=NO`. For distribution, use your own Developer ID and notarize the archive. `CONFIGURATION=Release script/build_and_package_macos.sh` builds a local ZIP; this does not notarize it. Quit another Kleio instance before launching a development build because the local database supports only one instance.

### macOS permissions checklist

- **Microphone**: required to capture audio.
- **Accessibility**: required to synthesize Cmd+V and inject text into the frontmost app.

If paste injection doesn’t work, open **System Settings → Privacy & Security → Accessibility** and enable Kleio.

## Realtime protocol notes

- The app/server uses a **versioned** realtime envelope: `v: 1`.

## Security & privacy

Kleio sends audio to your configured backend and providers. The local connector keeps audio only in memory and never logs or stores transcripts. New installations enable Privacy Mode and disable improvement sharing. Provider retention policies still apply. History stays on your Mac; final text passes through the clipboard. Read [SECURITY.md](./SECURITY.md) before using sensitive content.

## License and contributions

Kleio's original code is licensed under [GNU GPL version 3 only](./LICENSE). Dependencies retain their own licenses; see [THIRD-PARTY-NOTICES.md](./THIRD-PARTY-NOTICES.md). Binary distributions must include the matching source and notices. Eclipse Studios branding is not a grant of trademark rights.

Contributions are welcome through pull requests. See [CONTRIBUTING.md](./CONTRIBUTING.md) for development, review, and privacy requirements. Report vulnerabilities privately through GitHub's Security tab.
