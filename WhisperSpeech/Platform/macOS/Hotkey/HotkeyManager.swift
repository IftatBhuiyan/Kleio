import AppKit
import CoreGraphics
import Foundation
import QuartzCore

struct SmartDictationShortcutState {
    enum SessionMode: Equatable {
        case idle
        case pressing
        case holding
        case toggled
    }

    enum Effect: Equatable {
        case scheduleHoldActivation
        case cancelHoldActivation
        case startDictation
        case stopDictation
    }

    var sessionMode: SessionMode = .idle
    var isShortcutPressed = false
    var ignoreNextRelease = false
    var lastTapReleaseTimestamp: TimeInterval?

    mutating func handlePress(at timestamp: TimeInterval, doubleTapWindow: TimeInterval) -> [Effect] {
        guard !isShortcutPressed else { return [] }
        isShortcutPressed = true

        switch sessionMode {
        case .toggled:
            sessionMode = .idle
            ignoreNextRelease = true
            lastTapReleaseTimestamp = nil
            return [.cancelHoldActivation, .stopDictation]
        case .holding:
            return []
        case .pressing, .idle:
            if let lastTapReleaseTimestamp,
               timestamp - lastTapReleaseTimestamp <= doubleTapWindow {
                sessionMode = .toggled
                self.lastTapReleaseTimestamp = nil
                return [.cancelHoldActivation, .startDictation]
            } else {
                sessionMode = .pressing
                return [.cancelHoldActivation, .scheduleHoldActivation]
            }
        }
    }

    mutating func handleRelease(at timestamp: TimeInterval) -> [Effect] {
        guard isShortcutPressed else { return [] }
        isShortcutPressed = false

        if ignoreNextRelease {
            ignoreNextRelease = false
            return [.cancelHoldActivation]
        }

        switch sessionMode {
        case .holding:
            sessionMode = .idle
            lastTapReleaseTimestamp = nil
            return [.cancelHoldActivation, .stopDictation]
        case .pressing:
            sessionMode = .idle
            lastTapReleaseTimestamp = timestamp
            return [.cancelHoldActivation]
        case .toggled:
            return [.cancelHoldActivation]
        case .idle:
            lastTapReleaseTimestamp = timestamp
            return [.cancelHoldActivation]
        }
    }

    mutating func handleHoldActivationTimer() -> [Effect] {
        guard isShortcutPressed, sessionMode == .pressing else { return [] }
        sessionMode = .holding
        lastTapReleaseTimestamp = nil
        return [.startDictation]
    }

    mutating func syncDictationActiveState(_ isActive: Bool) -> [Effect] {
        guard isActive else {
            sessionMode = .idle
            lastTapReleaseTimestamp = nil
            if isShortcutPressed {
                ignoreNextRelease = true
            }
            return [.cancelHoldActivation]
        }

        if sessionMode == .idle {
            sessionMode = .toggled
        }
        return []
    }

    mutating func reset() {
        sessionMode = .idle
        isShortcutPressed = false
        ignoreNextRelease = false
        lastTapReleaseTimestamp = nil
    }
}

final class HotkeyManager {
    var onStartDictation: (() -> Void)?
    var onStopDictation: (() -> Void)?
    /// Fires as soon as a shortcut press begins (before the hold-vs-tap decision),
    /// so the app can warm the websocket/token during the disambiguation window.
    var onPressBegan: (() -> Void)?

    /// Whether the event tap is currently installed and receiving events.
    /// Published via callback so callers can surface a "hotkey inactive" state.
    private(set) var isActive = false {
        didSet {
            guard oldValue != isActive else { return }
            let value = isActive
            DispatchQueue.main.async { self.onActiveStateChanged?(value) }
        }
    }
    var onActiveStateChanged: ((Bool) -> Void)?

    private let stateQueue = DispatchQueue(label: "dictation.hotkey.manager.state")

    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private var tapThread: Thread?

    private var shortcut: KeyboardShortcut
    private var modifierState = KeyboardShortcutModifierState()
    private var shortcutState = SmartDictationShortcutState()
    private var pendingHoldActivationWorkItem: DispatchWorkItem?
    private var isStarted = false
    /// When true, the tap forwards every event untouched and dispatches no
    /// dictation effects — used while the settings recorder captures a shortcut.
    private var isCaptureMode = false
    // MAC-OPEN-07: 120 ms is enough to disambiguate a hold from a tap, and the
    // press-began hook lets the app overlap connection/token warm-up with this
    // window so hold-to-talk starts capturing sooner.
    private let holdActivationDelay: TimeInterval = 0.12
    private let doubleTapWindow: TimeInterval = 0.32

    // MARK: - Tap-creation retry (C-5)
    private var retryObserver: NSObjectProtocol?
    private var captureModeObserver: NSObjectProtocol?
    private var pendingRetryWorkItem: DispatchWorkItem?
    private var retryDelay: TimeInterval = 1.0
    private let maxRetryDelay: TimeInterval = 30.0

