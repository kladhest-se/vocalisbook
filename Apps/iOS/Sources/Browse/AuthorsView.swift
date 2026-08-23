import SwiftUI
import Audiobooks
import PlatformShared

/// The books one writer wrote.
///
/// The list of writers itself lives in `BrowseView` now, together with
/// narrators, series and genres — this file kept only the screens those
/// names push to. `books(byAuthor:)` reads the metadata agent's credits
/// alone, so this page and the list that leads to it agree about what an
/// author is.
struct AuthorBooksView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let author: String
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var books: [BookRecord] = []
    @State private var selection: String?

    private var columns: [GridItem] { .coverGrid(sizeClass) }

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
            .padding(20)
            .padding(.bottom, 90)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle(author)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: BookRoute.self) { BookDetailView(ratingKey: $0.ratingKey) }
        .task {
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
            books = (try? library.books(byAuthor: author, sectionID: sectionID, downloadedOnly: app.isOffline)) ?? []
        }
    }
}

/// A distinct route type for books.
///
/// `String` is already the author route in this stack, so a bare rating key
/// would push the wrong screen — two destinations for the same type, and
/// whichever was declared last wins.
struct BookRoute: Hashable {
    let ratingKey: String
}

/// Everything credited to one contributor, by their stable key.
///
/// Modeled directly on `AuthorBooksView` above — same grid, same loading,
/// same offline handling, same `BookRoute` navigation. The one difference is
/// the lookup: this reads `book_contributor` by key rather than `book`/
/// `book_author` by name, so a corrected or retranslated display name never
/// drops a book from the list, and two people who happen to share a name are
/// never merged onto one page.
struct ContributorBooksView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let contributorKey: String
    let displayName: String
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var books: [BookRecord] = []

    private var columns: [GridItem] { .coverGrid(sizeClass) }

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
            .padding(20)
            .padding(.bottom, 90)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: BookRoute.self) { BookDetailView(ratingKey: $0.ratingKey) }
        .task {
            guard let library = app.library, let sectionID = app.sectionID else {
                books = []
                return
            }
            books = (try? library.books(
                byContributor: contributorKey, sectionID: sectionID, downloadedOnly: app.isOffline
            )) ?? []
        }
    }
}
