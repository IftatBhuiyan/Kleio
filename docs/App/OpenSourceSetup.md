# Use your own resources

## Start the local connector

Install Node.js 22 or newer, then in the source checkout:

```sh
cd connector
npm ci
cp .env.example .env
chmod 600 .env
openssl rand -hex 32
```

Edit `.env` locally. Set `OPENAI_API_KEY` to your own provider API key and `KLEIO_ACCESS_TOKEN` to the generated random value. Do not paste either into a GitHub issue or commit. Start with `npm start` and leave that terminal running.

Open Kleio → Settings → Your connection. Use `ws://127.0.0.1:8080` and the **KLEIO_ACCESS_TOKEN**, then save. The backend token is separate from your provider API key. Grant Microphone and Accessibility permissions; hold the dictation shortcut, speak, and release it to transcribe and insert text.

The included connector returns a completed transcript after release; it does not show live partial text. It buffers up to 10 MiB of mono PCM audio and allows a recording up to five minutes (the byte limit can be reached sooner at higher sample rates). Processing has a 60-second provider deadline; local app finalization waits 65 seconds. This trades streaming latency for a small, provider-independent connector.

`TRANSCRIPTION_MODEL` selects an audio transcription model. `CLEANUP_MODEL` selects a chat-completions model for cleanup and output-language translation. Leave cleanup blank to return the provider's transcription unchanged; request matching source/output languages in that mode. The dashboard's cleanup-model picker applies to streaming backends; the local connector deliberately uses its own `.env` model selection. Custom vocabulary is supported by other compatible backends; it is not currently forwarded by this connector.

## Other providers and local inference

Set `OPENAI_BASE_URL` to a trusted OpenAI-compatible server ending in `/v1/`, with its API key and model names. It must implement multipart `POST audio/transcriptions` returning `{ "text": "..." }`. If cleanup is enabled, it must also implement `POST chat/completions`. HTTPS is required except on localhost. A local server that does not require an API key may use an arbitrary nonempty local value. Compatibility varies; a chat-only endpoint cannot transcribe audio.

Provider API access and charges belong to the user. ChatGPT subscriptions and OpenAI API billing are separate: https://help.openai.com/en/articles/9039756-managing-billing-for-chatgpt-and-the-api-platform . No subscription or quota is included with Kleio.

## Connect a streaming backend

Use Settings to enter a trusted `wss://` endpoint and its bearer token. The original hosted Eclipse service is not provided with this release. Do not send provider API keys directly to a WebSocket endpoint unless its documented protocol explicitly requires that.

Kleio protocol v1 exchanges JSON with `v: 1` and `type`. Client messages are `session_start`, `audio_chunk` (base64 signed 16-bit little-endian mono PCM), `session_end`, and `ping`. A server acknowledges `session_start` with `session_started` and matching `client_session_id`, may send cumulative `partial_text`, and completes with `final_text`, `text`, `raw_text`, and `is_canonical: true`. Reply to `ping` with `pong`. Send failures as `error` with `message`. See `Core/Dictation/Models/RealtimeMessage.swift` for fields and `connector/server.mjs` for a minimal implementation. Remote streaming backends should finalize within eight seconds.

## Optional accounts

No account is needed for public builds. To enable accounts on a developer build, create your own Firebase project and macOS app, place your downloaded `GoogleService-Info.plist` in `WhisperSpeech/` (gitignored), and configure authentication providers and Firestore rules for that project. Set your own Google reversed-client-ID URL scheme and Apple Sign-In capability/team if using those providers. Do not restore Eclipse's configuration or deploy rules to Eclipse's project. See `firebase/firestore.rules` as a starting point; review and test rules for your deployment.

## License and distribution

Kleio's original source is GPL-3.0-only; third-party components retain their licenses. When distributing a binary, provide its exact corresponding source, build/installation instructions, license, and dependency notices. Keep modifications under GPL-3.0-only when distributing the combined work. Hosting a provider service does not grant rights to its code, branding, models, or subscription. See the full root `LICENSE` and `THIRD-PARTY-NOTICES.md`.
