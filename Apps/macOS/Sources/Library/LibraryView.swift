import SwiftUI
import AppKit
import Audiobooks
// For `PlatformCapabilities`, which gates the Downloads row.
import Platform
import PlatformShared

/// The main window: a sidebar, a grid, and the player docked at the bottom.
///
/// This is where macOS earns a separate app rather than a resized phone. The
/// player is always visible instead of living in a sheet, and selecting a book
/// changes the detail pane rather than pushing a navigation stack.
struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var model = LibraryModel()

    /// The full trail, not just where it ends.
    ///
    /// A single `selection` value could only ever say where you are, so the
    /// back button had nowhere to go back *to* except a hardcoded root —
    /// opening a book from inside a specific author's page landed back on the
    /// author list at best and the library at worst, with no memory of having
    /// browsed by author at all. Every step — a sidebar section, a specific
    /// author or series or genre, a book — pushes onto this instead, and going
    /// back pops one, which is what going back means anywhere else.
    ///
    /// Always at least one element; `current` is what is actually on screen.
    @State private var path: [SidebarItem] = [.home]
    @State private var showingProfile = false
    @Environment(\.theme) private var theme

    private var current: SidebarItem { path.last ?? .home }

    var body: some View {
        // Always both columns, and no toggle.
        //
        // The toolbar buttons have been chased around this window three times.
        // Each attempt moved them somewhere the sidebar toggle could not push
        // them, and each failed for the same reason: the toolbar's usable width
        // changes when a column collapses, so anything in it moves.
        //
        // Nothing collapses now. The sidebar is part of this layout, and the
        // layout for a narrow window is the compact player — which `RootView`
        // switches to by width, and which is the honest way to make this window
        // small. A collapsed sidebar was a third state between the two, and the
        // only one that made the toolbar dance.
        VStack(spacing: 0) {
            controlBar
            NavigationSplitView(columnVisibility: .constant(.all)) {
            // One selection, with one meaning.
            //
            // This list had two selection mechanisms at once: "All books" was a
            // `Button` drawing its own highlight from `selection == nil`, and
            // Authors, Collections and History were `NavigationLink`s that never
            // touched `selection` at all.
            //
            // So opening Authors left `selection` nil, "All books" stayed lit
            // while something else was on screen, and clicking it set nil to nil
            // — no change, nothing happened, and the only way out was to pick a
            // book from Continue listening so that `selection` became non-nil
            // and could be cleared again.
            //
            // Every row is a case of one enum still, and the detail pane still
            // switches on it — that part was right. What changed is what draws
            // the rows.
            //
            // It moved on once more since: `selection` held one value, so the
            // back button had nowhere to go but a hardcoded root regardless of
            // how it was reached. `path`, below, is the same idea extended to
            // the whole trail rather than just its end — see the property
            // itself for why.
            //
            // `List(selection:)` drew its own separators between every row and
            // its own selection colour on top of the one this file chose — a
            // hairline nobody asked for under Home, under Browse, under every
            // row, and a selected row that flashed the platform's blue rather
            // than this app's accent. `List` on macOS does not give up that
            // chrome just because a row background is supplied; overriding it
            // fully needs private API this app has no business reaching for.
            //
            // A plain `ScrollView` of buttons draws nothing this file did not
            // ask it to. It is the same trade the iPad's tab bar already made,
            // for the same reason: full control over what a selected row looks
            // like, in exchange for the native list's built-in arrow-key
            // stepping between rows — Tab still reaches every row, and Space or
            // Return still activates one, which is what matters for using this
            // sidebar without a pointer at all.
            ScrollView {
                VStack(spacing: 2) {
                    // The same five as the phone and the television, in the
                    // same order. A sidebar row and a tab are the same idea in
                    // different furniture, and there is no reason to learn the
                    // app twice.
                    sidebarRow("Home", "house", tag: .home)
                    sidebarRow("Browse", "square.grid.2x2", tag: .allBooks)

                    // Directly under "All books": these are four ways into the
                    // same library, and a heading called "Library" said
                    // nothing while pushing three of them below a Continue
                    // listening section that grows.
                    sidebarRow("Authors", "person", tag: .authors)
                    sidebarRow("Series", "books.vertical", tag: .series)
                    sidebarRow("Genres", "theatermasks", tag: .genres)

                    // One wordless divider rather than a second "Library"
                    // heading nobody asked to read: everything above is a way
                    // of looking at the same books, everything below is a
                    // tool. The shape says that without a label having to.
                    Divider()
                        .padding(.vertical, 6)

                    // Only where downloads exist. The capability is true on
                    // this platform and checked anyway, so the row and the
                    // feature cannot come apart if that ever changes.
                    if PlatformCapabilities.supportsOfflineDownloads {
                        sidebarRow("Downloads", "arrow.down.circle", tag: .downloads)
                    }
                    sidebarRow("History", "flame", tag: .history)

                    // No Continue listening section here.
                    //
                    // Home is that list, on every platform, and it shows a
                    // cover, a position and how long is left. The sidebar had
                    // the same books as one-line labels, growing downwards and
                    // pushing the four ways into the library further from the
                    // top of the window — a second copy of one screen's
                    // content, in a worse form, in the way of everything else.
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
            }
            // Flush to the window, top to bottom, square.
            //
            // `.sidebar` insets its rows and rounds the selection into a pill
            // floating away from the edge — which reads as a panel laid over the
            // window rather than part of it. The theme's own surface, run edge
            // to edge, is the shape asked for: a column that starts at the
            // window border and runs the full height.
            .background(theme.surface)
            .ignoresSafeArea(edges: .vertical)
            .navigationSplitViewColumnWidth(min: 210, ideal: 250)
            // The system toggle, removed rather than hidden: leaving it and
            // pinning the columns would be a control that does nothing.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(spacing: 0) {
                DegradedBanner()

                // Only past the root: a trail with one crumb in it is just
                // the section you are already looking at in the sidebar, and
                // showing it again says nothing.
                if path.count > 1 {
                    breadcrumbBar
                }

                switch current {
                case .home:
                    HomeView(
                        open: { key, title in path.append(.book(ratingKey: key, title: title)) },
                        showHistory: { path = [.history] }
                    )
                case .allBooks:
                    grid
                case .authors:
                    AuthorsView(onSelect: { path.append(.authorDetail($0)) })
                case .authorDetail(let name):
                    AuthorBooksView(
                        author: name,
                        open: { key, title in path.append(.book(ratingKey: key, title: title)) }
                    )
                case .series:
                    SeriesView(onSelect: { path.append(.seriesDetail($0)) })
                case .seriesDetail(let name):
                    SeriesBooksView(
                        series: name,
                        open: { key, title in path.append(.book(ratingKey: key, title: title)) }
                    )
                case .genres:
                    GenresView(onSelect: { path.append(.genreDetail($0)) })
                case .genreDetail(let name):
                    GenreBooksView(
                        genre: name,
                        open: { key, title in path.append(.book(ratingKey: key, title: title)) }
                    )
                case .downloads:
                    DownloadsView()
                case .history:
                    HistoryView()
                case .book(let ratingKey, _):
                    BookDetailView(ratingKey: ratingKey)
                }
            }
        }
        // Attached to the split view, not the detail column.
        //
        // Inside the detail it vanished the moment a sidebar link pushed
        // something over it — so Authors, Collections and History all lost the
        // transport while a book was still playing. The one control that must
        // never disappear was in the one place that gets replaced.
        .safeAreaInset(edge: .bottom) {
            if app.player.bookRatingKey != nil { PlayerBar() }
        }
        // No `.searchable` here, and that is the fix rather than a preference.
        //
        // On this platform it puts a field *in the toolbar*, and the toolbar's
        // usable width changes when the sidebar collapses — so the field resizes
        // and everything beside it slides. Three placements were tried for the
        // buttons and a fourth would not have helped: they were moving relative
        // to something that moves.
        //
        // With search gone from the toolbar, the three buttons are the only
        // things in it. They pin to the window's trailing edge, which the
        // sidebar cannot move. The field is in the Browse screen now, above the
        // grid it filters, which is also where somebody looks for it.
            .onChange(of: model.search) { _, _ in
                path = [.allBooks]
                model.reload(app: app)
            }
        }
        // ⌘R, from the View menu, which is how this is reached when the sidebar
        // is hidden and the button is not on screen.
        .onChange(of: app.libraryRefreshRequested) { _, _ in
            Task { await model.refresh(app: app) }
        }
        .onChange(of: app.requestedBook) { _, requested in
            // Cleared as it is honoured, so asking for the same book twice in a
            // row still works — an unchanged value publishes nothing.
            guard let requested else { return }
            // A fresh trail rather than a push: this arrives from outside the
            // library entirely — Settings, the downloads list — so there is no
            // existing browsing context for a book opened this way to be a
            // step *in*. Falling back to the rating key itself if the lookup
            // somehow misses is a degraded crumb, not a broken one — the book
            // still opens either way.
            var title = requested
            if let library = app.library, let found = try? library.book(ratingKey: requested) {
                title = found.title
            }
            path = [.allBooks, .book(ratingKey: requested, title: title)]
            app.requestedBook = nil
        }
        .task {
            model.reload(app: app)
            // A full fetch when there is nothing, a catch-up when there is.
            // Incremental cannot see deletions, which is what the refresh
            // control is for.
            if model.books.isEmpty {
                await model.refresh(app: app)
            } else {
                await model.refresh(app: app, incremental: true)
            }
        }
        // Starting or finishing a book changes what belongs in the sidebar.
        .onChange(of: app.libraryRevision) { _, _ in model.reload(app: app) }
    }

    /// One row, coloured by whether its section is the root of the current
    /// trail.
    ///
    /// A plain button rather than a tagged `Label` — see the comment above the
    /// sidebar's `ScrollView` for why `List(selection:)` was replaced outright
    /// rather than patched. Clicking resets `path` to just this tag, which is
    /// the whole reason leaving a section through the sidebar and coming back
    /// always lands on its root; the tint and the filled icon are this
    /// function's whole job otherwise, matching the accent every other
    /// selected state in the app already uses — the iPad's tab bar, a focused
    /// row on the television, a chosen theme in Settings.
    ///
    /// The `.fill` suffix is assumed to exist for every symbol passed in here
    /// rather than checked — true for the seven in use, and worth confirming
    /// again before reaching for an eighth: a name that does not resolve
    /// renders as nothing rather than an error.
    private func sidebarRow(_ title: String, _ symbol: String, tag: SidebarItem) -> some View {
        // Checked against the root of the trail, not the current step: while
        // browsing a specific author's books, the row that should stay lit is
        // "Authors", not nothing — the trail started there and the sidebar
        // ought to say so.
        let isSelected = path.first == tag
        return Button {
            // A reset, not a push. This is what makes coming back to a
            // section through the sidebar always land on its root rather than
            // wherever it was left — the previous trail is discarded outright
            // rather than carried forward into an unrelated one.
            path = [tag]
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "\(symbol).fill" : symbol)
                    .frame(width: 20)
                    .foregroundStyle(isSelected ? theme.accent : theme.secondaryText)
                Text(title)
                    .foregroundStyle(isSelected ? theme.text : theme.secondaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? theme.accent.opacity(0.15) : .clear)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// The trail, drawn as one back button plus every step so far — clicking
    /// a step jumps straight to it, truncating whatever came after.
    ///
    /// Only ever shown past the root, by its one caller — a trail of one
    /// crumb is just the section already lit in the sidebar.
    private var breadcrumbBar: some View {
        HStack(spacing: 4) {
            BackButton(title: path[path.count - 2].breadcrumbTitle) {
                path.removeLast()
            }
            .padding(.trailing, 6)

            ForEach(Array(path.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Text("›")
                        .foregroundStyle(theme.tertiaryText)
                }
                Button {
                    // Truncates rather than replaces: everything up to and
                    // including this step stays, everything after it goes —
                    // which is what clicking a crumb in the middle of a trail
                    // ought to mean.
                    path = Array(path.prefix(index + 1))
                } label: {
                    Text(item.breadcrumbTitle)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                // The last crumb is where you already are; a click that does
                // nothing is a worse answer than no click at all.
                .disabled(index == path.count - 1)
                .foregroundStyle(index == path.count - 1 ? theme.text : theme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    /// The controls, on their own row under the title bar.
    ///
    /// Not a window toolbar. Items placed there share the title bar with the
    /// traffic lights and, on this system, with a tab bar — which is how they
    /// ended up beside a "VocalisBook" pill and a plus button, and part of why
    /// they kept moving. A row of this app's own is a row this app decides.
    ///
    /// Two groups rather than one, as asked: the actions in one capsule and
    /// search in another, so the eye separates "things that do something" from
    /// "the thing you type in".
    ///
    /// Trailing, because the sidebar is on the left and a control strip
    /// directly above it reads as belonging to it.
    private var controlBar: some View {
        HStack(spacing: 10) {
            Spacer()

            HStack(spacing: 12) {
                Button {
                    Task { await model.refresh(app: app) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.isRefreshing)
                .help("Refresh library")

                OfflineToggle()

                Button {
                    showingProfile = true
                } label: {
                    Image(systemName: "person.crop.circle")
                }
                .help("Account")
                .popover(isPresented: $showingProfile, arrowEdge: .bottom) {
                    ProfileView()
                        .frame(width: 300)
                        .padding(.vertical, 4)
                }

                // Down to the player, and back by widening the window.
                //
                // `RootView` switches on width, so this is the same gesture as
                // dragging the window narrow — with a button, because dragging a
                // window to a particular width to change mode is not something
                // anybody discovers.
                Button {
                    WindowSizer.shrink()
                } label: {
                    Image(systemName: "rectangle.bottomthird.inset.filled")
                }
                .help("Mini player")
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(theme.surface, in: .capsule)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(theme.tertiaryText)
                TextField("Title or author", text: $model.search)
                    .textFieldStyle(.plain)
                    .frame(width: 170)
                if !model.search.isEmpty {
                    Button {
                        model.search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(theme.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(theme.surface, in: .capsule)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.background)
    }

    private var grid: some View {
        // No search field here.
        //
        // It lived in this screen for one round, while the toolbar could not
        // hold it without everything beside it moving. The toolbar is fixed now,
        // so search is back where it belongs — one field, reachable from every
        // screen, rather than one that exists only on Browse.
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 20)],
                spacing: 24
            ) {
                ForEach(model.books, id: \.ratingKey) { book in
                    Button { path.append(.book(ratingKey: book.ratingKey, title: book.title)) } label: { BookTile(book: book) }
                        .buttonStyle(.plain)
                }
            }
            .padding(20)

            if model.books.isEmpty && !model.isRefreshing {
                if model.loadFailed {
                    // Refreshing will not help: the fetch is not what failed.
                    ContentUnavailableView(
                        "Couldn't read your library",
                        systemImage: "exclamationmark.triangle",
                        description: Text(
                            "The books are still on your server. This is the copy on "
                            + "this Mac, and something went wrong reading it."
                        )
                    )
                    .padding(.top, 60)
                } else {
                    ContentUnavailableView(
                        model.search.isEmpty ? "No books yet" : "Nothing matched",
                        systemImage: "books.vertical",
                        description: Text(
                            model.search.isEmpty
                            ? "Refresh to fetch your library from Plex."
                            : "Try a different title or author."
                        )
                    )
                    .padding(.top, 60)
                }
            }
        }
    }
}

@MainActor
@Observable
final class LibraryModel {
    private(set) var books: [BookRecord] = []
    private(set) var isRefreshing = false

    /// Whether the last read failed, as opposed to finding nothing.
    private(set) var loadFailed = false

    /// Whether this refresh has already put something on screen.
    ///
    /// On the model rather than in the closure: `onPage` is `@Sendable`, and
    /// mutating a captured local from inside it is exactly what Swift 6
    /// forbids. The model is already main-actor isolated, which is also where
    /// the reload has to happen.
    private var hasShownAPage = false
    var search = ""

    /// Reads from the local store only. Browsing never waits on the network.
    func reload(app: AppModel) {
        // Emptied rather than left, when there is nothing to read.
        //
        // A bare `return` here keeps whatever was last loaded on screen. After
        // clearing the cache the database is empty and `sectionID` is nil, so
        // this guard fired and the old rows stayed visible — the list was a
        // memory of a database that no longer held any of it.
        guard let library = app.library, let sectionID = app.sectionID else {
            books = []
            loadFailed = false
            return
        }
        // A failed read is not an empty library. `try?` makes them the same
        // array and the screen then gives advice that cannot help.
        do {
            books = try search.isEmpty
                ? library.books(sectionID: sectionID, downloadedOnly: app.isOffline)
                : library.search(search, downloadedOnly: app.isOffline)
            loadFailed = false
        } catch {
            books = []
            loadFailed = true
        }
    }

    func refresh(app: AppModel, incremental: Bool = false) async {
        guard let sync = app.librarySync, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false; app.setActivity(nil) }
        do {
            // Reloaded on the first page and then not again until the end.
            //
            // Every page replaced the whole list: a re-query and a fresh array
            // for each 200 books, so a library of a few thousand rebuilt its
            // grid a dozen times during one refresh. Each rebuild relays out the
            // grid, and doing that under a moving finger is what a stutter is.
            //
            // The first page still lands immediately, because an empty library
            // that stays empty for twenty seconds looks broken. After that the
            // count in the progress line is the thing that moves, which costs
            // nothing.
            hasShownAPage = false
            try await sync.refreshBooks(
                incremental: incremental,
                onPage: { _, _ in
                    Task { @MainActor in
                        guard !self.hasShownAPage else { return }
                        self.hasShownAPage = true
                        self.reload(app: app)
                    }
                },
                onSeries: { done, total in
                    Task { @MainActor in
                        app.setActivity(
                            done >= total ? nil : "Fetching series… \(done) of \(total)"
                        )
                    }
                }
            )
            app.clearDegraded()
            _ = try? await app.progressSync?.drain()
        } catch {
            app.handle(error)
        }
        reload(app: app)
    }
}

struct BookTile: View {
    let book: BookRecord
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverImage(thumb: book.thumb)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 8))
                // Downloaded, on the cover. Whether a book is on the device was
                // answerable only by opening it, which in a library of hundreds
                // means opening hundreds.
                .overlay(alignment: .bottomTrailing) {
                    if app.downloadedKeys.contains(book.ratingKey) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.white, .black.opacity(0.55))
                            .padding(6)
                            .accessibilityHidden(true)
                    }
                }
            Text(book.title).font(.callout.weight(.medium)).lineLimit(2)
            if let author = book.author {
                Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        // The badge is hidden from VoiceOver and said here instead, where it
        // joins the title rather than interrupting it as an unnamed image.
        .accessibilityElement(children: .combine)
        .accessibilityValue(app.downloadedKeys.contains(book.ratingKey) ? "Downloaded" : "")
    }
}

/// A cover, from disk when it is there.
///
/// Was `AsyncImage`, which is memory-first and re-fetches whenever the system
/// drops its cache — so an offline library drew a grid of grey placeholders,
/// having narrowed itself to exactly the books that were supposed to work
/// without a network. `ArtworkCache` keeps the bytes on disk.
struct CoverImage: View {
    let thumb: String?
    /// `.fill` everywhere this already was — a grid tile with a letterboxed
    /// grey band around an off-ratio cover reads as a mistake, and cropping
    /// is the right trade there. `.fit` exists for the one place that isn't
    /// true: the compact player's full-bleed tier, where the cover *is* the
    /// content rather than one tile among many, and losing part of the
    /// artwork to a crop is the mistake instead.
    var contentMode: ContentMode = .fill
    @Environment(AppModel.self) private var app
    @State private var image: NSImage?

    private static let side = 400

    /// Decoded covers, kept in memory.
    ///
    /// Cached but not decoded off the main actor, unlike the phone's. `NSImage`
    /// is not `Sendable` — it is mutable by design, which is the whole
    /// difference between it and `UIImage` — so it cannot be returned from a
    /// detached task without lying about it.
    ///
    /// The cache is the half that matters here anyway: the cost being paid over
    /// and over was decoding the *same* cover on every reappearance, and a hit
    /// now does no work at all. A cover is decoded once, on the main actor,
    /// which for one image at a time is not what makes a grid stutter.
    private static let decoded: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 240
        return cache
    }()

    var body: some View {
        Group {
            if let image {
                // Clipped, which it was not.
                //
                // `scaledToFill` makes the image cover its frame and *overflow*
                // whichever dimension does not fit — and without clipping, that
                // overflow is drawn. A tall book cover in a square frame painted
                // itself over the title and the transport beneath it, which is
                // why the player looked broken on exactly the books whose
                // artwork is not square.
                //
                // Fill by default, still: a cover with a letterboxed grey band
                // around it looks like a mistake in a grid of tiles. `.clipped()`
                // stays regardless of mode — a no-op when fitting, since a fitted
                // image is already fully contained in its frame, and load-bearing
                // when filling, for the reason above.
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .clipped()
            } else {
                Rectangle().fill(.quaternary)
                    .overlay(Image(systemName: "book.closed").foregroundStyle(.secondary))
            }
        }
        // Keyed on the thumb, so a reused cell in a scrolling grid loads the
        // cover for the book it is now showing rather than keeping the last
        // one. `AsyncImage` handled that itself, which is the one thing lost by
        // replacing it — and the one thing easy to get wrong here.
        .task(id: thumb) {
            guard let thumb, !thumb.isEmpty else {
                image = nil
                return
            }

            if let ready = Self.decoded.object(forKey: thumb as NSString) {
                image = ready
                return
            }

            image = nil

            guard let bytes = await ArtworkCache.shared.data(
                forThumb: thumb,
                width: Self.side,
                height: Self.side,
                url: app.server?.artworkURL(thumb: thumb, width: Self.side, height: Self.side)
            ) else { return }

            guard let decoded = NSImage(data: bytes) else { return }
            Self.decoded.setObject(decoded, forKey: thumb as NSString)

            // The cell may have been reused while the bytes were being read.
            guard thumb == self.thumb else { return }
            image = decoded
        }
    }
}

