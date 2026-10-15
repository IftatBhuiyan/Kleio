import AppKit
import Foundation

@MainActor
final class MacDictationSoundEffectService {
    private enum Asset {
        static let activation = "dictation-activation"
        static let deactivation = "dictation-deactivation"
        static let ext = "wav"
    }

    private let bundle: Bundle
    // Loaded lazily on first play so bundle I/O stays off the launch path (L-3).
    private lazy var activationSound: NSSound? = Self.loadSound(named: Asset.activation, bundle: bundle)
    private lazy var deactivationSound: NSSound? = Self.loadSound(named: Asset.deactivation, bundle: bundle)

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    @discardableResult
    func playActivation() -> TimeInterval {
        play(activationSound, label: "activation")
    }

    @discardableResult
    func playDeactivation() -> TimeInterval {
        play(deactivationSound, label: "deactivation")
    }

    private func play(_ sound: NSSound?, label: String) -> TimeInterval {
        guard let sound else {
            print("[sound] Missing \(label) sound asset")
            return 0
        }
        let duration = max(0, sound.duration)
        sound.stop()
        sound.play()
        return duration
    }

    private static func loadSound(named name: String, bundle: Bundle) -> NSSound? {
        // Direct lookup instead of a recursive bundle walk (L-3).
        guard let url = bundle.url(forResource: name, withExtension: Asset.ext) else {
            print("[sound] Could not locate \(name).\(Asset.ext) in app bundle")
            return nil
        }
        guard let sound = NSSound(contentsOf: url, byReference: false) else {
            print("[sound] Failed to load \(name).\(Asset.ext)")
            return nil
        }
        return sound
    }
}
