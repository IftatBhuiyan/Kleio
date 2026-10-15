import Foundation
import SwiftData
import os

@MainActor
final class DictionaryStore {
    private static let logger = Logger(subsystem: "com.eclipsestudio.kleio", category: "dictionary")
    private let modelContext: ModelContext
    private let configuration: AppConfiguration
    private let localOnlyProfileID: String
    var onDidChange: (() -> Void)?

    var currentOwnerProfileID: String {
        didSet {
            guard oldValue != currentOwnerProfileID else { return }
            migrateLegacyUnscopedEntriesIfNeeded()
            syncCompatibilityVocabularySnapshot()
        }
    }

    init(
        modelContext: ModelContext,
        configuration: AppConfiguration,
        localOnlyProfileID: String
    ) {
        self.modelContext = modelContext
        self.configuration = configuration
        self.localOnlyProfileID = localOnlyProfileID
        self.currentOwnerProfileID = localOnlyProfileID
    }

    func bootstrap() {
        migrateLegacyUnscopedEntriesIfNeeded()
        repairClusteringMetadata()
        reconcileSuggestionQueue()
        migrateLegacyVocabularyIfNeeded()
        syncCompatibilityVocabularySnapshot()
    }

    func activeVocabularyPayload(limit: Int = 200) -> [String] {
        let activeTerms = fetchAllTerms()
            .filter { $0.status == .active }
            .sorted(by: activeTermSort)

        var seen = Set<String>()
        var payload: [String] = []
        for entry in activeTerms {
            guard let sanitized = sanitizePayloadTerm(entry.text) else { continue }
            let key = DictionaryCandidateExtractor.normalizedKey(for: sanitized)
            guard !key.isEmpty else { continue }
            guard seen.insert(key).inserted else { continue }
            payload.append(sanitized)
            if payload.count >= limit {
                break
            }
        }
        return payload
    }

    func cloudSyncedActiveTermsSnapshot() -> [CloudDictionaryTermSnapshot] {
        fetchAllTerms()
            .filter { $0.status == .active || $0.status == .disabled }
            .map { term in
                CloudDictionaryTermSnapshot(
                    text: term.text,
                    normalizedKey: term.normalizedKey,
                    statusRawValue: term.status.rawValue,
                    sourceRawValue: term.source.rawValue,
                    knownVariants: term.knownVariants
                )
            }
    }

    func applyRemoteApprovedTerms(_ terms: [CloudDictionaryTermSnapshot]) {
        let existingTerms = fetchAllTerms()

        for snapshot in terms {
            let entry = matchingTerm(
                in: existingTerms,
                normalizedKey: snapshot.normalizedKey,
                clusterKey: DictionaryCandidateExtractor.clusterKey(
                    for: snapshot.text,
                    kind: DictionaryCandidateExtractor.inferKind(for: snapshot.text)
                ),
                displayText: snapshot.text
            )
                ?? DictionaryTermEntry(
                    ownerProfileID: currentOwnerProfileID,
                    text: snapshot.text,
                    normalizedKey: snapshot.normalizedKey,
                    clusterKey: DictionaryCandidateExtractor.clusterKey(
                        for: snapshot.text,
                        kind: DictionaryCandidateExtractor.inferKind(for: snapshot.text)
                    ),
                    source: DictionaryTermSource(rawValue: snapshot.sourceRawValue) ?? .manual,
                    status: DictionaryTermStatus(rawValue: snapshot.statusRawValue) ?? .active,
                    createdAt: .now,
                    approvedAt: .now,
                    lastSeenAt: nil,
                    usageCount: 0
                )

            if entry.modelContext == nil {
                modelContext.insert(entry)
            }

            entry.ownerProfileID = currentOwnerProfileID
            entry.text = snapshot.text
            entry.normalizedKey = snapshot.normalizedKey
            entry.clusterKeyValue = DictionaryCandidateExtractor.clusterKey(
                for: snapshot.text,
                kind: DictionaryCandidateExtractor.inferKind(for: snapshot.text)
            )
            entry.source = DictionaryTermSource(rawValue: snapshot.sourceRawValue) ?? entry.source
            entry.status = DictionaryTermStatus(rawValue: snapshot.statusRawValue) ?? .active
            entry.knownVariants = preferredVariantList(
                current: snapshot.knownVariants + [snapshot.text],
                canonical: snapshot.text
            )
        }

        saveAndRefresh()
    }

