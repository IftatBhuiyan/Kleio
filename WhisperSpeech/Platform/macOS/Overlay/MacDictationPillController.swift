import AppKit
import Combine
import SwiftUI

@MainActor
struct MacDictationPillState: Equatable {
    enum Activity: Equatable {
        case idle
        case listening
        case processing
        case error
    }

    var activity: Activity = .idle
    var liveInputLevel: Double = 0
    var shortcutTokens: [String] = []
    var notice: String? = nil

    var promptText: String {
        let shortcut = shortcutTokens.isEmpty ? "your shortcut" : shortcutTokens.joined(separator: " ")
        return "Click, hold, or double-tap \(shortcut) to start dictating"
    }
}

enum MacDictationPillLayout {
    // Enlarged (was 340x142) to make room for the hover-expanded recents card above
    // the pill. NSPanel/NSWindow frames are bottom-left-origin in AppKit screen space,
    // and panelOrigin() below always pins the panel's bottom edge to
    // `visibleFrame.minY + bottomMargin` regardless of height, so growing the height
    // only extends the panel upward — the pill (bottom-aligned inside the panel's
    // content view) stays anchored at the same on-screen position.
    static let panelSize = CGSize(width: 340, height: 290)
    static let bottomMargin: CGFloat = 10

    /// Invisible hover-detection zone around the idle 56x8 pill strip, sized larger
    /// than the strip itself so the recents card is discoverable without needing
    /// pixel-precise hovering.
    static let recentsHoverZoneSize = CGSize(width: 120, height: 24)

    static func panelOrigin(in visibleFrame: CGRect) -> CGPoint {
        CGPoint(
            x: visibleFrame.midX - (panelSize.width / 2),
            y: visibleFrame.minY + bottomMargin
        )
    }
}

/// A single row of transcript history surfaced in the pill's hover recents card.
/// Intentionally SwiftData-free (no `DictationHistoryEntry` reference) so the card
/// view never touches the model layer directly — the controller's owner supplies
/// these via `recentTranscriptsProvider`.
struct PillTranscriptItem: Identifiable, Equatable {
    let id: String
    let text: String
    let timestamp: Date
    let appName: String?
    let iconPNGData: Data?
}

@MainActor
private final class MacDictationPillViewModel: ObservableObject {
    @Published var state = MacDictationPillState()
    @Published var isFocusedScreen = true
}

@MainActor
final class MacDictationPillController {
    private let configuration: AppConfiguration
    private let coordinator: DictationCoordinator
    private let onToggle: () -> Void
    private let recentTranscriptsProvider: () -> [PillTranscriptItem]
    private let pasteTranscript: (String) -> Void
    private var panelEntries: [String: (panel: MacDictationPillPanel, viewModel: MacDictationPillViewModel)] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var hasStarted = false
    private var focusTimer: AnyCancellable?
    private var currentNotice: String?
    private var noticeClearWorkItem: DispatchWorkItem?

    init(
        configuration: AppConfiguration,
        coordinator: DictationCoordinator,
        onToggle: @escaping () -> Void,
        recentTranscriptsProvider: @escaping () -> [PillTranscriptItem] = { [] },
        pasteTranscript: @escaping (String) -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.coordinator = coordinator
        self.onToggle = onToggle
        self.recentTranscriptsProvider = recentTranscriptsProvider
        self.pasteTranscript = pasteTranscript
        bindState()
    }

