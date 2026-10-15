import Foundation

enum ClientMessageType: String, Codable {
    case sessionStart = "session_start"
    case audioChunk = "audio_chunk"
    case sessionEnd = "session_end"
    case ping
}

enum ServerMessageType: String, Codable {
    case sessionStarted = "session_started"
    case partialText = "partial_text"
    case finalText = "final_text"
    // Retained so newer clients can still talk to older deployed backends during rollout.
    case transcriptCorrection = "transcript_correction"
    case notice
    case error
    case pong
}

struct ClientMessage: Codable, Sendable {
    let v: Int
    let type: ClientMessageType
    let prompt: String?
    let promptProfile: String?
    let cleanupModel: String?
    let sourceLanguageMode: String?
    let sourceLanguage: String?
    let outputLanguage: String?
    let sampleRate: Int?
    let customVocabulary: [String]?
    let privacyModeEnabled: Bool?
    let improvementSharingEnabled: Bool?
    let clientAppVersion: String?
    let clientLocale: String?
    let clientPlatform: String?
    let clientSessionID: String?
    let data: String?

    enum CodingKeys: String, CodingKey {
        case v
        case type
        case prompt
        case promptProfile = "prompt_profile"
        case cleanupModel = "cleanup_model"
        case sourceLanguageMode = "source_language_mode"
        case sourceLanguage = "source_language"
        case outputLanguage = "output_language"
        case sampleRate = "sample_rate"
        case customVocabulary = "custom_vocabulary"
        case privacyModeEnabled = "privacy_mode_enabled"
        case improvementSharingEnabled = "improvement_sharing_enabled"
        case clientAppVersion = "client_app_version"
        case clientLocale = "client_locale"
        case clientPlatform = "client_platform"
        case clientSessionID = "client_session_id"
        case data
    }

    init(
        v: Int = 1,
        type: ClientMessageType,
        prompt: String?,
        promptProfile: String?,
        cleanupModel: String?,
        sourceLanguageMode: String?,
        sourceLanguage: String?,
        outputLanguage: String?,
        sampleRate: Int?,
        customVocabulary: [String]?,
        privacyModeEnabled: Bool?,
        improvementSharingEnabled: Bool?,
        clientAppVersion: String?,
        clientLocale: String?,
        clientPlatform: String?,
        clientSessionID: String?,
        data: String?
    ) {
        self.v = v
        self.type = type
        self.prompt = prompt
        self.promptProfile = promptProfile
        self.cleanupModel = cleanupModel
        self.sourceLanguageMode = sourceLanguageMode
        self.sourceLanguage = sourceLanguage
        self.outputLanguage = outputLanguage
        self.sampleRate = sampleRate
        self.customVocabulary = customVocabulary
        self.privacyModeEnabled = privacyModeEnabled
        self.improvementSharingEnabled = improvementSharingEnabled
        self.clientAppVersion = clientAppVersion
        self.clientLocale = clientLocale
        self.clientPlatform = clientPlatform
        self.clientSessionID = clientSessionID
        self.data = data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try container.decodeIfPresent(Int.self, forKey: .v) ?? 1
        type = try container.decode(ClientMessageType.self, forKey: .type)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        promptProfile = try container.decodeIfPresent(String.self, forKey: .promptProfile)
        cleanupModel = try container.decodeIfPresent(String.self, forKey: .cleanupModel)
        sourceLanguageMode = try container.decodeIfPresent(String.self, forKey: .sourceLanguageMode)
        sourceLanguage = try container.decodeIfPresent(String.self, forKey: .sourceLanguage)
        outputLanguage = try container.decodeIfPresent(String.self, forKey: .outputLanguage)
        sampleRate = try container.decodeIfPresent(Int.self, forKey: .sampleRate)
        customVocabulary = try container.decodeIfPresent([String].self, forKey: .customVocabulary)
        privacyModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .privacyModeEnabled)
        improvementSharingEnabled = try container.decodeIfPresent(Bool.self, forKey: .improvementSharingEnabled)
        clientAppVersion = try container.decodeIfPresent(String.self, forKey: .clientAppVersion)
        clientLocale = try container.decodeIfPresent(String.self, forKey: .clientLocale)
        clientPlatform = try container.decodeIfPresent(String.self, forKey: .clientPlatform)
        clientSessionID = try container.decodeIfPresent(String.self, forKey: .clientSessionID)
        data = try container.decodeIfPresent(String.self, forKey: .data)
    }

    static func sessionStart(
        prompt: String,
        promptProfile: String? = nil,
        cleanupModel: String? = nil,
        sourceLanguageMode: String? = nil,
        sourceLanguage: String? = nil,
        outputLanguage: String? = nil,
        sampleRate: Int,
        customVocabulary: [String]? = nil,
        privacyModeEnabled: Bool? = nil,
        improvementSharingEnabled: Bool? = nil,
        clientAppVersion: String? = nil,
        clientLocale: String? = nil,
        clientPlatform: String? = nil,
        clientSessionID: String
    ) -> ClientMessage {
        ClientMessage(
            type: .sessionStart,
            prompt: prompt,
            promptProfile: promptProfile,
            cleanupModel: cleanupModel,
            sourceLanguageMode: sourceLanguageMode,
            sourceLanguage: sourceLanguage,
            outputLanguage: outputLanguage,
            sampleRate: sampleRate,
            customVocabulary: customVocabulary,
            privacyModeEnabled: privacyModeEnabled,
            improvementSharingEnabled: improvementSharingEnabled,
            clientAppVersion: clientAppVersion,
            clientLocale: clientLocale,
            clientPlatform: clientPlatform,
            clientSessionID: clientSessionID,
            data: nil
        )
    }

    static func audioChunk(data: String, clientSessionID: String) -> ClientMessage {
        ClientMessage(
            type: .audioChunk,
            prompt: nil,
            promptProfile: nil,
            cleanupModel: nil,
            sourceLanguageMode: nil,
            sourceLanguage: nil,
            outputLanguage: nil,
            sampleRate: nil,
            customVocabulary: nil,
            privacyModeEnabled: nil,
            improvementSharingEnabled: nil,
            clientAppVersion: nil,
            clientLocale: nil,
            clientPlatform: nil,
            clientSessionID: clientSessionID,
            data: data
        )
    }

    static func sessionEnd(clientSessionID: String) -> ClientMessage {
        ClientMessage(
            type: .sessionEnd,
            prompt: nil,
            promptProfile: nil,
            cleanupModel: nil,
            sourceLanguageMode: nil,
            sourceLanguage: nil,
            outputLanguage: nil,
            sampleRate: nil,
            customVocabulary: nil,
            privacyModeEnabled: nil,
            improvementSharingEnabled: nil,
            clientAppVersion: nil,
            clientLocale: nil,
            clientPlatform: nil,
            clientSessionID: clientSessionID,
            data: nil
        )
    }

    static func ping() -> ClientMessage {
        ClientMessage(
            type: .ping,
            prompt: nil,
            promptProfile: nil,
            cleanupModel: nil,
            sourceLanguageMode: nil,
            sourceLanguage: nil,
            outputLanguage: nil,
            sampleRate: nil,
            customVocabulary: nil,
            privacyModeEnabled: nil,
            improvementSharingEnabled: nil,
            clientAppVersion: nil,
            clientLocale: nil,
            clientPlatform: nil,
            clientSessionID: nil,
            data: nil
        )
    }
}

