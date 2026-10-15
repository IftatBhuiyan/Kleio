import Foundation
import SwiftUI

/// Baseline typing speed behind every "time saved" estimate (words per minute).
enum AnalyticsTypingBaseline {
    static let wordsPerMinute: Double = 40
}

// MARK: - Per-entry rules

/// The single definition of which history rows count toward which statistic.
/// Every aggregate on the dashboard routes through these instead of re-deriving them.
extension DictationHistoryEntry {
    /// Sessions created by Import Audio carry this prefix so they can be kept out of
    /// dictation statistics. Imports made before the prefix existed are indistinguishable.
    static let importedAudioSessionPrefix = "import-"

    var isImportedAudio: Bool {
        sessionID?.hasPrefix(Self.importedAudioSessionPrefix) == true
    }

    /// Imported files are transcriptions, not dictations — they stay out of every stat.
    var countsTowardStats: Bool {
        !isImportedAudio
    }

    /// Recovered sessions carry a floored audio duration, so their speed is meaningless.
    var isSpeedEligible: Bool {
        countsTowardStats && !isFailedRawFallback && audioDuration >= 1 && wordCount > 0
    }

    /// Seconds saved versus typing the same words at `AnalyticsTypingBaseline`.
    var estimatedTimeSavedSeconds: TimeInterval {
        guard isSpeedEligible else { return 0 }
        let typingSeconds = Double(wordCount) / AnalyticsTypingBaseline.wordsPerMinute * 60
        return max(0, typingSeconds - audioDuration)
    }

    var hasCleanedText: Bool {
        !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasRawText: Bool {
        !(rawText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// The preset name, or nil for older rows saved before styles were recorded.
    var styleName: String? {
        outputPreset?.displayName
    }

    /// Trimmed source app name, or nil when the destination is unknown.
    var sourceAppDisplayName: String? {
        let name = sourceAppName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name?.isEmpty == false) ? name : nil
    }
}

// MARK: - Period totals

struct PeriodTotals: Equatable {
    var dictations = 0
    var words = 0
    var timeSavedSeconds: TimeInterval = 0
    var recoveredSessions = 0
    /// Words and audio seconds of speed-eligible sessions only.
    var eligibleWords = 0
    var eligibleSeconds: TimeInterval = 0
    var eligibleSessions = 0

    init() {}

    init<S: Sequence>(_ entries: S) where S.Element == DictationHistoryEntry {
        for entry in entries where entry.countsTowardStats {
            dictations += 1
            words += entry.wordCount
            if entry.isFailedRawFallback { recoveredSessions += 1 }
            if entry.isSpeedEligible {
                eligibleWords += entry.wordCount
                eligibleSeconds += entry.audioDuration
                eligibleSessions += 1
                timeSavedSeconds += entry.estimatedTimeSavedSeconds
            }
        }
    }

    /// Word- and time-weighted speed (total words / total audio minutes); nil when
    /// no session qualifies.
    var wordsPerMinute: Double? {
        eligibleSeconds > 0 ? Double(eligibleWords) / eligibleSeconds * 60 : nil
    }

    var averageDurationSeconds: TimeInterval? {
        eligibleSessions > 0 ? eligibleSeconds / Double(eligibleSessions) : nil
    }

    static func sum(_ parts: [PeriodTotals]) -> PeriodTotals {
        parts.reduce(into: PeriodTotals()) { result, part in
            result.dictations += part.dictations
            result.words += part.words
            result.timeSavedSeconds += part.timeSavedSeconds
            result.recoveredSessions += part.recoveredSessions
            result.eligibleWords += part.eligibleWords
            result.eligibleSeconds += part.eligibleSeconds
            result.eligibleSessions += part.eligibleSessions
        }
    }
}

/// Percent change, or nil when there's no previous value to compare against.
func kleioPercentChange(current: Double, previous: Double) -> Double? {
    guard previous > 0 else { return nil }
    return (current - previous) / previous * 100
}

// MARK: - Ranges

/// Rolling windows ending now. Each compares against the window of the same length
/// immediately before it, and `comparisonLabel` says exactly that.
enum AnalyticsDateRange: String, CaseIterable, Identifiable {
    case today
    case last7Days
    case last30Days

    var id: String { rawValue }

    var menuLabel: String {
        switch self {
        case .today: return "Today"
        case .last7Days: return "Last 7 days"
        case .last30Days: return "Last 30 days"
        }
    }

    var comparisonLabel: String {
        switch self {
        case .today: return "vs this time yesterday"
        case .last7Days: return "vs previous 7 days"
        case .last30Days: return "vs previous 30 days"
        }
    }

    var dayCount: Int {
        switch self {
        case .today: return 1
        case .last7Days: return 7
        case .last30Days: return 30
        }
    }

    /// `today` runs from midnight to now; the day ranges cover whole calendar days
    /// ending today (so "Last 7 days" = today plus the six days before it).
    func interval(now: Date = .now, calendar: Calendar = .current) -> DateInterval {
        let startOfToday = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(dayCount - 1), to: startOfToday) ?? startOfToday
        return DateInterval(start: start, end: now)
    }

    func previousInterval(now: Date = .now, calendar: Calendar = .current) -> DateInterval {
        let current = interval(now: now, calendar: calendar)
        let start = calendar.date(byAdding: .day, value: -dayCount, to: current.start) ?? current.start
        let end = calendar.date(byAdding: .day, value: -dayCount, to: now) ?? current.start
        return DateInterval(start: start, end: min(end, current.start))
    }

    /// Earliest timestamp any range (plus its comparison window) needs.
    static func statsWindowStart(now: Date = .now, calendar: Calendar = .current) -> Date {
        let longest = allCases.max { $0.dayCount < $1.dayCount } ?? .last30Days
        return longest.previousInterval(now: now, calendar: calendar).start
    }
}

// MARK: - Buckets

/// One slot on a trend chart: a calendar day, or an hour for the Today range.
struct ActivityBucket: Identifiable, Equatable {
    let id: Date
    let label: String
    let fullLabel: String
    var totals: PeriodTotals
}

enum ActivityBuckets {
    private static let dayLabel: DateFormatter = formatter(template: "MMMd")
    private static let weekdayLabel: DateFormatter = formatter(template: "EEE")
    private static let fullDayLabel: DateFormatter = formatter(template: "EEEMMMd")
    private static let hourLabel: DateFormatter = formatter(template: "j")

