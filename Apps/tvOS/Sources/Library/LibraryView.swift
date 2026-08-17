import SwiftUI
import UIKit
import Audiobooks
import PlatformShared

/// The library, built for a remote rather than a finger.
///
/// Rows are large, everything is reachable by focus, and nothing sits within the
/// 60pt overscan safe area — SwiftUI's default padding on tvOS handles that, but
/// only if nothing is pinned to the raw screen bounds.
struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var model = LibraryModel()

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 300), spacing: 48)]

    var body: some View {
        NavigationStack {
            ScrollView {
                DegradedBanner()

                // No streak card and no Continue listening here.
                //
                // This is the Browse tab now, and both belong on Home — which is
                // where the phone and the Mac have always put them. Home used to
                // be this screen, so the television showed every book twice and
                // showed where you left off nowhere.

                Text(model.search.isEmpty ? "Library" : "Results")
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 12)

                LazyVGrid(columns: columns, spacing: 48) {
                    ForEach(model.books, id: \.ratingKey) { book in
                        NavigationLink(value: book.ratingKey) { BookTile(book: book) }
                            .buttonStyle(.card)
                    }
                }
                .padding(.bottom, 60)

                if model.books.isEmpty && !model.isRefreshing {
                    VStack(spacing: 16) {
                        Image(systemName: model.loadFailed ? "exclamationmark.triangle"
                                          : (model.search.isEmpty ? "books.vertical" : "magnifyingglass"))
                            .font(.system(size: 64))
                        // "Fetching your library" is true on a fresh install and
                        // a lie during a search that found nothing.
                        Text(model.loadFailed
                             ? "Couldn't read your library"
                             : (model.search.isEmpty ? "No books yet" : "No matches"))
                            .font(.title2)
                        Text(model.loadFailed
                             ? "The books are still on your server. This is the copy on "
                               + "this Apple TV, and something went wrong reading it."
                             : (model.search.isEmpty
                                ? "Fetching your library from Plex…"
                                : "Nothing in this library matches “\(model.search)”."))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 80)
                }
            }
            .navigationDestination(for: String.self) { BookDetailView(ratingKey: $0) }
            // Searchable on the television too.
            //
            // Typing on a remote is miserable, which is the usual argument
            // against putting search on a television — and it is the wrong way
            // round for a library of a thousand books, where the alternative is
            // scrolling past nine hundred of them with a thumb pad. tvOS gives
            // this its own tab and a dictation button; the remote is not the
            // only way in.
            .searchable(text: $model.search, prompt: "Title or author")
            .onChange(of: model.search) { _, _ in model.reload(app: app) }
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
        .onChange(of: app.libraryRevision) { _, _ in model.reload(app: app) }
        .onChange(of: app.historyRevision) { _, _ in model.reload(app: app) }
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

    /// Reads from the cache. On this platform the cache may be empty on any
    /// launch, which is ordinary rather than an error — `refresh` repopulates it.
    var search = ""

    /// Whether the last read failed, as opposed to finding nothing.
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
        // Searched in the database rather than filtered in memory, so a large
        // library does not have to be held twice and the matching rules are the
        // ones the other two platforms already use — title and author, not title
        // alone.
        // A failed read is not an empty library. `try?` makes them the same
        // array and the screen then gives advice that cannot help.
        do {
            books = try search.isEmpty
                ? library.books(sectionID: sectionID)
                : library.search(search)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverImage(thumb: book.thumb)
                .aspectRatio(1, contentMode: .fit)
            Text(book.title).font(.callout).lineLimit(2)
            if let author = book.author {
                Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
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

    private static let side = 600

    /// Decoded covers, kept in memory. See the iPhone's version: decoding in
    /// `body` put a JPEG through the main thread for every cell each time it
    /// came back on screen, and a television grid is larger than a phone's.
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
                Rectangle().fill(.quaternary)
                    .overlay(Image(systemName: "book.closed").font(.largeTitle))
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

            let prepared = await Task.detached(priority: .userInitiated) {
                UIImage(data: bytes)?.preparingForDisplay()
            }.value

            guard let prepared else { return }
            Self.decoded.setObject(prepared, forKey: thumb as NSString)

            // The cell may have been reused while that ran.
            guard thumb == self.thumb else { return }
            image = prepared
        }
    }
}