    deinit {
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func start() {
        guard !hasStarted else {
            updatePanelVisibility()
            repositionPanels()
            return
        }
        hasStarted = true
        installObservers()
        updatePanelVisibility()
    }

    /// Shows a short-lived message bubble above the pill (e.g. "Copied — press ⌘V
    /// to paste" when injection degrades to clipboard-only). Renders only while the
    /// floating pill is enabled.
    func showTransientNotice(_ message: String, duration: TimeInterval = 3.5) {
        noticeClearWorkItem?.cancel()
        currentNotice = message
        pushCurrentStateToPanels()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentNotice = nil
                self.pushCurrentStateToPanels()
            }
        }
        noticeClearWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
    }

    private func pushCurrentStateToPanels() {
        let state = MacDictationPillState(
            activity: Self.activity(for: coordinator.status),
            liveInputLevel: coordinator.liveInputLevel,
            shortcutTokens: configuration.keyboardShortcut.displayTokens,
            notice: currentNotice
        )
        syncPanelState(state)
    }

    private func bindState() {
        coordinator.$status
            .combineLatest(coordinator.$liveInputLevel, configuration.$keyboardShortcut)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status, liveInputLevel, shortcut in
                guard let self else { return }
                let state = MacDictationPillState(
                    activity: Self.activity(for: status),
                    liveInputLevel: liveInputLevel,
                    shortcutTokens: shortcut.displayTokens,
                    notice: currentNotice
                )
                // M-2: only push state to the panels here. Repositioning happens
                // on screen-parameter / visibility changes, not on every level tick.
                syncPanelState(state)
            }
            .store(in: &cancellables)

        configuration.$floatingDictationPillEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updatePanelVisibility()
            }
            .store(in: &cancellables)
    }

    private func installObservers() {
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updatePanelVisibility()
            }
            .store(in: &cancellables)

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshFocusedScreen()
                    self?.repositionPanels()
                }
            }
        )
    }

    private func syncPanels() {
        // Use uniquingKeysWith to avoid a trap when two screens report the same
        // NSScreenNumber during mirroring transitions (L-7).
        let screensByID = Dictionary(
            NSScreen.screens.compactMap { screen in
                screenID(for: screen).map { ($0, screen) }
            },
            uniquingKeysWith: { first, _ in first }
        )

        let existingIDs = Set(panelEntries.keys)
        let currentIDs = Set(screensByID.keys)

        for removedID in existingIDs.subtracting(currentIDs) {
            panelEntries[removedID]?.panel.orderOut(nil)
            panelEntries.removeValue(forKey: removedID)
        }

        for (screenID, screen) in screensByID where panelEntries[screenID] == nil {
            let viewModel = MacDictationPillViewModel()
            let panel = MacDictationPillPanel(
                contentRect: CGRect(origin: .zero, size: MacDictationPillLayout.panelSize)
            )
            panel.contentView = NSHostingView(
                rootView: MacDictationPillRootView(
                    viewModel: viewModel,
                    onToggle: onToggle,
                    recentTranscriptsProvider: recentTranscriptsProvider,
                    onPasteTranscript: pasteTranscript
                )
                .frame(width: MacDictationPillLayout.panelSize.width, height: MacDictationPillLayout.panelSize.height)
            )
            panelEntries[screenID] = (panel: panel, viewModel: viewModel)
            let origin = MacDictationPillLayout.panelOrigin(in: screen.visibleFrame)
            panel.setFrame(CGRect(origin: origin, size: MacDictationPillLayout.panelSize), display: true)
        }

        syncPanelState(
            MacDictationPillState(
                activity: Self.activity(for: coordinator.status),
                liveInputLevel: coordinator.liveInputLevel,
                shortcutTokens: configuration.keyboardShortcut.displayTokens
            )
        )
        refreshFocusedScreen()
        repositionPanels()

        if configuration.floatingDictationPillEnabled {
            for entry in panelEntries.values {
                entry.panel.orderFrontRegardless()
            }
        }
    }

    private func updatePanelVisibility() {
        syncPanels()

        if configuration.floatingDictationPillEnabled {
            repositionPanels()
            for entry in panelEntries.values {
                entry.panel.orderFrontRegardless()
            }
        } else {
            for entry in panelEntries.values {
                entry.panel.orderOut(nil)
            }
        }
        updateFocusTimer()
    }

    /// The mouse-location poll only matters when the pill is visible across more
    /// than one screen (to highlight the focused one). Gate it accordingly and
    /// stop it entirely otherwise (M-3).
    private func updateFocusTimer() {
        let shouldRun = configuration.floatingDictationPillEnabled
            && !panelEntries.isEmpty
            && NSScreen.screens.count > 1
        guard shouldRun else {
            focusTimer?.cancel()
            focusTimer = nil
            return
        }
        guard focusTimer == nil else { return }
        focusTimer = Timer.publish(every: 0.2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshFocusedScreen()
            }
    }

    private func syncPanelState(_ state: MacDictationPillState) {
        for entry in panelEntries.values {
            entry.viewModel.state = state
        }
    }

    private func repositionPanels() {
        guard configuration.floatingDictationPillEnabled else { return }

        for screen in NSScreen.screens {
            guard let screenID = screenID(for: screen), let entry = panelEntries[screenID] else { continue }
            let origin = MacDictationPillLayout.panelOrigin(in: screen.visibleFrame)
            entry.panel.setFrame(
                CGRect(origin: origin, size: MacDictationPillLayout.panelSize),
                display: true
            )
        }
    }

    private func refreshFocusedScreen() {
        let activeID = activeScreen().flatMap(screenID(for:))
        for (screenID, entry) in panelEntries {
            let isFocused = screenID == activeID
            if entry.viewModel.isFocusedScreen != isFocused {
                entry.viewModel.isFocusedScreen = isFocused
            }
        }
    }

    private func activeScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        if let mouseScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return mouseScreen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func screenID(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return number.stringValue
    }

    private static func activity(for status: DictationStatus) -> MacDictationPillState.Activity {
        switch status {
        case .idle:
            return .idle
        case .listening:
            return .listening
        case .processing:
            return .processing
        case .error:
            // Launch-time connection hiccups should not make the idle pill look broken.
            // The main app surfaces the actual error state elsewhere when needed.
            return .idle
        }
    }
}

