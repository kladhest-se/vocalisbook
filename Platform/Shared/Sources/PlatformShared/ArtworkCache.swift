import Foundation

/// Covers, kept on disk.
///
/// Offline mode narrows the library to books that will play, and then drew every
/// one of them as a grey placeholder — because artwork is fetched from the
/// server on demand and `URLCache` is memory-first and purged whenever the
/// system feels like it. A library of unlabelled grey squares is not an offline
/// library.
///
/// Foundation only, so it lives here rather than three times over in the
/// platform packages. It deliberately stops at `Data`: turning bytes into an
/// image needs `UIImage` or `NSImage`, and this package may not import either.
/// Each app does that step itself, in one line.
public actor ArtworkCache {

    public static let shared = ArtworkCache()

    /// Fetches the bytes for a URL, or nil.
    ///
    /// Injectable so the cache can be tested without a network — the disk
    /// behaviour is the part with decisions in it, and none of those decisions
    /// need a server to exercise.
    public typealias Fetch = @Sendable (URL) async -> Data?

    private var inFlight: [String: Task<Data?, Never>] = [:]
    private let fetch: Fetch
    private let directory: URL?

    /// - Parameter directory: where files live. `nil` means Application Support,
    ///   which is what the app wants and what a test must never touch.
    public init(directory: URL? = nil, fetch: Fetch? = nil) {
        self.directory = directory
        self.fetch = fetch ?? { url in
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  !data.isEmpty
            else { return nil }
            return data
        }
    }

    /// The directory in use: the injected one, or the shared location.
    nonisolated func resolvedDirectory() throws -> URL {
        if let directory {
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true
                )
            }
            return directory
        }
        return try Self.directory()
    }

    /// A filename for a cover, with no credential in it.
    ///
    /// **The URL cannot be the key.** A Plex artwork URL carries
    /// `X-Plex-Token` in its query string, so hashing or sanitising the whole
    /// thing writes the account token into a filename — on disk, in a directory
    /// that outlives the session, readable by anything that can read the
    /// container. It would also break the cache the moment the token rotated,
    /// since every key would change at once.
    ///
    /// The thumb path and the requested size are the whole identity of a cover.
    /// Nothing else about the URL matters.
    public nonisolated static func key(thumb: String, width: Int, height: Int) -> String {
        let safe = thumb.unicodeScalars.map { scalar -> String in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", ".", "-", "_":
                String(scalar)
            default:
                "_"
            }
        }.joined()

        // Long thumb paths would exceed the filename limit, so anything past a
        // sensible length is replaced by a hash of the whole thing — which keeps
        // the key unique without keeping it readable.
        let trimmed = safe.count <= 96 ? safe : String(safe.suffix(64)) + "-" + String(fnv1a(safe), radix: 36)
        return "\(trimmed)-\(width)x\(height)"
    }

    /// A small deterministic hash, written out rather than imported.
    ///
    /// CryptoKit would do, but this needs to survive relaunches and be identical
    /// on every platform, and `hashValue` is neither — Swift seeds it per
    /// process, so a cache keyed on it would miss on every launch and grow
    /// forever.
    private nonisolated static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    public nonisolated static func directory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let directory = support.appendingPathComponent("VocalisBook/Artwork", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var mutable = directory
            var values = URLResourceValues()
            // Covers are re-fetchable. Backing them up would put a few hundred
            // megabytes of thumbnails into iCloud for no reason.
            values.isExcludedFromBackup = true
            try mutable.setResourceValues(values)
        }
        return directory
    }

    /// Cached bytes if they are there, fetched bytes if they are not, nil if
    /// neither works.
    ///
    /// A failed fetch is not cached. Offline, every request fails, and writing
    /// those failures down would mean a book whose cover never returns even
    /// after the network does.
    /// A cover, from disk if it is there.
    ///
    /// `nonisolated`, and that is the point. This was actor-isolated, and the
    /// disk read happened inside it — so a grid of forty covers queued forty
    /// synchronous `Data(contentsOf:)` calls through one actor, one at a time,
    /// while the user scrolled. Scrolling back up was the worst case, because
    /// every cell is a cache hit and every hit waited its turn.
    ///
    /// A hit now touches the actor not at all. Only a miss does, and only for
    /// the bookkeeping that has to be shared.
    public nonisolated func data(
        forThumb thumb: String,
        width: Int,
        height: Int,
        url: URL?
    ) async -> Data? {
        let key = Self.key(thumb: thumb, width: width, height: height)

        if let cached = try? cachedData(key: key) { return cached }
        guard let url else { return nil }

        return await fetchAndStore(key: key, from: url)
    }

    /// The part that must be serialised: one request per cover, however many
    /// views ask at once. A grid scrolling back and forth otherwise starts a
    /// fetch per appearance.
    /// Named `fetchAndStore` rather than `fetch`, because the closure below
    /// captures the stored property of that name — `[fetch]` next to a method
    /// called `fetch` is a question nobody should have to answer.
    private func fetchAndStore(key: String, from url: URL) async -> Data? {
        if let existing = inFlight[key] { return await existing.value }

        let task = Task<Data?, Never> { [fetch] in await fetch(url) }
        inFlight[key] = task

        let data = await task.value
        inFlight[key] = nil

        if let data { try? write(data, key: key) }
        return data
    }

    private nonisolated func cachedData(key: String) throws -> Data {
        try Data(contentsOf: try resolvedDirectory().appendingPathComponent(key))
    }

    private nonisolated func write(_ data: Data, key: String) throws {
        try data.write(
            to: try resolvedDirectory().appendingPathComponent(key),
            options: .atomic
        )
    }

    /// Drops the least recently used covers until the directory fits.
    ///
    /// Called at launch rather than on every write: the cost of being over the
    /// limit for one session is a few megabytes, and the cost of a sweep per
    /// cover is a directory enumeration per cover.
    public func prune(maxBytes: Int = 200 * 1024 * 1024) {
        guard let directory = try? resolvedDirectory(),
              let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentAccessDateKey, .fileSizeKey]
              )
        else { return }

        let sized = entries.compactMap { url -> (url: URL, bytes: Int, used: Date)? in
            guard let values = try? url.resourceValues(forKeys: [.contentAccessDateKey, .fileSizeKey]),
                  let bytes = values.fileSize
            else { return nil }
            return (url, bytes, values.contentAccessDate ?? .distantPast)
        }

        var total = sized.reduce(0) { $0 + $1.bytes }
        guard total > maxBytes else { return }

        for entry in sized.sorted(by: { $0.used < $1.used }) {
            guard total > maxBytes else { break }
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.bytes
        }
    }
}
