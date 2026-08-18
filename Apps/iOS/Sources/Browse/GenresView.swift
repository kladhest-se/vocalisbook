import SwiftUI
import Audiobooks
import PlatformShared

/// Genres, from the cache.
///
/// Shaped like `AuthorsView` on purpose: a list of names with a cover and a
/// count, and a grid of books behind each. It is the same screen with a
/// different noun, and two screens answering the same question should not answer
/// it differently.
///
/// Unlike authors, a book appears under several of these — that is what a genre
/// is, and why the store keeps them in their own table.
struct GenresView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var genres: [GenreSummary] = []
    @State private var search = ""

    private var shown: [GenreSummary] {
        search.isEmpty
            ? genres
            : genres.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List(shown) { genre in
                NavigationLink(value: GenreRoute(name: genre.name)) {
                    HStack(spacing: 12) {
                        CoverImage(thumb: genre.covers.first)
                            .frame(width: 44, height: 44)
                            .clipShape(.rect(cornerRadius: 6))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(genre.name)
                            Text(genre.bookCount == 1 ? "1 book" : "\(genre.bookCount) books")
                                .font(.caption)
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(genre.name)
                .accessibilityValue(genre.bookCount == 1 ? "1 book" : "\(genre.bookCount) books")
                .listRowBackground(theme.surface)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(theme.background.ignoresSafeArea())
            .refreshable {
                if let sync = app.librarySync {
                    _ = try? await sync.refreshBooks()
                }
                reload()
            }
            .searchable(text: $search, prompt: "Genre")
            .navigationTitle("Genres")
            .accountToolbar()
            .navigationDestination(for: GenreRoute.self) { GenreBooksView(genre: $0.name) }
            .overlay {
                if genres.isEmpty {
                    // Not "no genres yet", which sounds like something still
                    // arriving. A library Plex has not matched carries no tags
                    // at all, and no amount of refreshing here will produce
                    // any — it is a metadata problem with a metadata fix.
                    ContentUnavailableView(
                        "No genres",
                        systemImage: "theatermasks",
                        description: Text(
                            "Plex tags books with genres once an agent has matched them. "
                            + "Books it has not matched carry none."
                        )
                    )
                }
            }
        }
        .task { reload() }
        .onChange(of: app.libraryRevision) { _, _ in reload() }
        .onChange(of: app.isOffline) { _, _ in reload() }
    }

    private func reload() {
        // Emptied rather than left, when there is nothing to read.
        //
        // A bare `return` here keeps whatever was last loaded on screen. After
        // clearing the cache the database is empty and `sectionID` is nil, so
        // this guard fired and the old rows stayed visible — the list was a
        // memory of a database that no longer held any of it.
        guard let library = app.library, let sectionID = app.sectionID else {
            genres = []
            return
        }
        genres = (try? library.genres(sectionID: sectionID, downloadedOnly: app.isOffline)) ?? []
    }
}

/// The books in one genre.
struct GenreBooksView: View {
    let genre: String

    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.theme) private var theme
    @State private var books: [BookRecord] = []

    private var columns: [GridItem] { .coverGrid(sizeClass) }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(books, id: \.ratingKey) { book in
                    NavigationLink(value: book.ratingKey) {
                        BookTile(book: book)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationTitle(genre)
        .navigationDestination(for: String.self) { BookDetailView(ratingKey: $0) }
        // Found in the same audit pass as several other screens this
        // session: a second struct in a file whose *other* struct was
        // already theme-aware, which is exactly the shape that kept slipping
        // past a file-level check — `GenresView` itself had a background,
        // this screen it pushes to did not.
        .background(theme.background.ignoresSafeArea())
        .task { reload() }
        .onChange(of: app.libraryRevision) { _, _ in reload() }
    }

    private func reload() {
        // Emptied rather than left, when there is nothing to read.
        //
        // A bare `return` here keeps whatever was last loaded on screen. After
        // clearing the cache the database is empty and `sectionID` is nil, so
        // this guard fired and the old rows stayed visible — the list was a
        // memory of a database that no longer held any of it.
        guard let library = app.library, let sectionID = app.sectionID else {
            books = []
            return
        }
        books = (try? library.books(
            inGenre: genre,
            sectionID: sectionID,
            downloadedOnly: app.isOffline
        )) ?? []
    }
}

/// A route that is a genre, not a book.
///
/// `AuthorsView` pushes a bare `String` for an author and a bare `String` for a
/// book, which works only because the two live in different stacks. This screen
/// pushes both kinds from one stack, so the genre needs a type of its own —
/// otherwise a genre called "1234" and a book with that rating key are the same
/// destination.
struct GenreRoute: Hashable {
    let name: String
}
