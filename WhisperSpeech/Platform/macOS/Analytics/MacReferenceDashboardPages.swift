import AVFoundation
import SwiftData
import SwiftUI

// MARK: - Page chrome

/// Shared page layout: serif title, one-line subtitle, optional trailing control
/// (search or range picker), then content. The header doubles as a window drag area.
struct KleioPage<Accessory: View, Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.system(size: 30, weight: .regular, design: .serif))
                            .foregroundStyle(KleioPalette.ink)
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(KleioPalette.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    accessory
                }
                .padding(.bottom, 6)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())

                content
            }
            .padding(.horizontal, 28)
            .padding(.top, 34)
            .padding(.bottom, 28)
        }
    }
}

extension KleioPage where Accessory == EmptyView {
    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, accessory: { EmptyView() }, content: content)
    }
}

// MARK: - Shared entry cells

/// "Recovered" / "Imported" marker shown inline after a transcript.
struct EntryKindBadge: View {
    let entry: DictationHistoryEntry

    var body: some View {
        if entry.isImportedAudio {
            KleioStatusChip("Imported", color: KleioPalette.secondary)
        } else if entry.isFailedRawFallback {
            KleioStatusChip("Recovered", color: KleioPalette.attention)
                .help("Cleanup failed; this is the raw transcript.")
        }
    }
}

struct StyleDotLabel: View {
    let entry: DictationHistoryEntry

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(entry.outputPreset?.kleioColor ?? KleioPalette.stroke)
                .frame(width: 8, height: 8)
            Text(entry.styleName ?? "—")
                .foregroundStyle(entry.styleName == nil ? KleioPalette.secondary : KleioPalette.ink)
                .lineLimit(1)
        }
    }
}

struct SourceAppLabel: View {
    let entry: DictationHistoryEntry

    var body: some View {
        HStack(spacing: 7) {
            if entry.isImportedAudio {
                Image(systemName: "waveform")
                    .font(.system(size: 11))
                    .foregroundStyle(KleioPalette.secondary)
                    .frame(width: 16)
            } else {
                KleioSourceAppIcon(entry: entry, size: 16)
            }
            Text(entry.sourceAppDisplayName ?? "Unknown app")
                .foregroundStyle(entry.sourceAppDisplayName == nil ? KleioPalette.secondary : KleioPalette.ink)
                .lineLimit(1)
        }
    }
}

/// Copy actions that only copy real text — never the model's placeholder strings.
struct EntryCopyMenuItems: View {
    let entry: DictationHistoryEntry

    var body: some View {
        Button("Copy Cleaned Text") { KleioPasteboard.copy(entry.finalText) }
            .disabled(!entry.hasCleanedText)
        Button("Copy Raw Text") { KleioPasteboard.copy(entry.rawText ?? "") }
            .disabled(!entry.hasRawText)
    }
}

enum KleioPasteboard {
    static func copy(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(trimmed, forType: .string)
    }
}

