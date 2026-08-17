import SwiftUI
import Audiobooks
import PlatformShared

/// Genres, from the cache.
///
/// Shaped like `AuthorsView` next door — a list of names with a cover and a
/// count, and a grid behind each. Same screen, different noun.
///
/// Unlike an author, a book has several genres. That is what a genre is, and why
/// the store keeps them in a table of their own rather than a column.
struct GenresView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var genres: [GenreSummary] = []

    var body: some View {
        // A `NavigationStack` of its own, for the reason `AuthorsView` explains:
        // this is shown in a column, and a column is not a stack — without one,
        // every row is a button that takes focus and does nothing.
        NavigationStack {
            List(genres) { genre in
                NavigationLink(value: GenreRoute(name: genre.name)) {
                    HStack(spacing: 12) {
                        CoverImage(thumb: genre.covers.first)
                            .frame(width: 44, height: 44)
                            .clipShape(.rect(cornerRadius: 6))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(genre.name)
                                .foregroundStyle(theme.text)
                                .lineLimit(1)
                            Text(genre.bookCount == 1 ? "1 book" : "\(genre.bookCount) books")
                                .font(.caption)
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
                }
                .listRowBackground(theme.surface)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(theme.background)
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

/// The books in one genre.
struct GenreBooksView: View {
    let genre: String

    @Environment(AppModel.self) private var app
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
