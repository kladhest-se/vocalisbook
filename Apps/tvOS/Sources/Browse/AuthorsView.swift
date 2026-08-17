import SwiftUI
import Audiobooks
import PlatformShared

/// Authors, from the cache.
///
/// Plex models the author as the album artist, so it is already on every book
/// row — this needs no network and works offline like the rest of browsing.
///
/// A grid of cards, not a list. It was a `List` of names with a count on the
/// right, which is the shape this screen takes on the phone and the wrong shape
/// here: a television has no pointer, so the only way to tell a row apart is the
/// focus ring, and a focus ring around a line of text on a custom background
/// reads as nothing happening. It looked like a table of contents rather than
/// somewhere to go. `CollectionsView` next door was already a card grid; this
/// now matches it.
struct AuthorsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var authors: [AuthorSummary] = []

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
                Text("Authors")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(theme.text)
                    .padding(.horizontal, 16)
                    .padding(.top, 24)

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 40) {
                        ForEach(authors) { author in
                            NavigationLink(value: author.name) {
                                AuthorTile(author: author)
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
            authors = []
            return
        }
        authors = (try? library.authors(sectionID: sectionID)) ?? []
    }
}

/// An author as a card: their covers, their name, how many books.
///
/// The covers are the point. An author card with no art is a coloured rectangle
/// with a name on it, which is the list this replaced with extra steps — and the
/// art is already cached, so it costs a column in a query that was already
/// running.
struct AuthorTile: View {
    let author: AuthorSummary
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CoverCollage(thumbs: author.covers)
                .aspectRatio(1, contentMode: .fit)

            Text(author.name)
                .font(.callout)
                .lineLimit(2)
                .foregroundStyle(theme.text)

            Text(author.bookCount == 1 ? "1 book" : "\(author.bookCount) books")
                .font(.caption)
                .foregroundStyle(theme.tertiaryText)
        }
        // One element. Read separately it is four unlabelled images, a name and
        // a count — and the images are announced first, so the name arrives
        // fourth.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(author.name)
        .accessibilityValue(author.bookCount == 1 ? "1 book" : "\(author.bookCount) books")
    }
}

/// Up to four covers in a square.
///
/// One cover fills it, two split it, three or four make a grid. Anything else
/// would need a placeholder tile, and a hole in a collage looks like a failed
/// download rather than a design.
struct CoverCollage: View {
    let thumbs: [String]
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let half = side / 2

            switch thumbs.count {
            case 0:
                placeholder.frame(width: side, height: side)

            case 1:
                CoverImage(thumb: thumbs[0]).frame(width: side, height: side).clipped()

            case 2:
                HStack(spacing: 2) {
                    CoverImage(thumb: thumbs[0]).frame(width: half - 1, height: side).clipped()
                    CoverImage(thumb: thumbs[1]).frame(width: half - 1, height: side).clipped()
                }

            case 3:
                HStack(spacing: 2) {
                    CoverImage(thumb: thumbs[0]).frame(width: half - 1, height: side).clipped()
                    VStack(spacing: 2) {
                        CoverImage(thumb: thumbs[1]).frame(width: half - 1, height: half - 1).clipped()
                        CoverImage(thumb: thumbs[2]).frame(width: half - 1, height: half - 1).clipped()
                    }
                }

            default:
                VStack(spacing: 2) {
                    HStack(spacing: 2) {
                        CoverImage(thumb: thumbs[0]).frame(width: half - 1, height: half - 1).clipped()
                        CoverImage(thumb: thumbs[1]).frame(width: half - 1, height: half - 1).clipped()
                    }
                    HStack(spacing: 2) {
                        CoverImage(thumb: thumbs[2]).frame(width: half - 1, height: half - 1).clipped()
                        CoverImage(thumb: thumbs[3]).frame(width: half - 1, height: half - 1).clipped()
                    }
                }
            }
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(theme.surface)
            .overlay(
                Image(systemName: "person")
                    .font(.system(size: 64))
                    .foregroundStyle(theme.tertiaryText)
            )
    }
}

/// Everything by one author.
struct AuthorBooksView: View {
    let author: String
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var books: [BookRecord] = []

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 300), spacing: 48)]

    var body: some View {
        // A heading above the scroll view, for the reason the tab roots
        // give: a navigation title here is drawn over the content and
        // travels with it.
        VStack(alignment: .leading, spacing: 24) {
            Text(author)
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(theme.text)
                .lineLimit(2)
                .padding(.horizontal, 16)
                .padding(.top, 24)

            ScrollView {
                // Said once at the top rather than in the title bar, which tvOS
                // truncates a long name in without warning.
                if !books.isEmpty {
                    Text(books.count == 1 ? "1 book" : "\(books.count) books")
                        .font(.title3)
                        .foregroundStyle(theme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                }

                LazyVGrid(columns: columns, spacing: 48) {
                    ForEach(books, id: \.ratingKey) { book in
                        NavigationLink(value: BookRoute(ratingKey: book.ratingKey)) {
                            BookTile(book: book)
                        }
                        .buttonStyle(.card)
                    }
                }
                .padding(20)
                .padding(.bottom, 90)
            }
            .navigationDestination(for: BookRoute.self) { BookDetailView(ratingKey: $0.ratingKey) }
            .overlay {
                if books.isEmpty {
                    ContentUnavailableView(
                        "Nothing by this author",
                        systemImage: "books.vertical",
                        description: Text("The library may not have finished fetching.")
                    )
                }
            }
        }
        .background(theme.background.ignoresSafeArea())
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
            books = (try? library.books(byAuthor: author, sectionID: sectionID)) ?? []
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