    private func migrateLegacyVocabularyIfNeeded() {
        let legacyTerms = configuration.customVocabulary
        guard !legacyTerms.isEmpty else { return }

        let existingTerms = fetchAllTerms()
        var existingKeys = Set(existingTerms.map(\.normalizedKey))
        let now = Date()

        for rawTerm in legacyTerms {
            guard let prepared = DictionaryCandidateExtractor.prepareManualTerm(rawTerm) else { continue }
            guard !existingKeys.contains(prepared.normalizedKey) else { continue }

            modelContext.insert(
                DictionaryTermEntry(
                    ownerProfileID: currentOwnerProfileID,
                    text: prepared.text,
                    normalizedKey: prepared.normalizedKey,
                    clusterKey: prepared.clusterKey,
                    source: .manual,
                    status: .active,
                    createdAt: now,
                    approvedAt: now,
                    knownVariantsStorage: prepared.text
                )
            )
            existingKeys.insert(prepared.normalizedKey)
        }

        saveContext(operation: "inline")
    }

    func cleanupPromptAppendix(limit: Int = 50) -> String? {
        let activeTerms = fetchAllTerms()
            .filter { $0.status == .active }
            .sorted(by: activeTermSort)
            .prefix(limit)

        let lines = activeTerms.compactMap { term -> String? in
            let variants = term.knownVariants.filter { $0.caseInsensitiveCompare(term.text) != .orderedSame }
            guard !variants.isEmpty else { return nil }
            return "- If a close spelling or hearing variant appears (such as \(variants.joined(separator: ", "))), normalize it to \"\(term.text)\" when the context clearly indicates the same name or term."
        }

        guard !lines.isEmpty else { return nil }
        return """
        Approved dictionary normalization hints:
        Preserve approved spellings and normalize likely variants to the canonical term when the context clearly matches.
        \(lines.joined(separator: "\n"))
        """
    }

    private func syncCompatibilityVocabularySnapshot() {
        configuration.customVocabulary = activeVocabularyPayload(limit: 200)
    }

    private func saveAndRefresh() {
        saveContext(operation: "saveAndRefresh")
        syncCompatibilityVocabularySnapshot()
        onDidChange?()
    }

