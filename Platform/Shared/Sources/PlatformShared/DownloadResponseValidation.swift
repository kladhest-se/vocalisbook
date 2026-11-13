import Foundation

public enum DownloadResponseValidation {
    public enum Failure: Error, LocalizedError, Equatable {
        case nonHTTP
        case httpStatus(Int)
        case unexpectedContentType(String)

        public var errorDescription: String? {
            switch self {
            case .nonHTTP: "The download did not return an HTTP response."
            case .httpStatus(let code): "The server refused the download (HTTP \(code))."
            case .unexpectedContentType(let type): "The server returned \(type) instead of audio."
            }
        }
    }

    public static func validate(_ response: URLResponse?) throws {
        guard let response = response as? HTTPURLResponse else { throw Failure.nonHTTP }
        guard response.statusCode == 200 else { throw Failure.httpStatus(response.statusCode) }
        // Plex may use application/octet-stream. Reject known error/login
        // formats without rejecting legitimate audio containers.
        if let type = response.mimeType?.lowercased(),
           type.hasPrefix("text/") || type == "application/json" || type == "application/xml" {
            throw Failure.unexpectedContentType(type)
        }
    }
}