/// A way back, drawn in the content rather than the title bar.
///
/// `NavigationStack` draws its own back chevron automatically, in the title
/// bar row beside the traffic lights — which is where it was, on every screen
/// that reached a deeper view by pushing one. Nothing does that any more:
/// every step, from a sidebar section down to a specific book, is a push onto
/// `LibraryView.path` instead, and this is `breadcrumbBar`'s leading element —
/// its only remaining caller, now that Authors, Series and Genres no longer
/// keep any navigation state of their own to have a back button for.
///
/// Just the button, deliberately: the row it sits in, and what follows it, are
/// the caller's to decide.
struct BackButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "chevron.left")
        }
        .buttonStyle(.borderless)
        .keyboardShortcut("[", modifiers: .command)
        .help("Back to \(title)")
    }
}

/// Up to four covers in a square — an author, a series or a genre as a card,
/// rather than a name in a row.
///
/// Ported from the television's version, which solved this exact problem for
/// exactly this reason: a list of names told you nothing until you clicked one,
/// and the art is already cached, so showing it costs nothing a query was not
/// already doing. Nothing here is tvOS-specific — it is plain SwiftUI over this
/// file's own `CoverImage` — which is what let it move platforms unchanged.
///
/// One cover fills the square, two split it, three or four make a grid.
/// Anything else would need a placeholder tile, and a hole in a collage looks
/// like a failed download rather than a design.
struct CoverCollage: View {
    let thumbs: [String]
    var placeholderSymbol: String = "person"
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let half = side / 2

