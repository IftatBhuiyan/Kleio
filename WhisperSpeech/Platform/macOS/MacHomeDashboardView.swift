import AppKit
import SwiftData
import SwiftUI

struct MacHomeDashboardView: View {
    @EnvironmentObject private var appModel: AppModel

    let history: DashboardHistory
    let onSelectEntry: (DictationHistoryEntry) -> Void
    let onShowDictations: () -> Void

    private var stats: DashboardStats { history.stats }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                metricRow
                activityCard
                recentCard
            }
            .padding(.horizontal, 28)
            .padding(.top, 34)
            .padding(.bottom, 28)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(greetingText)
                        .font(.system(size: 30, weight: .regular, design: .serif))
                        .foregroundStyle(KleioPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("Today")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(KleioPalette.secondary)
                }

                HStack(spacing: 28) {
                    HeroStat(title: "DICTATIONS", value: KleioFormat.int(stats.today.dictations))
                    HeroStat(title: "WORDS", value: KleioFormat.int(stats.today.words))
                    HeroStat(title: "TIME SAVED", value: KleioFormat.duration(stats.today.timeSavedSeconds))
                        .help(timeSavedHelp)
                }
            }

            Spacer(minLength: 0)

            HeroArtwork()
                .frame(width: 330, height: 148)
        }
        .gesture(WindowDragGesture())
    }

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let phrase: String
        switch hour {
        case 5..<12: phrase = "Good morning"
        case 12..<17: phrase = "Good afternoon"
        case 17..<22: phrase = "Good evening"
        default: phrase = "Hello"
        }
        if let firstName = appModel.sessionManager.currentSession?.firstName {
            return "\(phrase), \(firstName)."
        }
        return "\(phrase)."
    }

    // MARK: Metrics

    private var metricRow: some View {
        HStack(spacing: 12) {
            MetricCard(
                title: "WORDS · 7 DAYS",
                value: KleioFormat.int(stats.week.words),
                delta: percentDelta(Double(stats.week.words), Double(stats.previousWeek.words)),
                caption: stats.week.words == 0 ? "No dictations yet" : nil
            ) {
                MiniBars(values: stats.weekBuckets.map { Double($0.totals.words) })
            }

            MetricCard(
                title: "TIME SAVED · 7 DAYS",
                value: KleioFormat.duration(stats.week.timeSavedSeconds),
                delta: nil,
                caption: "Estimate vs typing at \(Int(AnalyticsTypingBaseline.wordsPerMinute)) WPM"
            ) {
                MetricSymbol(name: "timer")
            }

            MetricCard(
                title: "SPEED · 7 DAYS",
                value: stats.week.wordsPerMinute.map { KleioFormat.wpm($0) } ?? "—",
                delta: stats.week.wordsPerMinute.flatMap { current in
                    stats.previousWeek.wordsPerMinute.flatMap { percentDelta(current, $0) }
                },
                caption: stats.week.wordsPerMinute == nil ? "No timed dictations yet" : nil
            ) {
                MetricSymbol(name: "speedometer")
            }

            MetricCard(
                title: "STREAK",
                value: stats.streakIsLowerBound ? "\(stats.streakDays)+ days" : KleioFormat.days(stats.streakDays),
                delta: nil,
                caption: streakCaption
            ) {
                MetricSymbol(name: "flame")
            }
        }
    }

    private func percentDelta(_ current: Double, _ previous: Double) -> MetricDelta? {
        guard current > 0 || previous > 0,
              let percent = kleioPercentChange(current: current, previous: previous),
              let text = KleioFormat.delta(percent, "vs previous 7 days")
        else { return nil }
        return MetricDelta(text: text, isUp: percent >= 0)
    }

    private var streakCaption: String {
        let calendar = Calendar.current
        guard let lastActive = stats.lastActiveDay else { return "Dictate today to start one" }
        if calendar.isDateInToday(lastActive) { return "Active today" }
        if stats.streakDays > 0 { return "Dictate today to keep it going" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: lastActive), to: calendar.startOfDay(for: .now)).day ?? 0
        return "Last active \(KleioFormat.days(days)) ago"
    }

    private var timeSavedHelp: String {
        "Estimated: the time typing these words at \(Int(AnalyticsTypingBaseline.wordsPerMinute)) WPM would take, minus the time spent speaking."
    }

    // MARK: Activity

    private var activityCard: some View {
        KleioCard {
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        KleioSectionTitle("Activity · Last 7 days")
                        Text("Each line is scaled to its own range — hover a day for exact values.")
                            .font(.system(size: 11))
                            .foregroundStyle(KleioPalette.secondary)
                    }
                    if stats.week.dictations == 0 {
                        KleioEmptyNote("No dictations in the last 7 days.", minHeight: 210)
                    } else {
                        KleioTrendChart(
                            series: ActivityBuckets.trendSeries(stats.weekBuckets),
                            xLabels: stats.weekBuckets.map(\.label),
                            tooltipLabels: stats.weekBuckets.map(\.fullLabel),
                            plotHeight: 170
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                Divider()
                    .overlay(KleioPalette.stroke)

                VStack(alignment: .leading, spacing: 14) {
                    KleioSectionTitle("Top styles")
                    if stats.weekStyles.isEmpty {
                        KleioEmptyNote("Styles you dictate with will show here.", minHeight: 150)
                    } else {
                        KleioDonut(
                            slices: stats.weekStyles,
                            centerValue: KleioFormat.int(stats.week.words),
                            centerCaption: "words"
                        )
                        .frame(width: 112, height: 112)
                        .frame(maxWidth: .infinity)
                        KleioShareLegend(slices: stats.weekStyles)
                    }
                }
                .frame(width: 190, alignment: .topLeading)
            }
        }
    }

    // MARK: Recent

    private var recentEntries: [DictationHistoryEntry] {
        Array(history.recent.prefix(5))
    }

    private var recentCard: some View {
        KleioCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    KleioSectionTitle("Recent dictations")
                    Spacer()
                    ImportAudioButton()
                    if !recentEntries.isEmpty {
                        Button("View all", action: onShowDictations)
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(KleioPalette.action)
                            .kleioPointer()
                    }
                }

                if history.loadFailed && recentEntries.isEmpty {
                    KleioEmptyNote("Couldn't load your dictations. They'll appear when the next one finishes.", minHeight: 80)
                } else if recentEntries.isEmpty {
                    KleioEmptyNote(
                        "Hold \(AppConfiguration.shared.keyboardShortcut.displayLabel) in any app to dictate. Finished dictations show up here.",
                        minHeight: 80
                    )
                } else {
                    VStack(spacing: 0) {
                        ForEach(recentEntries, id: \.persistentModelID) { entry in
                            RecentDictationRow(entry: entry) { onSelectEntry(entry) }
                            if entry.persistentModelID != recentEntries.last?.persistentModelID {
                                Divider().overlay(KleioPalette.stroke)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Components

/// The Overview artwork, cropped to its illustrated band so it reads as a header
/// accent instead of a full-window backdrop that pushes the data below the fold.
private struct HeroArtwork: View {
    // The art occupies roughly x 200–1230, y 40–500 of the 1448×1086 source image.
    private let source = CGSize(width: 1448, height: 1086)
    private let band = CGRect(x: 200, y: 40, width: 1030, height: 460)

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / band.width, proxy.size.height / band.height)
            Image("KleioDashboardHero")
                .resizable()
                .frame(width: source.width * scale, height: source.height * scale)
                .offset(x: -band.minX * scale, y: -band.minY * scale)
                .frame(width: band.width * scale, height: band.height * scale, alignment: .topLeading)
                .clipped()
                .blendMode(.multiply)
                // Feather the crop edges so the art melts into the page instead of reading as a box.
                .mask(
                    RadialGradient(
                        colors: [.black, .black.opacity(0.9), .clear],
                        center: .center,
                        startRadius: band.height * scale * 0.25,
                        endRadius: band.width * scale * 0.55
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct HeroStat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.9)
                .foregroundStyle(KleioPalette.secondary)
            Text(value)
                .font(.system(size: 22, weight: .regular, design: .serif))
                .foregroundStyle(KleioPalette.ink)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MetricDelta {
    let text: String
    let isUp: Bool
}

private struct MetricCard<Accessory: View>: View {
    let title: String
    let value: String
    let delta: MetricDelta?
    let caption: String?
    @ViewBuilder let accessory: Accessory

    var body: some View {
        KleioCard {
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 8) {
                    KleioSectionTitle(title)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(value)
                        .font(.system(size: 26, weight: .regular, design: .serif))
                        .foregroundStyle(KleioPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Group {
                        if let delta {
                            Label(delta.text, systemImage: delta.isUp ? "arrow.up" : "arrow.down")
                                .foregroundStyle(delta.isUp ? KleioPalette.positive : KleioPalette.danger)
                        } else {
                            Text(caption ?? " ")
                                .foregroundStyle(KleioPalette.secondary)
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                }
                Spacer(minLength: 0)
                accessory
                    .frame(width: 56, height: 40, alignment: .bottomTrailing)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct MetricSymbol: View {
    let name: String

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 22, weight: .light))
            .foregroundStyle(KleioPalette.secondary.opacity(0.7))
            .accessibilityHidden(true)
    }
}

/// True-zero bars: an idle day draws nothing, not a fake floor.
private struct MiniBars: View {
    let values: [Double]

    var body: some View {
        let maxValue = max(values.max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(KleioPalette.data)
                    .frame(width: 5, height: 40 * CGFloat(value / maxValue))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct RecentDictationRow: View {
    let entry: DictationHistoryEntry
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                HStack(spacing: 8) {
                    Text(entry.hasCleanedText ? entry.finalText.trimmingCharacters(in: .whitespacesAndNewlines) : "Empty transcript")
                        .foregroundStyle(KleioPalette.ink)
                        .lineLimit(1)
                    EntryKindBadge(entry: entry)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                StyleDotLabel(entry: entry)
                    .frame(width: 110, alignment: .leading)

                SourceAppLabel(entry: entry)
                    .frame(width: 140, alignment: .leading)

                Text(entry.timestamp, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                    .foregroundStyle(KleioPalette.secondary)
                    .frame(width: 84, alignment: .trailing)
            }
            .font(.system(size: 12))
            .padding(.vertical, 9)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? KleioPalette.selection.opacity(0.5) : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .kleioPointer()
        .contextMenu { EntryCopyMenuItems(entry: entry) }
    }
}
