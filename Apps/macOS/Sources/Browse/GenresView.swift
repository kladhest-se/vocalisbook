import SwiftUI
import Audiobooks
import PlatformShared

/// Genres, from the cache.
///
/// Shaped like `AuthorsView` next door — a grid of cards, and a grid of books
/// behind each. Same screen, different noun.
///
/// Unlike an author, a book has several genres. That is what a genre is, and why
/// the store keeps them in a table of their own rather than a column.
struct GenresView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var genres: [GenreSummary] = []

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 20)]

    var body: some View {
        // A `NavigationStack` of its own, for the reason `AuthorsView` explains:
        // this is shown in a column, and a column is not a stack — without one,
        // every card is a button that takes focus and does nothing.
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(genres) { genre in
                        NavigationLink(value: GenreRoute(name: genre.name)) {
                            GenreTile(genre: genre)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
                .padding(.bottom, 20)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("Genres")
            .navigationDestination(for: GenreRoute.self) { GenreBooksView(genre: $0.name) }
            .navigationDestination(for: BookRoute.self) { BookDetailView(ratingKey: $0.ratingKey) }
            .overlay {
                if genres.isEmpty {
                    // Not "yet": a library Plex has not matched carries no tags
                    // at all, and refreshing will not produce any. It is a
                    // metadata problem with a metadata fix.
                    ContentUnavailableView(
                        "No genres",
                        systemImage: "theatermasks",
                        description: Text(
                            "Plex tags books with genres once an agent has matched them."
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

/// A genre as a card: books that carry it, their covers, how many there are.
struct GenreTile: View {
    let genre: GenreSummary
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverCollage(thumbs: genre.covers, placeholderSymbol: "theatermasks")
                .aspectRatio(1, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 8))

            Text(genre.name)
                .font(.callout.weight(.medium))
                .foregroundStyle(theme.text)
                .lineLimit(2)

            Text(genre.bookCount == 1 ? "1 book" : "\(genre.bookCount) books")
                .font(.caption)
                .foregroundStyle(theme.tertiaryText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(genre.name)
        .accessibilityValue(genre.bookCount == 1 ? "1 book" : "\(genre.bookCount) books")
    }
}

/// The books in one genre.
struct GenreBooksView: View {
    let genre: String

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var books: [BookRecord] = []

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 20)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(books, id: \.ratingKey) { book in
                    NavigationLink(value: BookRoute(ratingKey: book.ratingKey)) {
                        BookTile(book: book)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle(genre)
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

/// A route that is a genre.
///
/// `String` is already the author route in this app, and `BookRoute` exists for
/// the same reason: one type per destination, or whichever
/// `navigationDestination` was declared last wins.
struct GenreRoute: Hashable {
    let name: String
}
