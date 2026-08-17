import Foundation
import os
@testable import PlexKit

/// Deterministic stand-in for the network. Handlers are matched against the
/// request path so tests read as "when asked for X, answer Y".
///
/// State lives in an `OSAllocatedUnfairLock` rather than an `NSLock`. Swift 6
/// marks `NSLock.lock()` and `unlock()` unavailable from asynchronous contexts,
/// and `send` is `async`, so the bare lock/unlock pair does not compile at all.
/// The scoped `withLock` form is the async-safe replacement, and it has the
/// further merit of making it impossible to return early still holding the lock.
final class StubHTTPClient: HTTPClient {
    typealias Handler = @Sendable (HTTPRequest) -> HTTPResponse

    private struct Rule: Sendable {
        let match: @Sendable (HTTPRequest) -> Bool
        let handler: Handler
    }

    private struct State: Sendable {
        var rules: [Rule] = []
        var recorded: [HTTPRequest] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func on(pathContains fragment: String, respond: @escaping Handler) {
        let rule = Rule(
            match: { request in request.url.absoluteString.contains(fragment) },
            handler: respond
        )
        state.withLock { current in current.rules.append(rule) }
    }

    func onJSON(pathContains fragment: String, status: Int = 200, _ json: String) {
        on(pathContains: fragment) { _ in
            HTTPResponse(status: status, body: Data(json.utf8))
        }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let handler: Handler? = state.withLock { current in
            current.recorded.append(request)
            return current.rules.first { rule in rule.match(request) }?.handler
        }

        guard let handler else {
            return HTTPResponse(status: 404, body: Data("no stub for \(request.url)".utf8))
        }
        return handler(request)
    }

    var recorded: [HTTPRequest] {
        state.withLock { current in current.recorded }
    }

    func requests(containing fragment: String) -> [HTTPRequest] {
        recorded.filter { $0.url.absoluteString.contains(fragment) }
    }
}

extension PlexClientIdentity {
    static let test = PlexClientIdentity(
        clientIdentifier: "TEST-CLIENT-0001",
        product: "VocalisBook",
        version: "0.1.0",
        device: "iPhone",
        deviceName: "Test Device",
        platform: "iOS",
        platformVersion: "18.0"
    )
}
