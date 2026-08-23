import SwiftUI
import Audiobooks
import Platform
import PlatformShared

struct BookDetailView: View {
    let ratingKey: String
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var model = BookDetailModel()
    @State private var nextBook: String?
    @State private var contributorRoute: ContributorRoute?

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 48) {
                CoverImage(thumb: model.book?.thumb)
                    .frame(width: 340, height: 340)
                    .clipShape(.rect(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 16) {
                    Text(model.book?.title ?? "").font(.system(size: 48, weight: .semibold))
                    if let author = model.book?.author {
                        Text(author).font(.title2).foregroundStyle(theme.secondaryText)
                    }
                    // Co-authors: the primary author above is Plex's own
                    // artist link, one name only. The rest of a multi-author
                    // credit is in `Mood`, already parsed into
                    // `credits.authors` — narrators and series read from the
                    // same place and were already shown here; this was the
                    // one field of the three that never made it onto any
                    // screen despite being fully available.
                    if !model.credits.authors.isEmpty {
                        Text("With \(model.credits.authors.joined(separator: ", "))")
                            .font(.callout)
                            .foregroundStyle(theme.secondaryText)
                    }
                    // Narrator and series: Plex has no field for either, so
                    // VocalisMeta puts them in Style and Mood.
                    if !model.credits.narrators.isEmpty {
                        Text("Read by \(model.credits.narrators.joined(separator: ", "))")
                            .font(.callout)
                            .foregroundStyle(theme.secondaryText)
                    }
                    if !model.credits.series.isEmpty {
                        Text(model.seriesLine)
                            .font(.callout)
                            .foregroundStyle(theme.tertiaryText)
                    }
                    // Only when known: absence means unknown.
                    if let edition = model.credits.editionLine {
                        Text(edition)
                            .font(.callout)
                            .foregroundStyle(theme.tertiaryText)
                    }
                    // Production and rating, from the same v2/v3 Mood
                    // namespaces as edition and language — absent just as
                    // often, and shown the same way when it is not.
                    if let production = model.credits.productionLine {
                        Text(production)
                            .font(.callout)
                            .foregroundStyle(theme.tertiaryText)
                    }
                    HStack(spacing: 20) {
                        if let duration = model.durationText {
                            Text(duration).foregroundStyle(theme.secondaryText)
                        }
                        if let progress = model.progressText(app: app) {
                            Text(progress).foregroundStyle(theme.tertiaryText)
                        }
                    }

                    Button {
                        if model.isCurrent(app: app) {
                            app.player.togglePlayPause()
                        } else {
                            Task {
                                await model.play(app: app, ratingKey: ratingKey)
                                app.selectedTab = .nowPlaying
                            }
                        }
                    } label: {
                        Label(
                            model.actionLabel(app: app),
                            systemImage: model.actionSymbol(app: app)
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isLoading)

                    // Finishing and starting again, which playback alone cannot
                    // do: a book abandoned halfway stays in Continue listening
                    // forever, and a finished one cannot be started again
                    // without scrubbing to zero.
                    //
                    // One button, and it says what the book is as well as
                    // changing it.
                    //
                    // This was two: "Mark as finished" and "Start from the
                    // beginning", which on a television is two focus targets
                    // for what is one decision — and neither of them showed
                    // whether the book was already finished.
                    //
                    // Finishing tells Plex the book is played; pressing again
                    // puts it back to the beginning and tells Plex that too.
                    // Either way it leaves Continue listening, which is a list
                    // of books in progress.
                    Button {
                        model.toggleFinished(app: app, ratingKey: ratingKey)
                    } label: {
                        Label(
                            model.isFinished ? "Finished" : "Mark as finished",
                            systemImage: model.isFinished
                                ? "checkmark.circle.fill" : "checkmark.circle"
                        )
                    }
                    .disabled(model.isLoading)

                    // Bookmarks, which this platform could make and never show.
                    //
                    // A plain list rather than the phone's swipe-to-delete: a
                    // television has no swipe, so removing is a button on the
                    // row and the row itself is the jump.
                    if !model.bookmarks.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Bookmarks")
                                .font(.headline)
                                .foregroundStyle(theme.secondaryText)

                            // `id: \.id`, as the phone's list does.
                            //
                            // `BookmarkRecord` has an `id` and does not declare
                            // `Identifiable` — it is a GRDB record, and that
                            // protocol belongs to the view layer rather than to
                            // a row.
                            ForEach(model.bookmarks, id: \.id) { bookmark in
                                HStack(spacing: 16) {
                                    Button {
                                        Task {
                                            await model.play(
                                                app: app,
                                                ratingKey: ratingKey,
                                                from: bookmark.absoluteMs
                                            )
                                            app.selectedTab = .nowPlaying
                                        }
                                    } label: {
                                        HStack {
                                            Text(bookmark.label ?? "Bookmark")
                                                .lineLimit(1)
                                            Spacer()
                                            Text(Format.duration(ms: bookmark.absoluteMs))
                                                .monospacedDigit()
                                                .foregroundStyle(theme.secondaryText)
                                        }
                                    }

                                    Button("Remove") {
                                        app.removeBookmark(id: bookmark.id)
                                        model.reloadBookmarks(app: app, ratingKey: ratingKey)
                                    }
                                }
                            }
                        }
                        .padding(.top, 12)
                    }

                    if let next = model.next {
                    // Shown whether or not the book is finished — "what comes
                    // after this one" is asked halfway through a series too, and
                    // a row that only appears at the end is one nobody has seen
                    // before the moment they need it.
                    // A button and a destination of this view's own, rather
                    // than a `NavigationLink(value:)`.
                    //
                    // A value link needs the enclosing stack to register a
                    // destination for that type, and this screen is reached from
                    // five of them: Genres and Series register `String`, Authors
                    // and Collections register `BookRoute`, and Home uses an
                    // item binding. So the link matched nothing from three of
                    // the five and the row simply did not respond — which is
                    // exactly what a tap on a dead `NavigationLink` looks like.
                    //
                    // Bound to this view instead, so it works the same way from
                    // wherever the book was opened.
                    Button {
                        nextBook = next.book.ratingKey
                    } label: {
                        HStack(spacing: 16) {
                            CoverImage(thumb: next.book.thumb)
                                .frame(width: 80, height: 80)
                                .clipShape(.rect(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(next.caption)
                                    .font(.caption)
                                    .foregroundStyle(theme.secondaryText)
                                Text(next.book.title).font(.headline).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.card)
                }

                if !model.otherEditions.isEmpty {
                    Text("Other Editions").font(.headline)
                    ForEach(model.otherEditions, id: \.ratingKey) { edition in
                        // Same reasoning as "Next in series" above: bound to
                        // this view's own `nextBook` rather than a
                        // `NavigationLink(value:)`, since this screen is
                        // reached from stacks that register different value
                        // types.
                        Button {
                            nextBook = edition.ratingKey
                        } label: {
                            HStack(spacing: 16) {
                                CoverImage(thumb: edition.thumb)
                                    .frame(width: 80, height: 80)
                                    .clipShape(.rect(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(edition.title).font(.headline).lineLimit(1)
                                    if let editionLabel = edition.edition {
                                        Text(editionLabel)
                                            .font(.caption)
                                            .foregroundStyle(theme.secondaryText)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.card)
                    }
                }

                if !model.credits.contributors.isEmpty {
                    Text("Contributors").font(.headline)
                    // A row per contributor, matching "Other Editions" above,
                    // rather than inline text: only some of the authors and
                    // narrators already shown higher up have a stable key at
                    // all, and mixing tappable and plain names inside one
                    // flowing sentence would leave no honest way to show
                    // which is which.
                    ForEach(model.credits.contributors, id: \.contributorKey) { contributor in
                        Button {
                            contributorRoute = ContributorRoute(
                                key: contributor.contributorKey, displayName: contributor.displayName
                            )
                        } label: {
                            HStack(spacing: 16) {
                                Image(systemName: contributor.role == "narrator" ? "waveform" : "person")
                                    .frame(width: 32)
                                    .foregroundStyle(theme.secondaryText)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(contributor.displayName).font(.headline).lineLimit(1)
                                    Text(contributor.role.capitalized)
                                        .font(.caption)
                                        .foregroundStyle(theme.secondaryText)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.card)
                    }
                }

                if !model.chapters.isEmpty {
                        NavigationLink {
                            ChapterListView(ratingKey: ratingKey, model: model)
                        } label: {
                            Label("Chapters (\(model.chapters.count))", systemImage: "list.bullet")
                        }
                    }

                    NavigationLink {
                        MetadataDiagnosticsView(
                            ratingKey: ratingKey,
                            chapterSource: model.chapters.first?.source
                        )
                    } label: {
                        Label("Metadata Diagnostics", systemImage: "wrench.and.screwdriver")
                    }

                    if let summary = model.book?.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.callout)
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(8)
                            .padding(.top, 8)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 40)
        }
        .task {
            await model.load(app: app, ratingKey: ratingKey)
            model.reloadBookmarks(app: app, ratingKey: ratingKey)
        }
        .onChange(of: app.libraryRevision) { _, _ in
            Task { await model.load(app: app, ratingKey: ratingKey) }
        }
        // Added from the player, which is a different screen. Without this the
        // list would be whatever it was when this one opened.
        // Pushed by this view, so it does not depend on which stack opened it.
        .navigationDestination(item: $nextBook) { BookDetailView(ratingKey: $0) }
        .navigationDestination(item: $contributorRoute) {
            ContributorBooksView(contributorKey: $0.key, displayName: $0.displayName)
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
        .onChange(of: app.bookmarkRevision) { _, _ in
            model.reloadBookmarks(app: app, ratingKey: ratingKey)
        }
        .overlay { if model.isLoading && model.book == nil { ProgressView() } }
        // Found in the same audit pass that fixed this exact gap across the
        // rest of this session: no theme awareness anywhere in this file
        // previously, colors included — the co-author line added earlier
        // this session matched the surrounding `.secondary` pattern rather
        // than catching the gap, since nothing nearby used `theme` yet to
        // signal it was missing.
        .background(theme.background.ignoresSafeArea())
    }
}

struct ChapterListView: View {
    let ratingKey: String
    let model: BookDetailModel
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(model.chapters) { chapter in
                    Button {
                        Task {
                            await model.play(app: app, ratingKey: ratingKey, from: chapter.startMs)
                            dismiss()
                            app.selectedTab = .nowPlaying
                        }
                    } label: {
                        let standing = model.standing(
                            of: chapter, app: app, ratingKey: ratingKey
                        )
                        HStack {
                            // A column of fixed width, so titles do not shift
                            // as chapters are finished.
                            Group {
                                switch standing {
                                case .done:
                                    Image(systemName: "checkmark")
                                case .playing:
                                    Image(systemName: "speaker.wave.2.fill")
                                case .ahead:
                                    Color.clear
                                }
                            }
                            .frame(width: 32)

                            Text(chapter.title).lineLimit(1)
                            Spacer()
                            Text(Format.duration(ms: chapter.startMs))
                                .monospacedDigit()
                                .foregroundStyle(theme.secondaryText)
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .padding(.vertical, 40)
        }
        .background(theme.background.ignoresSafeArea())
    }
}

/// A contributor's key and display name together, for
/// `.navigationDestination(item:)` — matching `BookRoute` in `AuthorsView.swift`,
/// which exists for the identical reason: a bare `String` is already another
/// route in play elsewhere in this stack.
struct ContributorRoute: Hashable {
    let key: String
    let displayName: String
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

    private(set) var bookmarks: [BookmarkRecord] = []

    /// Re-reads the bookmarks for this book.
    ///
    /// Called on load and after one is removed here. The player adds them from
    /// another screen, so `bookmarkRevision` is what brings those in.
    func reloadBookmarks(app: AppModel, ratingKey: String) {
        bookmarks = (try? app.bookmarks.bookmarks(bookRatingKey: ratingKey)) ?? []
    }

    /// Whether this book is filed as done.
    var isFinished: Bool { progress?.finishedAt != nil }

    /// Re-reads just the progress row, after a write this screen made itself.
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

    /// Other recordings of the same work — an abridgment beside its
    /// unabridged twin, a re-recording, a different narrator's take.
    /// Grouping only; nothing here touches this book's own progress.
    private(set) var otherEditions: [BookRecord] = []

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
    /// playing — so the screen gave no sign anything was happening, and pressing
    /// it reloaded the stream and threw away the position.
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
        otherEditions = credits.workIdentity.flatMap {
            try? app.library.otherEditions(ofWork: $0, excluding: ratingKey)
        } ?? []

        // Tracks are only fetched when a book is opened. Prefetching them for
        // a few thousand books would be thousands of requests for data almost
        // none of which gets used.
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

        // Built here, on the main actor, because the server client lives
        // here. Handing `upgradeChapters` a closure instead would mean
        // capturing it in a `@Sendable` one.
        // No download coordinator on tvOS: there is no durable local
        // storage, so there is never a local copy to prefer.
        let urls = cached.segments.map { server.streamURL(partKey: $0.partKey) }

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

        // Reconcile before loading, so someone who listened on another device
        // resumes in the right place rather than being yanked backwards a
        // chapter later when sync catches up.
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

        let timeline = BookTimeline(
            bookRatingKey: ratingKey,
            segments: cached.segments,
            chapters: cached.chapters
        )
        app.setNowPlaying(
            title: book?.title ?? "",
            author: book?.author,
            thumb: book?.thumb
        )
        app.player.load(
            timeline: timeline,
            startingAt: start,
            rate: app.rate(for: ratingKey)
        ) { segment in
            // Always the stream. There is no local copy to prefer on this
            // platform, and no way to make one.
            server.streamURL(partKey: segment.partKey)
        }
        app.player.play()
        app.refreshNowPlayingInfo()
    }
}
