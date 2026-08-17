import Foundation
import os
import Testing
@testable import PlexKit

/// How a failed request is classified, which decides what the app shows.
///
/// `PlexError.transport` is transient, and a transient error puts the app into
/// its degraded state — the "can't reach your server" banner. So the difference
/// between `.transport` and `.cancelled` is the difference between a banner and
/// nothing at all, and this file had no tests when that distinction was got
/// wrong.
///
/// Driven through a `URLProtocol` stub rather than a network: the classification
/// is the subject, and a test that needs a server tests the server.
///
/// `.serialized` because the stub's outcome is process-wide — a `URLProtocol` is
/// instantiated by `URLSession` and there is nowhere to hand it anything. Swift
/// Testing runs a suite's tests in parallel by default, so without this they set
/// that outcome over each other: the cancellation test was handed the success
/// payload belonging to another test and reported that no error was thrown.
@Suite("HTTP client", .serialized)
struct URLSessionHTTPClientTests {

    private func client() -> URLSessionHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSessionHTTPClient(session: URLSession(configuration: configuration))
    }

    private var request: HTTPRequest {
        HTTPRequest(url: URL(string: "https://server.example/library/sections")!)
    }

    /// The one that shipped as a bug.
    ///
    /// `URLSession` reports its own cancellation as `URLError.cancelled`, not as
    /// `CancellationError` — a different type, which fell through to
    /// `.transport`. Pull to refresh cancels its task whenever the list beneath
    /// it changes, so every refresh ended with the app claiming the server was
    /// unreachable while the server was answering.
    @Test("A cancelled request is cancelled, not a transport failure")
    func cancellationIsNotTransport() async {
        StubURLProtocol.outcome = .failure(URLError(.cancelled))

        await #expect(throws: PlexError.cancelled) {
            try await client().send(request)
        }
    }

    /// And a real network failure still is one, or the banner would never appear
    /// when it should.
    @Test("A genuine network failure is a transport error")
    func networkFailureIsTransport() async throws {
        StubURLProtocol.outcome = .failure(URLError(.cannotConnectToHost))

        do {
            _ = try await client().send(request)
            Issue.record("Expected a transport error")
        } catch let error as PlexError {
            guard case .transport = error else {
                Issue.record("Expected .transport, got \(error)")
                return
            }
            #expect(error.isTransient)
        }
    }

    @Test("A timeout is transient too, so the app degrades rather than failing")
    func timeoutIsTransient() async throws {
        StubURLProtocol.outcome = .failure(URLError(.timedOut))

        do {
            _ = try await client().send(request)
            Issue.record("Expected a transport error")
        } catch let error as PlexError {
            #expect(error.isTransient)
        }
    }

    @Test("A successful response carries its status, headers and body")
    func successIsPassedThrough() async throws {
        StubURLProtocol.outcome = .success(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"ok":true}"#.utf8)
        )

        let response = try await client().send(request)

        #expect(response.status == 200)
        #expect(response.headers["Content-Type"] == "application/json")
        #expect(response.body == Data(#"{"ok":true}"#.utf8))
    }

    /// A status is reported rather than thrown: which codes mean what is the
    /// transport's business, not the client's.
    @Test("An error status is a response, not a thrown error")
    func errorStatusIsAResponse() async throws {
        StubURLProtocol.outcome = .success(status: 401, headers: [:], body: Data())

        let response = try await client().send(request)
        #expect(response.status == 401)
    }
}

/// Answers requests with whatever the test set, without a network.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    /// `URLError` rather than `any Error`, so the outcome is `Sendable` and can
    /// live behind a lock. It is also the only thing worth putting here: the
    /// classification under test is of the errors `URLSession` itself reports.
    enum Outcome: Sendable {
        case success(status: Int, headers: [String: String], body: Data)
        case failure(URLError)
    }

    /// Locked, because the test writes it and `URLSession` reads it from its own
    /// queue. `.serialized` on the suite is what stops one test's outcome
    /// reaching another's request; this is what stops the two threads tearing
    /// the value between them.
    private static let state = OSAllocatedUnfairLock<Outcome>(
        initialState: .failure(URLError(.unknown))
    )

    static var outcome: Outcome {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch Self.outcome {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .success(let status, let headers, let body):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
