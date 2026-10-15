import SwiftUI
import SwiftData
import AppKit
import os

private let lifecycleLog = Logger(subsystem: "com.EclipseStudio.Kleio", category: "lifecycle")
private let macMainWindowMinimumWidth: CGFloat = 1100
private let macMainWindowMinimumHeight: CGFloat = 720

@main
struct WhisperSpeechApp: App {
    private let sharedModelContainer: ModelContainer
    @StateObject private var appModel: AppModel
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var macAppDelegate

    var body: some Scene {
        WindowGroup(id: "main-window") {
            AppRootView()
                .environmentObject(appModel)
                .background(MacMainWindowBinder())
                .frame(minWidth: macMainWindowMinimumWidth, minHeight: macMainWindowMinimumHeight)
                .onOpenURL { url in
                    _ = appModel.sessionManager.handleIncomingURL(url)
                }
        }
        .defaultSize(width: macMainWindowMinimumWidth, height: macMainWindowMinimumHeight)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .modelContainer(sharedModelContainer)

        MenuBarExtra(isInserted: menuBarExtraInsertionBinding) {
            MenuBarPanelView()
                .environmentObject(appModel)
        } label: {
            MenuBarLabelView(status: appModel.coordinator.status)
        }
        .menuBarExtraStyle(.menu)
    }

    @MainActor
    init() {
        // Opt out of Automatic Termination before AppKit starts managing it; enabling it
        // later than this did not stop macOS quitting the windowless app.
        ProcessInfo.processInfo.automaticTerminationSupportEnabled = false
        ProcessInfo.processInfo.disableAutomaticTermination("Kleio listens for the dictation shortcut")
        let schema = Schema([
            DictationHistoryEntry.self,
            DictionaryTermEntry.self,
            DictionarySuggestionEntry.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create model container: \(error)")
        }
        self.sharedModelContainer = container

        FirebaseBootstrap.configureIfNeeded()
        let sessionManager = SessionManager(configuration: .shared)
        let model = AppModel(
            configuration: .shared,
            sessionManager: sessionManager,
            modelContainer: container
        )
        _appModel = StateObject(wrappedValue: model)
        model.start()
    }

    private var menuBarExtraInsertionBinding: Binding<Bool> {
        Binding(
            get: { appModel.configuration.appVisibilityMode.showsMenuBarExtra },
            set: { isInserted in
                let currentMode = appModel.configuration.appVisibilityMode
                guard currentMode.showsMenuBarExtra != isInserted else { return }
                if isInserted {
                    appModel.configuration.appVisibilityMode = .dockAndMenuBar
                } else {
                    appModel.configuration.appVisibilityMode = .dockOnly
                }
            }
        )
    }
}

private struct MenuBarPanelView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var configuration = AppConfiguration.shared

    var body: some View {
        Button("Open Kleio") {
            openMainWindow()
        }
        .keyboardShortcut("m", modifiers: [.command])
        .onReceive(NotificationCenter.default.publisher(for: .openMainDashboard)) { _ in
            openMainWindow()
        }

        Button("Open Settings") {
            openSettings()
        }
        .keyboardShortcut(",", modifiers: [.command])

        Menu("App Visibility") {
            ForEach(AppVisibilityMode.allCases) { mode in
                Button {
                    configuration.appVisibilityMode = mode
                } label: {
                    if configuration.appVisibilityMode == mode {
                        Label(mode.displayName, systemImage: "checkmark")
                    } else {
                        Text(mode.displayName)
                    }
                }
            }
        }

        if !appModel.accessibilityPermissionGranted || !appModel.hotkeyActive {
            Divider()

            if !appModel.accessibilityPermissionGranted {
                Button("Grant Accessibility Permission") {
                    appModel.refreshAccessibilityPermissionStatus(promptIfNeeded: true)
                }
            }
            if appModel.hotkeyActive == false {
                Button("⚠️ Dictation Shortcut Inactive — Fix…") {
                    appModel.refreshAccessibilityPermissionStatus(promptIfNeeded: true)
                }
            }
        }

        Divider()

        Button("Quit Kleio") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: [.command])
    }

    private func openMainWindow() {
        guard !MacMainWindowController.shared.showWindow() else { return }
        openWindow(id: "main-window")
        // SwiftUI may not have materialized the window by the next runloop turn
        // (menuBarOnly mode after the window was destroyed) — retry briefly.
        retryShowWindow(attemptsRemaining: 5)
    }

    private func retryShowWindow(attemptsRemaining: Int) {
        guard attemptsRemaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if !MacMainWindowController.shared.showWindow() {
                retryShowWindow(attemptsRemaining: attemptsRemaining - 1)
            }
        }
    }

    private func openSettings() {
        openMainWindow()
        NotificationCenter.default.post(name: .showSettingsOverlay, object: nil)
    }
}

