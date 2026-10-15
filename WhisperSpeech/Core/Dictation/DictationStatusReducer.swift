import Foundation

enum DictationEvent {
    case startListening
    case stopListening
    case finalTextReceived
    case noSpeechDetected
    case failure(String)
    case reset
}

enum DictationStatusReducer {
    static func reduce(from current: DictationStatus, event: DictationEvent) -> DictationStatus {
        switch event {
        case .startListening:
            return .listening
        case .stopListening:
            return .processing
        case .finalTextReceived, .noSpeechDetected, .reset:
            return .idle
        case .failure(let message):
            return .error(message)
        }
    }
}