/// Transcribes an audio file into history. The import is fully separate from live
/// dictation (own socket session, never injects text).
struct ImportAudioButton: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var isImporting = false
    @State private var errorMessage: String?

    var body: some View {
        KleioSecondaryButton(
            title: isImporting ? "Importing…" : "Import Audio",
            systemImage: "square.and.arrow.down",
            action: startImport
        )
        .disabled(isImporting)
        .help("Transcribe an audio file into your history")
        .alert(
            "Couldn't import audio",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func startImport() {
        isImporting = true
        AudioImportService().presentAndImport { outcome in
            isImporting = false
            switch outcome {
            case .success(let result):
                appModel.persistImportedAudioEntry(
                    finalText: result.finalText,
                    rawText: result.rawText,
                    audioDuration: result.audioDuration,
                    wordCount: result.wordCount,
                    sourceLabel: result.sourceLabel
                )
            case .cancelled:
                break
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Trailing menu pill (value + chevron) that opens a real menu of options.
struct KleioMenuPill<Option: Hashable>: View {
    let options: [Option]
    let selection: Option
    let label: (Option) -> String
    var detail: ((Option) -> String)? = nil
    var systemImage: String? = nil
    let onSelect: (Option) -> Void

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    onSelect(option)
                } label: {
                    if let detail = detail?(option) {
                        // Two-line labels render reliably in NSMenu-backed menus; the
                        // checkmark is a text prefix rather than a nested Image.
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option == selection ? "✓ \(label(option))" : label(option))
                            Text(detail).font(.caption)
                        }
                    } else if option == selection {
                        Label(label(option), systemImage: "checkmark")
                    } else {
                        Text(label(option))
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(label(selection))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(KleioPalette.ink)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(KleioPalette.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(KleioPalette.stroke, lineWidth: 1))
        }
        // `.menuStyle(.borderlessButton)` leaves custom labels blank in cards; the plain idiom draws them.
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .kleioPointer()
    }
}

// MARK: - Dictations

struct MacReferenceDictationsPage: View {
    let history: DashboardHistory
    let onSelectEntry: (DictationHistoryEntry) -> Void
    let onLoadOlder: () -> Void

    @State private var searchText = ""
    @State private var filter: DictationFilter = .all
    // Lowercased search text per entry, rebuilt only when history reloads — not per keystroke.
    @State private var searchIndex: [PersistentIdentifier: String] = [:]
    @State private var indexedRevision = -1
    @FocusState private var isSearchFocused: Bool

    private enum DictationFilter: String, CaseIterable {
        case all = "All dictations"
        case dictated = "Dictated"
        case recovered = "Recovered"
        case imported = "Imported"

        func matches(_ entry: DictationHistoryEntry) -> Bool {
            switch self {
            case .all: return true
            case .dictated: return !entry.isImportedAudio && !entry.isFailedRawFallback
            case .recovered: return entry.isFailedRawFallback
            case .imported: return entry.isImportedAudio
            }
        }
    }

    var body: some View {
        let rows = visibleRows
        KleioPage(title: "Dictations", subtitle: "Everything you've dictated, newest first.") {
            searchField
        } content: {
            HStack(spacing: 10) {
                KleioMenuPill(
                    options: DictationFilter.allCases,
                    selection: filter,
                    label: \.rawValue,
                    systemImage: "line.3.horizontal.decrease"
                ) { filter = $0 }
                Text(countLabel(rows.count))
                    .font(.system(size: 12))
                    .foregroundStyle(KleioPalette.secondary)
                Spacer()
                ImportAudioButton()
            }

            KleioCard(padding: 0) {
                VStack(spacing: 0) {
                    DictationTableHeader()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    Divider().overlay(KleioPalette.stroke)

                    if rows.isEmpty {
                        emptyState
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(rows, id: \.persistentModelID) { entry in
                                DictationTableRow(entry: entry) { onSelectEntry(entry) }
                                Divider().overlay(KleioPalette.stroke.opacity(0.6))
                            }
                        }
                    }

                    if history.hasOlder {
                        HStack(spacing: 12) {
                            Text("Showing the \(KleioFormat.int(history.recent.count)) most recent. Search and filters cover these.")
                                .font(.system(size: 11))
                                .foregroundStyle(KleioPalette.secondary)
                            Spacer()
                            KleioSecondaryButton(title: "Show Older", systemImage: nil, action: onLoadOlder)
                        }
                        .padding(14)
                    }
                }
            }
        }
        .background(
            // ⌘K focuses search.
            Button("") { isSearchFocused = true }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        )
        .onAppear(perform: rebuildIndexIfNeeded)
        .onChange(of: history.revision) { _, _ in rebuildIndexIfNeeded() }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(KleioPalette.secondary)
            TextField("Search dictations", text: $searchText)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(KleioPalette.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            } else {
                Text("⌘K")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(KleioPalette.secondary.opacity(0.8))
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 11)
        .frame(width: 280, height: 34)
        .background(KleioPalette.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(KleioPalette.stroke, lineWidth: 1))
    }

    private var visibleRows: [DictationHistoryEntry] {
        let tokens = searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedLowercase
            .split(separator: " ")
        return history.recent.filter { entry in
            guard filter.matches(entry) else { return false }
            guard !tokens.isEmpty else { return true }
            // Every typed word must appear somewhere (text, raw text, style, app).
            let haystack = searchIndex[entry.persistentModelID] ?? Self.haystack(for: entry)
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }

    private func rebuildIndexIfNeeded() {
        guard indexedRevision != history.revision else { return }
        indexedRevision = history.revision
        searchIndex = Dictionary(
            history.recent.map { ($0.persistentModelID, Self.haystack(for: $0)) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Real fields only — placeholder copy like "unavailable" must not match.
    private static func haystack(for entry: DictationHistoryEntry) -> String {
        [entry.finalText, entry.rawText ?? "", entry.styleName ?? "", entry.sourceAppDisplayName ?? ""]
            .joined(separator: " ")
            .localizedLowercase
    }

    private func countLabel(_ count: Int) -> String {
        count == 1 ? "1 dictation" : "\(KleioFormat.int(count)) dictations"
    }

    @ViewBuilder
    private var emptyState: some View {
        if history.loadFailed && history.recent.isEmpty {
            KleioEmptyNote("Couldn't load your dictations. They'll appear when the next one finishes.")
        } else if history.recent.isEmpty {
            KleioEmptyNote("No dictations yet. Hold \(AppConfiguration.shared.keyboardShortcut.displayLabel) in any app to dictate.")
        } else {
            VStack(spacing: 8) {
                KleioEmptyNote("No dictations match.", minHeight: 40)
                Button("Clear search and filter") {
                    searchText = ""
                    filter = .all
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(KleioPalette.action)
                .kleioPointer()
            }
            .padding(.vertical, 24)
        }
    }
}

private enum DictationColumns {
    static let spacing: CGFloat = 14
    static let style: CGFloat = 104
    static let words: CGFloat = 52
    static let date: CGFloat = 132
    static let app: CGFloat = 128
    static let actions: CGFloat = 28
}

private struct DictationTableHeader: View {
    var body: some View {
        HStack(spacing: DictationColumns.spacing) {
            Text("DICTATION").frame(maxWidth: .infinity, alignment: .leading)
            Text("STYLE").frame(width: DictationColumns.style, alignment: .leading)
            Text("WORDS").frame(width: DictationColumns.words, alignment: .trailing)
            Text("DATE").frame(width: DictationColumns.date, alignment: .leading)
            Text("APP").frame(width: DictationColumns.app, alignment: .leading)
            Color.clear.frame(width: DictationColumns.actions, height: 1)
        }
        .font(.system(size: 10, weight: .bold))
        .tracking(0.9)
        .foregroundStyle(KleioPalette.secondary)
        .lineLimit(1)
    }
}

private struct DictationTableRow: View {
    let entry: DictationHistoryEntry
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: DictationColumns.spacing) {
            Button(action: onSelect) {
                HStack(spacing: DictationColumns.spacing) {
                    HStack(spacing: 8) {
                        Text(entry.hasCleanedText ? entry.finalText.trimmingCharacters(in: .whitespacesAndNewlines) : "Empty transcript")
                            .foregroundStyle(entry.hasCleanedText ? KleioPalette.ink : KleioPalette.secondary)
                            .lineLimit(1)
                        EntryKindBadge(entry: entry)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    StyleDotLabel(entry: entry)
                        .frame(width: DictationColumns.style, alignment: .leading)
                    Text(KleioFormat.int(entry.wordCount))
                        .monospacedDigit()
                        .frame(width: DictationColumns.words, alignment: .trailing)
                    Text(entry.timestamp.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                        .foregroundStyle(KleioPalette.secondary)
                        .lineLimit(1)
                        .frame(width: DictationColumns.date, alignment: .leading)
                    SourceAppLabel(entry: entry)
                        .frame(width: DictationColumns.app, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .kleioPointer()
            .accessibilityLabel("Open dictation")

            Menu {
                EntryCopyMenuItems(entry: entry)
                Divider()
                Button("View Details", action: onSelect)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(KleioPalette.secondary)
                    .frame(width: DictationColumns.actions, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .kleioPointer()
            .accessibilityLabel("Actions")
        }
        .font(.system(size: 12))
        .foregroundStyle(KleioPalette.ink)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isHovered ? KleioPalette.selection.opacity(0.45) : .clear)
        .onHover { isHovered = $0 }
        .contextMenu { EntryCopyMenuItems(entry: entry) }
    }
}

// MARK: - Styles

struct MacReferenceStylesPage: View {
    @ObservedObject private var configuration = AppConfiguration.shared

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        KleioPage(title: "Styles", subtitle: "How Kleio cleans up what you say. Applies to your next dictation.") {
            KleioCard {
                VStack(alignment: .leading, spacing: 14) {
                    KleioSectionTitle("Cleanup style")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Every card shows the same spoken sentence, cleaned up that style's way:")
                            .font(.system(size: 12))
                            .foregroundStyle(KleioPalette.secondary)
                        Text("“\(StyleSamples.spoken)”")
                            .font(.system(size: 12, design: .serif))
                            .italic()
                            .foregroundStyle(KleioPalette.ink.opacity(0.8))
                    }
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(DictationOutputPreset.allCases) { preset in
                            StyleCard(preset: preset, isSelected: configuration.outputPreset == preset) {
                                configuration.outputPreset = preset
                            }
                        }
                    }
                }
            }

            KleioCard {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Cleanup model")
                            .font(.system(size: 13, weight: .medium))
                        Text(configuration.usesLocalBackend
                             ? "Choose CLEANUP_MODEL in your local connector's .env. Leave it blank for transcription only."
                             : "The model that rewrites your transcript. \(configuration.cleanupModel.note).")
                            .font(.system(size: 11))
                            .foregroundStyle(KleioPalette.secondary)
                    }
                    Spacer()
                    if !configuration.usesLocalBackend { KleioMenuPill(
                        options: CleanupModel.allCases,
                        selection: configuration.cleanupModel,
                        label: \.displayName,
                        detail: \.note
                    ) { configuration.cleanupModel = $0 } }
                }
            }
        }
    }
}

/// One spoken sentence cleaned per style, matching each style's actual prompt rules
/// (filler removed, wording and perspective kept; casual styles drop the final period).
private enum StyleSamples {
    static let spoken = "um so I think we should uh move the meeting to thursday because the deck isn't ready and jamie needs more time"

    static func cleaned(for preset: DictationOutputPreset) -> String {
        switch preset {
        case .default, .email:
            return "I think we should move the meeting to Thursday because the deck isn't ready and Jamie needs more time."
        case .professional:
            return "I think we should move the meeting to Thursday, as the deck isn't ready and Jamie needs more time."
        case .casual:
            return "I think we should move the meeting to Thursday because the deck isn't ready and Jamie needs more time"
        case .veryCasual:
            return "So I think we should move the meeting to Thursday because the deck isn't ready and Jamie needs more time"
        case .excited:
            return "I think we should move the meeting to Thursday because the deck isn't ready and Jamie needs more time!"
        }
    }
}

private struct StyleCard: View {
    let preset: DictationOutputPreset
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: preset.kleioIcon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(preset.kleioColor, in: Circle())
                    Text(preset.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(KleioPalette.ink)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(KleioPalette.action)
                    }
                }
                Text(preset.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(KleioPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(StyleSamples.cleaned(for: preset))
                    .font(.system(size: 12))
                    .foregroundStyle(KleioPalette.ink)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(KleioPalette.page, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered && !isSelected ? KleioPalette.selection.opacity(0.6) : KleioPalette.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? KleioPalette.action : KleioPalette.stroke, lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .kleioPointer()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Analytics

struct MacReferenceAnalyticsPage: View {
    let history: DashboardHistory
    @Binding var dateRange: AnalyticsDateRange

    var body: some View {
        // Derived once per render; the page re-renders only when history or the range changes.
        let state = AnalyticsState(entries: history.statsEntries, range: dateRange)
        KleioPage(title: "Analytics", subtitle: "Your dictation habits over time.") {
            KleioMenuPill(
                options: AnalyticsDateRange.allCases,
                selection: dateRange,
                label: \.menuLabel,
                systemImage: "calendar"
            ) { dateRange = $0 }
        } content: {
            kpis(state)
            activityCard(state)
            HStack(alignment: .top, spacing: 12) {
                stylesCard(state)
                appsCard(state)
            }
            HStack(alignment: .top, spacing: 12) {
                heatmapCard
                highlightsCard(state)
            }
        }
    }

    private func kpis(_ state: AnalyticsState) -> some View {
        HStack(spacing: 12) {
            KPITile(
                title: "DICTATIONS",
                value: KleioFormat.int(state.current.dictations),
                change: state.change(\.dictations.asDouble)
            )
            KPITile(
                title: "WORDS",
                value: KleioFormat.int(state.current.words),
                change: state.change(\.words.asDouble)
            )
            KPITile(
                title: "TIME SAVED (EST.)",
                value: KleioFormat.duration(state.current.timeSavedSeconds),
                change: state.change(\.timeSavedSeconds)
            )
            .help("Estimated: typing these words at \(Int(AnalyticsTypingBaseline.wordsPerMinute)) WPM, minus the time spent speaking.")
            KPITile(
                title: "SPEED",
                value: state.current.wordsPerMinute.map { KleioFormat.wpm($0) } ?? "—",
                change: state.speedChange
            )
        }
    }

    private func activityCard(_ state: AnalyticsState) -> some View {
        KleioCard {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    KleioSectionTitle(dateRange == .today ? "Activity by hour" : "Activity by day")
                    Text("Each line is scaled to its own range — hover for exact values.")
                        .font(.system(size: 11))
                        .foregroundStyle(KleioPalette.secondary)
                }
                if state.current.dictations == 0 {
                    KleioEmptyNote("No dictations in this period.", minHeight: 200)
                } else {
                    KleioTrendChart(
                        series: ActivityBuckets.trendSeries(state.buckets),
                        xLabels: state.buckets.map(\.label),
                        tooltipLabels: state.buckets.map(\.fullLabel),
                        plotHeight: 190
                    )
                }
            }
        }
    }

    private func stylesCard(_ state: AnalyticsState) -> some View {
        KleioCard {
            VStack(alignment: .leading, spacing: 14) {
                KleioSectionTitle("Styles used")
                if state.styles.isEmpty {
                    KleioEmptyNote("No dictations in this period.")
                } else {
                    HStack(spacing: 20) {
                        KleioDonut(
                            slices: state.styles,
                            centerValue: KleioFormat.int(state.current.words),
                            centerCaption: "words"
                        )
                        .frame(width: 120, height: 120)
                        KleioShareLegend(slices: state.styles)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func appsCard(_ state: AnalyticsState) -> some View {
        KleioCard {
            VStack(alignment: .leading, spacing: 14) {
                KleioSectionTitle("Where you dictate")
                if state.apps.isEmpty {
                    KleioEmptyNote("No dictations in this period.")
                } else {
                    VStack(spacing: 10) {
                        ForEach(state.apps) { app in
                            ShareBarRow(slice: app, total: state.current.dictations)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var heatmapCard: some View {
        KleioCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    KleioSectionTitle("Words by day")
                    Spacer()
                    Text("Last 4 weeks")
                        .font(.system(size: 11))
                        .foregroundStyle(KleioPalette.secondary)
                }
                WordsHeatmap(entries: history.statsEntries)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func highlightsCard(_ state: AnalyticsState) -> some View {
        KleioCard {
            VStack(alignment: .leading, spacing: 12) {
                KleioSectionTitle("Highlights · \(dateRange.menuLabel)")
                HighlightRow(
                    icon: "calendar",
                    title: dateRange == .today ? "Busiest hour" : "Busiest day",
                    value: state.busiest.map { "\($0.fullLabel) · \(KleioFormat.int($0.totals.words)) words" } ?? "—"
                )
                HighlightRow(
                    icon: "mic",
                    title: "Average dictation",
                    value: state.averageLengthText
                )
                HighlightRow(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Recovered sessions",
                    value: state.current.recoveredSessions == 0
                        ? "None"
                        : "\(state.current.recoveredSessions) — cleanup failed, raw text kept",
                    tint: state.current.recoveredSessions > 0 ? KleioPalette.attention : nil
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private extension Int {
    var asDouble: Double { Double(self) }
}

/// All range-scoped numbers for the Analytics page, computed in one pass.
private struct AnalyticsState {
    let range: AnalyticsDateRange
    let current: PeriodTotals
    let previous: PeriodTotals
    let buckets: [ActivityBucket]
    let styles: [ShareSlice]
    let apps: [ShareSlice]

    init(entries: [DictationHistoryEntry], range: AnalyticsDateRange, now: Date = .now) {
        let interval = range.interval(now: now)
        let previousInterval = range.previousInterval(now: now)
        let inRange = entries.filter { interval.contains($0.timestamp) }
        self.range = range
        current = PeriodTotals(inRange)
        previous = PeriodTotals(entries.filter {
            $0.timestamp >= previousInterval.start && $0.timestamp < previousInterval.end
        })
        buckets = ActivityBuckets.build(entries, range: range, now: now)
        styles = ShareBreakdown.styles(inRange)
        apps = ShareBreakdown.apps(inRange)
    }

    func change(_ value: KeyPath<PeriodTotals, Double>) -> KPIChange? {
        let currentValue = current[keyPath: value]
        let previousValue = previous[keyPath: value]
        guard currentValue > 0 || previousValue > 0,
              let percent = kleioPercentChange(current: currentValue, previous: previousValue),
              let text = KleioFormat.delta(percent, range.comparisonLabel)
        else { return nil }
        return KPIChange(text: text, isUp: percent >= 0)
    }

    var speedChange: KPIChange? {
        guard let currentSpeed = current.wordsPerMinute,
              let previousSpeed = previous.wordsPerMinute,
              let percent = kleioPercentChange(current: currentSpeed, previous: previousSpeed),
              let text = KleioFormat.delta(percent, range.comparisonLabel)
        else { return nil }
        return KPIChange(text: text, isUp: percent >= 0)
    }

    var busiest: ActivityBucket? {
        buckets.filter { $0.totals.words > 0 }.max { $0.totals.words < $1.totals.words }
    }

    var averageLengthText: String {
        guard current.dictations > 0 else { return "—" }
        let words = current.words / current.dictations
        if let seconds = current.averageDurationSeconds {
            return "\(KleioFormat.duration(seconds)) · \(KleioFormat.int(words)) words"
        }
        return "\(KleioFormat.int(words)) words"
    }
}

private struct KPIChange {
    let text: String
    let isUp: Bool
}

private struct KPITile: View {
    let title: String
    let value: String
    let change: KPIChange?

    var body: some View {
        KleioCard {
            VStack(alignment: .leading, spacing: 8) {
                KleioSectionTitle(title)
                Text(value)
                    .font(.system(size: 26, weight: .regular, design: .serif))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Group {
                    if let change {
                        Label(change.text, systemImage: change.isUp ? "arrow.up" : "arrow.down")
                            .foregroundStyle(change.isUp ? KleioPalette.positive : KleioPalette.danger)
                    } else {
                        Text("No earlier data to compare")
                            .foregroundStyle(KleioPalette.secondary)
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct ShareBarRow: View {
    let slice: ShareSlice
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(slice.name)
                    .foregroundStyle(slice.id == "Unknown app" ? KleioPalette.secondary : KleioPalette.ink)
                    .lineLimit(1)
                Spacer()
                Text("\(KleioFormat.int(slice.count)) · \(KleioFormat.percent(slice.fraction))")
                    .foregroundStyle(KleioPalette.secondary)
                    .monospacedDigit()
            }
            .font(.system(size: 12))
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(KleioPalette.selection)
                    Capsule()
                        .fill(KleioPalette.data)
                        .frame(width: proxy.size.width * slice.fraction)
                }
            }
            .frame(height: 5)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct HighlightRow: View {
    let icon: String
    let title: String
    let value: String
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(tint ?? KleioPalette.secondary)
                .frame(width: 30, height: 30)
                .background(KleioPalette.selection.opacity(0.6), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(KleioPalette.secondary)
                Text(value)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tint ?? KleioPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Four weeks of words per day, normalized to the busiest visible day. Future days
/// in the current week are drawn as outlines, not as empty data.
private struct WordsHeatmap: View {
    let entries: [DictationHistoryEntry]

    private struct Cell: Identifiable {
        let id: Date
        let words: Int
        let isFuture: Bool
    }

    private static let weekLabel: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    private static let dayLabel: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return formatter
    }()

    var body: some View {
        let calendar = Calendar.current
        let weeks = buildWeeks(calendar: calendar)
        let maxWords = max(weeks.flatMap { $0.cells }.map(\.words).max() ?? 0, 1)
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let weekdays = (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }

        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Color.clear.frame(width: 46, height: 1)
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, day in
                    Text(day).frame(width: 22)
                }
            }
            .font(.system(size: 9))
            .foregroundStyle(KleioPalette.secondary)

            ForEach(weeks, id: \.start) { week in
                HStack(spacing: 6) {
                    Text(Self.weekLabel.string(from: week.start))
                        .font(.system(size: 9))
                        .foregroundStyle(KleioPalette.secondary)
                        .frame(width: 46, alignment: .leading)
                    ForEach(week.cells) { cell in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(cell.isFuture ? Color.clear : KleioPalette.data.opacity(intensity(cell.words, max: maxWords)))
                            .overlay(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .stroke(KleioPalette.stroke, lineWidth: cell.isFuture ? 1 : 0)
                            )
                            .frame(width: 22, height: 22)
                            .help(cell.isFuture ? "" : "\(Self.dayLabel.string(from: cell.id)): \(KleioFormat.int(cell.words)) words")
                    }
                }
            }

            HStack(spacing: 4) {
                Spacer()
                Text("Less")
                ForEach([0, 0.25, 0.5, 0.75, 1.0], id: \.self) { fraction in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(KleioPalette.data.opacity(intensity(Int(fraction * 100), max: 100)))
                        .frame(width: 11, height: 11)
                }
                Text("More")
            }
            .font(.system(size: 9))
            .foregroundStyle(KleioPalette.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Words per day for the last four weeks")
    }

    /// One ramp for cells and legend alike; zero words is a faint empty tile.
    private func intensity(_ words: Int, max: Int) -> Double {
        words == 0 ? 0.07 : 0.2 + 0.75 * Double(words) / Double(max)
    }

    private struct Week {
        let start: Date
        let cells: [Cell]
    }

    private func buildWeeks(calendar: Calendar) -> [Week] {
        let today = calendar.startOfDay(for: .now)
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start else { return [] }
        let wordsByDay = Dictionary(grouping: entries.filter(\.countsTowardStats)) { calendar.startOfDay(for: $0.timestamp) }
            .mapValues { $0.reduce(0) { $0 + $1.wordCount } }
        return (0..<4).reversed().compactMap { offset in
            guard let start = calendar.date(byAdding: .weekOfYear, value: -offset, to: thisWeek) else { return nil }
            let cells = (0..<7).compactMap { day -> Cell? in
                guard let date = calendar.date(byAdding: .day, value: day, to: start) else { return nil }
                return Cell(id: date, words: wordsByDay[date] ?? 0, isFuture: date > today)
            }
            return Week(start: start, cells: cells)
        }
    }
}

// MARK: - Settings

struct MacReferenceSettingsPage: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject private var configuration = AppConfiguration.shared

    @State private var isConfirmingSignOut = false
    @State private var isConfirmingDelete = false
    @State private var pendingRetention: HistoryRetention?
    @State private var pendingRetentionCount = 0
    @State private var isConfirmingDeleteAllHistory = false
    @State private var historyDeletionCount = 0
    @State private var activeLanguagePicker: LanguagePicker?
    @State private var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)

    private enum LanguagePicker: String, Identifiable {
        case spoken, output
        var id: String { rawValue }
    }

    var body: some View {
        KleioPage(title: "Settings", subtitle: "Your account, dictation, and privacy.") {
            if session != nil { accountCard }
            BackendConnectionCard()
            HStack(alignment: .top, spacing: 12) {
                dictationCard
                VStack(spacing: 12) {
                    generalCard
                    learnedTermsCard
                    historyCard
                    privacyCard
                }
            }
            permissionsCard
            Text(versionText)
                .font(.system(size: 11))
                .foregroundStyle(KleioPalette.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 4)
        }
        .sheet(item: $activeLanguagePicker) { picker in
            NavigationStack {
                DictationLanguagePickerView(
                    title: picker == .spoken ? "Spoken Language" : "Output Language",
                    selectedID: picker == .spoken ? spokenLanguageSelectionID : outputLanguageSelectionID,
                    options: picker == .spoken ? spokenLanguageOptions : outputLanguageOptions
                ) { selectedID in
                    applyLanguage(selectedID, for: picker)
                }
            }
            .frame(minWidth: 420, minHeight: 520)
        }
        .signOutConfirmation(isPresented: $isConfirmingSignOut)
        .alert(
            "Delete \(KleioFormat.int(pendingRetentionCount)) dictations?",
            isPresented: Binding(get: { pendingRetention != nil }, set: { if !$0 { pendingRetention = nil } })
        ) {
            Button("Cancel", role: .cancel) { pendingRetention = nil }
            Button("Delete", role: .destructive) {
                if let pendingRetention {
                    configuration.historyRetention = pendingRetention
                    appModel.enforceHistoryRetention()
                }
                pendingRetention = nil
            }
        } message: {
            Text("These are dictations older than the new window. Their transcripts are removed from this Mac and can't be recovered. Dashboard totals for older periods will no longer count them.")
        }
        .alert(
            "Delete all \(KleioFormat.int(historyDeletionCount)) dictations?",
            isPresented: $isConfirmingDeleteAllHistory
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive) { appModel.deleteAllLocalHistory() }
        } message: {
            Text("Every saved transcript on this Mac is removed and can't be recovered. Your account and settings stay.")
        }
        .alert("Delete your Kleio account?", isPresented: $isConfirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Account", role: .destructive) {
                Task { await appModel.sessionManager.deleteCurrentAccount() }
            }
        } message: {
            Text("This permanently deletes your account and synced settings, removes your dictation history from this Mac, and signs you out. You may be asked to sign in again first.")
        }
        // Permission changes happen in System Settings; re-read them when Kleio comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            appModel.refreshAccessibilityPermissionStatus(promptIfNeeded: false)
        }
    }

    // MARK: Account

    private var session: AccountSessionSnapshot? {
        appModel.sessionManager.currentSession
    }

    private var accountCard: some View {
        KleioCard {
            VStack(alignment: .leading, spacing: 14) {
                KleioSectionTitle("Account")
                HStack(spacing: 16) {
                    KleioAvatar(name: session?.primaryLabel ?? "", size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session?.primaryLabel ?? "Account")
                            .font(.system(size: 17, weight: .regular, design: .serif))
                        if let subtitle = accountSubtitle {
                            Text(subtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(KleioPalette.secondary)
                        }
                    }
                    Spacer()
                    if appModel.sessionManager.isBusy {
                        ProgressView().controlSize(.small)
                    }
                    KleioSecondaryButton(title: "Sign Out…", systemImage: nil) {
                        isConfirmingSignOut = true
                    }
                    Button("Delete Account…") { isConfirmingDelete = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(KleioPalette.danger)
                        .kleioPointer()
                }
                if let error = appModel.sessionManager.lastErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(KleioPalette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// "jane@example.com · Signed in with Google"
    private var accountSubtitle: String? {
        guard let session else { return nil }
        var parts: [String] = []
        if let email = session.email, !email.isEmpty, email != session.primaryLabel {
            parts.append(email)
        }
        let providers = session.providers.filter { $0 != .anonymous }.map(\.displayName)
        if !providers.isEmpty {
            parts.append("Signed in with \(providers.joined(separator: ", "))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Dictation

    private var dictationCard: some View {
        KleioCard {
            VStack(alignment: .leading, spacing: 14) {
                KleioSectionTitle("Dictation")
                ShortcutRecorderRow()
                Divider().overlay(KleioPalette.stroke)
                SettingsValueRow(title: "Spoken language", value: configuration.spokenLanguageSummary) {
                    activeLanguagePicker = .spoken
                }
                SettingsValueRow(title: "Output language", value: configuration.outputLanguageSummary) {
                    activeLanguagePicker = .output
                }
                Divider().overlay(KleioPalette.stroke)
                SettingsToggleRow(
                    title: "Start and stop sounds",
                    subtitle: "Play a sound when dictation starts and stops",
                    isOn: $configuration.dictationSoundEffectsEnabled
                )
                SettingsToggleRow(
                    title: "Mute audio while dictating",
                    subtitle: "Silence other apps' sound until you stop",
                    isOn: $configuration.dictationAudioDuckingEnabled
                )
                SettingsToggleRow(
                    title: "Floating dictation pill",
                    subtitle: "Keep the dictation control on screen, including while idle",
                    isOn: $configuration.floatingDictationPillEnabled
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: General

    private var generalCard: some View {
        KleioCard {
            VStack(alignment: .leading, spacing: 14) {
                KleioSectionTitle("General")
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show Kleio in")
                            .font(.system(size: 12, weight: .medium))
                        Text("Where the app icon appears")
                            .font(.system(size: 10))
                            .foregroundStyle(KleioPalette.secondary)
                    }
                    Spacer()
                    KleioMenuPill(
                        options: AppVisibilityMode.allCases,
                        selection: configuration.appVisibilityMode,
                        label: \.displayName
                    ) { configuration.appVisibilityMode = $0 }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Privacy

    private var learnedTermsCard: some View {
        KleioCard {
            VStack(alignment: .leading, spacing: 12) {
                KleioSectionTitle("Learned terms")
                Text("Names and jargon Kleio has heard across several days. Used to spell them correctly. Remove any that are wrong and they won't come back.")
                    .font(.system(size: 10))
                    .foregroundStyle(KleioPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if configuration.learnedVocabulary.isEmpty {
                    Text("Nothing learned yet. Terms appear after you use the same words on three different days.")
                        .font(.system(size: 11))
                        .foregroundStyle(KleioPalette.secondary)
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(configuration.learnedVocabulary, id: \.self) { term in
                            HStack(spacing: 5) {
                                Text(term)
                                    .font(.system(size: 11, weight: .medium))
                                Button {
                                    appModel.removeLearnedVocabulary(term)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8, weight: .bold))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(term)")
                                .kleioPointer()
                            }
                            .foregroundStyle(KleioPalette.ink)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(KleioPalette.selection, in: Capsule())
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var historyCard: some View {
        KleioCard {
            VStack(alignment: .leading, spacing: 14) {
                KleioSectionTitle("History")
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep transcripts")
                            .font(.system(size: 12, weight: .medium))
                        Text("Older transcripts are deleted. Totals you see for recent periods stay accurate.")
                            .font(.system(size: 10))
                            .foregroundStyle(KleioPalette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    KleioMenuPill(
                        options: HistoryRetention.allCases,
                        selection: configuration.historyRetention,
                        label: \.displayName
                    ) { choice in
                        let count = appModel.historyCountPastRetention(choice)
                        if count > 0 {
                            pendingRetentionCount = count
                            pendingRetention = choice
                        } else {
                            configuration.historyRetention = choice
                        }
                    }
                }
                HStack {
                    Text("Delete all dictations on this Mac")
                        .font(.system(size: 11))
                        .foregroundStyle(KleioPalette.secondary)
                    Spacer()
                    Button("Delete All…") {
                        historyDeletionCount = appModel.historyTotalCount()
                        isConfirmingDeleteAllHistory = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(KleioPalette.danger)
                    .kleioPointer()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var privacyCard: some View {
        KleioCard {
            VStack(alignment: .leading, spacing: 14) {
                KleioSectionTitle("Privacy")
                SettingsToggleRow(
                    title: "Privacy mode",
                    subtitle: "Requests no content retention from your backend. Your provider's own policies still apply.",
                    isOn: $configuration.privacyModeEnabled
                )
                SettingsToggleRow(
                    title: "Share samples with your backend",
                    subtitle: configuration.privacyModeEnabled
                        ? "Off while Privacy mode is on"
                        : "Allows a compatible backend to collect audio and transcripts. The bundled local connector never collects samples.",
                    isOn: $configuration.improvementSharingEnabled
                )
                .disabled(configuration.privacyModeEnabled)
                .opacity(configuration.privacyModeEnabled ? 0.55 : 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Permissions

    private var permissionsCard: some View {
        KleioCard {
            VStack(alignment: .leading, spacing: 14) {
                KleioSectionTitle("Permissions")
                HStack(alignment: .top, spacing: 24) {
                    PermissionRow(
                        title: "Microphone",
                        detail: "Needed to hear your dictation",
                        isGranted: microphoneStatus == .authorized,
                        actionTitle: microphoneStatus == .notDetermined ? "Allow…" : "Open Settings…"
                    ) {
                        if microphoneStatus == .notDetermined {
                            AVCaptureDevice.requestAccess(for: .audio) { _ in
                                Task { @MainActor in
                                    microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                                }
                            }
                        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    PermissionRow(
                        title: "Accessibility",
                        detail: "Needed to type text into other apps",
                        isGranted: appModel.accessibilityPermissionGranted,
                        actionTitle: "Open Settings…"
                    ) {
                        appModel.refreshAccessibilityPermissionStatus(promptIfNeeded: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "Kleio \(version) (\(build))"
    }

    // MARK: Languages

    private func applyLanguage(_ selectedID: String, for picker: LanguagePicker) {
        switch picker {
        case .spoken:
            if selectedID == "auto" {
                configuration.sourceLanguageMode = .auto
            } else {
                configuration.sourceLanguageMode = .explicit
                configuration.sourceLanguageCode = selectedID
            }
        case .output:
            if selectedID == DictationOutputLanguageMode.matchSource.rawValue {
                configuration.outputLanguageMode = .matchSource
            } else {
                configuration.outputLanguageMode = .explicit
                configuration.outputLanguageCode = selectedID
            }
        }
    }

    private var spokenLanguageSelectionID: String {
        configuration.sourceLanguageMode == .auto
            ? "auto"
            : DictationLanguageCatalog.language(for: configuration.sourceLanguageCode).code
    }

    private var outputLanguageSelectionID: String {
        configuration.outputLanguageMode == .matchSource
            ? DictationOutputLanguageMode.matchSource.rawValue
            : DictationLanguageCatalog.language(for: configuration.outputLanguageCode).code
    }

    private var spokenLanguageOptions: [DictationLanguagePickerOption] {
        let autoOption = DictationLanguagePickerOption(
            id: "auto",
            title: "Auto Detect",
            subtitle: "Detect the spoken language after you stop.",
            searchableText: "auto detect automatic spoken language"
        )
        return [autoOption] + languageOptions
    }

    private var outputLanguageOptions: [DictationLanguagePickerOption] {
        let matchOption = DictationLanguagePickerOption(
            id: DictationOutputLanguageMode.matchSource.rawValue,
            title: "Match Spoken Language",
            subtitle: "Keep the output in the language you spoke.",
            searchableText: "match spoken language source language original language"
        )
        return [matchOption] + languageOptions
    }

    private var languageOptions: [DictationLanguagePickerOption] {
        DictationLanguageCatalog.languages.map { language in
            DictationLanguagePickerOption(
                id: language.code,
                title: language.displayName,
                subtitle: language.code.uppercased(),
                searchableText: language.searchableText
            )
        }
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(KleioPalette.ink)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(KleioPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(KleioSwitchToggleStyle())
    }
}

/// Title on the left; the current value as a button that opens a picker sheet.
private struct SettingsValueRow: View {
    let title: String
    let value: String
    let action: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Button(action: action) {
                HStack(spacing: 7) {
                    Text(value).lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(KleioPalette.ink)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(KleioPalette.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(KleioPalette.stroke, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .kleioPointer()
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let isGranted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(isGranted ? KleioPalette.positive : KleioPalette.attention)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(isGranted ? "Allowed" : detail)
                    .font(.system(size: 10))
                    .foregroundStyle(KleioPalette.secondary)
            }
            Spacer(minLength: 8)
            if !isGranted {
                KleioSecondaryButton(title: actionTitle, systemImage: nil, action: action)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Shortcut recorder

/// Click the keycaps (or Change) to record; press a combo, or hold and release
/// modifiers for a modifier-only shortcut. Esc cancels. Capture also ends when the
/// app or window loses focus, so the global hotkey is never left suspended.
private struct ShortcutRecorderRow: View {
    @ObservedObject private var configuration = AppConfiguration.shared

    @State private var isRecording = false
    @State private var captureError: String?
    @State private var localMonitor: Any?
    @State private var pendingModifierCapture: Task<Void, Never>?
    @State private var modifierState = KeyboardShortcutModifierState()
    // The most recent non-empty chord held during capture — committed on release so
    // a quick fn tap can be recorded.
    @State private var lastHeldModifiers: KeyboardShortcutModifiers = []
    private let validator = MacKeyboardShortcutValidator()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dictation shortcut")
                        .font(.system(size: 12, weight: .medium))
                    Text("Hold to talk. Double-tap to start, tap again to stop.")
                        .font(.system(size: 10))
                        .foregroundStyle(KleioPalette.secondary)
                }
                Spacer()
                keycaps
                KleioSecondaryButton(title: isRecording ? "Cancel" : "Change", systemImage: nil) {
                    isRecording ? stopCapture() : startCapture()
                }
            }
            HStack {
                if let captureError {
                    Text(captureError)
                        .foregroundStyle(KleioPalette.danger)
                } else if isRecording {
                    Text("Press the keys you want — release to set. Esc cancels.")
                        .foregroundStyle(KleioPalette.secondary)
                }
                Spacer()
                if configuration.keyboardShortcut != .defaultTrigger && !isRecording {
                    Button("Reset to fn") {
                        configuration.keyboardShortcut = .defaultTrigger
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(KleioPalette.action)
                    .kleioPointer()
                }
            }
            .font(.system(size: 10, weight: .medium))
        }
        .onDisappear(perform: stopCapture)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            stopCapture()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            stopCapture()
        }
    }

    private var keycaps: some View {
        let tokens = isRecording
            ? KeyboardShortcut(keyCode: nil, modifiers: modifierState.pressedModifiers).displayTokens
            : configuration.keyboardShortcut.displayTokens
        return HStack(spacing: 5) {
            if isRecording && tokens.isEmpty {
                Text("Press shortcut…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(KleioPalette.secondary)
                    .padding(.horizontal, 4)
            } else {
                ForEach(tokens, id: \.self) { token in
                    KeyCap(token: token, emphasized: isRecording)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(minWidth: 110, minHeight: 34)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isRecording ? KleioPalette.action.opacity(0.06) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(isRecording ? KleioPalette.action : KleioPalette.stroke, lineWidth: isRecording ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { if !isRecording { startCapture() } }
        .kleioPointer(!isRecording)
        .animation(.easeOut(duration: 0.15), value: isRecording)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Dictation shortcut: \(configuration.keyboardShortcut.displayLabel)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { startCapture() }
    }

    private func startCapture() {
        captureError = nil
        isRecording = true
        NotificationCenter.default.post(name: .hotkeyCaptureModeDidChange, object: true)
        modifierState.reset()
        pendingModifierCapture?.cancel()
        removeMonitor()
        lastHeldModifiers = []
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            switch event.type {
            case .flagsChanged:
                modifierState.update(keyCode: event.keyCode, eventFlags: event.modifierFlags)
                let modifiers = modifierState.pressedModifiers
                guard !modifiers.isEmpty else {
                    pendingModifierCapture?.cancel()
                    pendingModifierCapture = nil
                    let released = lastHeldModifiers
                    lastHeldModifiers = []
                    if !released.isEmpty {
                        apply(KeyboardShortcut(keyCode: nil, modifiers: released))
                    }
                    return nil
                }
                captureError = nil
                lastHeldModifiers = modifiers
                scheduleModifierOnlyCapture(KeyboardShortcut(keyCode: nil, modifiers: modifiers))
                return nil
            case .keyDown:
                if event.keyCode == 53 {
                    stopCapture()
                    return nil
                }
                pendingModifierCapture?.cancel()
                pendingModifierCapture = nil
                lastHeldModifiers = []
                captureError = nil
                apply(KeyboardShortcut(keyCode: event.keyCode, modifiers: modifierState.pressedModifiers))
                return nil
            case .keyUp:
                return nil
            default:
                return event
            }
        }
    }

    private func stopCapture() {
        guard isRecording || localMonitor != nil else { return }
        isRecording = false
        captureError = nil
        NotificationCenter.default.post(name: .hotkeyCaptureModeDidChange, object: false)
        pendingModifierCapture?.cancel()
        pendingModifierCapture = nil
        modifierState.reset()
        lastHeldModifiers = []
        removeMonitor()
    }

    private func removeMonitor() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func scheduleModifierOnlyCapture(_ shortcut: KeyboardShortcut) {
        pendingModifierCapture?.cancel()
        pendingModifierCapture = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, isRecording else { return }
            apply(shortcut)
        }
    }

    private func apply(_ shortcut: KeyboardShortcut) {
        switch validator.validate(shortcut) {
        case .success(let valid):
            configuration.keyboardShortcut = valid
            stopCapture()
        case .failure(let error):
            captureError = error.localizedDescription
        }
    }
}

/// A physical-looking keycap; `emphasized` tints it action-green during capture.
private struct KeyCap: View {
    let token: String
    var emphasized = false

    var body: some View {
        Text(token)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(emphasized ? Color.white : KleioPalette.ink)
            .padding(.horizontal, token.count > 1 ? 8 : 0)
            .frame(minWidth: 26, minHeight: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(emphasized ? KleioPalette.action : KleioPalette.card)
                    .shadow(color: Color.black.opacity(0.12), radius: 0, y: 1.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(emphasized ? KleioPalette.action : KleioPalette.stroke, lineWidth: 1)
            )
    }
}
