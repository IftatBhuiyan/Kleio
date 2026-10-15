# Dictation System Overview

## Purpose

Kleio is a macOS dictation app backed by a local or hosted realtime websocket backend.
(The iOS host app, keyboard extension, and Live Activity were removed in October 2026.)

The system is designed to keep dictation fast, preserve enough transcript detail for debugging and review, and let platform-specific clients inject or display the result in the right place.

## High-Level Architecture

### Shared client core

The shared app target contains the dictation core:

- `DictationCoordinator`
- `RealtimeWebSocketClient`
- `AudioCaptureService`
- `AppConfiguration`
- SwiftData history persistence

This layer owns:

- websocket lifecycle
- microphone streaming
- partial transcript state
- canonical final transcript handling
- legacy cleanup-message compatibility during rollout
- history persistence callbacks
- dictionary vocabulary injection

### macOS

The macOS app provides:

- global hold-to-talk / toggle-to-talk hotkeys
- Accessibility-based paste injection into the focused app
- analytics and history views
- style selection

macOS injects the finalized transcript by:

1. waiting for canonical cleaned text
2. updating the clipboard with that canonical text
3. synthesizing paste into the frontmost app once
4. surfacing an error instead of pasting raw text when cleanup fails

## Realtime Session Flow

### Session start

When dictation starts, the client sends:

- prompt text
- prompt profile
- sample rate
- approved custom vocabulary

Approved vocabulary feeds both:

- Deepgram keyword biasing
- cleanup prompt context

### Audio streaming

Captured PCM audio is base64-encoded and sent over websocket as `audio_chunk`.

### Finalization

When the client sends `session_end`, the backend:

1. waits for the final STT transcript
2. runs cleanup/style processing
3. validates that the result is still safe and meaningfully cleaned
4. emits one canonical `final_text` payload or an `error`

## Transcript Layers

Kleio intentionally keeps more than one transcript representation.

### 1. Rough raw STT transcript

This is the least-formatted Deepgram STT transcript saved for history review.

Properties:

- derived directly from final Deepgram `is_final` STT output
- intentionally rougher than the final display text
- preserves filler words when Deepgram hears them
- does not run Kleio numeral formatting or Groq cleanup
- is still normal ASR word recognition, not a phonetic or phoneme-level dump
- preserved for debugging, auditing, and comparison
- stored in history as `rawText`

### 2. Cleaned transcript

This is the canonical post-processed transcript produced by the cleanup model.

Properties:

- grammar, punctuation, capitalization, and style cleanup applied
- preserves wording and intent as much as possible
- stored as the final history `finalText`
- is the only successful finalized output shown to users or injected into other apps

## Websocket Message Semantics

### `final_text`

Canonical finalization payload.

Fields:

- `text`: cleaned and styled transcript
- `raw_text`: least-formatted Deepgram raw STT transcript before cleanup
- `is_canonical`: `true`

Client behavior:

- finalize the session
- persist the cleaned text plus raw transcript for history
- inject only the cleaned text into other apps

### Legacy compatibility

Older backends may still send `transcript_correction`.

Current clients still accept that message during rollout, but the canonical contract going forward is a single successful `final_text` payload or an `error`.

## Style Presets

Style presets are selected in app configuration and applied per session.

Current presets:

- Default
- Professional
- Email
- Casual
- Very Casual
- Excited

Important detail:

- each saved history row stores the style snapshot used when that dictation session began
- changing the global default later does not change existing history rows

The style snapshot is shown in the dictation detail view.

## Dictionary System

The dictionary system has two layers:

### Active Terms

Approved terms that are sent into the next session’s `custom_vocabulary`.

Examples:

- names
- company jargon
- product names
- recurring phrases

### Suggested Terms

Auto-learned candidates that wait in a review queue. The macOS app has no review UI,
so suggestions are not promoted to active terms from the Mac.

Auto-learn behavior:

- based on repeated finalized dictations
- uses final text as primary evidence
- uses raw transcript as supporting evidence
- requires approval before becoming active

Manual terms:

- become active immediately
- are available to the next dictation session

## History Persistence

History is stored in SwiftData as `DictationHistoryEntry`.

Each row can contain:

- session ID
- timestamp
- cleaned/final text
- raw STT
- style preset snapshot
- duration
- word count
- words per minute
- source app metadata

Persistence behavior:

- a history row is saved only after canonical cleanup succeeds
- cleanup failure does not persist raw text as a successful dictation
- older rows may not have raw STT or style metadata

## Detail Views

### macOS

The dictation detail modal (opened from Overview and Dictations) shows:

- style used
- cleaned text
- raw STT
- deterministic status based on the preset that processed the dictation

Copy actions use the cleaned transcript as the main user-facing result.

## macOS Injection Flow

macOS relies on Accessibility-based paste injection.

Flow:

1. partial text can update on-screen session state while dictation is running
2. clipboard and paste injection wait for canonical cleaned text
3. cleanup failure results in an error instead of raw-text injection
4. the app never pastes a provisional raw transcript as a successful result

## Known Constraints

- older history rows may not have raw transcript or style metadata
- STT and cleanup quality depend on backend/provider behavior and prompt design
- vocabulary changes affect future sessions, not the session already in progress

## Manual Validation Checklist

At a minimum, validate:

1. macOS paste injection
2. per-session style snapshot persistence
3. raw vs cleaned transcript fidelity

For detailed test flows, also see:

- [DictationManualValidation.md](./DictationManualValidation.md)
