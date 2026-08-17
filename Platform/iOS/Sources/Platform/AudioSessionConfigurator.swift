#if canImport(AVFAudio)
import AVFAudio
import Foundation

/// Configures the shared audio session for spoken-word playback.
///
/// `.spokenAudio` is not cosmetic: it is what makes the system *pause* rather
/// than duck for navigation prompts, which is the correct behaviour for an
/// audiobook and the wrong one for music. Using `.default` here is the single
/// most common mistake in audiobook apps.
public struct AudioSessionConfigurator: Sendable {
    public init() {}

    public func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playback,
            mode: .spokenAudio,
            policy: .longFormAudio,
            options: []
        )
        try session.setActive(true)
    }

    public func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }
}
#endif
