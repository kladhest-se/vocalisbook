import SwiftUI
import UIKit
import Audiobooks
import PlatformShared

/// The library, built for a remote rather than a finger.
///
/// Rows are large, everything is reachable by focus, and nothing sits within the
/// 60pt overscan safe area — SwiftUI's default padding on tvOS handles that, but
/// only if nothing is pinned to the raw screen bounds.
struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var model = LibraryModel()

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 300), spacing: 48)]

    var body: some View {
        NavigationStack {
            ScrollView {
                DegradedBanner()

                // No streak card and no Continue listening here.
                //
                // This is the Browse tab now, and both belong on Home — which is
                // where the phone and the Mac have always put them. Home used to
                // be this screen, so the television showed every book twice and
                // showed where you left off nowhere.

                HStack {
                    Text(model.search.isEmpty ? "Library" : "Results")
                        .font(.title2.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    NavigationLink {
                        FilterSortView(filter: $model.filter, sort: $model.sort, languages: model.availableLanguages)
                    } label: {
                        Image(systemName: model.filter.isActive || model.sort != .title
                              ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("Filter and sort")
                }
                .padding(.top, 12)

                LazyVGrid(columns: columns, spacing: 48) {
                    ForEach(model.books, id: \.ratingKey) { book in
                        NavigationLink(value: book.ratingKey) { BookTile(book: book) }
                            .buttonStyle(.card)
                    }
                }
                .padding(.bottom, 60)

                if model.books.isEmpty && !model.isRefreshing {
                    VStack(spacing: 16) {
                        Image(systemName: model.loadFailed ? "exclamationmark.triangle"
                                          : (model.search.isEmpty ? "books.vertical" : "magnifyingglass"))
                            .font(.system(size: 64))
                        // "Fetching your library" is true on a fresh install and
                        // a lie during a search that found nothing.
                        Text(model.loadFailed
                             ? "Couldn't read your library"
                             : (model.search.isEmpty ? "No books yet" : "No matches"))
                            .font(.title2)
                        Text(model.loadFailed
                             ? "The books are still on your server. This is the copy on "
                               + "this Apple TV, and something went wrong reading it."
                             : (model.search.isEmpty
                                ? "Fetching your library from Plex…"
                                : "Nothing in this library matches “\(model.search)”."))
                            .foregroundStyle(theme.secondaryText)
                    }
                    .padding(.top, 80)
                }
            }
            .navigationDestination(for: String.self) { BookDetailView(ratingKey: $0) }
            // Searchable on the television too.
            //
            // Typing on a remote is miserable, which is the usual argument
            // against putting search on a television — and it is the wrong way
            // round for a library of a thousand books, where the alternative is
            // scrolling past nine hundred of them with a thumb pad. tvOS gives
            // this its own tab and a dictation button; the remote is not the
            // only way in.
            .searchable(text: $model.search, prompt: "Title or author")
            .onChange(of: model.search) { _, _ in model.reload(app: app) }
            .onChange(of: model.filter) { _, _ in model.reload(app: app) }
            .onChange(of: model.sort) { _, _ in model.reload(app: app) }
            // Found in the same audit that added this elsewhere: no theme
            // awareness at all in this file previously, not even for text —
            // the empty-state message above read `.secondary`, a system
            // color, same as the sign-in pickers on iOS did before this
            // pass.
            .background(theme.background.ignoresSafeArea())
        }
        .task {
            model.reload(app: app)
            // A full fetch when there is nothing, a catch-up when there is.
            // Incremental cannot see deletions, which is what the refresh
            // control is for.
            if model.books.isEmpty {
                await model.refresh(app: app)
            } else {
                await model.refresh(app: app, incremental: true)
            }
        }
        .onChange(of: app.libraryRevision) { _, _ in model.reload(app: app) }
        .onChange(of: app.historyRevision) { _, _ in model.reload(app: app) }
    }
}

@MainActor
@Observable
final class LibraryModel {
    private(set) var books: [BookRecord] = []
    private(set) var isRefreshing = false

    /// Whether this refresh has already put something on screen.
    ///
    /// On the model rather than in the closure: `onPage` is `@Sendable`, and
    /// mutating a captured local from inside it is exactly what Swift 6
    /// forbids. The model is already main-actor isolated, which is also where
    /// the reload has to happen.
    private var hasShownAPage = false

    /// Reads from the cache. On this platform the cache may be empty on any
    /// launch, which is ordinary rather than an error — `refresh` repopulates it.
    var search = ""
    var filter = BookFilter()
    var sort = BookSort.title
    private(set) var availableLanguages: [String] = []

    /// Whether the last read failed, as opposed to finding nothing.
    private(set) var loadFailed = false

    func reload(app: AppModel) {
        // Emptied rather than left, when there is nothing to read.
        //
        // A bare `return` here keeps whatever was last loaded on screen. After
        // clearing the cache the database is empty and `sectionID` is nil, so
        // this guard fired and the old rows stayed visible — the list was a
        // memory of a database that no longer held any of it.
        guard let library = app.library, let sectionID = app.sectionID else {
            books = []
            loadFailed = false
            availableLanguages = []
            return
        }
        // Searched in the database rather than filtered in memory, so a large
        // library does not have to be held twice and the matching rules are the
        // ones the other two platforms already use — title and author, not title
        // alone.
        // A failed read is not an empty library. `try?` makes them the same
        // array and the screen then gives advice that cannot help.
        do {
            // Filter and sort are not applied while searching, matching the
            // other two platforms. No `downloadedOnly` in `filter` is ever set
            // to true here — this platform has no downloads feature at all,
            // and the filter UI below never offers the toggle that would set
            // it, the same way `BookTile` here never gained the badge that
            // would show it.
            books = try search.isEmpty
                ? library.books(sectionID: sectionID, filter: filter, sort: sort)
                : library.search(search)
            loadFailed = false
            availableLanguages = (try? library.distinctLanguages(sectionID: sectionID)) ?? []
        } catch {
            books = []
            loadFailed = true
        }
    }

    func refresh(app: AppModel, incremental: Bool = false) async {
        guard let sync = app.librarySync, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false; app.setActivity(nil) }
        do {
            // Reloaded on the first page and then not again until the end.
            //
            // Every page replaced the whole list: a re-query and a fresh array
            // for each 200 books, so a library of a few thousand rebuilt its
            // grid a dozen times during one refresh. Each rebuild relays out the
            // grid, and doing that under a moving finger is what a stutter is.
            //
            // The first page still lands immediately, because an empty library
            // that stays empty for twenty seconds looks broken. After that the
            // count in the progress line is the thing that moves, which costs
            // nothing.
            hasShownAPage = false
            try await sync.refreshBooks(
                incremental: incremental,
                onPage: { _, _ in
                    Task { @MainActor in
                        guard !self.hasShownAPage else { return }
                        self.hasShownAPage = true
                        self.reload(app: app)
                    }
                },
                onSeries: { done, total in
                    Task { @MainActor in
                        app.setActivity(
                            done >= total ? nil : "Fetching series… \(done) of \(total)"
                        )
                    }
                }
            )
            app.clearDegraded()
            _ = try? await app.progressSync?.drain()
        } catch {
            app.handle(error)
        }
        reload(app: app)
    }
}

/// The Books grid's filter and sort control. Pushed rather than sheeted or
/// popped over, matching `MetadataDiagnosticsView`'s own convention on this
/// platform — no title, no on-screen dismiss button, since the remote's own
/// Menu button is how every other pushed screen here is left.
///
/// `finishedOnly`/`unfinishedOnly` are two independent booleans on
/// `BookFilter` — a shape that lets the data layer express "don't filter on
/// progress" as both being false, without a third enum case existing purely
/// for that — but they're mutually exclusive in this UI, which is why
/// `progressSelection` below translates between them and a single
/// three-way control rather than showing two toggles a person could set
/// inconsistently. No "Downloaded only" toggle here — this platform has no
/// downloads feature at all, the same reason `BookTile` below never gained
/// that badge.
struct FilterSortView: View {
    @Binding var filter: BookFilter
    @Binding var sort: BookSort
    let languages: [String]
    @Environment(\.theme) private var theme

    private enum ProgressFilter: String, CaseIterable {
        case all = "All", unfinished = "Unfinished", finished = "Finished"
    }

    private var progressSelection: Binding<ProgressFilter> {
        Binding(
            get: {
                if filter.finishedOnly { return .finished }
                if filter.unfinishedOnly { return .unfinished }
                return .all
            },
            set: { newValue in
                filter.finishedOnly = newValue == .finished
                filter.unfinishedOnly = newValue == .unfinished
            }
        )
    }

    var body: some View {
        List {
            Section {
                Picker("Sort", selection: $sort) {
                    Text("Title").tag(BookSort.title)
                    Text("Recently added").tag(BookSort.recentlyAdded)
                    Text("Release year").tag(BookSort.releaseYear)
                    Text("Publication year").tag(BookSort.publicationYear)
                }
                if !languages.isEmpty {
                    Picker("Language", selection: $filter.language) {
                        Text("Any").tag(String?.none)
                        ForEach(languages, id: \.self) { language in
                            Text(language).tag(String?.some(language))
                        }
                    }
                }
                Picker("Progress", selection: progressSelection) {
                    ForEach(ProgressFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            }
            Section {
                Toggle("Abridged only", isOn: $filter.abridgedOnly)
                Toggle("Full cast or dramatized only", isOn: $filter.fullCastOrDramatizedOnly)
            }
            if filter.isActive || sort != .title {
                Section {
                    Button("Reset") {
                        filter = BookFilter()
                        sort = .title
                    }
                }
            }
        }
        .background(theme.background.ignoresSafeArea())
    }
}

struct BookTile: View {
    let book: BookRecord
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverImage(thumb: book.thumb)
                .aspectRatio(1, contentMode: .fit)
                .overlay(alignment: .topLeading) {
                    // Language, when known — most valuable for a library that
                    // genuinely mixes languages; harmless repetition otherwise.
                    if let language = book.language {
                        cornerBadge(text: languageAbbreviation(language))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    // Abridged and a notable production type can both apply to
                    // the same book at once, so this stacks rather than picks
                    // one. Neither is inferred from anything: absence of a tag
                    // is not evidence of the ordinary case, matching the
                    // contract's own rule for both fields.
                    VStack(alignment: .trailing, spacing: 4) {
                        if book.edition == "Abridged" {
                            cornerIcon("scissors")
                        }
                        if let production = book.productionType,
                           ["Full cast", "Dramatized"].contains(production) {
                            cornerIcon("theatermasks")
                        }
                    }
                }
                // No "downloaded" badge here — tvOS has no downloads feature
                // at all, deliberately: see the note on `AppModel` next to
                // where `downloads` would be, and `PlatformCapabilities
                // .supportsOfflineDownloads`, which this platform asserts
                // false. `finished` sits alone in the bottom corner rather
                // than paired with a badge that does not exist on this port.
                .overlay(alignment: .bottomLeading) {
                    if app.finishedKeys.contains(book.ratingKey) {
                        cornerIcon("checkmark")
                    }
                }
            Text(book.title).font(.callout).lineLimit(2)
            if let author = book.author {
                Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        // Every badge above is hidden from focus-based navigation and said
        // here instead, where each joins the title rather than interrupting
        // it as a set of unnamed images read out of order.
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityBadgeSummary)
    }

    private var accessibilityBadgeSummary: String {
        var parts: [String] = []
        if let language = book.language { parts.append(language) }
        if book.edition == "Abridged" { parts.append("Abridged") }
        if let production = book.productionType,
           ["Full cast", "Dramatized"].contains(production) {
            parts.append(production)
        }
        if app.finishedKeys.contains(book.ratingKey) { parts.append("Finished") }
        return parts.joined(separator: ", ")
    }

    /// First two letters, uppercased — not a real ISO code, since VocalisMeta
    /// sends a full name ("Swedish") rather than one to look up. Good enough
    /// to tell two languages apart on a cover; the full name is one focus
    /// press away on the book detail screen.
    private func languageAbbreviation(_ language: String) -> String {
        String(language.prefix(2)).uppercased()
    }

    private func cornerBadge(text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.55), in: .rect(cornerRadius: 6))
            .padding(10)
            .accessibilityHidden(true)
    }

    private func cornerIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(6)
            .background(.black.opacity(0.55), in: .circle)
            .padding(6)
            .accessibilityHidden(true)
    }
}

