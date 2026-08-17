import SwiftUI
import Audiobooks
import Platform
import PlatformShared

/// Bookmarks for a book.
///
/// Only where the local store is durable. On tvOS the database is a cache the
/// system may purge between launches, so a bookmark made there would quietly
/// vanish — `PlatformCapabilities.localStoreIsDurable` is what decides, and this
/// screen does not exist in that port. It becomes possible there once the
/// CloudKit sync engine does.
struct BookmarksList: View {
    let ratingKey: String
    let onSeek: (Int) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var bookmarks: [BookmarkRecord] = []
    @State private var renaming: BookmarkRecord?
    @State private var draftLabel = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !bookmarks.isEmpty {
                Text("Bookmarks")
                    .font(.headline)
                    .foregroundStyle(theme.text)
            }

            ForEach(bookmarks, id: \.id) { bookmark in
                Button {
                    onSeek(bookmark.absoluteMs)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "bookmark.fill")
                            .font(.caption)
                            .foregroundStyle(theme.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(bookmark.label ?? "Bookmark")
                                .foregroundStyle(theme.text)
                                .lineLimit(1)
                            Text(Format.duration(ms: bookmark.absoluteMs))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(theme.secondaryText)
                        }
                        Spacer()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Rename") {
                        renaming = bookmark
                        draftLabel = bookmark.label ?? ""
                    }
                    Button("Delete", role: .destructive) {
                        app.save(while: "delete that bookmark") {
                            try app.bookmarks.delete(id: bookmark.id)
                        }
                        // A tombstone, not a hole: `delete` sets `deletedAt` and
                        // bumps the revision, so the deletion is a change like
                        // any other. This is what carries it off the device —
                        // without it the bookmark comes back from whichever
                        // device still has it.
                        app.syncToCloud()
                        reload()
                    }
                }
                Divider()
            }
        }
        .task { reload() }
        .onChange(of: app.bookmarkRevision) { _, _ in reload() }
        .alert("Rename bookmark", isPresented: .constant(renaming != nil)) {
            TextField("Label", text: $draftLabel)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let renaming {
                    app.save(while: "rename that bookmark") {
                        try app.bookmarks.setLabel(draftLabel, id: renaming.id)
                    }
                }
                renaming = nil
                reload()
            }
        }
    }

    private func reload() {
        bookmarks = (try? app.bookmarks.bookmarks(bookRatingKey: ratingKey)) ?? []
    }
}
