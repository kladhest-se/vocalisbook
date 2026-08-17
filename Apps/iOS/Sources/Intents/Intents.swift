import AppIntents
import SwiftUI

/// "Continue my audiobook."
///
/// The one thing worth asking for without opening the app, and the one thing
/// this app is for.
///
/// `openAppWhenRun` is true because playback needs the app: the audio session,
/// the player and the timeline all live in the running process, and an intent
/// that tried to start audio from outside it would have to rebuild all three in
/// an extension with no way to hand them over.
///
/// So the intent's whole job is to ask, and the app answers when it comes up.
struct ContinueListeningIntent: AppIntent {
    // `let`, not `var`.
    //
    // These read as `static var` in every App Intents example, and Swift 6 will
    // not have mutable static state: a nonisolated global anybody could write to
    // is exactly what strict concurrency exists to refuse. The protocol asks for
    // a getter, and a constant provides one.
    static let title: LocalizedStringResource = "Continue Listening"

    static let description = IntentDescription(
        "Resumes the audiobook you were last listening to."
    )

    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRequests.shared.pending = .resumeLastBook
        return .result()
    }
}

/// The phrases Siri will accept.
///
/// `\(.applicationName)` is required in every phrase — Siri needs to know which
/// app is being addressed, and a phrase without it is rejected at build time
/// rather than at runtime.
struct VocalisBookShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ContinueListeningIntent(),
            phrases: [
                "Continue listening in \(.applicationName)",
                "Resume my audiobook in \(.applicationName)",
                "Continue my book in \(.applicationName)",
            ],
            shortTitle: "Continue Listening",
            systemImageName: "play.fill"
        )
    }
}

/// What an intent asked for, waiting for the app to be in a position to do it.
///
/// A singleton, which is not how anything else here is built and is what App
/// Intents leaves room for: the intent is constructed by the system, not by the
/// app, so there is no initialiser to pass an `AppModel` to and no environment
/// to read it from.
///
/// Deliberately tiny — one enum, no logic. The alternative is `@Dependency`,
/// which means registering the model at launch and reaching for it from an
/// intent that may run before the model exists. This asks; the app decides when
/// it is ready to answer.
@MainActor
final class IntentRequests {
    static let shared = IntentRequests()

    enum Request {
        case resumeLastBook
    }

    /// Cleared by whoever honours it, so a request is acted on once.
    var pending: Request?

    private init() {}
}
