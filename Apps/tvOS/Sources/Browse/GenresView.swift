import SwiftUI
import Audiobooks
import PlatformShared

/// Genres, from the cache.
///
/// A grid of cards, like Authors and Collections beside it — a television has no
/// pointer, so a list of names with a focus ring reads as a table of contents
/// rather than somewhere to go.
///
/// Unlike an author, a book has several genres. That is what a genre is, and why
/// the store keeps them in a table of their own.
struct GenresView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var genres: [GenreSummary] = []

    // No search field: text entry on a remote is a chore, and the grid is
    // browsable by focus.
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
                Text("Genres")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(theme.text)
                    .padding(.horizontal, 16)
                    .padding(.top, 24)

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 40) {
                        ForEach(genres) { genre in
                            NavigationLink(value: GenreRoute(name: genre.name)) {
                                GenreTile(genre: genre)
                            }
                            // The card style is what gives the lift, the shadow and
                            // the parallax on focus. Without it a `NavigationLink`
                            // here is a button with no visible focus state.
                            .buttonStyle(.card)
                        }
                    }
                    .padding(16)
                    .padding(.bottom, 90)
                }
                .navigationDestination(for: GenreRoute.self) { GenreBooksView(genre: $0.name) }
                .overlay {
                    if genres.isEmpty {
                        // Not "yet": a library Plex has not matched carries no tags,
                        // and no amount of fetching here will produce any.
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
            // On the stack rather than the scroll view: the heading lives above
            // the scroll now, and a background that stops where the scrolling
            // starts leaves a strip of window behind the title.
            .background(theme.background.ignoresSafeArea())
        }
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
            genres = []
            return
        }
        genres = (try? library.genres(sectionID: sectionID)) ?? []
    }
}

/// One genre, as a card.
struct GenreTile: View {
    let genre: GenreSummary
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CoverCollage(thumbs: genre.covers)
                .aspectRatio(1, contentMode: .fit)

            Text(genre.name)
                .font(.callout)
                .lineLimit(2)
                .foregroundStyle(theme.text)

            Text(genre.bookCount == 1 ? "1 book" : "\(genre.bookCount) books")
                .font(.caption)
                .foregroundStyle(theme.tertiaryText)
        }
        // One element. Read separately it is four unlabelled images, a name and
        // a count, with the images announced first.
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

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 300), spacing: 48)]

    var body: some View {
        // A heading above the scroll view, for the reason the tab roots
        // give: a navigation title here is drawn over the content and
        // travels with it.
        VStack(alignment: .leading, spacing: 24) {
            Text(genre)
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(theme.text)
                .lineLimit(2)
                .padding(.horizontal, 16)
                .padding(.top, 24)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 48) {
                    ForEach(books, id: \.ratingKey) { book in
                        NavigationLink(value: book.ratingKey) {
                            BookTile(book: book)
                        }
                        .buttonStyle(.card)
                    }
                }
                .padding(16)
                .padding(.bottom, 90)
            }
            .navigationDestination(for: String.self) { BookDetailView(ratingKey: $0) }
        }
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
        books = (try? library.books(inGenre: genre, sectionID: sectionID)) ?? []
    }
}

/// A route that is a genre, not a book.
///
/// `String` is already the book route in this stack, so a genre named "1234" and
/// a book with that rating key would otherwise be the same destination.
struct GenreRoute: Hashable {
    let name: String
}