    private func saveContext(operation: String) {
        do {
            try modelContext.save()
        } catch {
            Self.logger.error("dictionary save failed op=\(operation, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func fetchAllTerms() -> [DictionaryTermEntry] {
        let owner = currentOwnerProfileID
        let includeLegacyUnscoped = currentOwnerProfileID == localOnlyProfileID
        let predicate = #Predicate<DictionaryTermEntry> { term in
            term.ownerProfileID == owner
                || (includeLegacyUnscoped && term.ownerProfileID == "")
        }
        do {
            return try modelContext.fetch(FetchDescriptor(predicate: predicate))
        } catch {
            Self.logger.error("term fetch failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func fetchAllSuggestions() -> [DictionarySuggestionEntry] {
        let owner = currentOwnerProfileID
        let includeLegacyUnscoped = currentOwnerProfileID == localOnlyProfileID
        let predicate = #Predicate<DictionarySuggestionEntry> { suggestion in
            suggestion.ownerProfileID == owner
                || (includeLegacyUnscoped && suggestion.ownerProfileID == "")
        }
        do {
            return try modelContext.fetch(FetchDescriptor(predicate: predicate))
        } catch {
            Self.logger.error("suggestion fetch failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func migrateLegacyUnscopedEntriesIfNeeded() {
        guard currentOwnerProfileID == localOnlyProfileID else { return }

        var didMutate = false
        for term in (try? modelContext.fetch(FetchDescriptor<DictionaryTermEntry>())) ?? [] where term.ownerProfileID.isEmpty {
            term.ownerProfileID = localOnlyProfileID
            didMutate = true
        }
        for suggestion in (try? modelContext.fetch(FetchDescriptor<DictionarySuggestionEntry>())) ?? [] where suggestion.ownerProfileID.isEmpty {
            suggestion.ownerProfileID = localOnlyProfileID
            didMutate = true
        }

        if didMutate {
            saveContext(operation: "inline")
        }
    }

    private func matchesCurrentOwnerScope(_ term: DictionaryTermEntry) -> Bool {
        matchesCurrentOwnerScope(ownerProfileID: term.ownerProfileID)
    }

    private func matchesCurrentOwnerScope(_ suggestion: DictionarySuggestionEntry) -> Bool {
        matchesCurrentOwnerScope(ownerProfileID: suggestion.ownerProfileID)
    }

    private func matchesCurrentOwnerScope(ownerProfileID: String) -> Bool {
        ownerProfileID == currentOwnerProfileID
            || (ownerProfileID.isEmpty && currentOwnerProfileID == localOnlyProfileID)
    }

    private func repairClusteringMetadata() {
        var didMutate = false

        for term in fetchAllTerms() {
            let repairedClusterKey = DictionaryCandidateExtractor.clusterKey(
                for: term.text,
                kind: DictionaryCandidateExtractor.inferKind(for: term.text)
            )
            if term.clusterKeyValue.isEmpty {
                term.clusterKeyValue = repairedClusterKey
                didMutate = true
            }
            if term.knownVariants.isEmpty {
                term.knownVariants = [term.text]
                didMutate = true
            }
        }

        for suggestion in fetchAllSuggestions() {
            let repairedClusterKey = DictionaryCandidateExtractor.clusterKey(
                for: suggestion.text,
                kind: suggestion.kind
            )
            if suggestion.clusterKeyValue.isEmpty {
                suggestion.clusterKeyValue = repairedClusterKey
                didMutate = true
            }
            if suggestion.knownVariants.isEmpty {
                suggestion.knownVariants = [suggestion.text]
                didMutate = true
            }
        }

        if didMutate {
            saveContext(operation: "inline")
        }
    }

    private func reconcileSuggestionQueue() {
        let suggestions = fetchAllSuggestions()
        guard !suggestions.isEmpty else { return }

        var didMutate = false

        for suggestion in suggestions where suggestion.status == .pending {
            let variants = [suggestion.text] + suggestion.knownVariants
            guard let prepared = bestPreparedSuggestion(from: variants, preferProperLike: suggestion.kind == .properLike) else {
                suggestion.status = .dismissed
                suggestion.dismissedAtEvidenceCount = suggestion.evidenceCount
                didMutate = true
                continue
            }

            let canonicalText = preferredDisplayText(current: suggestion.text, incoming: prepared.text)
            if suggestion.text != canonicalText {
                suggestion.text = canonicalText
                didMutate = true
            }
            if suggestion.normalizedKey != prepared.normalizedKey {
                suggestion.normalizedKey = prepared.normalizedKey
                didMutate = true
            }
            if suggestion.clusterKeyValue != prepared.clusterKey {
                suggestion.clusterKeyValue = prepared.clusterKey
                didMutate = true
            }
            if suggestion.kind != prepared.kind {
                suggestion.kind = prepared.kind
                didMutate = true
            }

            let preferredVariants = preferredVariantList(
                current: suggestion.knownVariants + [suggestion.text, prepared.text],
                canonical: canonicalText
            )
            if suggestion.knownVariants != preferredVariants {
                suggestion.knownVariants = preferredVariants
                didMutate = true
            }
        }

        if collapseDuplicateProperLikeSuggestions() {
            didMutate = true
        }

        if didMutate {
            saveContext(operation: "inline")
        }
    }

    private func bestPreparedSuggestion(
        from variants: [String],
        preferProperLike: Bool
    ) -> (text: String, normalizedKey: String, clusterKey: String, kind: DictionarySuggestionKind)? {
        var bestMatch: (text: String, normalizedKey: String, clusterKey: String, kind: DictionarySuggestionKind)?

        for variant in variants {
            guard let prepared = DictionaryCandidateExtractor.prepareSuggestedTerm(
                variant,
                allowRelaxedSingleWordProperLike: preferProperLike
            ) else {
                continue
            }

            guard let currentBest = bestMatch else {
                bestMatch = prepared
                continue
            }

            if prepared.kind == .properLike, currentBest.kind != .properLike {
                bestMatch = prepared
                continue
            }

            let preferredText = preferredDisplayText(current: currentBest.text, incoming: prepared.text)
            if preferredText == prepared.text {
                bestMatch = prepared
            }
        }

        return bestMatch
    }

    private func collapseDuplicateProperLikeSuggestions() -> Bool {
        let suggestions = fetchAllSuggestions()
            .filter { $0.kind == .properLike }
            .sorted(by: properLikeSuggestionSort)

        guard suggestions.count > 1 else { return false }

        var consumed = Set<ObjectIdentifier>()
        var didMutate = false

        for suggestion in suggestions {
            let identifier = ObjectIdentifier(suggestion)
            guard consumed.insert(identifier).inserted else { continue }

            let duplicates = suggestions.filter { other in
                let otherIdentifier = ObjectIdentifier(other)
                guard otherIdentifier != identifier else { return false }
                guard !consumed.contains(otherIdentifier) else { return false }
                guard suggestion.clusterKeyValue == other.clusterKeyValue else { return false }

                if suggestion.normalizedKey == other.normalizedKey {
                    return true
                }
                return DictionaryCandidateExtractor.shouldClusterTogether(suggestion.text, other.text)
            }

            guard !duplicates.isEmpty else { continue }

            var primary = suggestion
            for duplicate in duplicates {
                primary = mergeSuggestion(primary, with: duplicate)
                consumed.insert(ObjectIdentifier(duplicate))
                didMutate = true
            }
        }

        return didMutate
    }

    private func mergeSuggestion(
        _ primary: DictionarySuggestionEntry,
        with duplicate: DictionarySuggestionEntry
    ) -> DictionarySuggestionEntry {
        let canonicalText = preferredDisplayText(current: primary.text, incoming: duplicate.text)
        primary.text = canonicalText
        primary.normalizedKey = DictionaryCandidateExtractor.normalizedKey(for: canonicalText)
        primary.clusterKeyValue = DictionaryCandidateExtractor.clusterKey(for: canonicalText, kind: .properLike)
        primary.kind = .properLike
        primary.status = mergedSuggestionStatus(primary.status, duplicate.status)
        primary.evidenceCount += duplicate.evidenceCount
        primary.stableSpellingCount += duplicate.stableSpellingCount
        primary.rawMatchCount += duplicate.rawMatchCount
        primary.firstSeenAt = min(primary.firstSeenAt, duplicate.firstSeenAt)
        if duplicate.lastSeenAt > primary.lastSeenAt {
            primary.lastSeenAt = duplicate.lastSeenAt
            primary.lastSeenSessionID = duplicate.lastSeenSessionID
        }
        primary.dismissedAtEvidenceCount = max(primary.dismissedAtEvidenceCount, duplicate.dismissedAtEvidenceCount)
        primary.distinctDayKeys = primary.distinctDayKeys.union(duplicate.distinctDayKeys)
        primary.distinctAppKeys = primary.distinctAppKeys.union(duplicate.distinctAppKeys)
        primary.knownVariants = preferredVariantList(
            current: primary.knownVariants + duplicate.knownVariants + [duplicate.text],
            canonical: canonicalText
        )

        var snippets = primary.exampleSnippets
        for snippet in duplicate.exampleSnippets where !snippets.contains(snippet) {
            snippets.append(snippet)
        }
        snippets.sort { lhs, rhs in
            if lhs.count != rhs.count {
                return lhs.count > rhs.count
            }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
        primary.exampleSnippets = Array(snippets.prefix(3))

        modelContext.delete(duplicate)
        return primary
    }

    private func mergedSuggestionStatus(
        _ lhs: DictionarySuggestionStatus,
        _ rhs: DictionarySuggestionStatus
    ) -> DictionarySuggestionStatus {
        if lhs == .approved || rhs == .approved {
            return .approved
        }
        if lhs == .pending || rhs == .pending {
            return .pending
        }
        return .dismissed
    }

    private func properLikeSuggestionSort(
        lhs: DictionarySuggestionEntry,
        rhs: DictionarySuggestionEntry
    ) -> Bool {
        if lhs.status != rhs.status {
            return statusRank(lhs.status) < statusRank(rhs.status)
        }
        if lhs.confidenceScore != rhs.confidenceScore {
            return lhs.confidenceScore > rhs.confidenceScore
        }
        let lhsDisplayScore = displayTextScore(lhs.text)
        let rhsDisplayScore = displayTextScore(rhs.text)
        if lhsDisplayScore != rhsDisplayScore {
            return lhsDisplayScore > rhsDisplayScore
        }
        return lhs.lastSeenAt > rhs.lastSeenAt
    }

    private func statusRank(_ status: DictionarySuggestionStatus) -> Int {
        switch status {
        case .approved:
            return 0
        case .pending:
            return 1
        case .dismissed:
            return 2
        }
    }

    private func activeTermSort(lhs: DictionaryTermEntry, rhs: DictionaryTermEntry) -> Bool {
        if lhs.source != rhs.source {
            return lhs.source == .manual
        }
        if lhs.usageCount != rhs.usageCount {
            return lhs.usageCount > rhs.usageCount
        }
        let lhsDate = lhs.lastSeenAt ?? lhs.approvedAt ?? lhs.createdAt
        let rhsDate = rhs.lastSeenAt ?? rhs.approvedAt ?? rhs.createdAt
        if lhsDate != rhsDate {
            return lhsDate > rhsDate
        }
        return lhs.text.localizedCaseInsensitiveCompare(rhs.text) == .orderedAscending
    }

    private func preferredDisplayText(current: String, incoming: String) -> String {
        let currentScore = displayTextScore(current)
        let incomingScore = displayTextScore(incoming)
        if incomingScore > currentScore {
            return incoming
        }
        if incomingScore == currentScore && incoming.count > current.count {
            return incoming
        }
        return current
    }

    private func displayTextScore(_ text: String) -> Int {
        var score = 0
        if text.contains(where: \.isUppercase) { score += 3 }
        if text.rangeOfCharacter(from: .decimalDigits) == nil { score += 1 }
        if text.count > 4 { score += 1 }
        return score
    }

    private func sanitizePayloadTerm(_ text: String) -> String? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let words = cleaned.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty, words.count <= 4 else { return nil }
        guard cleaned.count <= 64 else { return nil }
        return cleaned
    }

    private func matchingTerm(
        in terms: [DictionaryTermEntry],
        normalizedKey: String,
        clusterKey: String,
        displayText: String
    ) -> DictionaryTermEntry? {
        if let exact = terms.first(where: { $0.normalizedKey == normalizedKey }) {
            return exact
        }

        return terms.first {
            !$0.clusterKeyValue.isEmpty
                && $0.clusterKeyValue == clusterKey
                && DictionaryCandidateExtractor.shouldClusterTogether($0.text, displayText)
        }
    }

    private func preferredVariantList(current: [String], canonical: String) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for variant in [canonical] + current {
            let cleaned = variant.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            let key = cleaned.lowercased()
            guard seen.insert(key).inserted else { continue }
            ordered.append(cleaned)
        }

        if let canonicalIndex = ordered.firstIndex(where: { $0.caseInsensitiveCompare(canonical) == .orderedSame }) {
            ordered.remove(at: canonicalIndex)
        }
        ordered.insert(canonical, at: 0)
        return Array(ordered.prefix(6))
    }
}

private struct DictionaryCandidateToken {
    let text: String
    let normalized: String
    let isSentenceInitial: Bool
}

private struct DictionaryCandidateWindowEvaluation {
    let kind: DictionarySuggestionKind
    let priorityScore: Int
}

private enum DictionaryCandidateExtractor {
    nonisolated private static let stopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "been", "being", "but", "by", "do", "does", "for",
        "from", "had", "has", "have", "he", "her", "here", "hers", "him", "his", "i", "i'd", "i'll",
        "i'm", "i've", "if", "in", "is", "it", "it's", "its", "just", "let's", "me", "my", "of", "on",
        "or", "our", "she", "she's", "so", "that", "that's", "the", "their", "them", "there", "they",
        "they're", "this", "to", "up", "us", "was", "we", "we're", "were", "what", "when", "where",
        "which", "who", "will", "with", "you", "you're", "your", "before", "after", "around", "during",
        "still", "into", "onto", "through", "until"
    ]

    nonisolated private static let veryCommonWords: Set<String> = [
        "about", "after", "again", "all", "also", "because", "can", "could", "day", "days", "did",
        "email", "emoji", "free", "friday", "get", "going", "good", "hello", "hey", "hi", "house",
        "how", "january", "july", "june", "know", "look", "monday", "need", "not", "okay", "only",
        "people", "place", "please", "real", "really", "right", "saturday", "send", "some", "study",
        "sunday", "sure", "test", "testing", "than", "then", "thing", "think", "thursday", "today",
        "tomorrow", "tuesday", "wednesday", "works", "working", "wrong"
    ]

    nonisolated private static let phraseNoiseWords: Set<String> = [
        "check", "checking", "come", "coming", "did", "do", "does", "doing", "done", "find", "get",
        "getting", "give", "go", "going", "gonna", "got", "help", "keep", "know", "look", "looking",
        "make", "making", "need", "play", "playlist", "really", "say", "see", "show", "sure", "tell",
        "think", "trying", "want", "watch", "work", "working"
    ]

    nonisolated private static let conversationalBoundaryWords: Set<String> = [
        "a", "an", "and", "are", "be", "can", "could", "did", "do", "does", "for", "from", "go",
        "going", "i", "i'm", "if", "in", "is", "it", "it's", "make", "my", "need", "of", "on", "or",
        "our", "please", "see", "she", "so", "that", "the", "their", "them", "they", "this", "to",
        "trying", "up", "want", "we", "what", "when", "where", "who", "why", "with", "you", "your"
    ]

    nonisolated private static let properLikeConnectorWords: Set<String> = [
        "&", "and", "for", "of", "the"
    ]

    nonisolated private static let genericPhraseConnectorWords: Set<String> = [
        "&", "and", "for", "of", "to"
    ]

    static func prepareManualTerm(_ text: String) -> (text: String, normalizedKey: String, clusterKey: String, kind: DictionarySuggestionKind)? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKey = normalizedKey(for: cleaned)
        guard !cleaned.isEmpty, !normalizedKey.isEmpty else { return nil }
        let kind = inferKind(for: cleaned)
        return (
            cleaned,
            normalizedKey,
            clusterKey(for: cleaned, kind: kind),
            kind
        )
    }

    static func prepareSuggestedTerm(
        _ text: String,
        allowRelaxedSingleWordProperLike: Bool
    ) -> (text: String, normalizedKey: String, clusterKey: String, kind: DictionarySuggestionKind)? {
        let tokens = tokenizedUnits(in: text)
        guard !tokens.isEmpty else { return nil }
        guard let evaluation = evaluateCandidate(
            tokens,
            allowRelaxedSingleWordProperLike: allowRelaxedSingleWordProperLike
        ) else {
            return nil
        }

        let cleaned = tokens.map(\.text).joined(separator: " ")
        let normalized = normalizedKey(for: cleaned)
        guard !normalized.isEmpty else { return nil }
        return (
            cleaned,
            normalized,
            clusterKey(for: cleaned, kind: evaluation.kind),
            evaluation.kind
        )
    }

    static func normalizedKey(for text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }

    static func searchableText(from text: String) -> String {
        normalizedKey(for: text)
    }

    static func inferKind(for text: String) -> DictionarySuggestionKind {
        let tokens = tokenizedUnits(in: text)
        guard !tokens.isEmpty else { return .genericPhrase }
        if let evaluation = evaluateCandidate(tokens, allowRelaxedSingleWordProperLike: true) {
            return evaluation.kind
        }
        return fallbackSuggestionKind(for: tokens)
    }

    static func clusterKey(for text: String, kind: DictionarySuggestionKind) -> String {
        let normalized = normalizedKey(for: text)
        guard !normalized.isEmpty else { return "" }
        guard kind == .properLike else { return normalized }

        let words = tokenizedWords(in: text)
        let encoded = words
            .map(soundex)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return encoded.isEmpty ? normalized : encoded
    }

    static func shouldClusterTogether(_ lhs: String, _ rhs: String) -> Bool {
        let lhsKind = inferKind(for: lhs)
        let rhsKind = inferKind(for: rhs)
        guard lhsKind == .properLike, rhsKind == .properLike else { return false }

        let lhsCluster = clusterKey(for: lhs, kind: lhsKind)
        let rhsCluster = clusterKey(for: rhs, kind: rhsKind)
        guard !lhsCluster.isEmpty, lhsCluster == rhsCluster else { return false }

        let lhsWords = normalizedKey(for: lhs).split(separator: " ")
        let rhsWords = normalizedKey(for: rhs).split(separator: " ")
        guard lhsWords.count == rhsWords.count else { return false }

        let lhsJoined = lhsWords.joined(separator: " ")
        let rhsJoined = rhsWords.joined(separator: " ")
        let maxDistance = max(2, min(4, max(lhsJoined.count, rhsJoined.count) / 3))
        return levenshteinDistance(lhsJoined, rhsJoined) <= maxDistance
    }

    private static func tokenizedWords(in text: String) -> [String] {
        tokenizedUnits(in: text).map(\.text)
    }

    // Compiled once; building an NSRegularExpression per tokenize call (hundreds per record)
    // caused a main-thread hitch at finalization (M-13).
    private static let tokenizerRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9&'\-]*|[A-Z]{2,}"#)
    }()

