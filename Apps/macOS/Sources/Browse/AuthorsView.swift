import SwiftUI
import Audiobooks
import PlatformShared

/// Authors, from the cache.
///
/// From `book_author` — the writers the metadata agent credited — and not from
/// Plex's album artist, which for an audiobook is as often the narrator as the
/// writer. Cached either way, so this needs no network and works offline like
/// the rest of browsing. A book the agent has not matched has no writer and
/// appears here under nobody.
///
/// A grid of cards, not a table. It was a `List` of names with a cover and a
/// count, which told you nothing until you clicked one — the covers were
/// already being fetched for the row and doing no work once they were there.
/// The television solved this exact problem the same way, for the same
/// reason: `CoverCollage` moved from that file to this one unchanged.
///
/// No navigation state of its own — not a `NavigationStack`, and not even the
/// local `@State` this held briefly in between. Which author is open, and
/// which book after that, are both steps in `LibraryView.path` now, so a back
/// button anywhere can step through the whole trail rather than only the one
/// level a given screen happens to remember.
struct AuthorsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var authors: [AuthorSummary] = []
    let onSelect: (String) -> Void

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 20)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(authors) { author in
                    Button {
                        onSelect(author.name)
                    } label: {
                        AuthorTile(author: author)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
            .padding(.bottom, 20)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("Authors")
        .overlay {
            if authors.isEmpty {
                ContentUnavailableView(
                    "No authors yet",
                    systemImage: "person",
                    description: Text("They appear once your library has been fetched.")
                )
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
    let open: (String, String) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var books: [BookRecord] = []

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 160), spacing: 16)]

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
            .padding(20)
            .padding(.bottom, 20)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle(author)
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

/// Everything credited to one contributor, by their stable key.
///
/// Modeled directly on `AuthorBooksView` beside it — same grid, same
/// loading, same offline handling. The one difference is the lookup: this
/// reads `book_contributor` by key rather than `book`/`book_author` by name,
/// so a corrected or retranslated display name never drops a book from the
/// list, and two people who happen to share a name are never merged onto
/// one page.
struct ContributorBooksView: View {
    let contributorKey: String
    let displayName: String
    let open: (String, String) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var books: [BookRecord] = []

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 160), spacing: 16)]

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
            .padding(20)
            .padding(.bottom, 20)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle(displayName)
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
