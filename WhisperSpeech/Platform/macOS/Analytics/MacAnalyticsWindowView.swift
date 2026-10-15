import SwiftUI
import AppKit
import SwiftData

struct MacAnalyticsWindowView: View {
    let history: DashboardHistory
    @Binding var dateRange: AnalyticsDateRange
    let onLoadOlder: () -> Void

    @State private var section: DashboardSection
    // One window-level modal for every surface that opens an entry, so the scrim
    // covers the sidebar too.
    @State private var selectedDetailEntry: DictationHistoryEntry?

    init(history: DashboardHistory, dateRange: Binding<AnalyticsDateRange>, onLoadOlder: @escaping () -> Void) {
        self.history = history
        self._dateRange = dateRange
        self.onLoadOlder = onLoadOlder
        var initialSection = DashboardSection.overview
        #if DEBUG
        // Screenshot hook: `open Kleio.app --args -kleio.debug.initialSection dictations`.
        if let stored = UserDefaults.standard.string(forKey: "kleio.debug.initialSection"),
           let debugSection = DashboardSection(rawValue: stored) {
            initialSection = debugSection
        }
        #endif
        _section = State(initialValue: initialSection)
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                MacDashboardSidebarView(selection: $section)
                    .frame(width: 228)

                Divider()
                    .overlay(KleioPalette.stroke)

                currentSectionView
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(KleioPalette.page)
            .ignoresSafeArea(.container, edges: .top)
            .accessibilityHidden(selectedDetailEntry != nil)

            if let selectedDetailEntry {
                MacDictationDetailOverlay(
                    entry: selectedDetailEntry,
                    onClose: { self.selectedDetailEntry = nil }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .zIndex(30)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: selectedDetailEntry != nil)
        .navigationTitle(section.title)
        .onReceive(NotificationCenter.default.publisher(for: .showSettingsOverlay)) { _ in
            section = .settings
        }
    }

    @ViewBuilder
    private var currentSectionView: some View {
        switch section {
        case .overview:
            MacHomeDashboardView(
                history: history,
                onSelectEntry: { selectedDetailEntry = $0 },
                onShowDictations: { section = .dictations }
            )
        case .dictations:
            MacReferenceDictationsPage(
                history: history,
                onSelectEntry: { selectedDetailEntry = $0 },
                onLoadOlder: onLoadOlder
            )
        case .styles:
            MacReferenceStylesPage()
        case .analytics:
            MacReferenceAnalyticsPage(history: history, dateRange: $dateRange)
        case .settings:
            MacReferenceSettingsPage()
        }
    }
}

// MARK: - Sidebar

private struct MacDashboardSidebarView: View {
    @Binding var selection: DashboardSection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.horizontal, 22)
                .padding(.top, 52)
                .padding(.bottom, 26)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                // The hidden titlebar leaves no chrome to grab; the brand area moves the window.
                .gesture(WindowDragGesture())

            VStack(spacing: 4) {
                ForEach(DashboardSection.allCases) { item in
                    MacDashboardSidebarRow(item: item, isSelected: selection == item) {
                        selection = item
                    }
                }
            }
            .padding(.horizontal, 14)

            Spacer(minLength: 18)

            MacDashboardStatusCard()
                .padding(.horizontal, 14)
                .padding(.bottom, 16)

            Divider()
                .overlay(KleioPalette.stroke)

            MacDashboardAccountRow(selection: $selection)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
        .background(Color.white.opacity(0.62))
    }

    private var brand: some View {
        HStack(spacing: 12) {
            Image("Kleio.icon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(KleioPalette.brand)
                .frame(width: 30, height: 30)

            Text("KLEIO")
                .font(.system(size: 20, weight: .regular, design: .serif))
                .tracking(6)
                .foregroundStyle(KleioPalette.ink)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Kleio")
    }
}

private struct MacDashboardSidebarRow: View {
    let item: DashboardSection
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: item.systemName)
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: 20)
                    .foregroundStyle(isSelected ? KleioPalette.action : KleioPalette.ink.opacity(0.8))

                Text(item.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(KleioPalette.ink.opacity(isSelected ? 1 : 0.85))

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? KleioPalette.selection : (isHovered ? KleioPalette.selection.opacity(0.5) : .clear))
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(KleioPalette.action)
                        .frame(width: 3, height: 16)
                        .padding(.leading, 2)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .kleioPointer()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Live dictation status plus the one thing the user can act on: how to start, or