    private static func tokenizedUnits(in text: String) -> [DictionaryCandidateToken] {
        guard let regex = tokenizerRegex else { return [] }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        return regex.matches(in: text, range: range).compactMap { match in
            guard
                match.range.location != NSNotFound,
                let tokenRange = Range(match.range, in: text)
            else {
                return nil
            }

            let tokenText = String(text[tokenRange])
            return DictionaryCandidateToken(
                text: tokenText,
                normalized: normalizedKey(for: tokenText),
                isSentenceInitial: isSentenceInitialToken(in: text, tokenRange: tokenRange)
            )
        }
    }

    private static func evaluateCandidate(
        _ tokens: [DictionaryCandidateToken],
        allowRelaxedSingleWordProperLike: Bool
    ) -> DictionaryCandidateWindowEvaluation? {
        guard !tokens.isEmpty else { return nil }
        let joined = tokens.map(\.text).joined(separator: " ")
        guard joined.count <= 64 else { return nil }
        guard !containsURLLikeText(joined) else { return nil }
        guard !tokens.allSatisfy({ $0.text.allSatisfy(\.isNumber) }) else { return nil }

        if tokens.count == 1, let token = tokens.first {
            return evaluateSingleWord(
                token,
                allowRelaxedSingleWordProperLike: allowRelaxedSingleWordProperLike
            )
        }

        guard (2...4).contains(tokens.count) else { return nil }
        return evaluatePhrase(tokens)
    }

