import Foundation

struct CloudAccountSettingsSnapshot: Equatable, Sendable {
    let outputPresetRawValue: String
    let cleanupModelRawValue: String
    let sourceLanguageModeRawValue: String
    let sourceLanguageCode: String
    let outputLanguageModeRawValue: String
    let outputLanguageCode: String
    let autoLearnDictionaryTermsEnabled: Bool

    init(configuration: AppConfiguration) {
        self.outputPresetRawValue = configuration.outputPreset.rawValue
        self.cleanupModelRawValue = configuration.cleanupModel.rawValue
        self.sourceLanguageModeRawValue = configuration.sourceLanguageMode.rawValue
        self.sourceLanguageCode = configuration.sourceLanguageCode
        self.outputLanguageModeRawValue = configuration.outputLanguageMode.rawValue
        self.outputLanguageCode = configuration.outputLanguageCode
        self.autoLearnDictionaryTermsEnabled = configuration.autoLearnDictionaryTermsEnabled
    }

    init?(documentData: [String: Any]) {
        guard
            let outputPresetRawValue = documentData["outputPreset"] as? String,
            let cleanupModelRawValue = documentData["cleanupModel"] as? String,
            let sourceLanguageModeRawValue = documentData["sourceLanguageMode"] as? String,
            let sourceLanguageCode = documentData["sourceLanguageCode"] as? String,
            let outputLanguageModeRawValue = documentData["outputLanguageMode"] as? String,
            let outputLanguageCode = documentData["outputLanguageCode"] as? String,
            let autoLearnDictionaryTermsEnabled = documentData["autoLearnDictionaryTermsEnabled"] as? Bool
        else {
            return nil
        }

        self.outputPresetRawValue = outputPresetRawValue
        self.cleanupModelRawValue = cleanupModelRawValue
        self.sourceLanguageModeRawValue = sourceLanguageModeRawValue
        self.sourceLanguageCode = sourceLanguageCode
        self.outputLanguageModeRawValue = outputLanguageModeRawValue
        self.outputLanguageCode = outputLanguageCode
        self.autoLearnDictionaryTermsEnabled = autoLearnDictionaryTermsEnabled
    }

    var firestoreData: [String: Any] {
        [
            "outputPreset": outputPresetRawValue,
            "cleanupModel": cleanupModelRawValue,
            "sourceLanguageMode": sourceLanguageModeRawValue,
            "sourceLanguageCode": sourceLanguageCode,
            "outputLanguageMode": outputLanguageModeRawValue,
            "outputLanguageCode": outputLanguageCode,
            "autoLearnDictionaryTermsEnabled": autoLearnDictionaryTermsEnabled
        ]
    }
}

struct CloudPrivacySettingsSnapshot: Equatable, Sendable {
    let cloudTranscriptStorageEnabled: Bool
    let privacyModeEnabled: Bool
    let improvementSharingEnabled: Bool
    let uploadDeviceSummariesEnabled: Bool

    init(configuration: AppConfiguration, uploadDeviceSummariesEnabled: Bool) {
        self.cloudTranscriptStorageEnabled = false
        self.privacyModeEnabled = configuration.privacyModeEnabled
        self.improvementSharingEnabled = configuration.privacyModeEnabled
            ? false
            : configuration.improvementSharingEnabled
        self.uploadDeviceSummariesEnabled = uploadDeviceSummariesEnabled
    }

    init?(documentData: [String: Any]) {
        let cloudTranscriptStorageEnabled =
            documentData["cloudTranscriptStorageEnabled"] as? Bool ?? false
        guard cloudTranscriptStorageEnabled == false else {
            return nil
        }

        self.cloudTranscriptStorageEnabled = false
        self.privacyModeEnabled = documentData["privacyModeEnabled"] as? Bool ?? false
        self.improvementSharingEnabled = documentData["improvementSharingEnabled"] as? Bool ?? true
        self.uploadDeviceSummariesEnabled = documentData["uploadDeviceSummariesEnabled"] as? Bool ?? false
    }

    var firestoreData: [String: Any] {
        [
            "cloudTranscriptStorageEnabled": cloudTranscriptStorageEnabled,
            "privacyModeEnabled": privacyModeEnabled,
            "improvementSharingEnabled": privacyModeEnabled ? false : improvementSharingEnabled,
            "uploadDeviceSummariesEnabled": uploadDeviceSummariesEnabled
        ]
    }
}

struct CloudDictionaryTermSnapshot: Equatable, Sendable {
    let text: String
    let normalizedKey: String
    let statusRawValue: String
    let sourceRawValue: String
    let knownVariants: [String]

    init(
        text: String,
        normalizedKey: String,
        statusRawValue: String,
        sourceRawValue: String,
        knownVariants: [String]
    ) {
        self.text = text
        self.normalizedKey = normalizedKey
        self.statusRawValue = statusRawValue
        self.sourceRawValue = sourceRawValue
        self.knownVariants = knownVariants
    }

    init?(documentData: [String: Any]) {
        guard
            let text = documentData["text"] as? String,
            let normalizedKey = documentData["normalizedKey"] as? String,
            let statusRawValue = documentData["status"] as? String,
            let sourceRawValue = documentData["source"] as? String
        else {
            return nil
        }

        self.text = text
        self.normalizedKey = normalizedKey
        self.statusRawValue = statusRawValue
        self.sourceRawValue = sourceRawValue
        self.knownVariants = documentData["knownVariants"] as? [String] ?? [text]
    }

    var firestoreData: [String: Any] {
        [
            "text": text,
            "normalizedKey": normalizedKey,
            "status": statusRawValue,
            "source": sourceRawValue,
            "knownVariants": knownVariants
        ]
    }
}