private final class MacDictationPillPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: CGRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed = false
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = .utilityWindow
    }
}

func macDictationPillDisplayActivity(
    for activity: MacDictationPillState.Activity,
    isFocusedScreen: Bool
) -> MacDictationPillState.Activity {
    guard isFocusedScreen else { return .idle }
    return activity
}

private struct MacDictationPillRootView: View {
    @ObservedObject var viewModel: MacDictationPillViewModel
    let onToggle: () -> Void
    let recentTranscriptsProvider: () -> [PillTranscriptItem]
    let onPasteTranscript: (String) -> Void

    @State private var isHovered = false
    @State private var displayedShellActivity: MacDictationPillState.Activity = .idle
    @State private var displayedShellAppearance: MacDictationPillState.Activity = .idle
    @State private var displayedActiveActivity: MacDictationPillState.Activity = .idle
    @State private var activeContentOpacity = 0.0
    @State private var pendingIdleAppearanceWorkItem: DispatchWorkItem?
    @State private var pendingIdleShrinkWorkItem: DispatchWorkItem?
    @State private var pendingContentRevealWorkItem: DispatchWorkItem?

    // MARK: Recents card (hover-history) state
    @State private var isRecentsZoneHovered = false
    @State private var isRecentsCardHovered = false
    @State private var isRecentsCardExpanded = false
    @State private var recentItems: [PillTranscriptItem] = []
    @State private var copiedItemID: String?
    @State private var recentsDwellWorkItem: DispatchWorkItem?
    @State private var recentsCollapseGraceWorkItem: DispatchWorkItem?
    @State private var copiedResetWorkItem: DispatchWorkItem?

    private let pillAnimation = Animation.spring(response: 0.34, dampingFraction: 0.84)
    private let expandedPillHeight: CGFloat = 32
    private let contentFadeDuration: TimeInterval = 0.10
    private let contentRevealDelay: TimeInterval = 0.03
    private let idleShrinkDelay: TimeInterval = 0.04

    // Shared with the hover-hint bubble transition so the card feels like the same
    // element expanding, not a separate popover.
    private let recentsCardAnimation = Animation.spring(response: 0.24, dampingFraction: 0.84)
    private let recentsDwellDelay: TimeInterval = 0.3
    private let recentsCollapseGraceDelay: TimeInterval = 0.2
    private let copiedFlashDuration: TimeInterval = 1.2

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
                .allowsHitTesting(false)

