import Foundation
import SwiftData

enum DictionaryTermSource: String, Codable, CaseIterable {
    case manual
    case learned

    var displayName: String {
        switch self {
        case .manual:
            return "Manual"
        case .learned:
            return "Learned"
        }
    }
}

enum DictionaryTermStatus: String, Codable, CaseIterable {
    case active
    case disabled
}

enum DictionarySuggestionStatus: String, Codable, CaseIterable {
    case pending
    case approved
    case dismissed
}

enum DictionarySuggestionKind: String, Codable, CaseIterable {
    case properLike
    case genericPhrase
}

@Model
final class DictionaryTermEntry {
    var ownerProfileID: String = ""
    var text: String
    var normalizedKey: String
    var clusterKey: String?
    var source: DictionaryTermSource
    var status: DictionaryTermStatus
    var createdAt: Date
    var approvedAt: Date?
    var lastSeenAt: Date?
    var usageCount: Int
    var knownVariantsStorage: String?

    init(
        ownerProfileID: String = "",
        text: String,
        normalizedKey: String,
        clusterKey: String,
        source: DictionaryTermSource,
        status: DictionaryTermStatus = .active,
        createdAt: Date = .now,
        approvedAt: Date? = nil,
        lastSeenAt: Date? = nil,
        usageCount: Int = 0,
        knownVariantsStorage: String = ""
    ) {
        self.ownerProfileID = ownerProfileID
        self.text = text
        self.normalizedKey = normalizedKey
        self.clusterKey = clusterKey.isEmpty ? nil : clusterKey
        self.source = source
        self.status = status
        self.createdAt = createdAt
        self.approvedAt = approvedAt
        self.lastSeenAt = lastSeenAt
        self.usageCount = usageCount
        self.knownVariantsStorage = knownVariantsStorage.isEmpty ? nil : knownVariantsStorage
    }

    var clusterKeyValue: String {
        get { clusterKey ?? "" }
        set { clusterKey = newValue.isEmpty ? nil : newValue }
    }

    var knownVariants: [String] {
        get { storageComponents(from: knownVariantsStorage ?? "") }
        set {
            let storage = makeStorageString(from: newValue)
            knownVariantsStorage = storage.isEmpty ? nil : storage
        }
    }

    var variantSummaryText: String? {
        let variants = knownVariants.filter { $0.caseInsensitiveCompare(text) != .orderedSame }
        guard !variants.isEmpty else { return nil }
        return "Also seen as \(variants.joined(separator: ", "))"
    }
}

@Model
final class DictionarySuggestionEntry {
    var ownerProfileID: String = ""
    var text: String
    var normalizedKey: String
    var clusterKey: String?
    var kind: DictionarySuggestionKind
    var status: DictionarySuggestionStatus
    var evidenceCount: Int
    var stableSpellingCount: Int
    var rawMatchCount: Int
    var firstSeenAt: Date
    var lastSeenAt: Date
    var lastSeenSessionID: String?
    var dismissedAtEvidenceCount: Int
    var exampleSnippetsStorage: String
    var distinctDayKeysStorage: String
    var distinctAppKeysStorage: String
    var knownVariantsStorage: String?

    init(
        ownerProfileID: String = "",
        text: String,
        normalizedKey: String,
        clusterKey: String,
        kind: DictionarySuggestionKind,
        status: DictionarySuggestionStatus = .pending,
        evidenceCount: Int = 0,
        stableSpellingCount: Int = 0,
        rawMatchCount: Int = 0,
        firstSeenAt: Date = .now,
        lastSeenAt: Date = .now,
        lastSeenSessionID: String? = nil,
        dismissedAtEvidenceCount: Int = 0,
        exampleSnippetsStorage: String = "",
        distinctDayKeysStorage: String = "",
        distinctAppKeysStorage: String = "",
        knownVariantsStorage: String = ""
    ) {
        self.ownerProfileID = ownerProfileID
        self.text = text
        self.normalizedKey = normalizedKey
        self.clusterKey = clusterKey.isEmpty ? nil : clusterKey
        self.kind = kind
        self.status = status
        self.evidenceCount = evidenceCount
        self.stableSpellingCount = stableSpellingCount
        self.rawMatchCount = rawMatchCount
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.lastSeenSessionID = lastSeenSessionID
        self.dismissedAtEvidenceCount = dismissedAtEvidenceCount
        self.exampleSnippetsStorage = exampleSnippetsStorage
        self.distinctDayKeysStorage = distinctDayKeysStorage
        self.distinctAppKeysStorage = distinctAppKeysStorage
        self.knownVariantsStorage = knownVariantsStorage.isEmpty ? nil : knownVariantsStorage
    }

    var clusterKeyValue: String {
        get { clusterKey ?? "" }
        set { clusterKey = newValue.isEmpty ? nil : newValue }
    }

    var exampleSnippets: [String] {
        get { storageComponents(from: exampleSnippetsStorage) }
        set { exampleSnippetsStorage = makeStorageString(from: newValue) }
    }

    var distinctDayKeys: Set<String> {
        get { Set(storageComponents(from: distinctDayKeysStorage)) }
        set { distinctDayKeysStorage = makeStorageString(from: Array(newValue).sorted()) }
    }

    var distinctAppKeys: Set<String> {
        get { Set(storageComponents(from: distinctAppKeysStorage)) }
        set { distinctAppKeysStorage = makeStorageString(from: Array(newValue).sorted()) }
    }

    var knownVariants: [String] {
        get { storageComponents(from: knownVariantsStorage ?? "") }
        set {
            let storage = makeStorageString(from: newValue)
            knownVariantsStorage = storage.isEmpty ? nil : storage
        }
    }

    var confidenceScore: Double {
        Double(evidenceCount) * 10
            + Double(distinctDayKeys.count) * 4
            + Double(distinctAppKeys.count) * 3
            + Double(stableSpellingCount) * 2
            + Double(rawMatchCount)
    }

    var variantSummaryText: String? {
        let variants = knownVariants.filter { $0.caseInsensitiveCompare(text) != .orderedSame }
        guard !variants.isEmpty else { return nil }
        return "Also seen as \(variants.joined(separator: ", "))"
    }
}

private let dictionaryStorageSeparator = "\u{1E}"

private func storageComponents(from value: String) -> [String] {
    value
        .split(separator: Character(dictionaryStorageSeparator), omittingEmptySubsequences: true)
        .map(String.init)
}

private func makeStorageString(from values: [String]) -> String {
    values
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: dictionaryStorageSeparator)
}

private func isAcronymLike(_ text: String) -> Bool {
    let letters = text.filter(\.isLetter)
    guard letters.count >= 2 else { return false }
    return letters == letters.uppercased()
}
