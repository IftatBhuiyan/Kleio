import Foundation

/// How long full dictation transcripts are kept on this Mac. Stats and the streak only
/// read the last ~60 days, so the shortest window still leaves every dashboard number
/// intact; older rows are removed, not summarized.
enum HistoryRetention: String, CaseIterable, Identifiable {
    case forever
    case days90
    case days180
    case days365

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .forever: return "Keep forever"
        case .days90: return "Keep 90 days"
        case .days180: return "Keep 6 months"
        case .days365: return "Keep 1 year"
        }
    }

    /// nil means nothing is ever deleted.
    var days: Int? {
        switch self {
        case .forever: return nil
        case .days90: return 90
        case .days180: return 180
        case .days365: return 365
        }
    }

    /// Entries strictly older than this instant are past retention.
    func cutoff(now: Date = .now, calendar: Calendar = .current) -> Date? {
        guard let days else { return nil }
        return calendar.date(byAdding: .day, value: -days, to: now)
    }
}
