import SwiftUI
import Audiobooks
import PlatformShared

/// Narrators, from the cache — modeled directly on `AuthorsView` beside it.
///
/// Both read one table now: `book_narrator` from Plex `Style` values here,
/// `book_author` from `Mood` credits there. The authors query used to union
/// in Plex's own album artist as well, and no longer does — in an audiobook
/// library that field is as often the narrator as the writer, so it was
/// putting people on the authors screen who had written nothing.
struct NarratorsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var narrators: [NarratorSummary] = []
    let onSelect: (String) -> Void

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 20)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(narrators) { narrator in
                    Button {
                        onSelect(narrator.name)
                    } label: {
                        NarratorTile(narrator: narrator)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
            .padding(.bottom, 20)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("Narrators")
        .overlay {
            if narrators.isEmpty {
                ContentUnavailableView(
                    "No narrators yet",
                    systemImage: "person.wave.2",
                    description: Text("They appear once your library has been fetched.")
                )
            }
        }
        .task { reload() }
        .onChange(of: app.libraryRevision) { _, _ in reload() }
    }

    private func reload() {
        guard let library = app.library, let sectionID = app.sectionID else {
            narrators = []
            return
        }
        narrators = (try? library.narrators(sectionID: sectionID, downloadedOnly: app.isOffline)) ?? []
    }
}

/// A narrator as a card: their covers, their name, how many books.
struct NarratorTile: View {
    let narrator: NarratorSummary
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverCollage(thumbs: narrator.covers, placeholderSymbol: "person.wave.2")
                .aspectRatio(1, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 8))

            Text(narrator.name)
                .font(.callout.weight(.medium))
                .foregroundStyle(theme.text)
                .lineLimit(2)

            Text(narrator.bookCount == 1 ? "1 book" : "\(narrator.bookCount) books")
                .font(.caption)
                .foregroundStyle(theme.tertiaryText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(narrator.name)
        .accessibilityValue(narrator.bookCount == 1 ? "1 book" : "\(narrator.bookCount) books")
    }
}

struct NarratorBooksView: View {
    let narrator: String
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
        .navigationTitle(narrator)
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
