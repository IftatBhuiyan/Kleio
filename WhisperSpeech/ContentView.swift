import SwiftUI
import SwiftData
import Combine
import AppKit

struct ContentView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.modelContext) private var modelContext

    @State private var analyticsDateRange: AnalyticsDateRange = .last30Days
    @State private var history = DashboardHistory()
    @State private var recentLimit = Self.recentPageSize

    /// The Dictations list loads this many rows at a time ("Show older" adds a page).
    private static let recentPageSize = 120

    var body: some View {
        MacAnalyticsWindowView(
            history: history,
            dateRange: $analyticsDateRange,
            onLoadOlder: {
                recentLimit += Self.recentPageSize
                refreshHistory()
            }
        )
        .task(id: appModel.currentOwnerProfileID) {
            recentLimit = Self.recentPageSize
            refreshHistory()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dictationHistoryDidChange)) { _ in
            refreshHistory()
        }
        // "Today" and every rolling window move at midnight even with no new dictations.
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in
            refreshHistory()
        }
    }

    private func refreshHistory() {
        let now = Date.now
        let statsStart = AnalyticsDateRange.statsWindowStart(now: now)
        do {
            // One extra row tells us whether older history exists beyond the page.
            let recent = try fetchEntries(since: nil, limit: recentLimit + 1)
            // Stats come from a date-bounded fetch, never from the capped list, so
            // totals and streaks cover every dictation in their window.
            let statsEntries = try fetchEntries(since: statsStart, limit: nil)
            history = DashboardHistory(
                recent: Array(recent.prefix(recentLimit)),
                hasOlder: recent.count > recentLimit,
                statsEntries: statsEntries,
                stats: DashboardStats(entries: statsEntries, windowStart: statsStart, now: now),
                loadFailed: false,
                revision: history.revision + 1
            )
        } catch {
            print("[mac] Failed to load dictation history: \(error)")
            // Keep whatever was showing; surface the failure instead of an empty first-run state.
            history.loadFailed = true
            history.revision += 1
        }
    }

    /// Owner-scoped fetch, newest first, including the legacy unscoped rows when the
    /// local-only profile still owns them.
    private func fetchEntries(since start: Date?, limit: Int?) throws -> [DictationHistoryEntry] {
        var entries = try fetchEntries(ownerID: appModel.currentOwnerProfileID, since: start, limit: limit)
        if appModel.includesLegacyHistoryOwnerScope {
            entries += try fetchEntries(ownerID: "", since: start, limit: limit)
            entries.sort { $0.timestamp > $1.timestamp }
            if let limit { entries = Array(entries.prefix(limit)) }
        }
        return entries
    }

    private func fetchEntries(ownerID: String, since start: Date?, limit: Int?) throws -> [DictationHistoryEntry] {
        let predicate: Predicate<DictationHistoryEntry>
        if let start {
            predicate = #Predicate { $0.ownerProfileID == ownerID && $0.timestamp >= start }
        } else {
            predicate = #Predicate { $0.ownerProfileID == ownerID }
        }
        var descriptor = FetchDescriptor(predicate: predicate, sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        if let limit { descriptor.fetchLimit = limit }
        return try modelContext.fetch(descriptor)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: DictationHistoryEntry.self, inMemory: true)
        .environmentObject(
            AppModel(
                configuration: .shared,
                sessionManager: SessionManager(configuration: .shared)
            )
        )
}
