import Foundation

public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
}

public struct HTTPRequest: Sendable, Hashable {
    public var method: HTTPMethod
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    public var timeout: Duration

    public init(
        method: HTTPMethod = .get,
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: Duration = .seconds(20)
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }

    public func adding(headers extra: [String: String]) -> HTTPRequest {
        var copy = self
        copy.headers.merge(extra) { _, new in new }
        return copy
    }
}

public struct HTTPResponse: Sendable, Hashable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public var isSuccess: Bool { (200..<300).contains(status) }
}

/// The single seam between PlexKit and the network. Tests inject a stub; the
/// apps inject `URLSessionHTTPClient`. Nothing else in PlexKit touches
/// URLSession directly.
public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}
