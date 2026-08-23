import SwiftUI
import Audiobooks
import PlatformShared

/// The books in one genre.
struct GenreBooksView: View {
    let genre: String

    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.theme) private var theme
    @State private var books: [BookRecord] = []

    private var columns: [GridItem] { .coverGrid(sizeClass) }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(books, id: \.ratingKey) { book in
                    NavigationLink(value: book.ratingKey) {
                        BookTile(book: book)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationTitle(genre)
        .navigationDestination(for: String.self) { BookDetailView(ratingKey: $0) }
        // Found in the same audit pass as several other screens this
        // session: a second struct in a file whose *other* struct was
        // already theme-aware, which is exactly the shape that kept slipping
        // past a file-level check — the list screen itself had a background,
        // this screen it pushes to did not.
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
        books = (try? library.books(
            inGenre: genre,
            sectionID: sectionID,
            downloadedOnly: app.isOffline
        )) ?? []
    }
}