/// what's blocking the shortcut.
private struct MacDashboardStatusCard: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject private var configuration = AppConfiguration.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusTint)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(KleioPalette.ink)
                    .lineLimit(1)
            }

            if let blocker {
                Button(blocker.action) {
                    appModel.refreshAccessibilityPermissionStatus(promptIfNeeded: true)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(KleioPalette.action)
                .kleioPointer()
            } else if case .error(let message) = appModel.coordinator.status, !message.isEmpty {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(KleioPalette.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let connectionNote {
                Text(connectionNote)
                    .font(.system(size: 11))
                    .foregroundStyle(KleioPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Hold \(configuration.keyboardShortcut.displayLabel) to dictate anywhere")
                    .font(.system(size: 11))
                    .foregroundStyle(KleioPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KleioPalette.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(KleioPalette.stroke, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private enum Blocker {
        case accessibility
        case shortcutInactive

        var title: String {
            switch self {
            case .accessibility: return "Accessibility access needed"
            case .shortcutInactive: return "Shortcut inactive"
            }
        }

        var action: String {
            switch self {
            case .accessibility: return "Grant access…"
            case .shortcutInactive: return "Fix shortcut…"
            }
        }
    }

    /// Only shown while nothing is in flight, so it never covers live status.
    private var blocker: Blocker? {
        switch appModel.coordinator.status {
        case .listening, .processing:
            return nil
        case .idle, .error:
            if !appModel.accessibilityPermissionGranted { return .accessibility }
            if !appModel.hotkeyActive { return .shortcutInactive }
            return nil
        }
    }

    /// True while idle and the server connection is being (re)established — shown
    /// instead of "Ready" so the card never claims more than is true.
    private var isReconnecting: Bool {
        guard appModel.coordinator.status == .idle else { return false }
        switch appModel.coordinator.connectionState {
        case .connecting, .sleeping, .reconnecting: return true
        case .connected, .disconnected: return false
        }
    }

    private var connectionNote: String? {
        isReconnecting ? "Dictation will start as soon as the server answers" : nil
    }

    private var statusText: String {
        if let blocker { return blocker.title }
        if isReconnecting { return "Connecting to server…" }
        switch appModel.coordinator.status {
        case .idle: return "Ready"
        case .listening: return "Listening"
        case .processing: return "Processing"
        case .error: return "Last dictation failed"
        }
    }

    private var statusTint: Color {
        if blocker != nil || isReconnecting { return KleioPalette.attention }
        switch appModel.coordinator.status {
        case .idle: return KleioPalette.positive
        case .listening: return KleioPalette.live
        case .processing: return KleioPalette.attention
        case .error: return KleioPalette.danger
        }
    }
}

/// Local workspace or optional account summary.
private struct MacDashboardAccountRow: View {
    @EnvironmentObject private var appModel: AppModel
    @Binding var selection: DashboardSection

    @State private var isHovered = false
    @State private var isConfirmingSignOut = false

    private var session: AccountSessionSnapshot? {
        appModel.sessionManager.currentSession
    }

    var body: some View {
        Menu {
            Button("Settings") { selection = .settings }
            if session != nil {
                Divider()
                Button("Sign Out…") { isConfirmingSignOut = true }
            }
        } label: {
            HStack(spacing: 10) {
                KleioAvatar(name: session?.primaryLabel ?? "", size: 32)

                VStack(alignment: .leading, spacing: 1) {
                    Text(session?.primaryLabel ?? "Local workspace")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(KleioPalette.ink)
                        .lineLimit(1)
                    if let email = session?.email, email != session?.primaryLabel {
                        Text(email)
                            .font(.system(size: 11))
                            .foregroundStyle(KleioPalette.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(KleioPalette.secondary)
            }
            .padding(6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? KleioPalette.selection : .clear)
            )
        }
        // `.menuStyle(.borderlessButton)` can leave a custom label blank; the plain idiom draws it.
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { isHovered = $0 }
        .kleioPointer()
        .signOutConfirmation(isPresented: $isConfirmingSignOut)
    }
}

// MARK: - Sign-out confirmation

extension View {
    /// Signing out deletes this account's dictation history from the Mac, so every
    /// Sign Out entry point confirms first and says so.
    func signOutConfirmation(isPresented: Binding<Bool>) -> some View {
        modifier(SignOutConfirmationModifier(isPresented: isPresented))
    }
}

private struct SignOutConfirmationModifier: ViewModifier {
    @EnvironmentObject private var appModel: AppModel
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.alert("Sign out of Kleio?", isPresented: $isPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) {
                Task { await appModel.sessionManager.signOutToLocalMode() }
            }
        } message: {
            Text("Your dictation history for this account will be removed from this Mac.")
        }
    }
}

// MARK: - Sections

enum DashboardSection: String, CaseIterable, Identifiable {
    case overview
    case dictations
    case styles
    case analytics
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .dictations: return "Dictations"
        case .styles: return "Styles"
        case .analytics: return "Analytics"
        case .settings: return "Settings"
        }
    }

    var systemName: String {
        switch self {
        case .overview: return "house"
        case .dictations: return "doc.text"
        case .styles: return "textformat"
        case .analytics: return "chart.bar.xaxis"
        case .settings: return "gearshape"
        }
    }
}
