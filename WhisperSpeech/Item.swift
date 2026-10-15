import Foundation
import SwiftData

@Model
final class DictationHistoryEntry {
    var ownerProfileID: String = ""
    var sessionID: String?
    var timestamp: Date
    var finalText: String
    var rawText: String?
    var outputPresetRawValue: String?
    var audioDuration: Double
    var wordCount: Int
    var wordsPerMinute: Double
    var requestedSourceLanguageModeRawValue: String?
    var requestedSourceLanguageCode: String?
    var resolvedSourceLanguageCode: String?
    var outputLanguageCode: String?
    var didTranslate: Bool?
    var providerRouteRawValue: String?
    var sourceAppBundleIdentifier: String?
    var sourceAppName: String?
    @Attribute(.externalStorage) var sourceAppIconPNGData: Data?
    // Non-nil when this entry was recovered from a failed session (watchdog/backend/transport
    // failure): the stored text is the best raw transcript, not a cleaned canonical result.
    var failureNote: String?

    init(
        ownerProfileID: String = "",
        sessionID: String? = nil,
        timestamp: Date = .now,
        finalText: String,
        rawText: String? = nil,
        outputPresetRawValue: String? = nil,
        audioDuration: Double,
        wordCount: Int,
        wordsPerMinute: Double,
        requestedSourceLanguageModeRawValue: String? = nil,
        requestedSourceLanguageCode: String? = nil,
        resolvedSourceLanguageCode: String? = nil,
        outputLanguageCode: String? = nil,
        didTranslate: Bool? = nil,
        providerRouteRawValue: String? = nil,
        sourceAppBundleIdentifier: String? = nil,
        sourceAppName: String? = nil,
        sourceAppIconPNGData: Data? = nil,
        failureNote: String? = nil
    ) {
        self.ownerProfileID = ownerProfileID
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.finalText = finalText
        self.rawText = rawText
        self.outputPresetRawValue = outputPresetRawValue
        self.audioDuration = audioDuration
        self.wordCount = wordCount
        self.wordsPerMinute = wordsPerMinute
        self.requestedSourceLanguageModeRawValue = requestedSourceLanguageModeRawValue
        self.requestedSourceLanguageCode = requestedSourceLanguageCode
        self.resolvedSourceLanguageCode = resolvedSourceLanguageCode
        self.outputLanguageCode = outputLanguageCode
        self.didTranslate = didTranslate
        self.providerRouteRawValue = providerRouteRawValue
        self.sourceAppBundleIdentifier = sourceAppBundleIdentifier
        self.sourceAppName = sourceAppName
        self.sourceAppIconPNGData = sourceAppIconPNGData
        self.failureNote = failureNote
    }

    var isFailedRawFallback: Bool {
        !(failureNote?.isEmpty ?? true)
    }

    var outputPreset: DictationOutputPreset? {
        guard let outputPresetRawValue else { return nil }
        return DictationOutputPreset(rawValue: outputPresetRawValue)
    }

    var cleanedDisplayText: String {
        let cleaned = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "No cleaned transcript available for this session." : cleaned
    }

    var rawDisplayText: String {
        let cleaned = rawText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? "Raw STT is unavailable for this older dictation entry." : cleaned
    }

}
