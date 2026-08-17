import Foundation

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// A configuration tuned for chatty metadata calls. Downloads use a
    /// separate background session owned by the download coordinator, not this.
    public static func foreground() -> URLSessionHTTPClient {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSessionHTTPClient(session: URLSession(configuration: config))
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = request.timeout.seconds
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw PlexError.transport("Non-HTTP response")
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let k = key as? String, let v = value as? String { headers[k] = v }
            }
            return HTTPResponse(status: http.statusCode, headers: headers, body: data)
        } catch let error as PlexError {
            throw error
        } catch is CancellationError {
            throw PlexError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            // `URLSession` reports its own cancellation as `URLError.cancelled`,
            // not as `CancellationError` — a different type, which fell through
            // to `.transport` below.
            //
            // `.transport` is transient, and a transient error puts the app in
            // its degraded state. So every cancelled request said "can't reach
            // your server": pull to refresh cancels its task whenever the list
            // it is refreshing changes underneath it, which during a refresh is
            // constantly, and the banner appeared on a server that was answering
            // perfectly.
            throw PlexError.cancelled
        } catch {
            throw PlexError.transport(error.localizedDescription)
        }
    }
}

extension Duration {
    var seconds: TimeInterval {
        let (secs, attos) = components
        return TimeInterval(secs) + TimeInterval(attos) / 1e18
    }
}
