import Foundation

/// Talks to one resolved Plex Media Server.
public struct PlexServerClient: Sendable {
    public let connection: ResolvedConnection
    private let transport: PlexTransport

    public init(connection: ResolvedConnection, transport: PlexTransport) {
        self.connection = connection
        self.transport = transport
    }

    private func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(
            url: connection.baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    // MARK: - Library

    public func sections() async throws -> [PlexLibrarySection] {
        let response = try await transport.decode(
            MediaContainerResponse<DirectoryContainer<PlexLibrarySection>>.self,
            from: HTTPRequest(url: url("library/sections")),
            token: connection.accessToken
        )
        return response.mediaContainer.directory
    }

    /// One page of books from a section.
    ///
    /// Plex caps page size server-side; requesting more than a few hundred at a
    /// time is slower, not faster, because the container is built in memory
    /// before it is serialised. Callers should page rather than ask for
    /// everything.
    /// One page of books from a section, optionally only what changed.
    ///
    /// `updatedSince` becomes Plex's own `updatedAt>=` filter. Without it every
    /// refresh pages the entire library from zero — fine for fifty books and a
    /// minute of requests for several thousand.
    ///
    /// **It cannot see deletions.** A book removed from the server never appears
    /// in a filtered page, so nothing tells the client it is gone. Callers that
    /// want the library to be *correct* rather than merely current must page it
    /// whole; this is for keeping up between those.
    public func books(
        sectionKey: String,
        offset: Int = 0,
        limit: Int = 200,
        sort: String = "titleSort:asc",
        updatedSince: Date? = nil
    ) async throws -> MetadataContainer<PlexBook> {
        var query = [
            URLQueryItem(name: "type", value: "9"),
            URLQueryItem(name: "sort", value: sort),
            // Asked for on the list as well as the detail: a library refresh
            // caches every book, and an identity that only arrives when somebody
            // opens a book is one most books never get.
            URLQueryItem(name: "includeGuids", value: "1"),
        ]
        if let updatedSince {
            // Plex spells its comparisons in the parameter name. Seconds since
            // the epoch, floored: a fractional value is silently ignored by some
            // server versions, which turns an incremental sync into a full one
            // without saying so.
            query.append(URLQueryItem(
                name: "updatedAt>=",
                value: String(Int(updatedSince.timeIntervalSince1970))
            ))
        }

        let request = HTTPRequest(
            url: url("library/sections/\(sectionKey)/all", query: query),
            headers: [
                "X-Plex-Container-Start": String(offset),
                "X-Plex-Container-Size": String(limit),
            ]
        )
        let response = try await transport.decode(
            MediaContainerResponse<MetadataContainer<PlexBook>>.self,
            from: request,
            token: connection.accessToken
        )
        return response.mediaContainer
    }

    public func book(ratingKey: String) async throws -> PlexBook {
        let response = try await transport.decode(
            MediaContainerResponse<MetadataContainer<PlexBook>>.self,
            // `includeGuids=1`, or the identity is simply absent.
            //
            // The whole cross-server identity contract depends on the GUID
            // arriving, and Plex omits it unless asked. Without this the parser
            // is correct and never sees anything to parse — which fails silently
            // as "every book is per-server", the exact problem it exists to fix.
            from: HTTPRequest(url: url("library/metadata/\(ratingKey)", query: [
                URLQueryItem(name: "includeGuids", value: "1"),
            ])),
            token: connection.accessToken
        )
        guard let book = response.mediaContainer.metadata.first else {
            throw PlexError.decoding("No metadata for ratingKey \(ratingKey)")
        }
        return book
    }

    /// The section's Mood tags, as Plex's own tag directory.
    ///
    /// This exists because the album *list* endpoint does not carry Mood, Style
    /// or Genre — only the per-book detail does. So a library refresh caches
    /// every book and none of its tags, and a Series screen built from those
    /// tags stays empty until somebody opens each book one at a time.
    ///
    /// Plex indexes tags itself and will list them, which is one request for the
    /// whole library rather than one per book.
    public func moods(sectionKey: String) async throws -> [PlexTag] {
        // `type=9`, like every other request against a section here.
        //
        // A music section holds artists, albums and tracks, and a tag list with
        // no type is ambiguous between them: Plex answers about a level this app
        // does not use, and the reply is a directory of moods that belong to
        // nothing it will ever ask about. Albums are the audiobooks.
        let request = HTTPRequest(url: url("library/sections/\(sectionKey)/mood", query: [
            URLQueryItem(name: "type", value: "9"),
        ]))
        let response = try await transport.decode(
            MediaContainerResponse<DirectoryContainer<PlexTag>>.self,
            from: request,
            token: connection.accessToken
        )
        return response.mediaContainer.directory
    }

    /// The books carrying one tag.
    ///
    /// `key` comes from a tag returned by `moods(sectionKey:)`. Plex's own
    /// filter, so the server does the matching and the answer is exactly the
    /// books that tag applies to.
    public func books(sectionKey: String, moodKey: String) async throws -> [PlexBook] {
        let request = HTTPRequest(url: url("library/sections/\(sectionKey)/all", query: [
            URLQueryItem(name: "type", value: "9"),
            URLQueryItem(name: "mood", value: moodKey),
            URLQueryItem(name: "includeGuids", value: "1"),
        ]))
        let response = try await transport.decode(
            MediaContainerResponse<MetadataContainer<PlexBook>>.self,
            from: request,
            token: connection.accessToken
        )
        return response.mediaContainer.metadata
    }

    /// Tracks of a book, sorted by their tag index.
    public func tracks(bookRatingKey: String) async throws -> [PlexTrack] {
        let request = HTTPRequest(
            url: url("library/metadata/\(bookRatingKey)/children", query: [
                URLQueryItem(name: "includeChapters", value: "1"),
            ])
        )
        let response = try await transport.decode(
            MediaContainerResponse<MetadataContainer<PlexTrack>>.self,
            from: request,
            token: connection.accessToken
        )
        return response.mediaContainer.metadata.sorted {
            ($0.index ?? .max, $0.title) < ($1.index ?? .max, $1.title)
        }
    }

    /// Collections in a section, which is where a series usually lives.
    ///
    /// Returned in a `Directory` container rather than `Metadata`, unlike almost
    /// everything else in the library — the same shape as `/library/sections`.
    /// Collections in a section.
    ///
    /// Decoded with `ItemContainer` rather than `DirectoryContainer`: this
    /// endpoint returns its entries under `Metadata`, and asking for `Directory`
    /// got an empty array and no error at all. See the note on that type.
    public func collections(sectionKey: String) async throws -> [PlexCollection] {
        let response = try await transport.decode(
            MediaContainerResponse<ItemContainer<PlexCollection>>.self,
            from: HTTPRequest(url: url("library/sections/\(sectionKey)/collections")),
            token: connection.accessToken
        )
        return response.mediaContainer.items
    }

    /// The books in a collection.
    public func collectionChildren(ratingKey: String) async throws -> [PlexBook] {
        let response = try await transport.decode(
            MediaContainerResponse<MetadataContainer<PlexBook>>.self,
            from: HTTPRequest(url: url("library/collections/\(ratingKey)/children")),
            token: connection.accessToken
        )
        return response.mediaContainer.metadata
    }

    public func search(sectionKey: String, query: String, limit: Int = 50) async throws -> [PlexBook] {
        let request = HTTPRequest(
            url: url("library/sections/\(sectionKey)/all", query: [
                URLQueryItem(name: "type", value: "9"),
                URLQueryItem(name: "title", value: query),
                URLQueryItem(name: "includeGuids", value: "1"),
            ]),
            headers: ["X-Plex-Container-Size": String(limit)]
        )
        let response = try await transport.decode(
            MediaContainerResponse<MetadataContainer<PlexBook>>.self,
            from: request,
            token: connection.accessToken
        )
        return response.mediaContainer.metadata
    }

    // MARK: - URLs handed to the player and the downloader

    /// Direct-play URL for a part.
    ///
    /// The token goes in the query string rather than a header because
    /// `AVPlayer` will not attach custom headers to its range requests, and
    /// neither will an AirPlay receiver fetching the stream itself. This is a
    /// deliberate, documented exception — it only ever points at the user's own
    /// server, and the URL must never be logged or written to an export.
    public func streamURL(part: PlexPart) -> URL {
        streamURL(partKey: part.key)
    }

    /// Builds a stream URL from a stored part key, so a cached timeline can be
    /// played without re-fetching the track from Plex.
    public func streamURL(partKey: String) -> URL {
        url(partKey.trimmingPrefixSlash, query: [
            URLQueryItem(name: "X-Plex-Token", value: connection.accessToken),
        ])
    }

    /// Transcoded artwork. Asking the server to resize is far cheaper than
    /// pulling full-resolution covers for a grid.
    public func artworkURL(thumb: String?, width: Int, height: Int) -> URL? {
        guard let thumb, !thumb.isEmpty else { return nil }
        return url("photo/:/transcode", query: [
            URLQueryItem(name: "width", value: String(width)),
            URLQueryItem(name: "height", value: String(height)),
            URLQueryItem(name: "minSize", value: "1"),
            URLQueryItem(name: "upscale", value: "0"),
            URLQueryItem(name: "url", value: thumb),
            URLQueryItem(name: "X-Plex-Token", value: connection.accessToken),
        ])
    }

    // MARK: - Progress

    /// Reports position for one track.
    ///
    /// Callers hold a book-absolute position; converting it to the track and
    /// offset this endpoint expects is the timeline's job, not this client's.
    public func reportTimeline(
        trackRatingKey: String,
        trackKey: String,
        state: PlaybackState,
        offsetMs: Int,
        durationMs: Int
    ) async throws {
        let request = HTTPRequest(url: url(":/timeline", query: [
            URLQueryItem(name: "ratingKey", value: trackRatingKey),
            URLQueryItem(name: "key", value: trackKey),
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
            URLQueryItem(name: "state", value: state.rawValue),
            URLQueryItem(name: "time", value: String(offsetMs)),
            URLQueryItem(name: "duration", value: String(durationMs)),
        ]))
        _ = try await transport.send(request, token: connection.accessToken)
    }

    public func scrobble(trackRatingKey: String) async throws {
        let request = HTTPRequest(url: url(":/scrobble", query: [
            URLQueryItem(name: "key", value: trackRatingKey),
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
        ]))
        _ = try await transport.send(request, token: connection.accessToken)
    }

    public func unscrobble(trackRatingKey: String) async throws {
        let request = HTTPRequest(url: url(":/unscrobble", query: [
            URLQueryItem(name: "key", value: trackRatingKey),
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
        ]))
        _ = try await transport.send(request, token: connection.accessToken)
    }

    public enum PlaybackState: String, Sendable {
        case playing, paused, stopped, buffering
    }
}

extension String {
    var trimmingPrefixSlash: String {
        hasPrefix("/") ? String(dropFirst()) : self
    }
}