            Button(action: onToggle) {
                pillBody
            }
            .buttonStyle(.plain)
            .padding(.bottom, 2)
            .onHover { hovering in
                withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
                    isHovered = hovering
                }
            }
            .background(
                // Enlarged, invisible hover-detection zone so the recents card is
                // discoverable without needing pixel-precise hovering over the tiny
                // 56x8 idle strip. No gesture/button here, so it never intercepts
                // clicks — it only observes hover.
                Color.clear
                    .contentShape(Rectangle())
                    .frame(
                        width: MacDictationPillLayout.recentsHoverZoneSize.width,
                        height: MacDictationPillLayout.recentsHoverZoneSize.height
                    )
                    .onHover { hovering in
                        isRecentsZoneHovered = hovering
                        handleRecentsHoverChange()
                    }
            )

            if isRecentsCardExpanded {
                MacDictationRecentsCardView(
                    items: recentItems,
                    promptHintText: viewModel.state.promptText,
                    copiedItemID: $copiedItemID,
                    onCopy: handleCopyRecentItem,
                    onPaste: handlePasteRecentItem,
                    onOpenKleio: handleOpenKleioFromCard
                )
                .padding(.bottom, expandedPillHeight + 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onHover { hovering in
                    isRecentsCardHovered = hovering
                    handleRecentsHoverChange()
                }
            } else if let bubbleText {
                Text(bubbleText)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.96))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(.black.opacity(0.92))
                    )
                    .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
                    .padding(.bottom, expandedPillHeight + 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(width: MacDictationPillLayout.panelSize.width, height: MacDictationPillLayout.panelSize.height)
        .animation(.spring(response: 0.24, dampingFraction: 0.84), value: viewModel.state.notice)
        .onAppear {
            syncDisplayedActivity(for: effectiveActivity, animated: false)
        }
        .onChange(of: viewModel.state.activity) { _, newActivity in
            syncDisplayedActivity(
                for: macDictationPillDisplayActivity(
                    for: newActivity,
                    isFocusedScreen: viewModel.isFocusedScreen
                ),
                animated: viewModel.isFocusedScreen
            )
            if newActivity != .idle {
                collapseRecentsCardImmediately()
            }
        }
        .onChange(of: viewModel.isFocusedScreen) { _, isFocusedScreen in
            syncDisplayedActivity(
                for: macDictationPillDisplayActivity(
                    for: viewModel.state.activity,
                    isFocusedScreen: isFocusedScreen
                ),
                animated: isFocusedScreen
            )
            if !isFocusedScreen {
                collapseRecentsCardImmediately()
            }
        }
        .onChange(of: viewModel.state.notice) { _, notice in
            // Transient notices (injection fallback, persist failure) take
            // precedence over the hover recents card.
            if notice != nil {
                collapseRecentsCardImmediately()
            }
        }
    }

    private var showsPromptBubble: Bool {
        isHovered && viewModel.state.activity == .idle
    }

    // A transient notice (injection fallback, persist failure) takes precedence
    // over the hover shortcut hint.
    private var bubbleText: String? {
        if let notice = viewModel.state.notice, viewModel.isFocusedScreen {
            return notice
        }
        return showsPromptBubble ? viewModel.state.promptText : nil
    }

    // MARK: - Recents card choreography

    private var canShowRecentsCard: Bool {
        viewModel.state.activity == .idle
            && viewModel.isFocusedScreen
            && viewModel.state.notice == nil
    }

    private func handleRecentsHoverChange() {
        let isHoveringPillOrCard = isRecentsZoneHovered || isRecentsCardHovered

        if isHoveringPillOrCard {
            recentsCollapseGraceWorkItem?.cancel()
            recentsCollapseGraceWorkItem = nil

            guard canShowRecentsCard, !isRecentsCardExpanded, recentsDwellWorkItem == nil else { return }

            let workItem = DispatchWorkItem {
                recentsDwellWorkItem = nil
                guard canShowRecentsCard, isRecentsZoneHovered || isRecentsCardHovered else { return }
                recentItems = recentTranscriptsProvider()
                withAnimation(recentsCardAnimation) {
                    isRecentsCardExpanded = true
                }
            }
            recentsDwellWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + recentsDwellDelay, execute: workItem)
        } else {
            recentsDwellWorkItem?.cancel()
            recentsDwellWorkItem = nil

            guard isRecentsCardExpanded, recentsCollapseGraceWorkItem == nil else { return }

            let workItem = DispatchWorkItem {
                recentsCollapseGraceWorkItem = nil
                guard !(isRecentsZoneHovered || isRecentsCardHovered) else { return }
                withAnimation(recentsCardAnimation) {
                    isRecentsCardExpanded = false
                }
            }
            recentsCollapseGraceWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + recentsCollapseGraceDelay, execute: workItem)
        }
    }

    private func collapseRecentsCardImmediately() {
        recentsDwellWorkItem?.cancel()
        recentsDwellWorkItem = nil
        recentsCollapseGraceWorkItem?.cancel()
        recentsCollapseGraceWorkItem = nil
        guard isRecentsCardExpanded else { return }
        withAnimation(recentsCardAnimation) {
            isRecentsCardExpanded = false
        }
    }

    private func handleCopyRecentItem(_ item: PillTranscriptItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.text, forType: .string)

        copiedResetWorkItem?.cancel()
        copiedItemID = item.id

        let workItem = DispatchWorkItem {
            copiedResetWorkItem = nil
            guard copiedItemID == item.id else { return }
            copiedItemID = nil
        }
        copiedResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + copiedFlashDuration, execute: workItem)
    }

    private func handlePasteRecentItem(_ item: PillTranscriptItem) {
        // Collapse first so the synthetic ⌘V lands with the card gone — the panel
        // never becomes key, so the frontmost app keeps focus throughout.
        collapseRecentsCardImmediately()
        onPasteTranscript(item.text)
    }

    private func handleOpenKleioFromCard() {
        collapseRecentsCardImmediately()
        NotificationCenter.default.post(name: .openMainDashboard, object: nil)
    }

    private var pillBody: some View {
        ZStack {
            pillChrome(
                fill: shellFill,
                border: shellBorderColor,
                lineWidth: shellBorderWidth,
                shadow: shellShadowColor,
                shadowRadius: shellShadowRadius,
                shadowOffsetY: shellShadowOffsetY
            )
            .frame(width: shellMetrics.width, height: shellMetrics.height)

            activePillContent
                .opacity(activeContentOpacity)
        }
        .frame(width: shellMetrics.width, height: shellMetrics.height)
    }

    private func pillChrome<Fill: ShapeStyle>(
        fill: Fill,
        border: Color,
        lineWidth: CGFloat,
        shadow: Color,
        shadowRadius: CGFloat,
        shadowOffsetY: CGFloat
    ) -> some View {
        Capsule()
            .fill(fill)
            .overlay(
                Capsule()
                    .stroke(border, lineWidth: lineWidth)
            )
            .shadow(color: shadow, radius: shadowRadius, y: shadowOffsetY)
    }

    private var activePillContent: some View {
        currentActivePillContent
        .padding(.horizontal, shellMetrics.horizontalPadding)
        .frame(width: shellMetrics.width, height: shellMetrics.height)
        .contentTransition(.opacity)
    }

    @ViewBuilder
    private var currentActivePillContent: some View {
        switch displayedActiveActivity {
        case .idle:
            Color.clear
        case .listening:
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.orange.opacity(0.92))
                    .frame(width: 8, height: 8)
                DictationWaveformView(
                    level: viewModel.state.liveInputLevel,
                    isAnimated: viewModel.isFocusedScreen
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        case .processing:
            ProcessingDotsView(isAnimated: viewModel.isFocusedScreen)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        case .error:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.orange.opacity(0.95))
                Text("Ready")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func syncDisplayedActivity(
        for activity: MacDictationPillState.Activity,
        animated: Bool
    ) {
        cancelPendingTransitionWorkItems()

        if activity == .idle {
            let fade = {
                activeContentOpacity = 0
            }
            if animated {
                withAnimation(.easeOut(duration: contentFadeDuration), fade)
            } else {
                fade()
            }

            let appearanceWorkItem = DispatchWorkItem {
                guard effectiveActivity == .idle else { return }
                displayedActiveActivity = .idle
                let settleAppearance = {
                    displayedShellAppearance = .idle
                }
                if animated {
                    withAnimation(.easeOut(duration: 0.08), settleAppearance)
                } else {
                    settleAppearance()
                }
            }
            pendingIdleAppearanceWorkItem = appearanceWorkItem
            DispatchQueue.main.asyncAfter(deadline: .now() + contentFadeDuration, execute: appearanceWorkItem)

            let shrinkWorkItem = DispatchWorkItem {
                guard effectiveActivity == .idle else { return }
                let collapse = {
                    displayedShellActivity = .idle
                }
                if animated {
                    withAnimation(pillAnimation, collapse)
                } else {
                    collapse()
                }
            }
            pendingIdleShrinkWorkItem = shrinkWorkItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + contentFadeDuration + (animated ? idleShrinkDelay : 0),
                execute: shrinkWorkItem
            )
            return
        }

        let isExpandingFromIdle = displayedShellActivity == .idle

        let updateShell = {
            displayedShellAppearance = activity
            displayedShellActivity = activity
        }
        if animated {
            withAnimation(pillAnimation, updateShell)
        } else {
            updateShell()
        }

        displayedActiveActivity = activity

        if isExpandingFromIdle {
            activeContentOpacity = 0
            let revealWorkItem = DispatchWorkItem {
                guard effectiveActivity == activity else { return }
                let reveal = {
                    activeContentOpacity = 1
                }
                if animated {
                    withAnimation(.easeOut(duration: 0.16), reveal)
                } else {
                    reveal()
                }
            }
            pendingContentRevealWorkItem = revealWorkItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + (animated ? contentRevealDelay : 0),
                execute: revealWorkItem
            )
        } else {
            activeContentOpacity = 1
        }
    }

    private func cancelPendingTransitionWorkItems() {
        pendingIdleAppearanceWorkItem?.cancel()
        pendingIdleAppearanceWorkItem = nil
        pendingIdleShrinkWorkItem?.cancel()
        pendingIdleShrinkWorkItem = nil
        pendingContentRevealWorkItem?.cancel()
        pendingContentRevealWorkItem = nil
    }

    private var effectiveActivity: MacDictationPillState.Activity {
        macDictationPillDisplayActivity(
            for: viewModel.state.activity,
            isFocusedScreen: viewModel.isFocusedScreen
        )
    }

    private var shellMetrics: (width: CGFloat, height: CGFloat, horizontalPadding: CGFloat) {
        switch displayedShellActivity {
        case .idle:
            return (width: 56, height: 8, horizontalPadding: 0)
        case .listening:
            return (width: 106, height: 32, horizontalPadding: 16)
        case .processing:
            return (width: 60, height: 32, horizontalPadding: 16)
        case .error:
            return (width: 96, height: 32, horizontalPadding: 16)
        }
    }

    private var shellFill: AnyShapeStyle {
        switch displayedShellAppearance {
        case .idle:
            return AnyShapeStyle(.black.opacity(0.86))
        case .listening:
            return AnyShapeStyle(LinearGradient(
                colors: [
                    Color.orange.opacity(0.20),
                    .black.opacity(0.94),
                    Color.orange.opacity(0.26)
                ],
                startPoint: .leading,
                endPoint: .trailing
            ))
        case .processing:
            return AnyShapeStyle(LinearGradient(
                colors: [
                    Color.orange.opacity(0.20),
                    .black.opacity(0.94),
                    Color.orange.opacity(0.26)
                ],
                startPoint: .leading,
                endPoint: .trailing
            ))
        case .error:
            return AnyShapeStyle(LinearGradient(
                colors: [.black.opacity(0.94), Color.orange.opacity(0.22)],
                startPoint: .leading,
                endPoint: .trailing
            ))
        }
    }

    private var shellBorderColor: Color {
        switch displayedShellAppearance {
        case .idle:
            return .white.opacity(0.08)
        case .listening:
            return Color.orange.opacity(0.32)
        case .processing:
            return Color.orange.opacity(0.32)
        case .error:
            return Color.orange.opacity(0.24)
        }
    }

    private var shellBorderWidth: CGFloat {
        displayedShellAppearance == .idle ? 0.75 : 1
    }

    private var shellShadowColor: Color {
        switch displayedShellAppearance {
        case .idle:
            return .black.opacity(0.12)
        case .listening, .processing:
            return Color.orange.opacity(0.22)
        case .error:
            return .black.opacity(0.18)
        }
    }

    private var shellShadowRadius: CGFloat {
        displayedShellAppearance == .idle ? 4 : 18
    }

    private var shellShadowOffsetY: CGFloat {
        displayedShellAppearance == .idle ? 1.5 : 8
    }
}

