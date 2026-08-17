import SwiftUI
import Audiobooks
import PlatformShared

/// Series, from the metadata agent's own tags.
///
/// Shaped like `GenresView` next door: a grid of cards, browsable by focus, with
/// the books behind each. The difference is that these have an order — the agent
/// records a position per book, and a series is the one grouping where reading
/// them out of order is a mistake rather than a preference.
///
/// Not from Plex collections. A collection is whatever somebody dragged into it;
/// a `Series:` Mood is something the metadata states.
struct SeriesView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var series: [SeriesSummary] = []

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
                Text("Series")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(theme.text)
                    .padding(.horizontal, 16)
                    .padding(.top, 24)

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 40) {
                        ForEach(series) { entry in
                            NavigationLink(value: SeriesRoute(name: entry.name)) {
                                SeriesTile(series: entry)
                            }
                            // The card style is what gives the lift and the parallax
                            // on focus; without it this is a button with no visible
                            // focus state.
                            .buttonStyle(.card)
                        }
                    }
                    .padding(16)
                    .padding(.bottom, 90)
                }
                .navigationDestination(for: SeriesRoute.self) { SeriesBooksView(series: $0.name) }
                .overlay {
                    if let activity = app.activity {
                        // Working, and saying so: this is a request per series, and
                        // an empty screen for a minute reads as a broken one. The
                        // "No series" message below is true only when nothing is
                        // being fetched.
                        VStack(spacing: 12) {
                            ProgressView()
                            Text(activity)
                                .font(.callout)
                                .foregroundStyle(theme.secondaryText)
                        }
                    } else if series.isEmpty {
                        ContentUnavailableView(
                            "No series",
                            systemImage: "books.vertical",
                            description: Text(
                                "Series come from the metadata agent. Books it has not "
                                + "matched, or that belong to no series, carry none."
                            )
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
        guard let library = app.library, let sectionID = app.sectionID else {
            series = []
            return
        }
        series = (try? library.series(sectionID: sectionID)) ?? []
    }
}

/// One series, as a card.
struct SeriesTile: View {
    let series: SeriesSummary
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CoverCollage(thumbs: series.covers)
                .aspectRatio(1, contentMode: .fit)

            Text(series.name)
                .font(.callout)
                .lineLimit(2)
                .foregroundStyle(theme.text)

            Text(series.bookCount == 1 ? "1 book" : "\(series.bookCount) books")
                .font(.caption)
                .foregroundStyle(theme.tertiaryText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(series.name)
        .accessibilityValue(series.bookCount == 1 ? "1 book" : "\(series.bookCount) books")
    }
}

/// One series, in reading order.
struct SeriesBooksView: View {
    let series: String

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var entries: [SeriesEntry] = []

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 300), spacing: 48)]

    var body: some View {
        // A heading above the scroll view, for the reason the tab roots
        // give: a navigation title here is drawn over the content and
        // travels with it.
        VStack(alignment: .leading, spacing: 24) {
            Text(series)
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(theme.text)
                .lineLimit(2)
                .padding(.horizontal, 16)
                .padding(.top, 24)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 48) {
                    ForEach(entries) { entry in
                        NavigationLink(value: entry.book.ratingKey) {
                            VStack(spacing: 6) {
                                BookTile(book: entry.book)

                                // The stated position, and nothing where there is
                                // none. A book can be in a series without the agent
                                // knowing where it sits, and an invented number
                                // would read as the reading order.
                                if let position = entry.position {
                                    Text("Book \(position)")
                                        .font(.caption)
                                        .foregroundStyle(theme.tertiaryText)
                                }
                            }
                        }
                        .buttonStyle(.card)
                    }
                }
                .padding(16)
                .padding(.bottom, 90)
            }
            .navigationDestination(for: String.self) { BookDetailView(ratingKey: $0) }
        }
        .background(theme.background.ignoresSafeArea())
        .task { reload() }
        .onChange(of: app.libraryRevision) { _, _ in reload() }
    }

    private func reload() {
        guard let library = app.library else {
            entries = []
            return
        }
        entries = (try? library.books(inSeries: series)) ?? []
    }
}

/// A route that is a series, not a book.
///
/// `String` is already the book route in this stack, so a series named "1234"
/// and a book with that rating key would otherwise be the same destination.
struct SeriesRoute: Hashable {
    let name: String
}