    private static func evaluateSingleWord(
        _ token: DictionaryCandidateToken,
        allowRelaxedSingleWordProperLike: Bool
    ) -> DictionaryCandidateWindowEvaluation? {
        let normalized = token.normalized
        guard !normalized.isEmpty else { return nil }
        guard !stopwords.contains(normalized) else { return nil }
        guard !veryCommonWords.contains(normalized) else { return nil }
        guard !phraseNoiseWords.contains(normalized) else { return nil }

        if isAcronymLike(token.text) {
            return DictionaryCandidateWindowEvaluation(kind: .properLike, priorityScore: 150 + token.text.count)
        }
        if hasInternalUppercase(token.text) {
            return DictionaryCandidateWindowEvaluation(kind: .properLike, priorityScore: 142 + token.text.count)
        }
        if hasMeaningfulInternalPunctuation(token.text) {
            return DictionaryCandidateWindowEvaluation(kind: .properLike, priorityScore: 138 + token.text.count)
        }
        if isTitleCase(token.text) && !token.isSentenceInitial {
            return DictionaryCandidateWindowEvaluation(kind: .properLike, priorityScore: 130 + token.text.count)
        }
        if allowRelaxedSingleWordProperLike,
           isTitleCase(token.text),
           token.text.count >= 6,
           !veryCommonWords.contains(normalized) {
            return DictionaryCandidateWindowEvaluation(kind: .properLike, priorityScore: 116 + token.text.count)
        }

        return nil
    }