private final class MacAppDelegate: NSObject, NSApplicationDelegate {
    private var openDashboardObserver: NSObjectProtocol?
    private var backgroundUtilityActivity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        lifecycleLog.notice("didFinishLaunching; automaticTerminationSupportEnabled=\(ProcessInfo.processInfo.automaticTerminationSupportEnabled, privacy: .public)")
        // Kleio is a background utility: it listens for the dictation shortcut with no
        // window open. AppKit's Automatic Termination treated "no windows + background"
        // as idle and macOS sent a Quit Apple Event (window closed, or after sleep), and
        // App Nap throttled the app so the first shortcut press felt dead. Opt out of
        // both for the life of the process. Idle system sleep stays allowed.
        ProcessInfo.processInfo.disableAutomaticTermination("Kleio listens for the dictation shortcut")
        backgroundUtilityActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Kleio listens for the dictation shortcut"
        )

        // The pill's "Open Kleio" posts this. Observe it here, not in the menu-bar
        // menu view, which doesn't exist in Dock Only mode.
        openDashboardObserver = NotificationCenter.default.addObserver(
            forName: .openMainDashboard,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                _ = MacMainWindowController.shared.showWindow()
            }
        }
    }

    /// Closing the dashboard must never quit Kleio — the shortcut, pill and menu bar keep
    /// working without it. SwiftUI's default answered YES here, so closing the window
    /// flagged the app "terminate after last window closed" and macOS quit it moments later.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        lifecycleLog.notice("asked shouldTerminateAfterLastWindowClosed -> false")
        return false
    }

    /// Logs who asked Kleio to quit (pid of the Apple Event sender) so unexpected quits
    /// can be traced from the unified log. Never blocks a quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let senderPID = event?.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value ?? 0
        let reason = event?.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue ?? 0
        lifecycleLog.notice("shouldTerminate: appleEvent=\(event != nil, privacy: .public) senderPID=\(senderPID, privacy: .public) quitReason=\(reason, privacy: .public)")
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        return !MacMainWindowController.shared.showWindow()
    }
}

private struct MacMainWindowBinder: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            attachWindow(for: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            attachWindow(for: nsView)
        }
    }

    private func attachWindow(for view: NSView) {
        guard let window = view.window else { return }
        MacMainWindowController.shared.attach(to: window)
        #if DEBUG
        MacMainWindowController.shared.scheduleDebugHideIfRequested()
        MacDebugWindowSnapshotter.scheduleIfRequested(window: window)
        #endif
    }
}

#if DEBUG
/// Screenshot/debug hook (pairs with `kleio.debug.initialSection`): when the
/// `kleio.debug.screenshotPath` default is set, render the main window's content
/// to a PNG at that path shortly after the window materializes. In-process
/// rendering needs no screen-recording permission, unlike `screencapture`.
/// Debug builds only — never active in release.
private enum MacDebugWindowSnapshotter {
    private static var didSchedule = false

    static func scheduleIfRequested(window: NSWindow) {
        guard !didSchedule,
              let path = UserDefaults.standard.string(forKey: "kleio.debug.screenshotPath")
        else { return }
        didSchedule = true
        attemptCapture(window: window, path: path, attemptsRemaining: 6)
    }

    private static func attemptCapture(window: NSWindow?, path: String, attemptsRemaining: Int) {
        guard attemptsRemaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak window] in
            guard
                let view = window?.contentView,
                view.bounds.width > 100, view.bounds.height > 100,
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else {
                attemptCapture(window: window, path: path, attemptsRemaining: attemptsRemaining - 1)
                return
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: URL(fileURLWithPath: path))
            // The sandbox container is TCC-protected from outside tooling; loopback
            // HTTP is not (network.client entitlement) — POST the capture to the
            // harness when `kleio.debug.screenshotUploadURL` is set.
            if let urlString = UserDefaults.standard.string(forKey: "kleio.debug.screenshotUploadURL"),
               let url = URL(string: urlString) {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.httpBody = png
                URLSession.shared.dataTask(with: request).resume()
            }
        }
    }
}
#endif

private final class MacMainWindowController: NSObject, NSWindowDelegate {
    static let shared = MacMainWindowController()

    private weak var window: NSWindow?

