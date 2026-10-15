import AppKit
import ApplicationServices
import Carbon.HIToolbox

final class AccessibilityPermissionService {
    func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    func requestIfNeeded(prompt: Bool = true) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func openSystemSettings() {
        guard
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Outcome of a text-injection attempt. Surfaced to callers via
/// `TextInjector.onInjectionResult` so the UI (pill / notice) can react.
/// The `TextInjecting` protocol lives in Core and returns `Void`, so this is a
/// side-channel rather than a return value — AppModel can wire the callback later.
enum TextInjectionResult: Equatable {
    /// Text was inserted directly at the caret via the Accessibility API;
    /// the clipboard was never touched.
    case injectedDirect
    /// Synthetic ⌘V was posted; the text should be in the focused field.
    case injected
    /// Accessibility not granted; text left on the clipboard for manual paste.
    case clipboardOnlyAccessibilityDenied
    /// Secure keyboard entry is active (e.g. Terminal, password field);
    /// synthetic paste can't run. Text left on the clipboard for manual paste.
    case clipboardOnlySecureInput
}

final class TextInjector: TextInjecting {
    private let permissionService: AccessibilityPermissionService

    /// Optional observer for injection outcomes. AppModel/Mac-1 can set this to
    /// surface "copied — paste manually" / "grant Accessibility" notices.
    var onInjectionResult: ((TextInjectionResult) -> Void)?

    /// Pasteboard type marking transient content so clipboard managers skip it.
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Snapshot of the user's pasteboard captured before we wrote a transcript.
    private var pendingRestoreItems: [NSPasteboardItem]?
    /// The last string we wrote ourselves, used to avoid snapshotting our own
    /// transient content when `updateClipboard` immediately precedes `inject`.
    private var lastWrittenText: String?
    /// Cancellable work item that restores the user's clipboard after a paste.
    private var pendingRestoreWorkItem: DispatchWorkItem?
    /// Whether we've already surfaced the Accessibility prompt this app session.
    private var didPromptForAccessibilityThisSession = false
    /// Pasteboard changeCount right after our own transcript write; the restore
    /// only runs if nothing else wrote to the pasteboard in between.
    private var changeCountAfterWrite: Int?
    /// Apps where direct AX insertion reported failure — after two failures the
    /// paste path is used directly for that app.
    private var axInsertionFailuresByApp: [String: Int] = [:]

    private let restoreDelay: TimeInterval = 0.3
    private let maxAXFailuresBeforeFallback = 2

    init(permissionService: AccessibilityPermissionService = AccessibilityPermissionService()) {
        self.permissionService = permissionService
    }

    // MARK: - TextInjecting

    func inject(text: String) {
        guard !text.isEmpty else { return }

        // Capture the user's clipboard before we overwrite it, so the paste path
        // can restore it afterwards.
        captureSnapshotIfExternal()

        // No Accessibility → we can't post a synthetic ⌘V. Degrade to clipboard
        // only; prompt/open System Settings at most once per session.
        guard permissionService.isTrusted() else {
            writeTranscript(text, concealed: false)
            cancelPendingRestore()
            pendingRestoreItems = nil // leave the transcript for manual paste
            promptForAccessibilityOnce()
            onInjectionResult?(.clipboardOnlyAccessibilityDenied)
            return
        }

        // Preferred path: insert directly at the caret through the AX API —
        // no clipboard involvement at all. Only attempted for native text roles
        // (web views/Electron report success unreliably) and disabled per-app
        // after repeated failures.
        if attemptDirectAXInsertion(text: text) {
            cancelPendingRestore()
            pendingRestoreItems = nil
            onInjectionResult?(.injectedDirect)
            return
        }

        // Secure keyboard entry (Terminal secure entry, password fields) swallows
        // synthetic key events → paste would silently drop the text. Degrade to
        // clipboard only and signal the caller.
        guard !IsSecureEventInputEnabled() else {
            writeTranscript(text, concealed: false)
            cancelPendingRestore()
            pendingRestoreItems = nil // leave the transcript for manual paste
            onInjectionResult?(.clipboardOnlySecureInput)
            return
        }

        // Paste path: write concealed transcript, post ⌘V, then restore the
        // user's prior clipboard after a short cancellable delay.
        writeTranscript(text, concealed: true)
        simulatePasteShortcut()
        scheduleClipboardRestore()
        onInjectionResult?(.injected)
    }

    // MARK: - Direct AX insertion

    /// Roles where setting `kAXSelectedTextAttribute` reliably inserts at the
    /// caret. Web areas and custom views are deliberately excluded — they can
    /// report success without updating the visible text.
    private static let axInsertableRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        "AXSearchField"
    ]

    /// Reads the currently selected text in the frontmost app's focused element, if
    /// any. Used to detect "user wants to revise this text by voice" at shortcut-engage
    /// time. Returns nil for empty selections or unsupported UI roles (same safelist as
    /// direct AX insertion — this is deliberately conservative: web views and custom
    /// controls can report stale or bogus selection state).
    func currentSelectionSnapshot() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return nil }
        let element = unsafeDowncast(focusedRef, to: AXUIElement.self)

        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
              let role = roleRef as? String, Self.axInsertableRoles.contains(role)
        else { return nil }