    private static func evaluatePhrase(_ tokens: [DictionaryCandidateToken]) -> DictionaryCandidateWindowEvaluation? {
        let normalizedWords = tokens.map(\.normalized)
        guard let first = normalizedWords.first, let last = normalizedWords.last else { return nil }
        guard !conversationalBoundaryWords.contains(first) else { return nil }
        guard !conversationalBoundaryWords.contains(last) else { return nil }

        let contentWords = normalizedWords.filter(isContentWord)
        guard contentWords.count >= 2 else { return nil }

        let uncommonContentCount = contentWords.filter(isUncommonPhraseContentWord).count
        let specializedTokenCount = tokens.filter(isSpecializedToken).count
        let kind = suggestionKind(for: tokens)

        if kind == .properLike {
            let properishTokenCount = tokens.filter { isProperLikePhraseToken($0, totalTokens: tokens.count) }.count
            let connectorCount = tokens.filter { properLikeConnectorWords.contains($0.normalized) }.count
            let totalNameLength = normalizedWords.reduce(0) { $0 + $1.count }
            guard properishTokenCount >= 2 else { return nil }
            guard properishTokenCount + connectorCount == tokens.count else { return nil }
            guard totalNameLength >= 8 else { return nil }

            let lexicalScore = properishTokenCount * 4
                + uncommonContentCount * 2
                + tokens.count
            let priority = 86 + lexicalScore * 6 + tokens.count * 4
            return DictionaryCandidateWindowEvaluation(kind: .properLike, priorityScore: priority)
        }

        guard specializedTokenCount == 0 else { return nil }

        let disallowedConnectorCount = normalizedWords.filter {
            !isContentWord($0) && !genericPhraseConnectorWords.contains($0)
        }.count
        guard disallowedConnectorCount == 0 else { return nil }

        let totalContentLength = contentWords.reduce(0) { $0 + $1.count }
        guard totalContentLength >= 14 else { return nil }

        let longContentCount = contentWords.filter { $0.count >= 5 }.count
        guard longContentCount >= 2 || specializedTokenCount > 0 else { return nil }
        if tokens.count == 2 && specializedTokenCount == 0 && uncommonContentCount < 2 {
            return nil
        }

        let lexicalScore = specializedTokenCount * 4
            + uncommonContentCount * 3
            + longContentCount * 2
            + contentWords.count
        guard lexicalScore >= 8 else { return nil }

        let priority = 70
            + lexicalScore * 6
            + tokens.count * 4
            + (kind == .properLike ? 16 : 0)
        return DictionaryCandidateWindowEvaluation(kind: kind, priorityScore: priority)
    }

