import SwiftUI
import Audiobooks
import PlatformShared

/// The detail screen for one narrator. `NarratorsView` itself does not exist
/// as a separate screen on iOS — see the mode toggle inside `AuthorsView`
/// for why: a sixth tab here triggers iOS's own unthemed "More" bucket past
/// five, so narrators are reached from the Authors tab instead.
struct NarratorBooksView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let narrator: String
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
        .navigationTitle(narrator)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: BookRoute.self) { BookDetailView(ratingKey: $0.ratingKey) }
        .task {
            guard let library = app.library, let sectionID = app.sectionID else {
                books = []
                return
            }
            books = (try? library.books(
                byNarrator: narrator, sectionID: sectionID, downloadedOnly: app.isOffline
            )) ?? []
        }
    }
}
