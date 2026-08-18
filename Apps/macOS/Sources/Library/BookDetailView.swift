import SwiftUI
import Audiobooks
import Platform
import PlatformShared

struct BookDetailView: View {
    let ratingKey: String
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var model = BookDetailModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 20) {
                    CoverImage(thumb: model.book?.thumb)
                        .frame(width: 180, height: 180)
                        .clipShape(.rect(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.book?.title ?? "").font(.title2.weight(.semibold))
                        if let author = model.book?.author {
                            Text(author).font(.title3).foregroundStyle(.secondary)
                        }
                        // Co-authors: the primary author above is Plex's own
                        // artist link, one name only. A book credited to two
                        // or three writers has the rest in `Mood`, parsed
                        // already into `credits.authors` and modeled all the
                        // way through — narrators and series read from the
                        // same place and were already shown here; this was
                        // the one field of the three that never made it into
                        // any screen despite being fully available.
                        if !model.credits.authors.isEmpty {
                            Text("With \(model.credits.authors.joined(separator: ", "))")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        // Narrator and series: Plex has no field for either, so
                        // VocalisMeta puts them in Style and Mood.
                        if !model.credits.narrators.isEmpty {
                            Text("Read by \(model.credits.narrators.joined(separator: ", "))")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        if !model.credits.series.isEmpty {
                            Text(model.seriesLine)
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                        }
                        // Only when known: absence means unknown.
                        if let edition = model.credits.editionLine {
                            Text(edition)
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                        }
                        if let duration = model.durationText {
                            Text(duration).font(.callout).foregroundStyle(.secondary)
                        }
                        if let progress = model.progressText(app: app) {
                            Text(progress).font(.callout).foregroundStyle(.tertiary)
                        }

                        Button {
                            // Already the book on the player: this is a
                            // transport control, not a start button. Reloading
                            // would restart the stream and lose the position.
                            if model.isCurrent(app: app) {
                                app.togglePlayPauseRespectingOffline()
                            } else {
                                Task { await model.play(app: app, ratingKey: ratingKey) }
                            }
                        } label: {
                            Label(
                                model.actionLabel(app: app),
                                systemImage: model.actionSymbol(app: app)
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(model.isLoading)
                        .padding(.top, 4)

                        // Finishing and starting again, which playback alone
                        // cannot do: a book abandoned halfway stays in Continue
                        // listening forever, and a finished one cannot be
                        // started again without scrubbing to zero.
                        // One control, and it shows the state as well as
                        // changing it.
                        //
                        // This was a `More` menu of three items doing two
                        // things — "Mark as finished", "Mark as unfinished" and
                        // "Start from the beginning" — and whether a book was
                        // finished could only be discovered by opening it.
                        //
                        // A filled tick means finished. Pressing it finishes or
                        // unfinishes, tells Plex either way, and the book leaves
                        // Continue listening: that list is books in progress, and
                        // this book is not in progress in either direction.
                        Button {
                            model.toggleFinished(app: app, ratingKey: ratingKey)
                        } label: {
                            Label(
                                model.isFinished ? "Finished" : "Mark as finished",
                                systemImage: model.isFinished
                                    ? "checkmark.circle.fill" : "checkmark.circle"
                            )
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(model.isFinished ? theme.accent : theme.secondaryText)
                        .help(model.isFinished
                              ? "Finished. Press to put it back to the beginning."
                              : "Mark as finished and tell your server.")
                        .padding(.top, 2)

                        if PlatformCapabilities.supportsOfflineDownloads {
                            DownloadButton(ratingKey: ratingKey, timeline: model.timeline)
                                .padding(.top, 2)
                        }
                    }
                    Spacer()
                }

                if let summary = model.book?.summary, !summary.isEmpty {
                    Text(summary).font(.body).textSelection(.enabled)
                }

if PlatformCapabilities.localStoreIsDurable {
                    BookmarksList(ratingKey: ratingKey) { position in
                        Task { await model.play(app: app, ratingKey: ratingKey, from: position) }
                    }
                }

                if let next = model.next {
                    // A button rather than a link: the detail pane is driven by
                    // `LibraryView`'s selection and nothing inside it can push.
                    Button {
                        app.open(bookRatingKey: next.book.ratingKey)
                    } label: {
                        HStack(spacing: 12) {
                            CoverImage(thumb: next.book.thumb)
                                .frame(width: 44, height: 44)
                                .clipShape(.rect(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Next in \(next.seriesTitle)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(next.book.title).font(.callout).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }

                if !model.chapters.isEmpty {
                    HStack {
                        Text("Chapters").font(.headline)
                        Spacer()
                        // A list built from track boundaries looks like chapters
                        // and is not; knowing which you have explains a lot.
                        Text(model.chapterSourceLabel)
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    ForEach(model.chapters) { chapter in
                        Button {
                            Task {
                                await model.play(app: app, ratingKey: ratingKey, from: chapter.startMs)
                            }
                        } label: {
                            let standing = model.standing(
                                of: chapter, app: app, ratingKey: ratingKey
                            )
                            HStack {
                                // A fixed-width column, so the titles line up
                                // whether or not a chapter has a mark. A tick
                                // that shifts every title beside it is a list
                                // that moves as you listen.
                                Group {
                                    switch standing {
                                    case .done:
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(theme.secondaryText)
                                    case .playing:
                                        Image(systemName: "speaker.wave.2.fill")
                                            .foregroundStyle(theme.accent)
                                    case .ahead:
                                        Color.clear
                                    }
                                }
                                .frame(width: 18)

                                Text(chapter.title)
                                    .lineLimit(1)
                                    .foregroundStyle(
                                        standing == .playing ? theme.accent : theme.text
                                    )
                                Spacer()
                                Text(Format.duration(ms: chapter.startMs))
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
            .padding(24)
        }
        // Asked once, with both answers spelled out.
        //
        // No default and nothing preselected: further along is usually right and
        // not always — somebody who went back to re-listen has the earlier
        // position and means it. Guessing is what this exists to stop.
        .alert(
            "Two different positions",
            isPresented: Binding(
                get: { model.conflict != nil },
                set: { if !$0 { model.conflict = nil } }
            ),
            presenting: model.conflict
        ) { conflict in
            Button("This device · \(conflict.localText)") {
                Task {
                    await model.resolve(
                        conflict, keepingLocal: true, app: app, ratingKey: ratingKey
                    )
                }
            }
            Button("Your server · \(conflict.remoteText)") {
                Task {
                    await model.resolve(
                        conflict, keepingLocal: false, app: app, ratingKey: ratingKey
                    )
                }
            }
            Button("Cancel", role: .cancel) { model.conflict = nil }
        } message: { _ in
            Text("This device and your server both moved since they last agreed. "
                 + "Whichever you choose is kept; the other is discarded.")
        }
        .task(id: ratingKey) { await model.load(app: app, ratingKey: ratingKey) }
        .overlay { if model.isLoading && model.book == nil { ProgressView() } }
        // Found in the same audit that fixed this exact gap on this view's
        // iOS sibling: every color here already reads from `theme`, but
        // nothing set the background, so this screen — reached from the
        // Books sidebar row — fell back to the system default regardless of
        // which theme was active.
        .background(theme.background.ignoresSafeArea())
    }
}

@MainActor
@Observable
final class BookDetailModel {
    private(set) var book: BookRecord?
    private(set) var timeline: CachedTimeline?

    /// Narrators, co-authors and series, from the tags VocalisMeta writes.
    ///
    /// Plex has no field for a narrator, so the agent puts them in `Style` and
    /// authors and series in `Mood`. Read from the cache rather than the
    /// network: they arrive with the book and change only when it is re-matched.
    private(set) var credits = BookCredits()

    /// Where this book sits in its series, among what the library holds.
    ///
    /// Nil unless the agent stated a position and the library has more than one
    /// book of that series — "book 1 of 1" is a gap in the library rather than a
    /// fact about the series.
    private(set) var standing: SeriesStanding?

    /// The series line: the names, and where this book sits when that is known.
    ///
    /// "Discworld · Book 6 of 9 in your library". The last four words are the
    /// contract's instruction rather than a flourish — the metadata agent does
    /// not know how many books a series contains, so the nine counts what is
    /// indexed here. Saying "of 9" alone would be a local count wearing the
    /// clothes of a publisher's total.
    var seriesLine: String {
        let names = credits.series.joined(separator: " · ")
        guard let standing else { return names }
        return names + " · Book \(standing.position) of \(standing.heldInLibrary) in your library"
    }

    /// Two positions that disagree, waiting for somebody to choose.
    var conflict: PositionConflict?
    private(set) var chapters: [Chapter] = []
    private(set) var isLoading = false
    private(set) var progress: ProgressRecord?

    /// Whether this book is filed as done.
    var isFinished: Bool { progress?.finishedAt != nil }

    /// Re-reads just the progress row.
    ///
    /// After marking finished or resetting, the screen has to catch up with a
    /// write it made itself. A full `load` would refetch the book and its tracks
    /// from the server to learn something already on disk.
    /// Turns the finished state on or off, and tells Plex either way.
    ///
    /// One control rather than a menu of two or three. "Mark as finished",
    /// "Mark as unfinished" and "Start from the beginning" were three items
    /// doing two things, behind a `More` button that had to be opened to find
    /// out which applied — and the state they describe was not shown anywhere
    /// until you opened it.
    ///
    /// Finishing scrobbles every track, which is how Plex records a book as
    /// played; unfinishing unscrobbles them and puts the position back to zero.
    /// Both leave Continue listening, because that list is books in progress and
    /// a book is no longer in progress either way.
    ///
    /// Queued rather than sent: the outbox carries it, so this works with no
    /// connection and arrives when there is one.
    /// Which of the three a chapter is, for this book.
    ///
    /// The rule is `ChapterStanding` in the shared module; this supplies the
    /// position. Measured against the live player when this book is the one
    /// loaded, and against the stored position otherwise — a book you are not
    /// playing still has a place in it, and the list should say the same thing
    /// either way.
    func standing(of chapter: Chapter, app: AppModel, ratingKey: String) -> ChapterStanding {
        let position = app.player.bookRatingKey == ratingKey
            ? app.player.absoluteMs
            : (progress?.absoluteMs ?? 0)

        return ChapterStanding.of(
            chapterStartMs: chapter.startMs,
            chapterEndMs: chapter.endMs,
            positionMs: position,
            isFinished: isFinished
        )
    }

    func toggleFinished(app: AppModel, ratingKey: String) {
        let wasFinished = isFinished

        app.save(while: wasFinished ? "mark this book unfinished" : "mark this book finished") {
            if wasFinished {
                try app.sync.resetProgress(bookRatingKey: ratingKey)
            } else {
                try app.sync.markFinished(bookRatingKey: ratingKey)
            }
        }

        reloadProgress(app: app, ratingKey: ratingKey)
        app.libraryChanged()
    }

    func reloadProgress(app: AppModel, ratingKey: String) {
        progress = try? app.sync.progress(bookRatingKey: ratingKey)
    }
    private(set) var next: NextInSeries?

    var durationText: String? {
        guard let ms = book?.durationMs, ms > 0 else { return nil }
        return Format.duration(ms: ms)
    }

    /// Where this book has got to.
    ///
    /// Takes `app` so it can read the live position when this is the book
    /// playing. `progress` is a row loaded once in `load` and never refreshed,
    /// so the screen sat at "0% — 33:51:10 left" while the mini player beneath
    /// it counted upwards — two numbers for the same thing, disagreeing in
    /// plain sight.
    ///
    /// Reading `app.player.absoluteMs` from inside a view body is also what
    /// makes it update: the player is `@Observable`, so the dependency is
    /// established by the read, and nothing has to be told to refresh.
    func progressText(app: AppModel) -> String? {
        guard let total = book?.durationMs, total > 0 else { return nil }

        let current = isCurrent(app: app) ? app.player.absoluteMs : progress?.absoluteMs ?? 0
        guard current > 0 else { return nil }

        let percent = Int(Double(current) / Double(total) * 100)
        return "\(percent)% — \(Format.duration(ms: total - current)) left"
    }

    /// Whether the player is on this book right now.
    func isCurrent(app: AppModel) -> Bool {
        app.player.bookRatingKey == book?.ratingKey
    }

    /// What the button does next.
    ///
    /// It used to always read "Play" or "Resume", even while this very book was
    /// playing — so the main window gave no sign that anything was happening and
    /// pressing it restarted the stream.
    func actionLabel(app: AppModel) -> String {
        PlaybackAction.label(
            isCurrent: isCurrent(app: app),
            state: app.player.state,
            hasProgress: (progress?.absoluteMs ?? 0) > 0
        )
    }

    func actionSymbol(app: AppModel) -> String {
        PlaybackAction.symbol(isCurrent: isCurrent(app: app), state: app.player.state)
    }

    var chapterSourceLabel: String {
        switch chapters.first?.source {
        case .plexMetadata: "from Plex"
        case .embeddedInFile: "from the file"
        case .trackBoundary: "one per file"
        case nil: ""
        }
    }

    func load(app: AppModel, ratingKey: String) async {
        isLoading = true
        defer { isLoading = false }

        book = try? app.library.book(ratingKey: ratingKey)
        progress = try? app.sync.progress(bookRatingKey: ratingKey)
        timeline = try? app.library.timeline(bookRatingKey: ratingKey)
        credits = (try? app.library.credits(bookRatingKey: ratingKey)) ?? BookCredits()
        standing = try? app.library.standing(ofBook: ratingKey)

        // Tracks are fetched only when a book is opened. Prefetching them for a
        // few thousand books would be thousands of requests for data almost none
        // of which gets used.
        if timeline == nil, let sync = app.librarySync {
            do {
                timeline = try await sync.refreshBook(ratingKey: ratingKey)
                book = try? app.library.book(ratingKey: ratingKey)
                app.clearDegraded()
            } catch {
                app.handle(error)
            }
        }
        chapters = timeline?.chapters ?? []
        next = try? app.library.nextInSeries(after: ratingKey)

        // Playable from here, so the button stops waiting.
        //
        // `isLoading` gated the play control until the whole load finished, and
        // the last step reads chapter markers out of the audio files — range
        // requests over the network against a book that may be twenty parts.
        // None of it is needed to start playing.
        isLoading = false
        await upgradeChapters(app: app, ratingKey: ratingKey)
    }

    /// Tier 2, on open.
    ///
    /// Deliberately after `load` has already shown something. Reading chapter
    /// atoms out of a remote file takes a moment, and a detail screen that waits
    /// on it before drawing would be slower for every book in order to improve
    /// the chapter list on some of them.
    ///
    /// Cheap to call every time: `upgradeChapters` stops at the first check when
    /// the cached list is already at tier 1 or tier 2, so only a book still on
    /// track boundaries costs anything.
    private func upgradeChapters(app: AppModel, ratingKey: String) async {
        guard let sync = app.librarySync,
              let server = app.server,
              let cached = timeline,
              chapters.isEmpty || chapters.first?.source == .trackBoundary
        else { return }

        // Built here, on the main actor, because the download coordinator and
        // the server client both live here. Handing `upgradeChapters` a closure
        // instead would mean capturing them in a `@Sendable` one.
        let urls = cached.segments.map { segment in
            app.downloads.localURL(forPartCacheKey: segment.partCacheKey)
                ?? server.streamURL(partKey: segment.partKey)
        }

        do {
            if let upgraded = try await sync.upgradeChapters(
                ratingKey: ratingKey,
                partURLs: urls,
                read: { await EmbeddedChapterReader.chapters(at: $0) }
            ) {
                timeline = upgraded
                chapters = upgraded.chapters
            }
        } catch {
            // A book keeps the chapters it had. Nothing here is worth telling
            // the user about — they did not ask for this and cannot act on it.
        }
    }


    /// Takes one of the two positions and plays from it.
    ///
    /// Whichever is chosen is written locally and pushed, so the next device to
    /// ask gets an answer rather than the same question.
    func resolve(_ conflict: PositionConflict, keepingLocal: Bool, app: AppModel, ratingKey: String) async {
        let chosen = keepingLocal ? conflict.local : conflict.remote

        app.save(while: "use that position") {
            if keepingLocal {
                // Recorded rather than adopted: this is a local decision the
                // server has not heard, and recording it queues the push.
                try app.sync.recordPosition(bookRatingKey: ratingKey, absoluteMs: chosen)
            } else {
                try app.sync.adoptRemote(bookRatingKey: ratingKey, absoluteMs: chosen)
            }
        }

        self.conflict = nil
        await play(app: app, ratingKey: ratingKey, from: chosen)
    }

    func play(app: AppModel, ratingKey: String, from absoluteMs: Int? = nil) async {
        guard let cached = timeline ?? (try? app.library.timeline(bookRatingKey: ratingKey)),
              let server = app.server
        else { return }

        // Offline means offline.
        //
        // Pausing what was already playing was half a fix: the book stayed on
        // screen with a Resume button, and pressing it started the stream again.
        // A mode that stops the network until you touch a control is not a mode.
        //
        // Checked here rather than in the URL closure because refusing there
        // would leave the player loaded with nothing to play — a book that looks
        // ready and does nothing is worse than one that says why.
        if app.isOffline, !app.isFullyDownloaded(cached.segments) {
            app.reportOfflineRefusal()
            return
        }
        // Annotated, because assigning an implicitly-unwrapped property to a
        // `let` infers the optional rather than the unwrapped type — so the
        // capture below became `BackgroundDownloadCoordinator?` and stopped
        // accepting a member call.
        let downloads: BackgroundDownloadCoordinator = app.downloads

        // Reconcile before loading, so someone who listened on another device
        // resumes in the right place rather than being yanked backwards later.
        var start = absoluteMs ?? progress?.absoluteMs ?? 0
        if absoluteMs == nil, let progressSync = app.progressSync {
            switch try? await progressSync.reconcile(bookRatingKey: ratingKey) {
            case .adoptRemote(let remote):
                // Failing here starts the book in the wrong place, which is the
                // one thing this app is for. Silence would look like the other
                // device never synced.
                app.save(while: "take the position from your other device") {
                    try app.sync.adoptRemote(bookRatingKey: ratingKey, absoluteMs: remote)
                }
                start = remote

            case .conflict(let local, let remote):
                // Asked, not guessed. Both sides moved since the last sync, so
                // one is about to be discarded and neither knows which.
                // `Reconciliation` has always said a conflict is never resolved
                // silently — and nothing handled the case, so the local position
                // won by default and an evening on another device vanished.
                //
                // Playback waits: starting the book and asking afterwards means
                // playing from a position the app is admitting may be wrong.
                conflict = PositionConflict(local: local, remote: remote)
                return

            case .pushLocal, .noChange, .none:
                break
            }
        }

        app.setNowPlaying(title: book?.title ?? "", author: book?.author, thumb: book?.thumb)
        let timeline = BookTimeline(
            bookRatingKey: ratingKey,
            segments: cached.segments,
            chapters: cached.chapters
        )
        app.player.load(
            timeline: timeline,
            startingAt: start,
            rate: app.rate(for: ratingKey)
        ) { segment in
            // A downloaded copy when there is one, the stream otherwise. The
            // player has always asked in this order; there was simply never
            // anything to find.
            downloads.localURL(forPartCacheKey: segment.partCacheKey)
                ?? server.streamURL(partKey: segment.partKey)
        }
        app.player.play()
        app.refreshNowPlayingInfo()
    }
}

/// The download control for a book.
///
/// One button with four states, rather than a button and a separate indicator:
/// the thing you press and the thing that reports progress are the same object,
/// so they cannot disagree.
struct DownloadButton: View {
    let ratingKey: String
    let timeline: CachedTimeline?

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var state: BookDownloadState = .notDownloaded
    @State private var failure: String?

    var body: some View {
        Group {
            switch state {
            case .notDownloaded:
                Button {
                    start()
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .disabled(timeline == nil)

            case .downloading(let fraction):
                // Two things were wrong with showing `Int(fraction * 100)`.
                //
                // It truncates, so 99.6% reads as 99% — and on a 500 MB file
                // the last fraction of a percent is real time, which is why the
                // bar appeared to stop there.
                //
                // And the last byte arriving is not the end. The system still
                // has to hand over the temporary file, which is then moved into
                // Application Support and recorded, and no progress callback
                // fires during any of it. So the number genuinely does sit
                // still, at a value that looks like a stall rather than like
                // work. It says so now instead of lying with a stuck 99%.
                HStack(spacing: 8) {
                    ProgressView(value: fraction)
                        .frame(width: 90)
                    if fraction >= 0.995 {
                        Text("Finishing…")
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                    } else {
                        Text("\((fraction * 100).rounded(), specifier: "%.0f")%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(theme.secondaryText)
                    }
                }

            case .complete(let bytes):
                Menu {
                    Button("Remove download", role: .destructive) { evict() }
                } label: {
                    Label(
                        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file),
                        systemImage: "checkmark.circle.fill"
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

            case .failed(let message):
                Button {
                    start()
                } label: {
                    Label("Retry", systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                }
                .help(message)
            }
        }
        .task { refresh() }
        // The coordinator publishes one value rather than a stream of events, so
        // a view watches that instead of subscribing to every transfer.
        .onChange(of: app.downloads.revision) { _, _ in refresh() }
        // And a poll while a transfer is live.
        //
        // The revision is the fast path and it is not enough on its own: the
        // last thing a download does is hand over a temporary file, which is
        // then moved into place and recorded — and if that final bump is missed
        // for any reason, the row sits on "Finishing…" until the screen is left
        // and re-entered, which reads as a stuck download of a book that is
        // actually on disk. That is exactly what it did.
        //
        // Only while something is happening. A finished or absent download polls
        // nothing, so this costs one store read a second during a transfer and
        // nothing at all otherwise.
        .task(id: state.isSettled) {
            guard !state.isSettled else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                refresh()
            }
        }
    }

    private func refresh() {
        // Judged against the keys this book asks for now, and against the files
        // actually on disk. Counting rows filed under the book was enough to
        // show a tick over a book that streams — see `DownloadStore.state`.
        //
        // Without a timeline there are no keys to check, so the older, looser
        // answer is the only one available; that only happens before the book
        // has loaded, when the row is not claiming anything yet.
        let keys = timeline?.segments.map(\.partCacheKey)

        // The grid's badges are read from the same set, and this is where a
        // download stops being in progress and starts being a downloaded book.
        app.refreshDownloadedKeys()

        state = (try? app.downloadStore.state(
            bookRatingKey: ratingKey,
            partCacheKeys: keys,
            fileExists: { app.downloads.hasFile(atRelativePath: $0) }
        )) ?? .notDownloaded

        // Rows for parts the book no longer wants are dropped as they are
        // noticed, which leaves their files unreferenced for the launch sweep to
        // reclaim. Cheap, and it happens exactly where the mismatch is found.
        if let keys, !keys.isEmpty {
            _ = try? app.downloadStore.discardStale(bookRatingKey: ratingKey, keeping: keys)
        }
    }

    private func start() {
        guard let timeline, let server = app.server else { return }
        do {
            try app.downloads.download(
                bookRatingKey: ratingKey,
                segments: timeline.segments
            ) { segment in
                server.streamURL(partKey: segment.partKey)
            }
            refresh()
        } catch {
            failure = error.plexExplanation
        }
    }

    private func evict() {
        app.save(while: "remove that download") {
            try app.downloads.evict(bookRatingKey: ratingKey)
            app.refreshDownloadedKeys()
        }
        refresh()
    }
}