    private static func containsURLLikeText(_ text: String) -> Bool {
        text.contains("@") || text.contains("://") || text.contains("www.")
    }

    nonisolated private static func isContentWord(_ word: String) -> Bool {
        !stopwords.contains(word) && !phraseNoiseWords.contains(word)
    }

    nonisolated private static func isUncommonPhraseContentWord(_ word: String) -> Bool {
        isContentWord(word) && !veryCommonWords.contains(word) && word.count >= 4
    }

    nonisolated private static func isSpecializedToken(_ token: DictionaryCandidateToken) -> Bool {
        if isAcronymLike(token.text) || hasInternalUppercase(token.text) || hasMeaningfulInternalPunctuation(token.text) {
            return true
        }
        return isTitleCase(token.text) && !token.isSentenceInitial
    }

    private static func isProperLikePhraseToken(
        _ token: DictionaryCandidateToken,
        totalTokens: Int
    ) -> Bool {
        guard isTitleCase(token.text) else { return false }
        guard !veryCommonWords.contains(token.normalized) else { return false }
        guard !phraseNoiseWords.contains(token.normalized) else { return false }
        return !token.isSentenceInitial || totalTokens > 1
    }

    private static func suggestionKind(for tokens: [DictionaryCandidateToken]) -> DictionarySuggestionKind {
        guard !tokens.isEmpty else { return .genericPhrase }

        let properishCount = tokens.filter { token in
            isAcronymLike(token.text)
                || hasInternalUppercase(token.text)
                || hasMeaningfulInternalPunctuation(token.text)
                || isProperLikePhraseToken(token, totalTokens: tokens.count)
        }.count

        if properishCount >= 2 {
            return .properLike
        }
        if tokens.count == 1, properishCount == 1 {
            return .properLike
        }
        return .genericPhrase
    }

