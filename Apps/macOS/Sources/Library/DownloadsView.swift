import SwiftUI
import Audiobooks
import PlatformShared

/// What is on this Mac.
///
/// The phone has had this since downloads existed; the Mac could download books
/// and offered no way to see which, or to clear them without opening each one.
/// "What is taking up 12 GB" had no answer here.
///
/// A sidebar item rather than a corner of Settings, unlike the phone's. On iOS
/// this is pushed from a Settings sheet because a phone has four tabs and no
/// room for a fifth; the Mac's sidebar is a list that already holds six things
/// and this is a seventh way of looking at the same library.
///
/// Books still downloading are shown too. A transfer in progress has bytes on
/// disk and is what somebody opens this screen to check on, so hiding it until
/// it finished would empty the screen at the only moment it was wanted.
struct DownloadsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var entries: [OfflineEntry] = []
    @State private var totalBytes = 0
    @State private var confirmingRemoveAll = false

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 20)]

    var body: some View {
        ScrollView {
            if !entries.isEmpty {
                header
            }

            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(entries) { entry in
                    // Asks for the book rather than selecting it.
                    //
                    // The detail pane belongs to `LibraryView`, and a view inside
                    // it cannot change the sidebar selection. `requestedBook` is
                    // the same route the phone's downloads list uses, for the
                    // same reason.
                    Button {
                        app.open(bookRatingKey: entry.book.ratingKey)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            BookTile(book: entry.book)
                            caption(for: entry)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Remove Download") {
                            remove(entry.book.ratingKey)
                        }
                    }
                }
            }
            .padding(20)

            if entries.isEmpty {
                ContentUnavailableView(
                    "Nothing downloaded",
                    systemImage: "arrow.down.circle",
                    description: Text(
                        "Books you download are kept here and play without a connection."
                    )
                )
                .padding(.top, 60)
            }
        }
        .background(theme.background)
        .navigationTitle("Downloads")
        .confirmationDialog(
            "Remove all downloads?",
            isPresented: $confirmingRemoveAll,
            titleVisibility: .visible
        ) {
            Button("Remove All", role: .destructive) { removeAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The files are deleted from this Mac. Your place in each book is kept.")
        }
        .task { refresh() }
        .onChange(of: app.downloads.revision) { _, _ in refresh() }
        .onChange(of: app.libraryRevision) { _, _ in refresh() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file))
                    .font(.headline)
                    .foregroundStyle(theme.text)
                Text(entries.count == 1 ? "1 book" : "\(entries.count) books")
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer()
            Button("Remove All…") { confirmingRemoveAll = true }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }

    /// The line under each cover: a size when it is there, progress when it is
    /// not. Both answer "can I play this on a train", which is the question.
    @ViewBuilder
    private func caption(for entry: OfflineEntry) -> some View {
        switch entry.state {
        case .complete(let bytes):
            Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                .font(.caption.monospacedDigit())
                .foregroundStyle(theme.tertiaryText)

        case .downloading(let fraction):
            Text(fraction >= 0.995
                 ? "Finishing…"
                 : "\(Int((fraction * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(theme.secondaryText)

        case .failed(let message):
            // The reason, not just the word.
            //
            // This said "Failed" and dropped the message the store had already
            // recorded — so a download that could not start looked identical to
            // one the server refused, one with no disk space, and one whose
            // token had expired. "Downloading failed" is not a report, it is the
            // absence of one.
            VStack(alignment: .trailing, spacing: 2) {
                Text("Failed")
                    .font(.caption)
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(theme.tertiaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
            .help(message)

        case .notDownloaded:
            EmptyView()
        }
    }

    private func refresh() {
        guard let library = app.library else { return }
        let keys = (try? app.downloadStore.booksWithDownloads()) ?? []
        let books = (try? library.books(ratingKeys: keys)) ?? []

        // Built from what was found rather than what was asked for:
        // `books(ratingKeys:)` promises no order, and a book cached before its
        // record was written may not come back at all.
        entries = books
            // Checked against the files, not only the rows — a record whose file
            // has gone is precisely what this screen must not list.
            .map { book in
                OfflineEntry(
                    book: book,
                    state: (try? app.downloadStore.state(
                        bookRatingKey: book.ratingKey,
                        fileExists: { app.downloads.hasFile(atRelativePath: $0) }
                    )) ?? .notDownloaded
                )
            }
            .sorted { left, right in
                // `titleSort` is optional — Plex omits it more often than not —
                // so the title is the fallback rather than an empty string,
                // which would sort those books to the front in a block.
                let a = left.book.titleSort ?? left.book.title
                let b = right.book.titleSort ?? right.book.title
                return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }

        totalBytes = (try? app.downloadStore.totalBytes()) ?? 0
    }

    private func remove(_ ratingKey: String) {
        app.save(while: "remove that download") {
            try app.downloads.evict(bookRatingKey: ratingKey)
        }
        app.refreshDownloadedKeys()
        refresh()
    }

    private func removeAll() {
        // One report for the action, not one per book: somebody who pressed
        // "remove all" is asking about the outcome of the whole thing, not about
        // whichever file failed last.
        app.save(while: "remove those downloads") {
            for entry in entries {
                try app.downloads.evict(bookRatingKey: entry.book.ratingKey)
            }
        }
        app.refreshDownloadedKeys()
        refresh()
    }
}

/// A downloaded book and what state its files are in.
///
/// Its own copy rather than shared with the phone's: the two apps are separate
/// targets with no code between them but `Core` and `Platform`, and a type this
/// small is not worth a package. `drift.sh` does not guard it because the two are
/// allowed to differ — the Mac shows sizes in a grid, the phone in a sheet.
struct OfflineEntry: Identifiable {
    let book: BookRecord
    let state: BookDownloadState

    var id: String { book.ratingKey }
}
