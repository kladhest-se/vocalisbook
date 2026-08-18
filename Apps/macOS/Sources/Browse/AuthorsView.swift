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
///
/// No `NavigationStack`, and deliberately not any more. It used to have one of
/// its own, needed because this view sits in the detail column of a
/// `NavigationSplitView`, and a column is not a stack — `NavigationLink`
/// resolves against a stack in scope or does nothing at all. Local state does
/// the same job without the push, which is what stopped the system drawing an
/// automatic back chevron in the title bar every time an author's books came
/// on screen: there is no push for it to be a chevron *for*. It also means
/// leaving Authors and coming back through the sidebar always shows the grid
/// again, never wherever it was left — the view is torn down and rebuilt, and
/// `selectedAuthor` goes with it.
///
/// `open` reaches a book the same way `HomeView` already does: by asking the
/// sidebar to swap its own `selection` to `.book`, rather than pushing a
/// second stack on top of this one.
struct AuthorsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var authors: [AuthorSummary] = []
    @State private var selectedAuthor: String?
    let open: (String) -> Void

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 20)]

    var body: some View {
        Group {
            if let selectedAuthor {
                VStack(spacing: 0) {
                    BackButton(title: "Authors") { self.selectedAuthor = nil }
                    AuthorBooksView(author: selectedAuthor, open: open)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 24) {
                        ForEach(authors) { author in
                            Button {
                                selectedAuthor = author.name
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
                // No `.searchable` here.
                //
                // The split view already has one, and each `.searchable` wants
                // a search item in the same NSToolbar — inserting the second
                // throws, from inside a layout pass, which is fatal. That was
                // the crash on opening Authors. Filtering happens in the field
                // that is already there.
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
    let open: (String) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var books: [BookRecord] = []

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 160), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(books, id: \.ratingKey) { book in
                    Button {
                        open(book.ratingKey)
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
