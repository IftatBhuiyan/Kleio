import Foundation

enum DictationSourceLanguageMode: String, CaseIterable, Codable, Sendable {
    case auto
    case explicit

    var displayName: String {
        switch self {
        case .auto:
            return "Auto"
        case .explicit:
            return "Specific Language"
        }
    }
}

enum DictationOutputLanguageMode: String, CaseIterable, Codable, Sendable {
    case matchSource = "match_source"
    case explicit

    var displayName: String {
        switch self {
        case .matchSource:
            return "Match Spoken Language"
        case .explicit:
            return "Specific Language"
        }
    }
}

enum DictationProviderRoute: String, Codable, Sendable {
    case deepgramLive = "deepgram_live"
    case groqWhisperBuffered = "groq_whisper_buffered"
    case deepgramLiveGroqBufferedFallback = "deepgram_live_groq_buffered_fallback"

    var displayName: String {
        switch self {
        case .deepgramLive:
            return "Deepgram Live"
        case .groqWhisperBuffered:
            return "Groq Whisper Buffered"
        case .deepgramLiveGroqBufferedFallback:
            return "Deepgram Live with Groq Fallback"
        }
    }
}

struct DictationLanguageOption: Identifiable, Hashable, Sendable {
    let code: String
    let displayName: String
    let aliases: [String]

    var id: String { code }

    var searchableText: String {
        ([displayName, code] + aliases).joined(separator: " ").lowercased()
    }
}

enum DictationLanguageCatalog {
    static let defaultExplicitSourceLanguageCode = "en"
    static let defaultExplicitOutputLanguageCode = "en"

    static let languages: [DictationLanguageOption] = [
        .init(code: "en", displayName: "English", aliases: ["american english", "british english"]),
        .init(code: "bn", displayName: "Bengali", aliases: ["bangla"]),
        .init(code: "es", displayName: "Spanish", aliases: ["espanol", "castilian"]),
        .init(code: "hi", displayName: "Hindi", aliases: []),
        .init(code: "ar", displayName: "Arabic", aliases: []),
        .init(code: "zh", displayName: "Chinese", aliases: ["mandarin", "mandarin chinese"]),
        .init(code: "fr", displayName: "French", aliases: ["francais"]),
        .init(code: "de", displayName: "German", aliases: ["deutsch"]),
        .init(code: "pt", displayName: "Portuguese", aliases: ["brazilian portuguese", "portugues"]),
        .init(code: "ru", displayName: "Russian", aliases: []),
        .init(code: "ja", displayName: "Japanese", aliases: []),
        .init(code: "ko", displayName: "Korean", aliases: []),
        .init(code: "it", displayName: "Italian", aliases: ["italiano"]),
        .init(code: "tr", displayName: "Turkish", aliases: ["turkce"]),
        .init(code: "id", displayName: "Indonesian", aliases: ["bahasa indonesia"]),
        .init(code: "ms", displayName: "Malay", aliases: ["bahasa melayu"]),
        .init(code: "vi", displayName: "Vietnamese", aliases: ["tieng viet"]),
        .init(code: "th", displayName: "Thai", aliases: []),
        .init(code: "ur", displayName: "Urdu", aliases: []),
        .init(code: "pa", displayName: "Punjabi", aliases: ["panjabi"]),
        .init(code: "ta", displayName: "Tamil", aliases: []),
        .init(code: "te", displayName: "Telugu", aliases: []),
        .init(code: "mr", displayName: "Marathi", aliases: []),
        .init(code: "gu", displayName: "Gujarati", aliases: []),
        .init(code: "ml", displayName: "Malayalam", aliases: []),
        .init(code: "kn", displayName: "Kannada", aliases: []),
        .init(code: "pl", displayName: "Polish", aliases: ["polski"]),
        .init(code: "uk", displayName: "Ukrainian", aliases: ["ukrainska"]),
        .init(code: "ro", displayName: "Romanian", aliases: ["romana"]),
        .init(code: "el", displayName: "Greek", aliases: ["ellinika"]),
        .init(code: "he", displayName: "Hebrew", aliases: ["ivrit"]),
        .init(code: "fa", displayName: "Persian", aliases: ["farsi"]),
        .init(code: "sw", displayName: "Swahili", aliases: ["kiswahili"]),
        .init(code: "nl", displayName: "Dutch", aliases: ["nederlands"]),
        .init(code: "sv", displayName: "Swedish", aliases: ["svenska"]),
        .init(code: "da", displayName: "Danish", aliases: ["dansk"]),
        .init(code: "fi", displayName: "Finnish", aliases: ["suomi"]),
        .init(code: "no", displayName: "Norwegian", aliases: ["norsk", "bokmal"]),
        .init(code: "cs", displayName: "Czech", aliases: ["cesky"]),
        .init(code: "hu", displayName: "Hungarian", aliases: ["magyar"]),
        .init(code: "sk", displayName: "Slovak", aliases: ["slovencina"]),
        .init(code: "sl", displayName: "Slovenian", aliases: ["slovenscina"]),
        .init(code: "hr", displayName: "Croatian", aliases: ["hrvatski"]),
        .init(code: "sr", displayName: "Serbian", aliases: ["srpski"]),
        .init(code: "bg", displayName: "Bulgarian", aliases: ["balgarski"]),
        .init(code: "lt", displayName: "Lithuanian", aliases: ["lietuviu"]),
        .init(code: "lv", displayName: "Latvian", aliases: ["latviesu"]),
        .init(code: "et", displayName: "Estonian", aliases: ["eesti"]),
        .init(code: "ca", displayName: "Catalan", aliases: ["catala"]),
        .init(code: "af", displayName: "Afrikaans", aliases: []),
        .init(code: "fil", displayName: "Filipino", aliases: ["tagalog"]),
        .init(code: "is", displayName: "Icelandic", aliases: ["islenska"])
    ]

    private static let languagesByCode = Dictionary(uniqueKeysWithValues: languages.map { ($0.code, $0) })

    static func normalize(code: String?) -> String? {
        guard let code else { return nil }
        let cleaned = code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !cleaned.isEmpty else { return nil }
        return cleaned.split(separator: "-").first.map(String.init)
    }

    static func isSupported(code: String?) -> Bool {
        guard let normalized = normalize(code: code) else { return false }
        return languagesByCode[normalized] != nil
    }

    static func language(for code: String?) -> DictationLanguageOption {
        guard let normalized = normalize(code: code), let language = languagesByCode[normalized] else {
            return languagesByCode[defaultExplicitOutputLanguageCode] ?? languages[0]
        }
        return language
    }

    static func resolvedOutputLanguageCode(
        outputMode: DictationOutputLanguageMode,
        explicitOutputLanguageCode: String,
        sourceMode: DictationSourceLanguageMode,
        explicitSourceLanguageCode: String,
        resolvedSourceLanguageCode: String?
    ) -> String? {
        switch outputMode {
        case .explicit:
            return normalize(code: explicitOutputLanguageCode) ?? defaultExplicitOutputLanguageCode
        case .matchSource:
            if sourceMode == .explicit {
                return normalize(code: explicitSourceLanguageCode) ?? defaultExplicitSourceLanguageCode
            }
            return normalize(code: resolvedSourceLanguageCode)
        }
    }
}