        var selectedTextRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedTextRef) == .success,
              let selectedText = selectedTextRef as? String,
              !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return selectedText
    }

    private func attemptDirectAXInsertion(text: String) -> Bool {
        let appKey = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        if axInsertionFailuresByApp[appKey, default: 0] >= maxAXFailuresBeforeFallback {
            return false
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success,
            let focusedRef,
            CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else {
            return false
        }
        let element = unsafeDowncast(focusedRef, to: AXUIElement.self)

        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
              let role = roleRef as? String,
              Self.axInsertableRoles.contains(role)
        else {
            return false
        }

        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &settable
        ) == .success, settable.boolValue else {
            return false
        }

        let status = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        )
        if status != .success {
            axInsertionFailuresByApp[appKey, default: 0] += 1
            return false
        }
        return true
    }

    // MARK: - Clipboard snapshot / restore

    private func captureSnapshotIfExternal() {
        let pasteboard = NSPasteboard.general
        // Only snapshot content that isn't our own last transient write.
        if pasteboard.string(forType: .string) == lastWrittenText, lastWrittenText != nil {
            return
        }
        pendingRestoreItems = pasteboard.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
            let copy = NSPasteboardItem()
            var copiedAnything = false
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                    copiedAnything = true
                }
            }
            return copiedAnything ? copy : nil
        }
    }

    private func writeTranscript(_ text: String, concealed: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if concealed {
            // Marks the item transient so clipboard managers skip it.
            pasteboard.setData(Data(), forType: Self.concealedType)
        }
        lastWrittenText = text
        changeCountAfterWrite = pasteboard.changeCount
    }

    private func scheduleClipboardRestore() {
        cancelPendingRestore()
        guard let items = pendingRestoreItems, !items.isEmpty else {
            // Nothing to restore (clipboard was empty); leave the transcript.
            pendingRestoreItems = nil
            return
        }
        let expectedChangeCount = changeCountAfterWrite
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let pasteboard = NSPasteboard.general
            // If anything else wrote to the pasteboard since our transcript
            // (an explicit Copy click, another app), that content is the user's
            // clipboard now — restoring would destroy it. Skip.
            guard pasteboard.changeCount == expectedChangeCount else {
                self.lastWrittenText = nil
                self.pendingRestoreItems = nil
                self.pendingRestoreWorkItem = nil
                return
            }
            pasteboard.clearContents()
            pasteboard.writeObjects(items)
            self.lastWrittenText = nil
            self.pendingRestoreItems = nil
            self.pendingRestoreWorkItem = nil
        }
        pendingRestoreWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay, execute: workItem)
    }

    private func cancelPendingRestore() {
        pendingRestoreWorkItem?.cancel()
        pendingRestoreWorkItem = nil
    }

    private func promptForAccessibilityOnce() {
        guard !didPromptForAccessibilityThisSession else { return }
        didPromptForAccessibilityThisSession = true
        _ = permissionService.requestIfNeeded(prompt: true)
        permissionService.openSystemSettings()
    }

    private func simulatePasteShortcut() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }

        let keyCode: CGKeyCode = 9 // v
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
}