    func attach(to window: NSWindow) {
        guard self.window !== window else { return }
        if let currentWindow = self.window, currentWindow.delegate === self {
            currentWindow.delegate = nil
        }
        self.window = window
        window.identifier = NSUserInterfaceItemIdentifier("main-window")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: macMainWindowMinimumWidth, height: macMainWindowMinimumHeight)
        window.contentMinSize = NSSize(width: macMainWindowMinimumWidth, height: macMainWindowMinimumHeight)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
        // false, not true (H-xx): with no visible titlebar, "movable by window
        // background" makes AppKit treat ANY click SwiftUI doesn't explicitly claim —
        // plain text, table rows, card padding — as "empty background," so click-drag
        // anywhere dragged the whole window instead of e.g. selecting text. The
        // window is still draggable from genuinely empty chrome via the explicit
        // `.gesture(WindowDragGesture())` on MacAnalyticsWindowView's backgroundLayer.
        window.isMovableByWindowBackground = false
        window.backgroundColor = NSColor(
            calibratedRed: 0.975,
            green: 0.966,
            blue: 0.944,
            alpha: 1.0
        )
        if window.frame.width < window.minSize.width || window.frame.height < window.minSize.height {
            var frame = window.frame
            frame.size.width = max(frame.width, window.minSize.width)
            frame.size.height = max(frame.height, window.minSize.height)
            // Never grow the window beyond the visible screen (H-1) — on 13"/14"
            // MacBooks the old 1135pt minimum height exceeded the usable frame.
            if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
                frame.size.width = min(frame.size.width, visible.width)
                frame.size.height = min(frame.size.height, visible.height)
                frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.size.width)
                frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.size.height)
            }
            window.setFrame(frame, display: true)
        }
        if let closeButton = window.standardWindowButton(.closeButton) {
            closeButton.target = self
            closeButton.action = #selector(hideWindowFromCloseButton(_:))
        }
    }

    func showWindow() -> Bool {
        if window == nil,
           let existingWindow = NSApp.windows.first(where: { $0.identifier?.rawValue == "main-window" }) {
            attach(to: existingWindow)
        }
        guard let window else { return false }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    #if DEBUG
    /// Test hook: `-kleio.debug.hideWindowAfterSeconds N` presses the close button's
    /// action after N seconds, to reproduce "close the window" without UI scripting.
    private var didScheduleDebugHide = false

    func scheduleDebugHideIfRequested() {
        guard !didScheduleDebugHide else { return }
        didScheduleDebugHide = true
        let seconds = UserDefaults.standard.double(forKey: "kleio.debug.hideWindowAfterSeconds")
        guard seconds > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            lifecycleLog.notice("debug: hiding window via close-button action")
            self?.hideWindowFromCloseButton(nil)
        }
    }
    #endif

    @objc private func hideWindowFromCloseButton(_ sender: Any?) {
        window?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

private struct MenuBarLabelView: View {
    let status: DictationStatus

    var body: some View {
        labelContent
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 5)
            .background(backgroundFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    @ViewBuilder
    private var labelContent: some View {
        switch visualState {
        case .idle:
            Image("Kleio.icon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
        case .listening:
            Image(systemName: "mic.fill")
                .font(.system(size: 13, weight: .semibold))
        case .processing:
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .bold))
        }
    }

    private var foregroundColor: Color {
        switch visualState {
        case .idle:
            return .white.opacity(0.96)
        case .listening, .processing:
            return .white
        }
    }

    private var backgroundFill: LinearGradient {
        switch visualState {
        case .idle:
            return LinearGradient(
                colors: [Color(red: 0.36, green: 0.17, blue: 0.22), Color(red: 0.24, green: 0.11, blue: 0.16)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .listening:
            return LinearGradient(
                colors: [Color(red: 1.0, green: 0.72, blue: 0.31), Color(red: 0.97, green: 0.55, blue: 0.17)],
                startPoint: .leading,
                endPoint: .trailing
            )
        case .processing:
            return LinearGradient(
                colors: [Color(red: 1.0, green: 0.76, blue: 0.43), Color(red: 0.96, green: 0.63, blue: 0.28)],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    private var horizontalPadding: CGFloat {
        switch visualState {
        case .idle:
            return 8
        case .listening, .processing:
            return 10
        }
    }

    private var visualState: MenuBarVisualState {
        switch status {
        case .listening:
            return .listening
        case .processing:
            return .processing
        case .idle, .error:
            return .idle
        }
    }
}

extension Notification.Name {
    static let showSettingsOverlay = Notification.Name("showSettingsOverlay")
    static let dictationHistoryDidChange = Notification.Name("dictationHistoryDidChange")
    // Posted by the dictation pill's hover recents card ("Open Kleio" footer
    // button) to bring the main window forward without needing SwiftUI
    // environment access from the pill's own NSPanel-hosted view.
    static let openMainDashboard = Notification.Name("openMainDashboard")
}

private enum MenuBarVisualState {
    case idle
    case listening
    case processing
}
