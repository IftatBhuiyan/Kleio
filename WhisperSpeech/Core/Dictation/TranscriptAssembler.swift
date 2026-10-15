import Foundation

struct TranscriptSnapshot: Sendable {
    let bestText: String
    let partialText: String
    let finalText: String
}

struct TranscriptAssembler {
    private(set) var partialText = ""
    private(set) var finalText = ""

    mutating func reset() {
        partialText = ""
        finalText = ""
    }

    mutating func applyPartial(_ text: String) -> TranscriptSnapshot {
        partialText = text
        return snapshot()
    }

    mutating func applyFinal(_ text: String) -> TranscriptSnapshot {
        finalText = text
        partialText = text
        return snapshot()
    }

    func snapshot() -> TranscriptSnapshot {
        let best = finalText.isEmpty ? partialText : finalText
        return TranscriptSnapshot(bestText: best, partialText: partialText, finalText: finalText)
    }
}