private struct DictationWaveformView: View {
    let level: Double
    let isAnimated: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !isAnimated)) { context in
            let seconds = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<12, id: \.self) { index in
                    Capsule()
                        .fill(.white.opacity(index.isMultiple(of: 3) ? 0.96 : 0.82))
                        .frame(width: 3, height: barHeight(at: index, time: seconds))
                }
            }
            .frame(width: 56, height: 18)
        }
    }

    private func barHeight(at index: Int, time: TimeInterval) -> CGFloat {
        let amplitude = max(0.16, min(level, 1))
        let phase = time * 7.6 + (Double(index) * 0.55)
        let pulse = (sin(phase) + 1) * 0.5
        let floor: CGFloat = 4
        let ceiling: CGFloat = 16
        return floor + ((ceiling - floor) * CGFloat((amplitude * 0.72) + (pulse * amplitude * 0.6)))
    }
}

private struct ProcessingDotsView: View {
    private enum Metrics {
        static let dotDiameter: CGFloat = 5
        static let dotSpacing: CGFloat = 4
        static let contentWidth: CGFloat = (dotDiameter * 3) + (dotSpacing * 2)
    }

    let isAnimated: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 18, paused: !isAnimated)) { context in
            let seconds = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: Metrics.dotSpacing) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(.white.opacity(dotOpacity(at: index, time: seconds)))
                        .frame(width: Metrics.dotDiameter, height: Metrics.dotDiameter)
                }
            }
            .frame(width: Metrics.contentWidth, height: Metrics.dotDiameter)
        }
    }

    private func dotOpacity(at index: Int, time: TimeInterval) -> Double {
        let phase = time * 4.8 + (Double(index) * 0.45)
        return 0.28 + (((sin(phase) + 1) * 0.5) * 0.72)
    }
}

