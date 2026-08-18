import SwiftUI
import Audiobooks
import PlatformShared

/// Authors, from the cache.
///
/// Plex models the author as the album artist, so it is already on every book
/// row — this needs no network and works offline like the rest of browsing.
///
/// A grid of cards, not a table. It was a `List` of names with a cover and a
/// count, which told you nothing until you clicked one — the covers were
/// already being fetched for the row and doing no work once they were there.
/// The television solved this exact problem the same way, for the same
/// reason: `CoverCollage` moved from that file to this one unchanged.
struct AuthorsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var authors: [AuthorSummary] = []

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 20)]

    var body: some View {
        // A `NavigationStack` of its own.
        //
        // This view is pushed into the sidebar column of a `NavigationSplitView`,
        // and a column is not a stack. `NavigationLink(value:)` needs one in
        // scope to resolve against, and `navigationDestination` outside a stack
        // is a no-op — so every row was a button that looked live, took focus
        // and did nothing. The list of authors was the whole feature, with the
        // half that matters silently inert.
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(authors) { author in
                        NavigationLink(value: author.name) {
                            AuthorTile(author: author)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
                .padding(.bottom, 20)
            }
            .background(theme.background.ignoresSafeArea())
            // No `.searchable` here.
            //
            // The split view already has one, and each `.searchable` wants a
            // search item in the same NSToolbar — inserting the second throws,
            // from inside a layout pass, which is fatal. That is the crash on
            // opening Authors. Filtering happens in the field that is already
            // there.
            .navigationTitle("Authors")
            .navigationDestination(for: String.self) { AuthorBooksView(author: $0) }
            .overlay {
                if authors.isEmpty {
                    ContentUnavailableView(
                        "No authors yet",
                        systemImage: "person",
                        description: Text("They appear once your library has been fetched.")
                    )
                }
            }
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
            authors = []
            return
        }
        authors = (try? library.authors(sectionID: sectionID, downloadedOnly: app.isOffline)) ?? []
    }
}

/// An author as a card: their covers, their name, how many books.
struct AuthorTile: View {
    let author: AuthorSummary
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverCollage(thumbs: author.covers, placeholderSymbol: "person")
                .aspectRatio(1, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 8))

            Text(author.name)
                .font(.callout.weight(.medium))
                .foregroundStyle(theme.text)
                .lineLimit(2)

            Text(author.bookCount == 1 ? "1 book" : "\(author.bookCount) books")
                .font(.caption)
                .foregroundStyle(theme.tertiaryText)
        }
        // One element. Read separately it is an unlabelled image, a name and a
        // count — and the image is announced first, so the name arrives last.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(author.name)
        .accessibilityValue(author.bookCount == 1 ? "1 book" : "\(author.bookCount) books")
    }
}

struct AuthorBooksView: View {
    let author: String
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var books: [BookRecord] = []

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 160), spacing: 16)]

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
            .padding(.bottom, 20)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle(author)
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
