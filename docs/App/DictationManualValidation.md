# Real-Time Dictation Manual Validation Checklist

## Setup
- Launch the app and confirm menu bar icon appears.
- Open Settings and set a valid backend `wss://` URL.
- Confirm microphone permission prompt appears and is granted.
- Enable Accessibility permission for the app in macOS System Settings.

## Connection Warm-Up
- With app idle, verify connection state becomes `Connected`.
- Disable network briefly and confirm status shows reconnecting/error, then recovers.

## Push-to-Talk
- Set shortcut to `Option (hold)` and hold/release once.
- Confirm state transitions: `Idle -> Listening -> Processing -> Idle`.
- Repeat for `Right Option (hold)` and `Command + Shift (hold)`.

## Incremental Dictation
- Dictate a sentence with correction:
  - "Send the email to John, actually wait, send it to Sarah."
- Verify `Current text` updates during streaming and `Last final text` contains only final intent.

## Universal Paste Injection
- Focus a text field in Cursor, then dictate and release.
- Repeat in Chrome and Slack.
- Confirm final polished text is pasted in the active app.

## Latency Spot Check
- Perform at least 10 short dictations.
- Check `Last latency` and ensure perceived turnaround stays near sub-500ms target.