/// A cover, from disk when it is there.
///
/// Was `AsyncImage`, which is memory-first and re-fetches whenever the system
/// drops its cache — so an offline library drew a grid of grey placeholders,
/// having narrowed itself to exactly the books that were supposed to work
/// without a network. `ArtworkCache` keeps the bytes on disk.
struct CoverImage: View {
    let thumb: String?
    @Environment(AppModel.self) private var app
    @State private var image: UIImage?

    private static let side = 600

    /// Decoded covers, kept in memory. See the iPhone's version: decoding in
    /// `body` put a JPEG through the main thread for every cell each time it
    /// came back on screen, and a television grid is larger than a phone's.
    private static let decoded: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 240
        return cache
    }()

    var body: some View {
        Group {
            if let image {
                // Clipped, which it was not.
                //
                // `scaledToFill` makes the image cover its frame and *overflow*
                // whichever dimension does not fit — and without clipping, that
                // overflow is drawn. A tall book cover in a square frame painted
                // itself over the title and the transport beneath it, which is
                // why the player looked broken on exactly the books whose
                // artwork is not square.
                //
                // Fill rather than fit, still: a cover with a letterboxed grey
                // band around it looks like a mistake in a grid of tiles. Fill
                // and clip is the same picture with the spill removed.
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            } else {
                Rectangle().fill(.quaternary)
                    .overlay(Image(systemName: "book.closed").font(.largeTitle))
            }
        }
        // Keyed on the thumb, so a reused cell in a scrolling grid loads the
        // cover for the book it is now showing rather than keeping the last
        // one. `AsyncImage` handled that itself, which is the one thing lost by
        // replacing it — and the one thing easy to get wrong here.
        .task(id: thumb) {
            guard let thumb, !thumb.isEmpty else {
                image = nil
                return
            }

            if let ready = Self.decoded.object(forKey: thumb as NSString) {
                image = ready
                return
            }

            image = nil

            guard let bytes = await ArtworkCache.shared.data(
                forThumb: thumb,
                width: Self.side,
                height: Self.side,
                url: app.server?.artworkURL(thumb: thumb, width: Self.side, height: Self.side)
            ) else { return }

            let prepared = await Task.detached(priority: .userInitiated) {
                UIImage(data: bytes)?.preparingForDisplay()
            }.value

            guard let prepared else { return }
            Self.decoded.setObject(prepared, forKey: thumb as NSString)

            // The cell may have been reused while that ran.
            guard thumb == self.thumb else { return }
            image = prepared
        }
    }
}