    init(shortcut: KeyboardShortcut) {
        self.shortcut = shortcut
    }

    deinit {
        // Deinit must be synchronous: capturing `self` in an async block during
        // deinit is undefined behavior. Tear down the tap here by value.
        if let observer = retryObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = captureModeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        stopSynchronously()
    }

    func updateShortcut(_ shortcut: KeyboardShortcut) {
        stateQueue.async {
            self.shortcut = shortcut
            self.resetPressedState()
        }
    }

    func syncDictationActiveState(_ isActive: Bool) {
        stateQueue.async {
            let effects = self.shortcutState.syncDictationActiveState(isActive)
            self.apply(effects)
        }
    }

    /// Enter/exit capture mode. While enabled, the tap forwards all events and
    /// dispatches no dictation effects so the settings shortcut recorder can see
    /// the user pressing the currently-configured shortcut (H-4).
    func setCaptureMode(_ enabled: Bool) {
        stateQueue.async {
            guard self.isCaptureMode != enabled else { return }
            self.isCaptureMode = enabled
            self.resetPressedState()
        }
    }

    func start() {
        stateQueue.async {
            guard !self.isStarted else { return }
            self.isStarted = true
            self.installRetryObserverIfNeeded()

            let thread = Thread { [weak self] in
                self?.setupEventTapOnCurrentThread()
            }
            thread.name = "dictation.hotkey.tap"
            thread.qualityOfService = .userInteractive
            self.tapThread = thread
            thread.start()
        }
    }

    func stop() {
        stateQueue.async {
            self.cancelPendingRetry()
            self.tearDownTap()
        }
    }

    /// Synchronous teardown used from `deinit`. Captures the run loop and ports
    /// by value and stops the tap without re-dispatching onto `stateQueue`.
    private func stopSynchronously() {
        stateQueue.sync {
            self.cancelPendingRetry()
            self.tearDownTap()
        }
    }

