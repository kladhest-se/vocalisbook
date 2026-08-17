import Foundation
import PlexKit

/// Pulls Plex metadata into the local store.
///
/// Deliberately not an actor: it holds no mutable state, and serialising
/// refreshes is the caller's concern.
public struct LibrarySync: Sendable {
    private let client: PlexServerClient
    private let store: LibraryStore
    private let sectionID: String
    private let sectionKey: String

    /// Where positions go.
    ///
    /// Passed in rather than built from the library store's database, which is
    /// private and should stay so. Every caller already holds both.
    private let progress: SyncStore

    public init(
        client: PlexServerClient,
        store: LibraryStore,
        progress: SyncStore,
        sectionID: String,
        sectionKey: String
    ) {
        self.client = client
        self.store = store
        self.progress = progress
        self.sectionID = sectionID
        self.sectionKey = sectionKey
    }

    /// Fills in the series tags the list endpoint does not carry.
    ///
    /// The album list gives titles, authors, artwork and durations, and no Mood
    /// at all — only the per-book detail carries those. So a refresh caches the
    /// whole library and no series, and the Series screen stays empty until
    /// every book has been opened by hand.
    ///
    /// Plex indexes its own tags, so this asks for the Mood directory once and
    /// then for the books under each `Series:` and `Sequence:` tag. Requests are
    /// bounded by the number of series in the library rather than the number of
    /// books — a shelf of two thousand books in forty series costs forty-one
    /// requests, not two thousand.
    ///
    /// Only the two reserved prefixes it can use. `Language:`, `Edition:` and
    /// every author Mood are skipped rather than fetched and discarded.
    /// `onProgress` is called with how many series tags have been handled and
    /// how many there are.
    ///
    /// This pass is one request per series and there is no way to make it fewer:
    /// Plex will say which books carry a tag, one tag at a time. On a library
    /// with forty series that is forty round trips, which is long enough that
    /// silence reads as nothing happening. The count is the only honest thing to
    /// show, so it is reported rather than left to be guessed at.
    @discardableResult
    public func refreshSeriesTags(
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> Int {
        let moods = try await client.moods(sectionKey: sectionKey)

        // Counted before the work starts, so the total is right from the first
        // report rather than climbing as it goes.
        let relevant = moods.filter {
            $0.title.hasPrefix("Series: ") || $0.title.hasPrefix("Sequence: ")
        }
        onProgress?(0, relevant.count)

        var written = 0
        var handled = 0
        for mood in moods {
            let isSeries = mood.title.hasPrefix("Series: ")
            let isSequence = mood.title.hasPrefix("Sequence: ")
            guard isSeries || isSequence else { continue }

            // A failure on one tag does not stop the rest: forty series and one
            // unreachable is thirty-nine series, not none.
            guard let books = try? await client.books(
                sectionKey: sectionKey,
                moodKey: mood.key
            ) else { continue }

            for book in books {
                // The tag is known from the directory, so it is supplied rather
                // than re-read from a response that will not carry it.
                if isSeries {
                    let name = String(mood.title.dropFirst("Series: ".count))
                    written += (try? store.addSeries(name, toBook: book.ratingKey)) != nil ? 1 : 0
                } else {
                    let body = String(mood.title.dropFirst("Sequence: ".count))
                    if let sequence = BookSequence(mood: body) {
                        written += (try? store.addSequence(sequence, toBook: book.ratingKey)) != nil ? 1 : 0
                    }
                }
            }

            handled += 1
            onProgress?(handled, relevant.count)
        }

        return written
    }

    /// Pages the whole section into the store.
    ///
    /// Pages are written as they arrive rather than accumulated and written at
    /// the end: a library of several thousand books takes long enough that the
    /// user should see rows appearing, and a dropped connection halfway should
    /// leave what it managed rather than nothing.
    ///
    /// `incremental` asks the server for books changed since the last completed
    /// sync, which on a library of a few thousand is the difference between one
    /// request and twenty. It is off by default, because it trades a property
    /// for speed:
    ///
    /// **An incremental sync cannot see deletions.** A book removed on the
    /// server never appears in a filtered page, so nothing says it is gone and
    /// it stays in the library until something pages the whole thing. Pull to
    /// refresh is the whole pass; the automatic one on opening the app is the
    /// cheap one.
    ///
    /// The first sync is always full — there is no stamp to filter on — and the
    /// stamp is written after the last page lands rather than before the first,
    /// so anything changing mid-sync is picked up next time instead of being
    /// marked seen and skipped forever.
    @discardableResult
    public func refreshBooks(
        pageSize: Int = 200,
        incremental: Bool = false,
        onPage: (@Sendable (Int, Int?) -> Void)? = nil,
        onSeries: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> Int {
        var offset = 0
        var total: Int?
        let startedAt = Date()

        let since = incremental ? try store.lastSynced(sectionID: sectionID) : nil

        while true {
            try Task.checkCancellation()
            let page = try await client.books(
                sectionKey: sectionKey,
                offset: offset,
                limit: pageSize,
                updatedSince: since
            )
            total = page.totalSize ?? total
            guard !page.metadata.isEmpty else { break }

            try store.cacheBookList(page.metadata, sectionID: sectionID)

            // Plex's positions are deliberately not read here.
            //
            // Plex tracks progress within a file, and that is what it is for.
            // *Which books are on the go* is the client's own state, kept here
            // and carried between devices by iCloud — so a refresh brings
            // metadata and nothing else.
            //
            // This used to seed every book's position from the list, which is
            // why clearing the cache appeared not to work: the rows were deleted
            // and the next refresh put them straight back. The list was Plex's
            // opinion of what had been listened to, and the app's own record of
            // it was being overwritten by a copy.

            offset += page.metadata.count
            onPage?(offset, total)

            if let total, offset >= total { break }
            if page.metadata.count < pageSize { break }
        }

        // Series tags, on a full sync.
        //
        // These were behind a button nobody pressed, which is the same as not
        // existing: a Series screen that only fills when somebody finds a
        // control they have no reason to look for is an empty screen.
        //
        // Not on an incremental sync. Tags change when the metadata agent
        // re-matches something, which is rare and deliberate, and this costs a
        // request per series.
        if since == nil {
            _ = try? await refreshSeriesTags(onProgress: onSeries)
        }

        try store.markSynced(sectionID: sectionID, at: startedAt)
        return offset
    }


    /// Pulls the section's collections and their membership into the store.
    ///
    /// One request for the list and one per collection for the members, which is
    /// why this is not part of the ordinary refresh — a library with fifty series
    /// is fifty-one requests. Called on demand, and the result is cached so
    /// browsing them afterwards needs no network.
    public func refreshCollections() async throws {
        let collections = try await client.collections(sectionKey: sectionKey)

        var entries: [(collection: PlexCollection, bookRatingKeys: [String])] = []
        for collection in collections {
            try Task.checkCancellation()
            let members = try await client.collectionChildren(ratingKey: collection.ratingKey)
            entries.append((collection, members.map(\.ratingKey)))
        }
        try store.cacheCollections(entries, sectionID: sectionID)
    }

    /// Fetches tracks for one book and caches the resolved timeline.
    ///
    /// Chapter resolution stops at tier 1 or tier 3 here — reading chapters
    /// embedded in the file needs platform APIs, so tier 2 is a second pass:
    /// `upgradeChapters` below, called by the app layer once it can hand over
    /// URLs and a reader.
    @discardableResult
    public func refreshBook(ratingKey: String) async throws -> CachedTimeline? {
        let book = try await client.book(ratingKey: ratingKey)
        let tracks = try await client.tracks(bookRatingKey: ratingKey)

        let timeline = BookTimeline(bookRatingKey: ratingKey, tracks: tracks)
        guard timeline.isComplete else {
            // At least one track had no duration, which means Plex has not
            // finished analysing the file. Caching now would bake wrong offsets
            // into every position after that track.
            throw SyncError.metadataIncomplete(ratingKey: ratingKey)
        }

        let chapters = ChapterResolver.fromPlex(tracks: tracks)
            ?? ChapterResolver.fromTrackBoundaries(segments: timeline.segments)

        try store.cache(book: book, tracks: tracks, chapters: chapters, sectionID: sectionID)
        return try store.timeline(bookRatingKey: ratingKey)
    }

    /// Tier 2: chapters embedded in the file.
    ///
    /// This is the pass that had never been written. `ChapterResolver.fromEmbedded`
    /// existed, was public and was documented as the reason this package needs no
    /// FFmpeg — and nothing in the tree called it. The visible result was that a
    /// single-file m4b resolved straight past tier 2 to track boundaries, so a
    /// thirty-three hour book had exactly one chapter covering all of it. Not a
    /// cosmetic loss: next and previous chapter, the chapter list, the chapter
    /// line in Now Playing, and "end of chapter" on the sleep timer are all built
    /// on this list, so all four were inert for the commonest audiobook format
    /// there is.
    ///
    /// `read` is supplied by the platform, which is what keeps `AVFoundation`
    /// out of this package — the same seam as `HTTPClient`. `partURLs` are
    /// passed in already built rather than derived from a closure, because the
    /// caller holds main-actor-isolated things (the download coordinator, the
    /// server client) that cannot be captured in a `@Sendable` closure this
    /// method would run off the main actor.
    ///
    /// Returns nil, without writing, whenever there is nothing to do: no cached
    /// timeline, a list already at tier 1, too many files to be worth the
    /// requests, or no chapter atoms found. A nil is the ordinary outcome and
    /// not a failure.
    @discardableResult
    public func upgradeChapters(
        ratingKey: String,
        partURLs: [URL],
        maxSegments: Int = 12,
        read: @Sendable (URL) async -> EmbeddedChapterList
    ) async throws -> CachedTimeline? {
        guard let cached = try store.timeline(bookRatingKey: ratingKey) else { return nil }

        // Only ever an upgrade. A Plex-supplied list is never replaced by one
        // read out of the file, which is also why this is safe to call on every
        // open: the second call sees tier 2 cached and stops here.
        guard ChapterResolver.shouldReplace(
            cached: cached.chapters.first?.source,
            with: .embeddedInFile
        ) else { return nil }

        // Each file costs a range request or two to parse. For a single-file
        // m4b — the case this exists for — that is one. For a book split into
        // ninety MP3s it is ninety, to improve on track boundaries that are
        // already the right answer for a book split into ninety MP3s.
        guard !cached.segments.isEmpty,
              cached.segments.count <= maxSegments,
              partURLs.count == cached.segments.count
        else { return nil }

        var perSegment: [(segmentIndex: Int, chapters: EmbeddedChapterList)] = []
        for (index, url) in partURLs.enumerated() {
            try Task.checkCancellation()
            let found = await read(url)
            if !found.isEmpty { perSegment.append((index, found)) }
        }

        guard let upgraded = ChapterResolver.fromEmbedded(
            perSegment: perSegment,
            segments: cached.segments
        ) else { return nil }

        try store.replaceChapters(bookRatingKey: ratingKey, chapters: Self.titled(upgraded))
        return try store.timeline(bookRatingKey: ratingKey)
    }

    /// Numbers the chapters that arrive without a title.
    ///
    /// A chapter atom is not obliged to carry one, and plenty do not — a list of
    /// blank rows is worse than the single wrong row it replaced, because at
    /// least the wrong row said something. Numbered here rather than in
    /// `ChapterResolver` so the resolver stays arithmetic with no opinions about
    /// presentation, and numbered after assembly so the sequence runs across the
    /// whole book rather than restarting in each file.
    static func titled(_ chapters: [Chapter]) -> [Chapter] {
        chapters.map { chapter in
            guard chapter.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return chapter }
            return Chapter(
                index: chapter.index,
                title: "Chapter \(chapter.index + 1)",
                startMs: chapter.startMs,
                endMs: chapter.endMs,
                source: chapter.source
            )
        }
    }
}

/// One file's chapters, as the platform reads them. Offsets are relative to the
/// file, not the book; `ChapterResolver.fromEmbedded` does the shifting.
public typealias EmbeddedChapterList = [(title: String, startMs: Int, endMs: Int)]

/// Drains the outbox and reconciles positions against the server.
public struct ProgressSync: Sendable {
    private let client: PlexServerClient
    private let store: SyncStore
    private let library: LibraryStore

