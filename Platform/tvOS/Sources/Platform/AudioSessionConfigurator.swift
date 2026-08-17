#if canImport(AVFAudio)
import AVFAudio
import Foundation

/// tvOS does have an audio session, unlike macOS. `.spokenAudio` still applies:
/// it is what makes the system pause rather than duck for other audio.
public struct AudioSessionConfigurator: Sendable {
    public init() {}

    public func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
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
