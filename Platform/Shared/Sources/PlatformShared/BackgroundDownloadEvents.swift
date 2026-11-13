import Foundation

/// Retains the system's background-session handoff until all download events
/// have been saved. Completion may arrive before or after the delegate handoff.
@MainActor
public final class BackgroundDownloadEvents {
    public static let sessionIdentifier = "se.kladhest.vocalisbook.downloads"
    public static let shared = BackgroundDownloadEvents()

    private var completion: (() -> Void)?
    private var finished = false

    public init() {}

    public func handleEvents(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Self.sessionIdentifier else {
            completionHandler()
            return
        }
        completion = completionHandler
        completeIfReady()
    }

    public func finishEvents() {
        finished = true
        completeIfReady()
    }

    private func completeIfReady() {
        guard finished, let handler = completion else { return }
        completion = nil
        finished = false
        handler()
    }
}
