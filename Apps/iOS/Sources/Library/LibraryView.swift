import SwiftUI
import UIKit
import Audiobooks
import PlatformShared

struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.theme) private var theme
    @State private var model = LibraryModel()
    @State private var selection: String?

    private var columns: [GridItem] { .coverGrid(sizeClass) }

    var body: some View {
        // One shape, on every size of screen.
        //
        // This was a split view on regular width and an iPad showed why that was
        // wrong: the grid went into a sidebar column, the covers came back down
        // to phone size in a narrow strip, and the rest of the screen said
        // "Nothing open" until something was picked.
        //
        // A library is a wall of covers. It wants the whole width, and on an
        // iPad it gets more of them per row rather than a column of the same
        // few — which is a matter of grid metrics, not of navigation structure.
        NavigationStack {
            grid
                .navigationTitle("Library")
                .accountToolbar()
                .navigationDestination(item: $selection) { ratingKey in
                    BookDetailView(ratingKey: ratingKey)
                }
        }
        .task {
            model.reload(app: app)
            await model.refreshIfStale(app: app)
        }
    }

    /// Removed: this filter and the new persistent Downloads button, once
    /// both were in the toolbar at once, read as two ways to reach the same
    /// place — the arrow-down icon in both, one leading and one trailing.
    /// They were never quite the same thing (this narrowed the grid in
    /// place; Downloads opens a separate management screen), but that
    /// distinction was not visible at a glance, and a toolbar with two
    /// download-shaped buttons is a worse toolbar regardless of what each
    /// one technically does. Offline mode alone now drives `downloadedOnly`
    /// below — see `LibraryModel.reload(app:)`.

    /// The grid itself, which is the same in both shapes — only what happens
    /// when a cover is tapped differs, and that is `selection` either way.
    private var grid: some View {
        ScrollView {
                DegradedBanner()

                // No Continue listening here.
                //
                // It is Home's job, and Home does it properly — a card with a
                // Resume button and a row of everything else. Repeating it one
                // tab away made Browse open on books you had already started
                // instead of on the library, which is the one thing this tab is
                // for.
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(model.books, id: \.ratingKey) { book in
                        // A selection rather than a link, so the same grid
                        // serves a push on the phone and a detail column on the
                        // iPad.
                        Button {
                            selection = book.ratingKey
                        } label: {
                            BookTile(book: book)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 90)

                if model.books.isEmpty && !model.isRefreshing {
                    if model.loadFailed {
                        // A different sentence, because a different thing
                        // happened. Fetching again will not help: the fetch is
                        // not what failed.
                        ContentUnavailableView(
                            "Couldn't read your library",
                            systemImage: "exclamationmark.triangle",
                            description: Text(
                                "The books are still on your server. This is the copy "
                                + "on this device, and something went wrong reading it."
                            )
                        )
                        .padding(.top, 60)
                    } else {
                        ContentUnavailableView(
                            app.isOffline ? "Nothing downloaded"
                                : model.search.isEmpty ? "No books yet" : "Nothing matched",
                            systemImage: app.isOffline ? "arrow.down.circle" : "books.vertical",
                            description: Text(
                                app.isOffline
                                ? "Nothing in your library is downloaded to this device yet."
                                : model.search.isEmpty
                                ? "Pull down to fetch your library from Plex."
                                : "Try a different title or author."
                            )
                        )
                        .padding(.top, 60)
                    }
                }
            }
        .background(theme.background.ignoresSafeArea())
        .refreshable { await model.refresh(app: app) }
        .searchable(text: $model.search, prompt: "Title or author")
        .onChange(of: model.search) { _, _ in model.reload(app: app) }
        // This screen listened to nothing but its own search field.
        //
        // Its Continue listening row is the same row Home has, and Home reloads
        // on both of these — so finishing a book updated one screen and not the
        // other, and the row here stayed as it was until the search text changed
        // or the tab was rebuilt.
        // The player observer went with the Continue listening row: this screen
        // shows the library, and which book is playing does not change it.
        // `libraryRevision` still matters — finishing a book changes what the
        // grid should show.
        .onChange(of: app.libraryRevision) { _, _ in model.reload(app: app) }
        // Added alongside removing the downloaded-only toggle above: that
        // button called `model.reload(app:)` directly in its own action,
        // which was the only thing making a switch between filtered and
        // unfiltered take effect immediately. `isOffline`'s own `didSet`
        // does not bump `libraryRevision` or anything else this screen
        // already listens to, so without this the grid would only catch up
        // with offline mode next time something else happened to trigger a
        // reload — the search field changing, say — rather than the moment
        // offline mode actually changed.
        .onChange(of: app.isOffline) { _, _ in model.reload(app: app) }
    }
}

@MainActor
@Observable
final class LibraryModel {
    private(set) var books: [BookRecord] = []
    private(set) var isRefreshing = false

    /// Whether this refresh has already put something on screen.
    ///
    /// On the model rather than in the closure: `onPage` is `@Sendable`, and
    /// mutating a captured local from inside it is exactly what Swift 6
    /// forbids. The model is already main-actor isolated, which is also where
    /// the reload has to happen.
    private var hasShownAPage = false
    private(set) var progressText: String?
    var search = ""

