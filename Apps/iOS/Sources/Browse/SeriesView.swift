import SwiftUI
import Audiobooks
import PlatformShared

/// One series, in reading order.
struct SeriesBooksView: View {
    let series: String

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var entries: [SeriesEntry] = []

    var body: some View {
        List(entries) { entry in
            NavigationLink(value: entry.book.ratingKey) {
                HStack(spacing: 12) {
                    CoverImage(thumb: entry.book.thumb)
                        .frame(width: 52, height: 52)
                        .clipShape(.rect(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.book.title)
                        if let author = entry.book.author {
                            Text(author)
                                .font(.caption)
                                .foregroundStyle(theme.secondaryText)
                        }
                    }

                    Spacer()

                    // The stated position, and nothing invented where there is
                    // none. A book can be in a series without the agent knowing
                    // where it sits, and a made-up number would be worse than a
                    // blank — somebody would read it as the reading order.
                    if let position = entry.position {
                        Text(position)
                            .font(.callout.weight(.medium).monospacedDigit())
                            .foregroundStyle(theme.secondaryText)
                    }
                }
            }
            .listRowBackground(theme.surface)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.background.ignoresSafeArea())
        .navigationTitle(series)
        .navigationDestination(for: String.self) { BookDetailView(ratingKey: $0) }
        .task { reload() }
        .onChange(of: app.libraryRevision) { _, _ in reload() }
    }

    private func reload() {
        guard let library = app.library, let sectionID = app.sectionID else {
            entries = []
            return
        }
        entries = (try? library.books(
            inSeries: series, sectionID: sectionID, downloadedOnly: app.isOffline
        )) ?? []
    }
}
