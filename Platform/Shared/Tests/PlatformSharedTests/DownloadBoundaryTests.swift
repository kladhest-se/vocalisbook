import Foundation
import Testing
@testable import PlatformShared

@Suite("Download response and background lifecycle")
struct DownloadBoundaryTests {
    private func response(status: Int, type: String = "audio/mp4") -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://example.invalid/book.m4b")!,
                        statusCode: status, httpVersion: nil,
                        headerFields: ["Content-Type": type])!
    }

    @Test("HTTP error bodies never qualify as downloaded audio", arguments: [401, 403, 404, 500, 206, 204])
    func errorStatuses(status: Int) {
        #expect(throws: DownloadResponseValidation.Failure.httpStatus(status)) {
            try DownloadResponseValidation.validate(response(status: status))
        }
    }

    @Test("Audio and binary responses are accepted", arguments: ["audio/mp4", "audio/mpeg", "application/octet-stream"])
    func audioResponses(type: String) throws {
        try DownloadResponseValidation.validate(response(status: 200, type: type))
    }

    @Test("A successful login or error document is still rejected", arguments: ["text/html", "application/json", "application/xml"])
    func loginPage(type: String) {
        #expect(throws: DownloadResponseValidation.Failure.unexpectedContentType(type)) {
            try DownloadResponseValidation.validate(response(status: 200, type: type))
        }
    }

    @Test("A missing response is not a completed download")
    func missingResponse() {
        #expect(throws: DownloadResponseValidation.Failure.nonHTTP) {
            try DownloadResponseValidation.validate(nil)
        }
    }

    @MainActor @Test("The background handoff completes only after events, once per delivery")
    func completionOrder() {
        let events = BackgroundDownloadEvents()
        var count = 0
        events.handleEvents(identifier: BackgroundDownloadEvents.sessionIdentifier) { count += 1 }
        #expect(count == 0)
        events.finishEvents()
        #expect(count == 1)
        events.finishEvents()
        #expect(count == 1)
        // A finish notification can precede the app delegate handoff.
        events.handleEvents(identifier: BackgroundDownloadEvents.sessionIdentifier) { count += 1 }
        #expect(count == 2)
    }

    @MainActor @Test("An unknown background session does not retain the system handoff")
    func unknownSession() {
        let events = BackgroundDownloadEvents()
        var completed = false
        events.handleEvents(identifier: "other.session") { completed = true }
        #expect(completed)
    }
}