struct ServerMessage: Codable, Sendable {
    let v: Int
    let type: ServerMessageType
    let text: String?
    let rawText: String?
    let message: String?
    let original: String?
    let corrected: String?
    let isCanonical: Bool?
    let sourceLanguageMode: String?
    let sourceLanguage: String?
    let resolvedSourceLanguage: String?
    let outputLanguage: String?
    let didTranslate: Bool?
    let providerRoute: String?
    let clientSessionID: String?
    let connectionID: String?

    enum CodingKeys: String, CodingKey {
        case v
        case type
        case text
        case rawText = "raw_text"
        case message
        case original
        case corrected
        case isCanonical = "is_canonical"
        case sourceLanguageMode = "source_language_mode"
        case sourceLanguage = "source_language"
        case resolvedSourceLanguage = "resolved_source_language"
        case outputLanguage = "output_language"
        case didTranslate = "did_translate"
        case providerRoute = "provider_route"
        case clientSessionID = "client_session_id"
        case connectionID = "connection_id"
    }

    init(
        v: Int = 1,
        type: ServerMessageType,
        text: String?,
        rawText: String? = nil,
        message: String?,
        original: String? = nil,
        corrected: String? = nil,
        isCanonical: Bool? = nil,
        sourceLanguageMode: String? = nil,
        sourceLanguage: String? = nil,
        resolvedSourceLanguage: String? = nil,
        outputLanguage: String? = nil,
        didTranslate: Bool? = nil,
        providerRoute: String? = nil,
        clientSessionID: String? = nil,
        connectionID: String? = nil
    ) {
        self.v = v
        self.type = type
        self.text = text
        self.rawText = rawText
        self.message = message
        self.original = original
        self.corrected = corrected
        self.isCanonical = isCanonical
        self.sourceLanguageMode = sourceLanguageMode
        self.sourceLanguage = sourceLanguage
        self.resolvedSourceLanguage = resolvedSourceLanguage
        self.outputLanguage = outputLanguage
        self.didTranslate = didTranslate
        self.providerRoute = providerRoute
        self.clientSessionID = clientSessionID
        self.connectionID = connectionID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try container.decodeIfPresent(Int.self, forKey: .v) ?? 1
        type = try container.decode(ServerMessageType.self, forKey: .type)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        rawText = try container.decodeIfPresent(String.self, forKey: .rawText)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        original = try container.decodeIfPresent(String.self, forKey: .original)
        corrected = try container.decodeIfPresent(String.self, forKey: .corrected)
        isCanonical = try container.decodeIfPresent(Bool.self, forKey: .isCanonical)
        sourceLanguageMode = try container.decodeIfPresent(String.self, forKey: .sourceLanguageMode)
        sourceLanguage = try container.decodeIfPresent(String.self, forKey: .sourceLanguage)
        resolvedSourceLanguage = try container.decodeIfPresent(String.self, forKey: .resolvedSourceLanguage)
        outputLanguage = try container.decodeIfPresent(String.self, forKey: .outputLanguage)
        didTranslate = try container.decodeIfPresent(Bool.self, forKey: .didTranslate)
        providerRoute = try container.decodeIfPresent(String.self, forKey: .providerRoute)
        clientSessionID = try container.decodeIfPresent(String.self, forKey: .clientSessionID)
        connectionID = try container.decodeIfPresent(String.self, forKey: .connectionID)
    }
}