            switch thumbs.count {
            case 0:
                placeholder.frame(width: side, height: side)

            case 1:
                CoverImage(thumb: thumbs[0]).frame(width: side, height: side).clipped()

            case 2:
                HStack(spacing: 2) {
                    CoverImage(thumb: thumbs[0]).frame(width: half - 1, height: side).clipped()
                    CoverImage(thumb: thumbs[1]).frame(width: half - 1, height: side).clipped()
                }

            case 3:
                HStack(spacing: 2) {
                    CoverImage(thumb: thumbs[0]).frame(width: half - 1, height: side).clipped()
                    VStack(spacing: 2) {
                        CoverImage(thumb: thumbs[1]).frame(width: half - 1, height: half - 1).clipped()
                        CoverImage(thumb: thumbs[2]).frame(width: half - 1, height: half - 1).clipped()
                    }
                }

            default:
                VStack(spacing: 2) {
                    HStack(spacing: 2) {
                        CoverImage(thumb: thumbs[0]).frame(width: half - 1, height: half - 1).clipped()
                        CoverImage(thumb: thumbs[1]).frame(width: half - 1, height: half - 1).clipped()
                    }
                    HStack(spacing: 2) {
                        CoverImage(thumb: thumbs[2]).frame(width: half - 1, height: half - 1).clipped()
                        CoverImage(thumb: thumbs[3]).frame(width: half - 1, height: half - 1).clipped()
                    }
                }
            }
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(theme.surface)
            .overlay(
                Image(systemName: placeholderSymbol)
                    .font(.system(size: 40))
                    .foregroundStyle(theme.tertiaryText)
            )
    }
}

