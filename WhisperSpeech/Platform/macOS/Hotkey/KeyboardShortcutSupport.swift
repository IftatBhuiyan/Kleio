import AppKit
import Carbon
import Foundation

struct KeyboardShortcutModifierState {
    private(set) var pressedModifiers: KeyboardShortcutModifiers = []

    mutating func reset() {
        pressedModifiers = []
    }

    mutating func update(keyCode: UInt16, eventFlags: CGEventFlags) {
        update(
            keyCode: keyCode,
            commandDown: eventFlags.contains(.maskCommand),
            shiftDown: eventFlags.contains(.maskShift),
            optionDown: eventFlags.contains(.maskAlternate),
            controlDown: eventFlags.contains(.maskControl),
            fnDown: eventFlags.contains(.maskSecondaryFn)
        )
    }

    mutating func update(keyCode: UInt16, eventFlags: NSEvent.ModifierFlags) {
        let filtered = eventFlags.intersection(.deviceIndependentFlagsMask)
        update(
            keyCode: keyCode,
            commandDown: filtered.contains(.command),
            shiftDown: filtered.contains(.shift),
            optionDown: filtered.contains(.option),
            controlDown: filtered.contains(.control),
            fnDown: filtered.contains(.function)
        )
    }

    private mutating func update(
        keyCode: UInt16,
        commandDown: Bool,
        shiftDown: Bool,
        optionDown: Bool,
        controlDown: Bool,
        fnDown: Bool
    ) {
        switch keyCode {
        case 55:
            updatePairedModifier(.leftCommand, counterpart: .rightCommand, genericDown: commandDown)
        case 54:
            updatePairedModifier(.rightCommand, counterpart: .leftCommand, genericDown: commandDown)
        case 56:
            updatePairedModifier(.leftShift, counterpart: .rightShift, genericDown: shiftDown)
        case 60:
            updatePairedModifier(.rightShift, counterpart: .leftShift, genericDown: shiftDown)
        case 58:
            updatePairedModifier(.leftOption, counterpart: .rightOption, genericDown: optionDown)
        case 61:
            updatePairedModifier(.rightOption, counterpart: .leftOption, genericDown: optionDown)
        case 59:
            updatePairedModifier(.leftControl, counterpart: .rightControl, genericDown: controlDown)
        case 62:
            updatePairedModifier(.rightControl, counterpart: .leftControl, genericDown: controlDown)
        case 63:
            set(.fn, pressed: fnDown)
        default:
            break
        }
    }

    private mutating func updatePairedModifier(
        _ changed: KeyboardShortcutModifiers,
        counterpart: KeyboardShortcutModifiers,
        genericDown: Bool
    ) {
        if genericDown {
            if !pressedModifiers.contains(changed) {
                pressedModifiers.insert(changed)
            } else if pressedModifiers.contains(counterpart) {
                pressedModifiers.remove(changed)
            }
        } else {
            pressedModifiers.remove(changed)
            pressedModifiers.remove(counterpart)
        }
    }

    private mutating func set(_ modifier: KeyboardShortcutModifiers, pressed: Bool) {
        if pressed {
            pressedModifiers.insert(modifier)
        } else {
            pressedModifiers.remove(modifier)
        }
    }
}

enum KeyboardShortcutValidationError: LocalizedError {
    case emptyShortcut
    case missingModifier
    case reservedBySystem

    var errorDescription: String? {
        switch self {
        case .emptyShortcut:
            return "Press a key or modifier to record a shortcut."
        case .missingModifier:
            return "Use at least one modifier key for keyboard shortcuts."
        case .reservedBySystem:
            return "That shortcut is already used by macOS. Try a different combination."
        }
    }
}

@MainActor
struct MacKeyboardShortcutValidator {
    func validate(_ shortcut: KeyboardShortcut) -> Result<KeyboardShortcut, KeyboardShortcutValidationError> {
        guard shortcut.keyCode != nil || !shortcut.modifiers.isEmpty else {
            return .failure(.emptyShortcut)
        }

        if shortcut.keyCode != nil && shortcut.modifiers.isEmpty {
            return .failure(.missingModifier)
        }

        if matchesExplicitlyReservedShortcut(shortcut) || conflictsWithSystemSymbolicHotKey(shortcut) {
            return .failure(.reservedBySystem)
        }

        return .success(shortcut)
    }

    private func matchesExplicitlyReservedShortcut(_ shortcut: KeyboardShortcut) -> Bool {
        guard let keyCode = shortcut.keyCode else { return false }
        let modifiers = shortcut.carbonModifierFlags
        let reservedCombos: Set<ShortcutConflictSignature> = [
            ShortcutConflictSignature(keyCode: 48, modifiers: UInt32(cmdKey)),
            ShortcutConflictSignature(keyCode: 49, modifiers: UInt32(cmdKey)),
            ShortcutConflictSignature(keyCode: 49, modifiers: UInt32(cmdKey | optionKey)),
            ShortcutConflictSignature(keyCode: 49, modifiers: UInt32(controlKey)),
            ShortcutConflictSignature(keyCode: 49, modifiers: UInt32(controlKey | optionKey)),
            ShortcutConflictSignature(keyCode: 50, modifiers: UInt32(cmdKey))
        ]
        return reservedCombos.contains(ShortcutConflictSignature(keyCode: keyCode, modifiers: modifiers))
    }

