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
///
/// No navigation state of its own, for the reason `AuthorsView` explains at
/// length: which genre is open, and which book after that, are steps in
/// `LibraryView.path` rather than something this screen remembers by itself.
struct GenresView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var genres: [GenreSummary] = []
    let onSelect: (String) -> Void

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 20)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(genres) { genre in
                    Button {
                        onSelect(genre.name)
                    } label: {
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
    let open: (String, String) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var books: [BookRecord] = []

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 20)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(books, id: \.ratingKey) { book in
                    Button {
                        open(book.ratingKey, book.title)
                    } label: {
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