    public init(client: PlexServerClient, store: SyncStore, library: LibraryStore) {
        self.client = client
        self.store = store
        self.library = library
    }

    public struct Result: Sendable, Equatable {
        public var pushed = 0
        public var failed = 0
        public var remaining = 0
    }

    /// Pushes everything pending.
    ///
    /// A failure on one entry does not abort the rest: entries are independent,
    /// and one book whose rating key no longer exists on the server should not
    /// block every other book's progress from syncing.
    @discardableResult
    public func drain(limit: Int = 50) async throws -> Result {
        var result = Result()

        for entry in try store.pendingOutbox(limit: limit) {
            do {
                try await push(entry)
                try store.markSynced(
                    bookRatingKey: entry.bookRatingKey,
                    kind: entry.kind,
                    absoluteMs: entry.absoluteMs
                )
                result.pushed += 1
            } catch let error as PlexError where error.isAuthFailure {
                // The token is bad. Stop rather than burning attempt counts on
                // every remaining entry — they would all fail identically, and
                // the app stays playable in degraded mode meanwhile.
                try store.markFailed(entry: entry, error: "unauthorized")
                result.failed += 1
                break
            } catch {
                try store.markFailed(entry: entry, error: "\(error)")
                result.failed += 1
            }
        }

        result.remaining = try store.outboxDepth()
        return result
    }