    private static func formatter(template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    /// Dense buckets covering `range` — empty slots are kept so gaps stay visible.
    static func build(
        _ entries: [DictationHistoryEntry],
        range: AnalyticsDateRange,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [ActivityBucket] {
        let interval = range.interval(now: now, calendar: calendar)
        let component: Calendar.Component = range == .today ? .hour : .day
        let slotCount = range == .today ? 24 : range.dayCount
        var buckets: [ActivityBucket] = (0..<slotCount).compactMap { index in
            guard let start = calendar.date(byAdding: component, value: index, to: interval.start) else { return nil }
            let label: String
            let fullLabel: String
            switch range {
            case .today:
                label = hourLabel.string(from: start)
                fullLabel = hourLabel.string(from: start)
            case .last7Days:
                label = weekdayLabel.string(from: start)
                fullLabel = fullDayLabel.string(from: start)
            case .last30Days:
                label = dayLabel.string(from: start)
                fullLabel = fullDayLabel.string(from: start)
            }
            return ActivityBucket(id: start, label: label, fullLabel: fullLabel, totals: PeriodTotals())
        }
        let grouped = Dictionary(grouping: entries.filter { interval.contains($0.timestamp) }) { entry in
            calendar.dateInterval(of: component, for: entry.timestamp)?.start ?? entry.timestamp
        }
        for index in buckets.indices {
            if let slotEntries = grouped[buckets[index].id] {
                buckets[index].totals = PeriodTotals(slotEntries)
            }
        }
        return buckets
    }

    /// Chart series for the shared trend chart: words, dictations, time saved, speed.
    static func trendSeries(_ buckets: [ActivityBucket]) -> [KleioTrendSeries] {
        let totals = PeriodTotals.sum(buckets.map(\.totals))
        return [
            KleioTrendSeries(
                id: "words",
                name: "Words",
                color: KleioPalette.data,
                values: buckets.map { Double($0.totals.words) },
                display: buckets.map { KleioFormat.int($0.totals.words) },
                summary: KleioFormat.int(totals.words)
            ),
            KleioTrendSeries(
                id: "dictations",
                name: "Dictations",
                color: KleioPalette.dataSecondary,
                values: buckets.map { Double($0.totals.dictations) },
                display: buckets.map { KleioFormat.int($0.totals.dictations) },
                summary: KleioFormat.int(totals.dictations)
            ),
            KleioTrendSeries(
                id: "timeSaved",
                name: "Time saved",
                color: KleioPalette.dataTertiary,
                values: buckets.map(\.totals.timeSavedSeconds),
                display: buckets.map { KleioFormat.duration($0.totals.timeSavedSeconds) },
                summary: KleioFormat.duration(totals.timeSavedSeconds)
            ),
            KleioTrendSeries(
                id: "speed",
                name: "Speed",
                color: KleioPalette.dataQuaternary,
                values: buckets.map(\.totals.wordsPerMinute),
                display: buckets.map { $0.totals.wordsPerMinute.map { KleioFormat.wpm($0) } },
                summary: totals.wordsPerMinute.map { KleioFormat.wpm($0) } ?? "—"
            )
        ]
    }
}

// MARK: - Shares

struct ShareSlice: Identifiable, Equatable {
    let id: String
    let name: String
    let count: Int
    let fraction: Double
    let color: Color
}

enum ShareBreakdown {
    /// Word share per style. Rows saved before styles were recorded are grouped as
    /// "Unknown" rather than silently counted as Default.
    static func styles(_ entries: [DictationHistoryEntry], limit: Int = 5) -> [ShareSlice] {
        let counted = entries.filter(\.countsTowardStats)
        let total = counted.reduce(0) { $0 + $1.wordCount }
        guard total > 0 else { return [] }
        let grouped = Dictionary(grouping: counted) { $0.outputPreset }
        let slices = grouped.map { preset, list -> ShareSlice in
            let words = list.reduce(0) { $0 + $1.wordCount }
            return ShareSlice(
                id: preset?.rawValue ?? "unknown",
                name: preset?.displayName ?? "Unknown",
                count: words,
                fraction: Double(words) / Double(total),
                color: preset?.kleioColor ?? KleioPalette.stroke
            )
        }
        .filter { $0.count > 0 }
        .sorted { $0.count > $1.count }
        return collapse(slices, limit: limit)
    }

    /// Dictation share per destination app.
    static func apps(_ entries: [DictationHistoryEntry], limit: Int = 5) -> [ShareSlice] {
        let counted = entries.filter(\.countsTowardStats)
        guard !counted.isEmpty else { return [] }
        let grouped = Dictionary(grouping: counted) { $0.sourceAppDisplayName ?? "Unknown app" }
        let slices = grouped.map { name, list in
            ShareSlice(
                id: name,
                name: name,
                count: list.count,
                fraction: Double(list.count) / Double(counted.count),
                color: KleioPalette.data
            )
        }
        .sorted { $0.count > $1.count }
        return collapse(slices, limit: limit)
    }

    private static func collapse(_ slices: [ShareSlice], limit: Int) -> [ShareSlice] {
        guard slices.count > limit else { return slices }
        let rest = slices.dropFirst(limit - 1)
        let other = ShareSlice(
            id: "other",
            name: "Other",
            count: rest.reduce(0) { $0 + $1.count },
            fraction: rest.reduce(0) { $0 + $1.fraction },
            color: KleioPalette.secondary.opacity(0.45)
        )
        return Array(slices.prefix(limit - 1)) + [other]
    }
}

// MARK: - Streak

enum DictationStreak {
    /// Consecutive days with a dictation, ending today — or yesterday, so a streak
    /// isn't shown as broken before today's first dictation. 0 otherwise.
    static func days(in entries: [DictationHistoryEntry], now: Date = .now, calendar: Calendar = .current) -> Int {
        let activeDays = Set(entries.filter(\.countsTowardStats).map { calendar.startOfDay(for: $0.timestamp) })
        let today = calendar.startOfDay(for: now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return 0 }
        var cursor: Date
        if activeDays.contains(today) {
            cursor = today
        } else if activeDays.contains(yesterday) {
            cursor = yesterday
        } else {
            return 0
        }
        var streak = 0
        while activeDays.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }
}

// MARK: - Dashboard history

/// What the dashboard window renders from: the newest page of rows for lists, plus a
/// date-bounded set (and its derived stats) for every number and chart.
struct DashboardHistory {
    var recent: [DictationHistoryEntry] = []
    /// More rows exist beyond `recent`.
    var hasOlder = false
    /// Every entry inside `AnalyticsDateRange.statsWindowStart()`.
    var statsEntries: [DictationHistoryEntry] = []
    var stats = DashboardStats.empty
    var loadFailed = false
    /// Bumped on every reload so pages can key their caches on it.
    var revision = 0
}

// MARK: - Dashboard stats

/// Everything the Overview needs, computed once per history change from the
/// date-bounded stats fetch (not from the capped recent list).
struct DashboardStats: Equatable {
    var today = PeriodTotals()
    var week = PeriodTotals()
    var previousWeek = PeriodTotals()
    var weekBuckets: [ActivityBucket] = []
    var weekStyles: [ShareSlice] = []
    var streakDays = 0
    /// True when the streak reaches back to the edge of the loaded stats window.
    var streakIsLowerBound = false
    var lastActiveDay: Date?

    static let empty = DashboardStats()

    init() {}

    init(entries: [DictationHistoryEntry], windowStart: Date, now: Date = .now, calendar: Calendar = .current) {
        let todayInterval = AnalyticsDateRange.today.interval(now: now, calendar: calendar)
        let weekInterval = AnalyticsDateRange.last7Days.interval(now: now, calendar: calendar)
        let previousWeekInterval = AnalyticsDateRange.last7Days.previousInterval(now: now, calendar: calendar)
        let weekEntries = entries.filter { weekInterval.contains($0.timestamp) }

        today = PeriodTotals(entries.filter { todayInterval.contains($0.timestamp) })
        week = PeriodTotals(weekEntries)
        previousWeek = PeriodTotals(entries.filter {
            $0.timestamp >= previousWeekInterval.start && $0.timestamp < previousWeekInterval.end
        })
        weekBuckets = ActivityBuckets.build(entries, range: .last7Days, now: now, calendar: calendar)
        weekStyles = ShareBreakdown.styles(weekEntries)
        streakDays = DictationStreak.days(in: entries, now: now, calendar: calendar)
        let windowDays = calendar.dateComponents([.day], from: calendar.startOfDay(for: windowStart), to: calendar.startOfDay(for: now)).day ?? 0
        streakIsLowerBound = streakDays > 0 && streakDays >= windowDays
        lastActiveDay = entries.filter(\.countsTowardStats).map(\.timestamp).max()
    }
}