    /// Reads from the local store only. Browsing never waits on the network —
    /// that is the entire reason the cache exists.
    /// Whether the last read failed, as opposed to finding nothing.
    ///
    /// `try?` turns both into an empty array, and the screen then says "No books
    /// yet — pull down to fetch your library", which is true of a fresh install
    /// and a lie about a database that would not open. Somebody follows that
    /// advice, the fetch succeeds, the read fails again, and the screen gives
    /// the same instruction.
    private(set) var loadFailed = false

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
        // Offline mode is now the only reason this narrows to what is on
        // disk — the standalone toggle that used to sit beside it in the
        // toolbar was removed as a duplicate of the new persistent Downloads
        // button, which opens a full management screen instead of filtering
        // in place.
        let downloadedOnly = app.isOffline
        do {
            books = try search.isEmpty
                ? library.books(sectionID: sectionID, downloadedOnly: downloadedOnly)
                : library.search(search, downloadedOnly: downloadedOnly)
            loadFailed = false
        } catch {
            books = []
            loadFailed = true
        }
    }

    /// Opening the app catches up; pulling down re-reads everything.
    ///
    /// An empty library has nothing to be incremental about, so the first fetch
    /// is the whole thing. After that this asks only for what changed, which is
    /// one request rather than twenty — and cannot see deletions, which is what
    /// pull to refresh is for.
    func refreshIfStale(app: AppModel) async {
        if books.isEmpty {
            await refresh(app: app)
        } else {
            await refresh(app: app, incremental: true)
        }
    }

    func refresh(app: AppModel, incremental: Bool = false) async {
        guard let sync = app.librarySync, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false; progressText = nil; app.setActivity(nil) }

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
                onPage: { [weak self] done, total in
                    Task { @MainActor in
                        self?.progressText = total.map { "\(done) of \($0)" } ?? "\(done)"
                        guard let self, !self.hasShownAPage else { return }
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
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverImage(thumb: book.thumb)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 8))
                // Downloaded, on the cover.
                //
                // Whether a book is on the device was answerable only by opening
                // it, which in a library of hundreds means opening hundreds. The
                // badge is small and in a corner because it is a fact about the
                // book, not a thing to press.
                .overlay(alignment: .bottomTrailing) {
                    if app.downloadedKeys.contains(book.ratingKey) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.white, .black.opacity(0.55))
                            .padding(6)
                            .accessibilityHidden(true)
                    }
                }

            Text(book.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(theme.text)
                .lineLimit(2)
            if let author = book.author {
                Text(author)
                    .font(.caption2)
                    .foregroundStyle(theme.tertiaryText)
                    .lineLimit(1)
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
    @Environment(AppModel.self) private var app
    @State private var image: UIImage?

    private static let side = 400

    /// Decoded covers, kept in memory.
    ///
    /// `NSCache` because it is what the system evicts under pressure without
    /// being asked, which is the entire requirement — this is a convenience, and
    /// the bytes are still on disk if it goes.
    private static let decoded: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
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
                // Fill rather than fit, still: a cover with a letterboxed grey
                // band around it looks like a mistake in a grid of tiles. Fill
                // and clip is the same picture with the spill removed.
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            } else {
                Rectangle()
                    .fill(.quaternary)
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

            // Already decoded: no await, no flicker, and no work at all on the
            // way back up a grid.
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

            // Decoded off the main actor.
            //
            // `UIImage(data:)` in `body` decoded a JPEG on the main thread for
            // every cell, every time it came back on screen — which is what a
            // grid does constantly and what made scrolling back up stutter and
            // stall. `preparingForDisplay` does the work that would otherwise
            // happen at draw time, here, where nothing is waiting on it.
            let prepared = await Task.detached(priority: .userInitiated) {
                UIImage(data: bytes)?.preparingForDisplay()
            }.value

            guard let prepared else { return }
            Self.decoded.setObject(prepared, forKey: thumb as NSString)

            // The cell may have been reused for another book while that ran.
            guard thumb == self.thumb else { return }
            image = prepared
        }
    }
}

extension Array where Element == GridItem {
    /// Covers sized for the screen they are on.
    ///
    /// 110pt is a phone tile. On an iPad the same number gives a wall of small
    /// artwork — correct, reflowed, and unmistakably a phone layout that
    /// happened to fit. The Mac, doing the same job on a similar amount of
    /// glass, asks for 240.
    ///
    /// One definition rather than four: the library, authors, collections and
    /// the downloads list all draw the same kind of grid, and four copies of a
    /// pair of numbers is four chances for them to stop matching.
    static func coverGrid(_ sizeClass: UserInterfaceSizeClass?) -> [GridItem] {
        let regular = sizeClass == .regular
        // Bigger covers on an iPad, not merely more of them.
        //
        // A wall of 110pt tiles across a 10-inch screen is a phone layout that
        // reflowed — technically correct, and it makes a library of a thousand
        // books look like a contact sheet. 150 to 190 gives roughly six per row
        // on an iPad mini and eight on a 13-inch, at a size where the cover art
        // is legible, which is the whole reason a library screen shows covers
        // rather than a list of titles.
        return [
            GridItem(
                .adaptive(minimum: regular ? 150 : 110, maximum: regular ? 190 : 160),
                spacing: regular ? 22 : 16
            )
        ]
    }
}