    /// Converts a book-absolute position to the track and offset Plex expects.
    private func push(_ entry: OutboxEntry) async throws {
        guard let cached = try library.timeline(bookRatingKey: entry.bookRatingKey) else {
            throw SyncError.timelineMissing(ratingKey: entry.bookRatingKey)
        }
        let timeline = BookTimeline(
            bookRatingKey: entry.bookRatingKey,
            segments: cached.segments,
            chapters: cached.chapters
        )
        guard let position = timeline.locate(absoluteMs: entry.absoluteMs) else {
            throw SyncError.timelineMissing(ratingKey: entry.bookRatingKey)
        }
        let segment = timeline.segments[position.segmentIndex]

        switch entry.kind {
        case .position:
            try await client.reportTimeline(
                trackRatingKey: segment.trackRatingKey,
                trackKey: segment.trackKey,
                state: .paused,
                offsetMs: position.offsetInSegmentMs,
                durationMs: segment.durationMs
            )
        case .finished:
            // Plex marks completion per track, so finishing a book means
            // scrobbling every one of them.
            for segment in timeline.segments {
                try await client.scrobble(trackRatingKey: segment.trackRatingKey)
            }
        case .unfinished:
            for segment in timeline.segments {
                try await client.unscrobble(trackRatingKey: segment.trackRatingKey)
            }
        }
    }

