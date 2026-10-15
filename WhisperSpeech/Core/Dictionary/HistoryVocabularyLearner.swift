import AppKit
import SwiftData
import Foundation

/// Learns names and jargon from recent dictations, with no review step, then applies them
/// three ways: casing is restored after transcription, the macOS spell checker learns them,
/// and they're sent to recognition as terms (see `AppModel.mergedVocabulary`).
///
/// A word is a candidate when it recurs across several dictation sessions on several days,
/// and it's either a proper noun (capitalized mid-sentence) or unknown to the spell checker.
/// Sentence-initial capitals carry no signal and are ignored. Results are capped, so one bad
/// term can't grow into a large recognition bias.
@MainActor
enum HistoryVocabularyLearner {
    static let maximumTerms = 60
    static let minimumDays = 3
    static let minimumSessions = 3
    static let windowDays = 60

    /// Learns terms from `entries`. `alreadyLearned` keeps a term while it keeps recurring, even
    /// after the spell checker knows it, so learning doesn't flip-flop.
    static func learn(
        from entries: [DictationHistoryEntry],
        suppressed: Set<String>,
        alreadyLearned: Set<String>,
        calendar: Calendar = .current
    ) -> [String] {
        struct Tally {
            var days = Set<Date>()
            var sessions = Set<String>()
            var forms: [String: Int] = [:]
            var properNounCount = 0
        }
        var tallies: [String: Tally] = [:]

        for entry in entries where entry.countsTowardStats && entry.hasCleanedText {
            let day = calendar.startOfDay(for: entry.timestamp)
            let session = entry.sessionID ?? "\(entry.persistentModelID)"
            for occurrence in occurrences(in: entry.finalText) {
                let key = occurrence.word.lowercased()
                guard !suppressed.contains(key) else { continue }
                var tally = tallies[key, default: Tally()]
                tally.days.insert(day)
                tally.sessions.insert(session)
                tally.forms[occurrence.word, default: 0] += 1
                if !occurrence.isSentenceStart, occurrence.word.first?.isUppercase == true {
                    tally.properNounCount += 1
                }
                tallies[key] = tally
            }
        }

        var picked: [(term: String, sessions: Int)] = []
        for (key, tally) in tallies
        where tally.days.count >= minimumDays && tally.sessions.count >= minimumSessions {
            let isProperNoun = tally.properNounCount > 0
            let isUnknown = NSSpellChecker.shared.checkSpelling(of: key, startingAt: 0).location != NSNotFound
            guard isProperNoun || isUnknown || alreadyLearned.contains(key) else { continue }
            let form = tally.forms.max { $0.value < $1.value }?.key ?? key
            picked.append((form, tally.sessions.count))
        }
        return picked
            .sorted { $0.sessions == $1.sessions ? $0.term < $1.term : $0.sessions > $1.sessions }
            .prefix(maximumTerms)
            .map(\.term)
    }

    /// Keeps the macOS spell checker's learned words in step with Kleio's list.
    static func synchronizeSpellChecker(previous: Set<String>, current: Set<String>) {
        let checker = NSSpellChecker.shared
        for term in current.subtracting(previous) {
            checker.learnWord(term)
        }
        for term in previous.subtracting(current) {
            checker.unlearnWord(term)
        }
    }
}

// MARK: - Text rules (pure; safe to call from the dictation path)

extension HistoryVocabularyLearner {
    struct Occurrence: Equatable {
        let word: String
        let isSentenceStart: Bool
    }

    /// Words of three or more letters (apostrophes and hyphens allowed inside), with
    /// whether each starts a sentence.
    nonisolated static func occurrences(in text: String) -> [Occurrence] {
        var result: [Occurrence] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { substring, range, _, _ in
            guard let word = substring, word.count >= 3 else { return }
            guard word.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" }) else { return }
            result.append(Occurrence(word: word, isSentenceStart: isSentenceStart(at: range.lowerBound, in: text)))
        }
        return result
    }

    nonisolated static func isSentenceStart(at index: String.Index, in text: String) -> Bool {
        var cursor = index
        while cursor > text.startIndex {
            cursor = text.index(before: cursor)
            let character = text[cursor]
            if character.isNewline { return true }
            if character.isWhitespace { continue }
            return ".!?".contains(character)
        }
        return true
    }

    /// Restores a learned term's capitalization where dictation came out all-lowercase
    /// ("jamie" → "Jamie"). Terms that are lowercase by design (e.g. "rust") are never
    /// changed, and words already capitalized are left alone.
    nonisolated static func restoreCasing(_ text: String, terms: [String]) -> String {
        var canonical: [String: String] = [:]
        for term in terms where term.contains(where: \.isUppercase) {
            canonical[term.lowercased(), default: term] = term
        }
        guard !canonical.isEmpty else { return text }

        var replacements: [(Range<String.Index>, String)] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { substring, range, _, _ in
            guard let word = substring, word == word.lowercased(),
                  let fixed = canonical[word] else { return }
            replacements.append((range, fixed))
        }
        var output = text
        for (range, fixed) in replacements.reversed() {
            output.replaceSubrange(range, with: fixed)
        }
        return output
    }
}

#if DEBUG
extension HistoryVocabularyLearner {
    /// Pure checks for the text rules. Runs with the other DEBUG self-tests.
    static func runSelfTests() {
        let sentence = occurrences(in: "Jamie said it. Then jamie left.")
        assert(sentence.map(\.isSentenceStart) == [true, false, true, false, false], "sentence-start detection")
        assert(sentence.first?.word == "Jamie", "first word is captured")

        let fixed = restoreCasing("i sent it to jamie and rust", terms: ["Jamie", "rust"])
        assert(fixed == "i sent it to Jamie and rust", "casing restored only for capitalized terms: \(fixed)")

        let untouched = restoreCasing("Jamie is here", terms: ["Jamie"])
        assert(untouched == "Jamie is here", "already-capitalized words stay as spoken")

        let apostrophe = occurrences(in: "don't stop")
        assert(apostrophe.first?.word == "don't", "apostrophes stay inside words")
    }
}
#endif
