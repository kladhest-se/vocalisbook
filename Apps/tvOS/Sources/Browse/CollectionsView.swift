import SwiftUI
import Audiobooks
import PlatformShared

/// Collections, from the server.
///
/// These are Plex's own collections — in an audiobook library that is usually
/// one per series. Distinct from the `collection` table in the local store,
/// which is for collections a listener makes and which Plex has no API for.
///
/// Cached like everything else. This header used to say the opposite — that
/// collections were the one part of browsing needing the network — and stayed
/// that way after the `plex_collection` table and the sync path were added,
/// directly above a model whose own comment describes reading the cache first.
/// Two accounts of one screen, three files each, and nothing comparing them.
struct CollectionsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var model = CollectionsModel()

    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 380), spacing: 40)]

    var body: some View {
        NavigationStack {
            // A heading above the scroll view, not a navigation title.
            //
            // `navigationTitle` on a tab root here is drawn over the content and
            // travels with the scroll, so it slid down onto the grid as soon as
            // anything moved. Home and Library never had the problem because
            // neither uses one — they draw their own text and let it sit still.
            VStack(alignment: .leading, spacing: 24) {
                Text("Collections")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(theme.text)
                    .padding(.horizontal, 16)
                    .padding(.top, 24)

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 40) {
                        ForEach(model.collections) { collection in
                            NavigationLink(value: collection.ratingKey) {
                                CollectionTile(collection: collection)
                            }
                            .buttonStyle(.card)
                        }
                    }
                    .padding(16)
                    .padding(.bottom, 90)
                }
                .navigationDestination(for: String.self) { CollectionBooksView(ratingKey: $0) }
                .overlay {
                    if model.collections.isEmpty {
                        ContentUnavailableView {
                            Label(model.failure == nil ? "No collections" : "Couldn't load",
                                  systemImage: "folder")
                        } description: {
                            Text(model.failure ?? "This library has no collections on the server.")
                        }
                    }
                }
            }
            // On the stack rather than the scroll view: the heading lives above
            // the scroll now, and a background that stops where the scrolling
            // starts leaves a strip of window behind the title.
            .background(theme.background.ignoresSafeArea())
        }
        .task { await model.load(app: app) }
    }
}

struct CollectionTile: View {
    let collection: PlexCollectionRecord
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: app.server?.artworkURL(thumb: collection.thumb, width: 500, height: 500)) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                default: Rectangle().fill(theme.surface)
                }
            }
            .aspectRatio(1, contentMode: .fill)

            // A scrim, because cover art is unpredictable and white-on-anything
            // is not readable.
            LinearGradient(
                colors: [.clear, .black.opacity(0.75)],
                startPoint: .center, endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(collection.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let count = collection.childCount {
                    Text("\(count) book\(count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .padding(10)
        }
        .clipShape(.rect(cornerRadius: 10))
    }
}

struct CollectionBooksView: View {
    let ratingKey: String
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var books: [BookRecord] = []
    @State private var title = ""

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 300), spacing: 48)]

    var body: some View {
        // A heading above the scroll view, for the reason the tab roots
        // give: a navigation title here is drawn over the content and
        // travels with it.
        VStack(alignment: .leading, spacing: 24) {
            Text(title)
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(theme.text)
                .lineLimit(2)
                .padding(.horizontal, 16)
                .padding(.top, 24)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 48) {
                    ForEach(books, id: \.ratingKey) { book in
                        NavigationLink(value: BookRoute(ratingKey: book.ratingKey)) {
                            BookTile(book: book)
                        }
                        .buttonStyle(.card)
                    }
                }
                .padding(20)
                .padding(.bottom, 90)
            }
            .navigationDestination(for: BookRoute.self) { BookDetailView(ratingKey: $0.ratingKey) }
        }
        .background(theme.background.ignoresSafeArea())
        .task {
            // Emptied rather than left, when there is nothing to read.
            //
            // A bare `return` here keeps whatever was last loaded on screen. After
            // clearing the cache the database is empty and `sectionID` is nil, so
            // this guard fired and the old rows stayed visible — the list was a
            // memory of a database that no longer held any of it.
            guard let library = app.library, let sectionID = app.sectionID else {
                books = []
                title = ""
                return
            }
            // Entirely from the cache now, membership included, so a collection
            // opens offline like any other list.
            books = (try? library.books(inCollection: ratingKey)) ?? []
            title = (try? library.collections(sectionID: sectionID))?
                .first { $0.ratingKey == ratingKey }?.title ?? "Collection"
        }
    }
}

@MainActor
@Observable
final class CollectionsModel {
    private(set) var collections: [PlexCollectionRecord] = []
    private(set) var failure: String?
    private(set) var isRefreshing = false

    /// Reads the cache first, then refreshes if it is empty.
    ///
    /// Collections used to be fetched every time this screen appeared, which
    /// made it the one part of browsing that needed the network. They are cached
    /// now like everything else; the fetch is a refresh, not a load.
    func load(app: AppModel) async {
        reload(app: app)
        if collections.isEmpty { await refresh(app: app) }
    }

    func reload(app: AppModel) {
        // Emptied rather than left, when there is nothing to read.
        //
        // A bare `return` here keeps whatever was last loaded on screen. After
        // clearing the cache the database is empty and `sectionID` is nil, so
        // this guard fired and the old rows stayed visible — the list was a
        // memory of a database that no longer held any of it.
        guard let library = app.library, let sectionID = app.sectionID else {
            collections = []
            return
        }
        collections = (try? library.collections(sectionID: sectionID)) ?? []
    }

    /// One request for the list and one per collection for the membership, which
    /// is why this is not part of the ordinary library refresh.
    func refresh(app: AppModel) async {
        guard let sync = app.librarySync, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await sync.refreshCollections()
            failure = nil
            app.clearDegraded()
        } catch {
            failure = error.plexExplanation
            app.handle(error)
        }
        reload(app: app)
    }
}
