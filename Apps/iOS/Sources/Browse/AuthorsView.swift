import SwiftUI
import Audiobooks
import PlatformShared

/// Authors and narrators, from the cache, as one screen with a segmented
/// switch rather than a sixth tab.
///
/// iOS caps this app's tab bar at five deliberately — a sixth tab is not
/// dropped, it is bucketed into iOS's own unthemed "More" screen, which
/// looks like a different app sitting on top of this one. A segmented
/// control inside the tab both existing browse screens already had room for
/// avoids that entirely, the same way the Music app puts Artists and
/// Albums behind one tab rather than two.
///
/// Both sides read one table: `book_author` from the metadata agent's `Mood`
/// credits, `book_narrator` from its `Style` values. Cached either way, so
/// this needs no network and works offline like the rest of browsing.
///
/// Plex's own album artist is deliberately not consulted. It is whatever the
/// files were tagged with, and for an audiobook that is as often the narrator
/// as the writer — unioning it in put people on this screen who had written
/// nothing, and the same writer on it twice. A book the agent has not matched
/// therefore has no author and appears here under nobody.
struct AuthorsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var mode: Mode = .authors
    @State private var authors: [AuthorSummary] = []
    @State private var narrators: [NarratorSummary] = []
    @State private var search = ""

    private enum Mode: String, CaseIterable {
        case authors = "Authors"
        case narrators = "Narrators"
    }

    /// Name, cover, book count — the one shape both `AuthorSummary` and
    /// `NarratorSummary` share, so one row and one filter serve both without
    /// either type needing to know about the other.
    private struct Row: Identifiable {
        let name: String
        let bookCount: Int
        let cover: String?
        var id: String { name }
    }

    private var rows: [Row] {
        let source: [Row]
        switch mode {
        case .authors:
            source = authors.map { Row(name: $0.name, bookCount: $0.bookCount, cover: $0.covers.first) }
        case .narrators:
            source = narrators.map { Row(name: $0.name, bookCount: $0.bookCount, cover: $0.covers.first) }
        }
        return search.isEmpty
            ? source
            : source.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List(rows) { row in
                NavigationLink(value: PersonRoute(name: row.name, mode: mode)) {
                    HStack(spacing: 12) {
                        // One cover, not the four the television shows. A 2×2
                        // collage at this size is mush; the point here is only
                        // to make the row scannable by something other than
                        // reading it.
                        CoverImage(thumb: row.cover)
                            .frame(width: 44, height: 44)
                            .clipShape(.rect(cornerRadius: 6))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name)
                                .foregroundStyle(theme.text)
                                .lineLimit(1)
                            Text(row.bookCount == 1 ? "1 book" : "\(row.bookCount) books")
                                .font(.footnote)
                                .foregroundStyle(theme.tertiaryText)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(row.name)
                    .accessibilityValue(row.bookCount == 1 ? "1 book" : "\(row.bookCount) books")
                }
                .listRowBackground(theme.surface)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(theme.background.ignoresSafeArea())
            .safeAreaInset(edge: .top) {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(theme.background)
            }
            // Pulling down here did nothing at all: authors are derived from
            // the cached books, so the list only changes when the library is
            // fetched — and this screen never fetched. Every other tab
            // refreshes; a gesture that works in three places and silently does
            // nothing in the fourth is worse than one that is absent everywhere.
            .refreshable {
                if let sync = app.librarySync {
                    _ = try? await sync.refreshBooks()
                }
                reload()
            }
            .searchable(text: $search, prompt: mode == .authors ? "Author" : "Narrator")
            .navigationTitle(mode.rawValue)
            .accountToolbar()
            .navigationDestination(for: PersonRoute.self) { route in
                switch route.mode {
                case .authors: AuthorBooksView(author: route.name)
                case .narrators: NarratorBooksView(narrator: route.name)
                }
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView(
                        mode == .authors ? "No authors yet" : "No narrators yet",
                        systemImage: mode == .authors ? "person" : "person.wave.2",
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
            narrators = []
            return
        }
        authors = (try? library.authors(sectionID: sectionID, downloadedOnly: app.isOffline)) ?? []
        narrators = (try? library.narrators(sectionID: sectionID, downloadedOnly: app.isOffline)) ?? []
    }

    /// A name alone is not enough to know which detail screen to push — an
    /// author and a narrator with the same first name would collide on a
    /// bare `String` route. Carrying `mode` alongside the name is what keeps
    /// the destination correct regardless of which segment the row was
    /// tapped from, rather than reading whatever `mode` happens to be at
    /// navigation time.
    private struct PersonRoute: Hashable {
        let name: String
        let mode: Mode
    }
}

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