    private func conflictsWithSystemSymbolicHotKey(_ shortcut: KeyboardShortcut) -> Bool {
        guard let keyCode = shortcut.keyCode else { return false }

        var symbolicHotKeys: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&symbolicHotKeys) == noErr,
              let symbolicHotKeys = symbolicHotKeys?.takeRetainedValue() as? [[String: Any]]
        else {
            return false
        }

        let signature = ShortcutConflictSignature(
            keyCode: keyCode,
            modifiers: shortcut.carbonModifierFlags
        )

        return symbolicHotKeys.contains { entry in
            let enabled = (entry[kHISymbolicHotKeyEnabled as String] as? Bool) ?? false
            guard enabled else { return false }
            guard let entryKeyCode = entry[kHISymbolicHotKeyCode as String] as? NSNumber,
                  let entryModifiers = entry[kHISymbolicHotKeyModifiers as String] as? NSNumber
            else {
                return false
            }

            let candidate = ShortcutConflictSignature(
                keyCode: entryKeyCode.uint16Value,
                modifiers: entryModifiers.uint32Value
            )
            return candidate == signature
        }
    }
}

private struct ShortcutConflictSignature: Hashable {
    let keyCode: UInt16
    let modifiers: UInt32
}

extension KeyboardShortcut {
    var displayTokens: [String] {
        var tokens = modifiers.displayTokens
        if let keyCode {
            tokens.append(MacKeyboardShortcutFormatter.displayToken(for: keyCode))
        }
        return tokens
    }

    var displayLabel: String {
        displayTokens.joined(separator: " ")
    }

    fileprivate var carbonModifierFlags: UInt32 {
        var flags: UInt32 = 0
        if !modifiers.intersection(.anyCommand).isEmpty {
            flags |= UInt32(cmdKey)
        }
        if !modifiers.intersection(.anyShift).isEmpty {
            flags |= UInt32(shiftKey)
        }
        if !modifiers.intersection(.anyOption).isEmpty {
            flags |= UInt32(optionKey)
        }
        if !modifiers.intersection(.anyControl).isEmpty {
            flags |= UInt32(controlKey)
        }
        if modifiers.contains(.fn) {
            flags |= UInt32(kEventKeyModifierFnMask)
        }
        return flags
    }

    func usesModifierKeyCode(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 55:
            return modifiers.contains(.leftCommand)
        case 54:
            return modifiers.contains(.rightCommand)
        case 56:
            return modifiers.contains(.leftShift)
        case 60:
            return modifiers.contains(.rightShift)
        case 58:
            return modifiers.contains(.leftOption)
        case 61:
            return modifiers.contains(.rightOption)
        case 59:
            return modifiers.contains(.leftControl)
        case 62:
            return modifiers.contains(.rightControl)
        case 63:
            return modifiers.contains(.fn)
        default:
            return false
        }
    }
}

private extension KeyboardShortcutModifiers {
    // The engine tracks left/right sides, but the UI shows plain macOS symbols in
    // the conventional fn ⌃ ⌥ ⇧ ⌘ order — the old side-suffixed tokens ("⇧L",
    // "⌘L") read as shift+L / command+L.
    var displayTokens: [String] {
        var tokens: [String] = []
        if contains(.fn) { tokens.append("fn") }
        if !intersection(.anyControl).isEmpty { tokens.append("\u{2303}") }
        if !intersection(.anyOption).isEmpty { tokens.append("\u{2325}") }
        if !intersection(.anyShift).isEmpty { tokens.append("\u{21E7}") }
        if !intersection(.anyCommand).isEmpty { tokens.append("\u{2318}") }
        return tokens
    }
}

private enum MacKeyboardShortcutFormatter {
    static func displayToken(for keyCode: UInt16) -> String {
        if let special = specialKeyToken(for: keyCode) {
            return special
        }

        if let translated = translatedCharacter(for: keyCode), !translated.isEmpty {
            return translated.uppercased()
        }

        return "K\(keyCode)"
    }

    private static func specialKeyToken(for keyCode: UInt16) -> String? {
        let specialKeys: [UInt16: String] = [
            36: "\u{21A9}",
            48: "\u{21E5}",
            49: "\u{2423}",
            51: "\u{232B}",
            53: "esc",
            76: "\u{2305}",
            117: "\u{2326}",
            123: "\u{2190}",
            124: "\u{2192}",
            125: "\u{2193}",
            126: "\u{2191}"
        ]
        return specialKeys[keyCode]
    }

    private static func translatedCharacter(for keyCode: UInt16) -> String? {
        guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutDataPointer = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData)
        else {
            return nil
        }

        let layoutData = unsafeBitCast(layoutDataPointer, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(layoutData) else {
            return nil
        }

        let keyboardLayout = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { $0 }
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)

        let status = UCKeyTranslate(
            keyboardLayout,
            keyCode,
            UInt16(kUCKeyActionDown),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysMask),
            &deadKeyState,
            characters.count,
            &length,
            &characters
        )

        guard status == noErr, length > 0 else {
            return nil
        }

        let string = String(utf16CodeUnits: characters, count: Int(length))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return string.isEmpty ? nil : string
    }
}