    /// Compares one book against the server on reconnect.
    /// Where Plex thinks this book is, in book-absolute milliseconds.
    ///
    /// Plex has no book-level position: it lives scattered across the tracks,
    /// and this is the only place that knows how to put it back together.
    ///
    /// The first version returned nil for anything with more than one file,
    /// which is nearly every audiobook — so a second device could never adopt
    /// what the first had pushed. iOS reported its position correctly and macOS
    /// started from zero.
    ///
    /// The second version fixed that but kept a shortcut for single-file books,
    /// reading the album's `viewOffset` instead. That is a second code path
    /// doing the same job less well: it skipped the clamping below, and the
    /// album value is derived from the track's anyway. One path now, for any
    /// number of files.
    ///
    /// Reassembly: a track that has been scrobbled is finished, so the position
    /// is at least its end; a track with an offset puts the position inside it.
    /// The furthest of those wins, because listening moves forward and a
    /// half-played track behind a finished one means the finished one was
    /// re-listened, not that progress went backwards.
    public func remotePosition(bookRatingKey: String) async throws -> (absoluteMs: Int?, changedAt: Date?) {
        guard let cached = try library.timeline(bookRatingKey: bookRatingKey) else {
            return (nil, nil)
        }

        let tracks = try await client.tracks(bookRatingKey: bookRatingKey)
        let byRatingKey = Dictionary(
            tracks.map { ($0.ratingKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var furthest: Int?
        var changedAt: Date?

        for segment in cached.segments {
            guard let track = byRatingKey[segment.trackRatingKey] else { continue }

            if let lastViewed = track.lastViewedAt {
                changedAt = max(changedAt ?? lastViewed, lastViewed)
            }

            var candidate: Int?
            if let offset = track.viewOffsetMs, offset > 0 {
                candidate = segment.startMs + min(offset, segment.durationMs)
            } else if (track.viewCount ?? 0) > 0 {
                candidate = segment.endMs
            }

            if let candidate {
                furthest = max(furthest ?? candidate, candidate)
            }
        }
        return (furthest, changedAt)
    }

    /// Brings the active list up to date with Plex, book by book.
    ///
    /// The active list — what "Continue listening" shows — is the client's, and
    /// travels between devices through iCloud. Plex holds the position within
    /// each file. This is where the two meet: for every book on the list, ask
    /// the server where it is and what it thinks of it.
    ///
    /// Three outcomes per book:
    ///
    /// - Plex has it finished, so it leaves the list. Somebody finished it in
    ///   Plexamp or on another client and this is how that arrives.
    /// - Plex is further along than this device, so the position is adopted.
    /// - This device is further along, so the outbox already holds the change and
    ///   the next drain sends it. Nothing to do here.
    ///
    /// Bounded by the list, which is a dozen books rather than a library. One
    /// request each, and only for books somebody is actually part-way through.
    ///
    /// Failures are per book and ignored: a server that cannot answer about one
    /// title should not stop the other eleven being checked.
    @discardableResult
    public func refreshActive(bookRatingKeys: [String]) async -> Int {
        var changed = 0

        for key in bookRatingKeys {
            guard let finished = try? await isFinishedOnServer(bookRatingKey: key) else {
                continue
            }

            if finished {
                if (try? store.markFinished(bookRatingKey: key)) != nil { changed += 1 }
                continue
            }

            guard let outcome = try? await reconcile(bookRatingKey: key) else { continue }
            if case .adoptRemote(let absoluteMs) = outcome {
                if (try? store.adoptRemote(bookRatingKey: key, absoluteMs: absoluteMs)) != nil {
                    changed += 1
                }
            }
        }

        return changed
    }

    /// Whether Plex considers every file in the book played.
    ///
    /// Plex has no "finished" for an album: it is finished when each track has
    /// been played, which is what `viewCount` says. A book still on the list
    /// whose files the server has all marked played is one somebody finished
    /// elsewhere.
    private func isFinishedOnServer(bookRatingKey: String) async throws -> Bool {
        let tracks = try await client.tracks(bookRatingKey: bookRatingKey)
        guard !tracks.isEmpty else { return false }
        return tracks.allSatisfy { ($0.viewCount ?? 0) > 0 }
    }

    /// Compares one book against the server.
    ///
    /// This is the one place Plex's position is still read, and it survives the
    /// move to client-owned listening state deliberately: it asks about *one*
    /// file, at the moment somebody is about to play it, which is exactly what
    /// Plex tracks. What it does not do is tell this device which books are on
    /// the go — that is the app's own state, and a bulk read of the library was
    /// the thing overwriting it.
    ///
    /// So a book listened to in Plexamp opens where Plexamp left it, and the
    /// Continue listening list stays the client's.
    public func reconcile(bookRatingKey: String) async throws -> Reconciliation {
        let remote = try await remotePosition(bookRatingKey: bookRatingKey)
        return try store.reconcile(
            bookRatingKey: bookRatingKey,
            remoteMs: remote.absoluteMs,
            remoteChangedAt: remote.changedAt
        )
    }
}

public enum SyncError: Error, Sendable, Equatable {
    /// A track had no duration, so the server has not finished analysing the
    /// file. Retry later — do not cache a partial timeline.
    case metadataIncomplete(ratingKey: String)
    case timelineMissing(ratingKey: String)
}