/// The offline switch, next to the account button. See the iOS one for why this
/// is a choice rather than something detected.
struct OfflineToggle: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var app = app

        Button {
            app.isOffline.toggle()
        } label: {
            // The glyph alone.
            //
            // It was a `Label`, which on this platform draws its text beside the
            // icon — so a toggle in a row of icon buttons carried "Offline mode
            // off" next to it, three words to say what the crossed-out cloud
            // already says.
            //
            // The state is still visible: a filled, struck-through cloud when
            // on, a plain outline when off, and the accent colour to separate
            // "this is doing something" from "this is available".
            Image(systemName: app.isOffline ? "icloud.slash.fill" : "icloud")
                .foregroundStyle(app.isOffline ? theme.accent : theme.text)
        }
        .help(app.isOffline
              ? "Showing downloaded books only. Click to go back online."
              : "Show downloaded books only, and stop contacting the server.")
        .accessibilityLabel("Offline mode")
        .accessibilityValue(app.isOffline ? "On, showing downloaded books only" : "Off")
    }
}

/// What the sidebar can be showing.
///
/// One type for every level of navigation, not only the top-level sections —
/// `authorDetail`/`seriesDetail`/`genreDetail` exist so that opening a book
/// from inside a specific author, series, or genre is a step in the *same*
/// shared trail as everything else, not a separate piece of state that gets
/// lost the moment something else replaces it. See `path` on `LibraryView`
/// for what that trail actually is and why it exists.
enum SidebarItem: Hashable {
    case home
    case allBooks
    case authors
    case series
    case genres
    case downloads
    case history
    case authorDetail(String)
    case seriesDetail(String)
    case genreDetail(String)
    case book(ratingKey: String, title: String)

    /// What a breadcrumb crumb says for this step, and what the back button
    /// says it is going back *to* — the previous step's title, read from here.
    var breadcrumbTitle: String {
        switch self {
        case .home: "Home"
        case .allBooks: "Browse"
        case .authors: "Authors"
        case .series: "Series"
        case .genres: "Genres"
        case .downloads: "Downloads"
        case .history: "History"
        case .authorDetail(let name): name
        case .seriesDetail(let name): name
        case .genreDetail(let name): name
        case .book(_, let title): title
        }
    }
}