/// The Wispr-Flow-style hover-history card: last-3 transcripts, revealed row
/// actions, and a footer that opens the full app. Matches the pill's existing
/// dark-bubble visual language (black.opacity(0.92) fill, white text) and reserves
/// the ember orange accent for small on-hover/confirmation touches only.
private struct MacDictationRecentsCardView: View {
    let items: [PillTranscriptItem]
    let promptHintText: String
    @Binding var copiedItemID: String?
    let onCopy: (PillTranscriptItem) -> Void
    let onPaste: (PillTranscriptItem) -> Void
    let onOpenKleio: () -> Void

    @State private var hoveredItemID: String?

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private let cardWidth: CGFloat = 312

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if items.isEmpty {
                Text("No recent dictations yet")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { item in
                        row(for: item)
                    }
                }
                .padding(.vertical, 6)
            }

            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 1)

            HStack(spacing: 8) {
                Button(action: onOpenKleio) {
                    Text("Open Kleio")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .buttonStyle(.plain)

                Spacer(minLength: 8)

                Text(promptHintText)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: cardWidth)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.black.opacity(0.92))
        )
        .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
    }

    @ViewBuilder
    private func row(for item: PillTranscriptItem) -> some View {
        let isRowHovered = hoveredItemID == item.id
        HStack(spacing: 8) {
            Text(Self.relativeFormatter.localizedString(for: item.timestamp, relativeTo: Date()))
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 42, alignment: .leading)
                .lineLimit(1)

            iconView(for: item)

            Text(item.text)
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isRowHovered {
                rowActions(for: item)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background(isRowHovered ? Color.white.opacity(0.06) : Color.clear)
        .animation(.easeOut(duration: 0.12), value: isRowHovered)
        .onHover { hovering in
            hoveredItemID = hovering ? item.id : (hoveredItemID == item.id ? nil : hoveredItemID)
        }
    }

    @ViewBuilder
    private func rowActions(for item: PillTranscriptItem) -> some View {
        let isCopied = copiedItemID == item.id
        HStack(spacing: 8) {
            Button {
                onCopy(item)
            } label: {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(isCopied ? Color.orange.opacity(0.95) : Color.orange.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help(isCopied ? "Copied" : "Copy")

            Button {
                onPaste(item)
            } label: {
                Image(systemName: "arrow.turn.down.left")
                    .foregroundStyle(Color.orange.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help("Paste")
        }
        .font(.system(size: 11, weight: .semibold))
    }

    @ViewBuilder
    private func iconView(for item: PillTranscriptItem) -> some View {
        if let data = item.iconPNGData, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            PillRecentsMonogramView(appName: item.appName)
        }
    }
}

/// Fallback avatar for rows whose source app icon wasn't captured at dictation
/// time (e.g. older history entries, or apps that don't vend an icon).
private struct PillRecentsMonogramView: View {
    let appName: String?

    var body: some View {
        Circle()
            .fill(Color.white.opacity(0.14))
            .frame(width: 16, height: 16)
            .overlay(
                Text(monogram)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
            )
    }

    private var monogram: String {
        guard let appName, let first = appName.trimmingCharacters(in: .whitespaces).first else {
            return "?"
        }
        return String(first).uppercased()
    }
}
