# Security

## Reporting

Use **Security → Report a vulnerability** in the public GitHub repository. Do not put secrets, real recordings, private transcripts, or exploit details in public issues. If private reporting is unavailable, open an issue asking for a private reporting channel without disclosing the vulnerability.

This is an early open-source release. Security fixes target the latest published release; there is no support SLA.

## Trust boundaries

- The app sends microphone audio and dictation preferences to the backend selected in Settings. A remote backend must use `wss://`; unencrypted WebSockets are allowed only on loopback. Use only a backend you trust.
- Backend access tokens are stored in macOS Keychain. Provider API keys stay in the local connector's ignored `.env`, never in the app bundle or public source. Protect that file with `chmod 600 connector/.env`.
- The included connector listens only on `127.0.0.1`, requires a random access token, rejects browser origins, limits connections, message size, audio size, recording duration, and provider request time. It is intended for one person's Mac, not public hosting or a multi-tenant service.
- Audio is buffered in memory and uploaded when dictation stops. The connector does not log or persist audio or transcripts. Providers have their own retention and billing policies. Privacy Mode cannot guarantee a third party's behavior.
- SwiftData history stays on the Mac and may contain sensitive text. Use the history retention/deletion controls. Text insertion requires Accessibility access and uses the system clipboard; clipboard managers may retain final text.
- Public builds include no Firebase configuration and work without an account. Account sync remains optional for developers configuring their own Firebase project and rules.

## Publication and releases

Do not make the original private repository/history public. Publish only the reviewed clean snapshot. Scan both the snapshot and packaged app before release. If a credential was ever published, revoke/rotate it: removing it from a later commit does not revoke it.

Release ZIPs must identify signing/notarization status, architecture, macOS minimum, version, SHA256, and the exact corresponding source commit. Never attach an old private build. Do not disable Gatekeeper globally.