    /// Tears down the current tap (if any). Must be called on `stateQueue`.
    /// Captures the run loop / ports by value so a concurrent restart can't have
    /// its fresh tap invalidated by this block (M-21).
    private func tearDownTap() {
        guard self.isStarted else { return }
        self.isStarted = false
        self.isActive = false

        guard let tapRunLoop = self.tapRunLoop else {
            self.tapThread = nil
            return
        }
        // Snapshot the objects owned by *this* tap generation by value.
        let tap = self.eventTap
        let source = self.eventTapSource
        self.eventTap = nil
        self.eventTapSource = nil
        self.tapRunLoop = nil
        self.tapThread = nil
        self.resetPressedState()

        CFRunLoopPerformBlock(tapRunLoop, CFRunLoopMode.commonModes.rawValue) {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
            }
            if let source {
                CFRunLoopRemoveSource(tapRunLoop, source, .commonModes)
            }
            CFRunLoopStop(tapRunLoop)
        }
        CFRunLoopWakeUp(tapRunLoop)
    }

    private func setupEventTapOnCurrentThread() {
        let mask =
            CGEventMask(1 << CGEventType.flagsChanged.rawValue) |
            CGEventMask(1 << CGEventType.keyDown.rawValue) |
            CGEventMask(1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            let shouldSuppress = manager.handleTapEvent(type: type, event: event)
            return shouldSuppress ? nil : Unmanaged.passUnretained(event)
        }

        guard let eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // Tap creation fails when Accessibility / Input Monitoring hasn't been
            // granted yet. Instead of dying forever, mark inactive and schedule a
            // retry (C-5). The retry observer also fires on app activation.
            stateQueue.async {
                self.isStarted = false
                self.isActive = false
                self.scheduleTapRetry()
            }
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        let runLoop = CFRunLoopGetCurrent()

        stateQueue.sync {
            self.eventTap = eventTap
            self.eventTapSource = source
            self.tapRunLoop = runLoop
            self.isActive = true
            self.retryDelay = 1.0 // reset backoff after a successful creation
        }

        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        CFRunLoopRun()
    }

    // MARK: - Retry (C-5)

    /// Installs a one-time observer that retries tap creation when the app is
    /// activated (a natural moment for the user to have just granted permission),
    /// plus the capture-mode observer for the settings shortcut recorder (H-4).
    private func installRetryObserverIfNeeded() {
        if retryObserver == nil {
            retryObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.stateQueue.async {
                    self?.retryTapIfNeeded()
                }
            }
        }
        if captureModeObserver == nil {
            captureModeObserver = NotificationCenter.default.addObserver(
                forName: .hotkeyCaptureModeDidChange,
                object: nil,
                queue: nil
            ) { [weak self] note in
                let enabled = (note.object as? Bool) ?? false
                self?.setCaptureMode(enabled)
            }
        }
    }

    /// Schedules a backoff retry (used after a creation failure). Also polls
    /// `AXIsProcessTrusted()` so a permission grant while the app is frontmost
    /// still recovers without waiting for the next activation.
    private func scheduleTapRetry() {
        cancelPendingRetry()
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, maxRetryDelay)
        let workItem = DispatchWorkItem { [weak self] in
            self?.retryTapIfNeeded()
        }
        pendingRetryWorkItem = workItem
        stateQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// Attempts to (re)create the tap if we don't currently have an active one.
    /// Must run on `stateQueue`.
    private func retryTapIfNeeded() {
        cancelPendingRetry()
        guard !isActive, !isStarted else { return }
        isStarted = true

        let thread = Thread { [weak self] in
            self?.setupEventTapOnCurrentThread()
        }
        thread.name = "dictation.hotkey.tap"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()
    }

    private func cancelPendingRetry() {
        pendingRetryWorkItem?.cancel()
        pendingRetryWorkItem = nil
    }

    private func handleTapEvent(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            stateQueue.sync {
                if let eventTap {
                    CGEvent.tapEnable(tap: eventTap, enable: true)
                }
            }
            return false
        }

        return stateQueue.sync {
            self.processEvent(type: type, event: event)
        }
    }

    private func processEvent(type: CGEventType, event: CGEvent) -> Bool {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        // Capture mode (H-4): keep modifier tracking coherent but forward every
        // event and dispatch no effects, so the recorder can observe the shortcut.
        if isCaptureMode {
            if type == .flagsChanged {
                modifierState.update(keyCode: keyCode, eventFlags: event.flags)
            }
            return false
        }

        switch type {
        case .flagsChanged:
            modifierState.update(keyCode: keyCode, eventFlags: event.flags)
            // Only modifier-only shortcuts (e.g. bare ⌥) should suppress
            // flagsChanged. For combo shortcuts the modifiers are shared with the
            // rest of the system, so swallowing them breaks other apps' modifier
            // tracking (H-3) — forward them untouched.
            guard shortcut.isModifierOnly else { return false }
            handleShortcutTransition(isPressed: isShortcutCurrentlyPressed())
            return shortcut.usesModifierKeyCode(keyCode)
        case .keyDown:
            guard let shortcutKeyCode = shortcut.keyCode else { return false }
            guard keyCode == shortcutKeyCode else { return false }
            guard modifierState.pressedModifiers == shortcut.modifiers else { return false }
            handleShortcutTransition(isPressed: true)
            return true
        case .keyUp:
            guard let shortcutKeyCode = shortcut.keyCode else { return false }
            guard keyCode == shortcutKeyCode else { return false }
            guard shortcutState.isShortcutPressed else { return false }
            handleShortcutTransition(isPressed: false)
            return true
        default:
            return false
        }
    }

    private func handleShortcutTransition(isPressed: Bool) {
        let now = CACurrentMediaTime()
        let effects: [SmartDictationShortcutState.Effect]
        if isPressed {
            effects = shortcutState.handlePress(at: now, doubleTapWindow: doubleTapWindow)
        } else {
            effects = shortcutState.handleRelease(at: now)
        }
        apply(effects)
    }

    private func isShortcutCurrentlyPressed() -> Bool {
        shortcut.isModifierOnly && modifierState.pressedModifiers == shortcut.modifiers
    }

    private func apply(_ effects: [SmartDictationShortcutState.Effect]) {
        for effect in effects {
            switch effect {
            case .scheduleHoldActivation:
                scheduleHoldActivation()
                DispatchQueue.main.async { self.onPressBegan?() }
            case .cancelHoldActivation:
                cancelPendingHoldActivation()
            case .startDictation:
                DispatchQueue.main.async { self.onStartDictation?() }
            case .stopDictation:
                DispatchQueue.main.async { self.onStopDictation?() }
            }
        }
    }

    private func scheduleHoldActivation() {
        cancelPendingHoldActivation()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let effects = self.shortcutState.handleHoldActivationTimer()
            self.apply(effects)
        }
        pendingHoldActivationWorkItem = workItem
        stateQueue.asyncAfter(deadline: .now() + holdActivationDelay, execute: workItem)
    }

    private func cancelPendingHoldActivation() {
        pendingHoldActivationWorkItem?.cancel()
        pendingHoldActivationWorkItem = nil
    }

    private func resetPressedState() {
        modifierState.reset()
        cancelPendingHoldActivation()
        shortcutState.reset()
    }
}

extension Notification.Name {
    /// Posted by the settings shortcut recorder to toggle capture mode on the
    /// hotkey tap. `object` carries a `Bool` (true = entering capture). Owned by
    /// the macOS platform layer (HotkeyManager + SettingsWindowView).
    static let hotkeyCaptureModeDidChange = Notification.Name("hotkeyCaptureModeDidChange")
}
