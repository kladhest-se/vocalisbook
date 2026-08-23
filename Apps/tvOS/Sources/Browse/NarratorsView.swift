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

    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 380), spacing: 40)]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                Text("Narrators")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(theme.text)
                    .padding(.horizontal, 16)
                    .padding(.top, 24)

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 40) {
                        ForEach(narrators) { narrator in
                            NavigationLink(value: narrator.name) {
                                NarratorTile(narrator: narrator)
                            }
                            .buttonStyle(.card)
                        }
                    }
                    .padding(16)
                    .padding(.bottom, 90)
                }
                .navigationDestination(for: String.self) { NarratorBooksView(narrator: $0) }
                .overlay {
                    if narrators.isEmpty {
                        ContentUnavailableView(
                            "No narrators yet",
                            systemImage: "person.wave.2",
                            description: Text("They appear once your library has been fetched.")
                        )
                    }
                }
            }
            .background(theme.background.ignoresSafeArea())
        }
        .task { reload() }
        .onChange(of: app.libraryRevision) { _, _ in reload() }
    }

    private func reload() {
        guard let library = app.library, let sectionID = app.sectionID else {
            narrators = []
            return
        }
        narrators = (try? library.narrators(sectionID: sectionID)) ?? []
    }
}

/// A narrator as a card: their covers, their name, how many books.
struct NarratorTile: View {
    let narrator: NarratorSummary
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CoverCollage(thumbs: narrator.covers)
                .aspectRatio(1, contentMode: .fit)

            Text(narrator.name)
                .font(.callout)
                .lineLimit(2)
                .foregroundStyle(theme.text)

            Text(narrator.bookCount == 1 ? "1 book" : "\(narrator.bookCount) books")
                .font(.caption)
                .foregroundStyle(theme.tertiaryText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(narrator.name)
        .accessibilityValue(narrator.bookCount == 1 ? "1 book" : "\(narrator.bookCount) books")
    }
}

/// Everything read by one narrator.
struct NarratorBooksView: View {
    let narrator: String
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var books: [BookRecord] = []

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 300), spacing: 48)]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(narrator)
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(theme.text)
                .lineLimit(2)
                .padding(.horizontal, 16)
                .padding(.top, 24)

            ScrollView {
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
                        "Nothing read by this narrator",
                        systemImage: "books.vertical",
                        description: Text("The library may not have finished fetching.")
                    )
                }
            }
        }
        .background(theme.background.ignoresSafeArea())
        .task {
            guard let library = app.library, let sectionID = app.sectionID else {
                books = []
                return
            }
            books = (try? library.books(byNarrator: narrator, sectionID: sectionID)) ?? []
        }
    }
}
