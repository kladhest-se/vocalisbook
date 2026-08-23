import SwiftUI
import Audiobooks
import PlexKit
import Platform
import PlatformShared

/// A live, read-only look at exactly what VocalisMeta sent for one book.
///
/// Deliberately reads through a **fresh** Plex fetch rather than the local
/// cache: `BookDetailModel.book` is a `BookRecord`, the persisted row this
/// app actually plays from, and extending what that row carries is a real
/// schema migration — a bigger, separate decision from a diagnostics screen.
/// A tool meant to answer "what is the agent actually sending" is more
/// honest reading the agent's current answer directly than reading whatever
/// this device happened to cache the last time it synced, which is exactly
/// the kind of gap a malformed-library report needs ruled out, not
/// reintroduced.
///
/// No external requests: everything shown here already came from Plex, the
/// one server this app is allowed to talk to.
struct MetadataDiagnosticsView: View {
    let ratingKey: String
    /// Passed in rather than re-resolved: the chapter tier that was actually
    /// used for playback is a fact about this session, not something a fresh
    /// metadata fetch could answer on its own.
    let chapterSource: Chapter.Source?

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var book: PlexBook?
    @State private var loadError: String?
    @State private var isLoading = true
    @State private var isReloading = false
    @State private var reloadError: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Fetching current metadata…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    ContentUnavailableView(
                        "Couldn't fetch metadata",
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadError)
                    )
                } else if let book {
                    List {
                        contractSection(for: book)
                        identitySection(for: book)
                        creditsSection(for: book)
                        editionSection(for: book)
                        technicalSection(for: book)
                        reloadSection
                    }
                }
            }
            .navigationTitle("Metadata Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(theme.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    /// "Reload from Plex" writes what this screen already fetched live into
    /// the local cache, which is what every other screen actually reads
    /// from. It never contacts VocalisMeta, Audible, Open Library, or
    /// anything else — only Plex, and only for what Plex is already
    /// holding. Getting VocalisMeta to look up something new is a separate
    /// action the person takes in Plex itself (Refresh Metadata), which
    /// this deliberately does not attempt to trigger — a client asking an
    /// agent to re-scan is a different kind of request than reading what
    /// scanning already produced.
    @ViewBuilder
    private var reloadSection: some View {
        Section {
            Button {
                Task { await reloadFromPlex() }
            } label: {
                if isReloading {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Reloading…")
                    }
                } else {
                    Label("Reload from Plex", systemImage: "arrow.clockwise")
                }
            }
            .disabled(isReloading)
            if let reloadError {
                Text(reloadError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } footer: {
            Text("""
                Reads the latest metadata already stored by Plex and updates \
                every screen this app builds from it. To have VocalisMeta look \
                up new information, use Refresh Metadata on this item in Plex \
                itself.
                """)
        }
        .listRowBackground(theme.surface)
    }

    private func reloadFromPlex() async {
        isReloading = true
        reloadError = nil
        guard let sync = app.librarySync else {
            reloadError = "Not connected to a server."
            isReloading = false
            return
        }
        do {
            _ = try await sync.refreshBook(ratingKey: ratingKey)
            app.libraryChanged()
            await load()
        } catch {
            reloadError = error.plexExplanation
        }
        isReloading = false
    }

    private func load() async {
        isLoading = true
        loadError = nil
        do {
            book = try await app.server?.book(ratingKey: ratingKey)
            if book == nil { loadError = "Not signed in to a server." }
        } catch {
            loadError = error.plexExplanation
        }
        isLoading = false
    }

    @ViewBuilder
    private func contractSection(for book: PlexBook) -> some View {
        Section("Contract") {
            // Full Plex record is always Yes here specifically: this screen
            // only ever reaches this branch after a live fetch succeeded — a
            // failed one shows the error state above instead. The other
            // three are the genuine per-book question this section exists to
            // answer, since none of them can be assumed from whether this
            // one succeeded.
            row("Full Plex record", "Loaded")
            row("Identity contract (v1)", canonicalIdentity.isStrong ? "Available" : "Unavailable")
            row("Work contract (v2)", hasWorkContract(book) ? "Available" : "Unavailable")
            row("Extended contract (v3)", hasExtendedContract(book) ? "Available" : "Unavailable")
        }
    }

    /// v1 available means the agent matched this recording to something
    /// external — Audible, LibriVox or ISBN — not merely that some
    /// identity exists. `BookIdentity.isStrong` is precisely that
    /// distinction: true for a real match, false for the `local:`
    /// fingerprint and the per-server fallback, both of which mean no
    /// match was made at all.
    ///
    /// v2 and v3 aren't named as such anywhere in what the agent sends —
    /// there's no header field saying "this book has v3". This treats
    /// Work-ID and Contributor-ID as the work contract and the remaining
    /// four (Work-Published, Production, Rating-Source, Rating-Count) as
    /// the extended one, matching the order the original spec introduced
    /// them in. Deliberately computed per book from what was actually
    /// decoded, never assumed globally from one book having them — the
    /// spec is explicit that one book's contract says nothing about any
    /// other book's.
    private func hasWorkContract(_ book: PlexBook) -> Bool {
        book.workIdentity != nil || !book.contributors.isEmpty
    }

    private func hasExtendedContract(_ book: PlexBook) -> Bool {
        book.workPublishedYear != nil || book.productionType != nil
            || book.ratingSource != nil || book.ratingCount != nil
    }

    @ViewBuilder
    private func identitySection(for book: PlexBook) -> some View {
        Section("Identity") {
            row("Raw GUID", book.guid ?? "—")
            row("Rating key", ratingKey)
            row("Server", serverIdentifier ?? "—")
            row("Canonical identity", canonicalIdentity.key)
            row("Portable", canonicalIdentity.isPortable ? "Yes" : "No, per-server only")
            if let workIdentity = book.workIdentity {
                row("Work identity", workIdentity.key)
            }
        }
    }

    @ViewBuilder
    private func creditsSection(for book: PlexBook) -> some View {
        Section("Credits") {
            row("Primary author", book.author ?? "—")
            row("Co-authors (Mood)", list(book.authors))
            row("Narrators (Style)", list(book.narrators))
            row("Genres", list(book.genres))
            if !book.contributors.isEmpty {
                ForEach(book.contributors, id: \.key) { contributor in
                    row("Contributor: \(contributor.role)", "\(contributor.displayName)\n\(contributor.key)")
                }
            }
        }
    }

    @ViewBuilder
    private func editionSection(for book: PlexBook) -> some View {
        Section("Edition") {
            row("Series", list(book.series))
            row("Sequence", book.sequences.map { "\($0.series) #\($0.position)" }.joined(separator: ", ").ifEmpty("—"))
            row("Language", book.language ?? "—")
            row("Abridgment", book.edition ?? "—")
            row("Recording release (Plex)", book.year.map(String.init) ?? "—")
            row("Work first published", book.workPublishedYear.map(String.init) ?? "—")
            row("Production", book.productionType ?? "—")
            row("Rating source", book.ratingSource ?? "—")
            row("Rating count", book.ratingCount.map(String.init) ?? "—")
        }
    }

    @ViewBuilder
    private func technicalSection(for book: PlexBook) -> some View {
        Section("Technical") {
            row("Chapter source", chapterSourceLabel)
            row(
                "Artwork URL",
                redactedArtworkURL(app.server?.artworkURL(thumb: book.thumb, width: 400, height: 400))
            )
        }
    }

    /// The artwork URL with `X-Plex-Token` redacted before display.
    ///
    /// A diagnostics screen exists to be looked at, shared and screenshotted
    /// — exactly what happened the first time this shipped, and exactly how
    /// a raw token ends up somewhere it should never be. The rest of the URL
    /// (server address, thumb identifier, transcode parameters) stays, since
    /// none of that is a credential; only the token value itself is
    /// replaced.
    private func redactedArtworkURL(_ url: URL?) -> String {
        guard let url else { return "—" }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems
        else {
            // Malformed enough that the token's own position in the string
            // cannot be trusted to find safely — better to withhold the
            // whole thing than to guess and get it wrong.
            return "(unable to redact safely — omitted)"
        }
        components.queryItems = items.map { item in
            item.name == "X-Plex-Token" ? URLQueryItem(name: item.name, value: "REDACTED") : item
        }
        return components.string ?? "(unable to redact safely — omitted)"
    }

    private var canonicalIdentity: BookIdentity {
        BookIdentity.from(
            guid: book?.guid,
            serverIdentifier: serverIdentifier ?? "",
            ratingKey: ratingKey
        )
    }

    /// The machine identifier is the part of `sectionID` before the colon —
    /// the same assumption `LibraryStore.identityKey` and the v9 migration
    /// both already make, in the two other places this app builds this
    /// string.
    private var serverIdentifier: String? {
        guard let sectionID = app.sectionID, let colon = sectionID.firstIndex(of: ":") else {
            return nil
        }
        return String(sectionID[sectionID.startIndex..<colon])
    }

    private var chapterSourceLabel: String {
        switch chapterSource {
        case .plexMetadata: return "Plex chapter metadata"
        case .embeddedInFile: return "Embedded chapter markers"
        case .trackBoundary: return "Track boundaries (fallback)"
        case nil: return "No chapters resolved"
        }
    }

    private func list(_ values: [String]) -> String {
        values.isEmpty ? "—" : values.joined(separator: ", ")
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
            Text(value)
                .font(.body.monospaced())
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
