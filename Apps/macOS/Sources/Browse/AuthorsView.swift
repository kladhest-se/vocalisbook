import SwiftUI
import Audiobooks
import PlatformShared

/// Authors, from the cache.
///
/// Plex models the author as the album artist, so it is already on every book
/// row — this needs no network and works offline like the rest of browsing.
struct AuthorsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var authors: [AuthorSummary] = []

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
            List(authors) { author in
                NavigationLink(value: author.name) {
                    HStack(spacing: 12) {
                        // One cover, not the four the television shows. A 2×2
                        // collage at this size is mush; the point here is only
                        // to make the row scannable by something other than
                        // reading it.
                        CoverImage(thumb: author.covers.first)
                            .frame(width: 44, height: 44)
                            .clipShape(.rect(cornerRadius: 6))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(author.name)
                                .foregroundStyle(theme.text)
                                .lineLimit(1)
                            // "12 books", not a bare "12" in the corner — which
                            // could as easily have been a rating or a position.
                            Text(author.bookCount == 1 ? "1 book" : "\(author.bookCount) books")
                                .font(.footnote)
                                .foregroundStyle(theme.tertiaryText)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(author.name)
                    .accessibilityValue(author.bookCount == 1 ? "1 book" : "\(author.bookCount) books")
                }
                .listRowBackground(theme.surface)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
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

struct AuthorBooksView: View {
    let author: String
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var books: [BookRecord] = []
    @State private var selection: String?

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
