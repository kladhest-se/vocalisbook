import SwiftUI
import Audiobooks
import PlatformShared

/// What is on this device.
///
/// Browse, restricted to books with files on disk — the one place where "what
/// is taking up 12 GB" has an answer you can act on: every book, its size,
/// remove one or all, transfers in progress.
///
/// It had a tab of its own, twice, both given back for the same reason: a tab
/// is for a way of looking at the library, and this is storage management. A
/// toolbar button was tried too and given back in turn — it answered "what is
/// on this device" the same way regardless of which of those two questions
/// somebody actually had. They are different questions now: a quick glance —
/// "show me only what is downloaded" while still browsing — is a toggle in
/// Browse's own toolbar, independent of offline mode; managing what is here —
/// sizes, removing things, watching a transfer — is this screen, pushed from
/// Settings, next to the size it reports.
///
/// Books still downloading are shown too. A transfer in progress has bytes on
/// disk and is exactly what somebody opens this screen to check on, so hiding it
/// until it finished would empty the screen at the only moment it was wanted.
struct OfflineView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.theme) private var theme
    @State private var entries: [OfflineEntry] = []
    @State private var totalBytes = 0
    @State private var confirmingRemoveAll = false

    private var columns: [GridItem] { .coverGrid(sizeClass) }

    var body: some View {
        // No `NavigationStack` of its own — Settings pushes this and already
        // has one; nesting them breaks both the push and the title.
        //
        // A screen that supplies its own stack cannot be pushed; one that
        // supplies none can be either pushed or wrapped, and the caller
        // decides. Kept this way even with one caller today, since it has had
        // two before and may again.
        Group {
            ScrollView {
                if !entries.isEmpty {
                    header
                }

                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(entries) { entry in
                        // Asks for the book rather than pushing it.
                        //
                        // This list sits inside the Settings sheet, so a push
                        // opened the reader *within* a modal called Settings,
                        // with Done as the way out of a book. It worked, and it
                        // was plainly the wrong place to arrive.
                        //
                        // Now the sheet closes, Home comes forward, and the book
                        // opens where books open.
                        Button {
                            // Asking is the whole action: the toolbar that
                            // presented this sheet closes it, and Home opens the
                            // book. Dismissing from here would pop back to
                            // Settings and leave the sheet up.
                            app.open(bookRatingKey: entry.book.ratingKey)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                BookTile(book: entry.book)
                                caption(for: entry)
                            }
                        }
                        .buttonStyle(.plain)
                        // Long press is not discoverable on its own, which is
                        // why the size line below each tile and the button in
                        // the header both exist. This is the shortcut, not the
                        // only way in — the book's own screen has it too.
                        .contextMenu {
                            Button("Remove download", role: .destructive) {
                                remove(entry.book.ratingKey)
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 90)

                if entries.isEmpty {
                    ContentUnavailableView(
                        "Nothing downloaded",
                        systemImage: "arrow.down.circle",
                        description: Text("Books you download are kept here and play without a connection.")
                    )
                    .padding(.top, 60)
                }
            }
            // "Downloads", matching the tab and the Mac's sidebar row.
            //
            // It was "Offline", which is the mode rather than the contents —
            // and the mode is a switch in the toolbar, not this list.
            .navigationTitle("Downloads")
            .scrollContentBackground(.hidden)
            .background(theme.background.ignoresSafeArea())
            .confirmationDialog(
                "Remove all downloads?",
                isPresented: $confirmingRemoveAll,
                titleVisibility: .visible
            ) {
                Button("Remove all", role: .destructive) { removeAll() }
            } message: {
                Text("The files are deleted from this device. Your place in each book is kept.")
            }
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
                Text(entries.count == 1 ? "1 book" : "\(entries.count) books")
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer()
            Button("Remove all", role: .destructive) { confirmingRemoveAll = true }
                .font(.footnote)
        }
        .padding(.horizontal)
        .padding(.bottom, 12)
    }

    /// The line under each cover: a size when it is there, progress when it is
    /// not. Both answer "can I play this on a plane", which is the question.
    @ViewBuilder
    private func caption(for entry: OfflineEntry) -> some View {
        switch entry.state {
        case .complete(let bytes):
            Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(theme.tertiaryText)

        case .downloading(let fraction):
            Text(fraction >= 0.995
                 ? "Finishing…"
                 : "\(Int((fraction * 100).rounded()))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(theme.secondaryText)

        case .failed:
            Text("Failed")
                .font(.caption2)
                .foregroundStyle(.red)

        case .notDownloaded:
            EmptyView()
        }
    }

    private func refresh() {
        guard let library = app.library else { return }
        let keys = (try? app.downloadStore.booksWithDownloads()) ?? []
        let books = (try? library.books(ratingKeys: keys)) ?? []

        // `books(ratingKeys:)` does not promise an order, and a book cached
        // before its record was written may not come back at all — so the list
        // is built from what was found rather than from what was asked for.
        entries = books
            // Checked against the files, not only the rows. This screen exists
            // to say what will play without a connection, so a record whose file
            // has gone is precisely the thing it must not list.
            //
            // No part keys here: that would need every book's timeline loaded to
            // draw one list. The file check catches the case this screen is for,
            // and the book's own screen does the stricter comparison.
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
                // `titleSort` is optional in the record — Plex omits it more
                // often than not — so the title is the fallback rather than an
                // empty string, which would sort those books to the front in a
                // block.
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
        refresh()
    }

    private func removeAll() {
        // One report for the action, not one per book. A loop of individual
        // saves would leave whichever failed last on screen and say nothing
        // about the rest, and somebody who pressed "remove all" is asking about
        // the outcome of the whole thing.
        app.save(while: "remove those downloads") {
            for entry in entries {
                try app.downloads.evict(bookRatingKey: entry.book.ratingKey)
            }
        }
        refresh()
    }
}

struct OfflineEntry: Identifiable {
    let book: BookRecord
    let state: BookDownloadState

    var id: String { book.ratingKey }
}