    private static func fallbackSuggestionKind(for tokens: [DictionaryCandidateToken]) -> DictionarySuggestionKind {
        let titleCasedCount = tokens.filter { isTitleCase($0.text) }.count
        if titleCasedCount >= 2 || tokens.contains(where: { isAcronymLike($0.text) || hasInternalUppercase($0.text) }) {
            return .properLike
        }
        return .genericPhrase
    }

    private static func isSentenceInitialToken(
        in text: String,
        tokenRange: Range<String.Index>
    ) -> Bool {
        var index = tokenRange.lowerBound
        while index > text.startIndex {
            let previousIndex = text.index(before: index)
            let character = text[previousIndex]
            if character.isWhitespace || "\"'([{".contains(character) {
                index = previousIndex
                continue
            }
            return ".!?:;".contains(character)
        }
        return true
    }

    nonisolated private static func isTitleCase(_ word: String) -> Bool {
        guard let first = word.first, first.isUppercase else { return false }
        return word.dropFirst().contains(where: \.isLowercase)
    }

    nonisolated private static func hasInternalUppercase(_ word: String) -> Bool {
        word.dropFirst().contains(where: \.isUppercase) && word.contains(where: \.isLowercase)
    }

    nonisolated private static func hasMeaningfulInternalPunctuation(_ word: String) -> Bool {
        word.contains("-") || word.contains("&")
    }

    nonisolated private static func isAcronymLike(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        guard letters.count >= 2 else { return false }
        return letters == letters.uppercased()
    }

    private static func suggestionKind(for words: [String]) -> DictionarySuggestionKind {
        guard !words.isEmpty else { return .genericPhrase }
        let hasMixedCase = words.contains { word in
            let scalars = Array(word.unicodeScalars)
            let uppercaseCount = scalars.filter { CharacterSet.uppercaseLetters.contains($0) }.count
            let lowercaseCount = scalars.filter { CharacterSet.lowercaseLetters.contains($0) }.count
            return uppercaseCount > 0 && lowercaseCount > 0
        }
        let hasAcronym = words.contains { word in
            word.count >= 2 && word == word.uppercased()
        }
        let titleCasedWords = words.filter { word in
            guard let first = word.first else { return false }
            return first.isUppercase
        }

        if hasMixedCase || hasAcronym || titleCasedWords.count >= 2 {
            return .properLike
        }

        if words.count == 1,
           let first = words.first?.first,
           first.isUppercase,
           !veryCommonWords.contains(words[0].lowercased()) {
            return .properLike
        }

        return .genericPhrase
    }

    nonisolated private static func soundex(_ word: String) -> String {
        let letters = Array(
            word
                .folding(options: .diacriticInsensitive, locale: .current)
                .uppercased()
                .filter { $0.isLetter }
        )
        guard let first = letters.first else { return "" }

        func code(for character: Character) -> Character {
            switch character {
            case "B", "F", "P", "V": return "1"
            case "C", "G", "J", "K", "Q", "S", "X", "Z": return "2"
            case "D", "T": return "3"
            case "L": return "4"
            case "M", "N": return "5"
            case "R": return "6"
            default: return "0"
            }
        }

        var result = [first]
        var previousCode = code(for: first)

        for letter in letters.dropFirst() {
            let currentCode = code(for: letter)
            if currentCode == "0" {
                previousCode = currentCode
                continue
            }
            if currentCode != previousCode {
                result.append(currentCode)
            }
            previousCode = currentCode
            if result.count == 4 {
                break
            }
        }

        while result.count < 4 {
            result.append("0")
        }
        return String(result)
    }

    nonisolated private static func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
        let lhsChars = Array(lhs)
        let rhsChars = Array(rhs)
        guard !lhsChars.isEmpty else { return rhsChars.count }
        guard !rhsChars.isEmpty else { return lhsChars.count }

        var previous = Array(0...rhsChars.count)
        for (lhsIndex, lhsChar) in lhsChars.enumerated() {
            var current = [lhsIndex + 1]
            for (rhsIndex, rhsChar) in rhsChars.enumerated() {
                let substitutionCost = lhsChar == rhsChar ? 0 : 1
                current.append(
                    min(
                        current[rhsIndex] + 1,
                        previous[rhsIndex + 1] + 1,
                        previous[rhsIndex] + substitutionCost
                    )
                )
            }
            previous = current
        }

        return previous[rhsChars.count]
    }
}
