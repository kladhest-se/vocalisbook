import Foundation

/// Wraps an `HTTPClient` with the Plex header set, token injection, status
/// mapping and JSON decoding. Everything above this layer works in terms of
/// decoded models.
public struct PlexTransport: Sendable {
    private let client: HTTPClient
    private let identity: PlexClientIdentity

    public init(client: HTTPClient, identity: PlexClientIdentity) {
        self.client = client
        self.identity = identity
    }

    public func send(_ request: HTTPRequest, token: String? = nil) async throws -> HTTPResponse {
        var headers = identity.headers
        if let token { headers["X-Plex-Token"] = token }
        let response = try await client.send(request.adding(headers: headers))

        guard response.isSuccess else {
            if response.status == 401 || response.status == 403 { throw PlexError.unauthorized }
            let body = String(data: response.body.prefix(512), encoding: .utf8)
            throw PlexError.http(status: response.status, body: body)
        }
        return response
    }

    public func decode<T: Decodable & Sendable>(
        _ type: T.Type,
        from request: HTTPRequest,
        token: String? = nil
    ) async throws -> T {
        let response = try await send(request, token: token)
        do {
            return try Self.decoder.decode(T.self, from: response.body)
        } catch {
            throw PlexError.decoding("\(T.self): \(error)")
        }
    }

    /// Plex is inconsistent about whether numeric fields arrive as JSON numbers
    /// or as quoted strings, so every numeric model field uses the lenient
    /// wrappers in `LenientScalars.swift` rather than a custom decoding
    /// strategy here.
    static let decoder = JSONDecoder()
}
