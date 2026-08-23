import SwiftUI
import Audiobooks
import Platform
import PlatformShared

/// The bookmarks for whatever is playing, and a way to add one.
///
/// The bookmark button used to save silently: press it, get a brief "Saved", and
/// the only way to see what you had saved was to leave the player, find the
/// book, and open its screen. So the control that makes bookmarks and the place
/// that shows them were in different parts of the app.
///
/// One sheet, opened from the player, on every platform. The pieces differ where
/// the platform does — a television has no swipe-to-delete and a phone has no
/// hover — but the shape is the same list in the same order with the same button
/// at the top, because a bookmark is the same idea everywhere.
///
/// Ordered by position in the book rather than by when they were made: the
/// question is "where did I mark", and a list in book order can be read against
/// the scrubber.
struct PlayerBookmarksSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var bookmarks: [BookmarkRecord] = []
    @State private var renaming: BookmarkRecord?
    @State private var draftLabel = ""

    private var player: AudiobookPlayer { app.player }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        // Saved first, then offered a name.
                        //
                        // The bookmark exists either way — dismissing the
                        // prompt leaves it unlabelled, showing its timestamp,
                        // which is what an unnamed bookmark has always looked
                        // like. So this adds a chance to name it without
                        // making naming a step you have to complete.
                        if let created = app.addBookmark() {
                            renaming = created
                            draftLabel = ""
                        }
                        reload()
                    } label: {
                        Label(
                            "Bookmark \(Format.duration(ms: player.absoluteMs))",
                            systemImage: "bookmark.fill"
                        )
                    }
                }

                if bookmarks.isEmpty {
                    Text("No bookmarks in this book yet.")
                        .foregroundStyle(theme.secondaryText)
                } else {
                    Section("Saved") {
                        ForEach(bookmarks, id: \.id) { bookmark in
                            HStack(spacing: 8) {
                                Button {
                                    player.seek(toAbsoluteMs: bookmark.absoluteMs)
                                    dismiss()
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            // The label when there is one, the time
                                            // when there is not — an unlabelled
                                            // bookmark is still a place, and hiding
                                            // it behind "Untitled" says less than
                                            // the time it points at.
                                            Text(bookmark.label ?? Format.duration(ms: bookmark.absoluteMs))
                                                .lineLimit(1)
                                            if bookmark.label != nil {
                                                Text(Format.duration(ms: bookmark.absoluteMs))
                                                    .font(.caption.monospacedDigit())
                                                    .foregroundStyle(theme.secondaryText)
                                            }
                                        }
                                        Spacer()
                                    }
                                    .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                // A context menu rather than a swipe: a Mac has no
                                // swipe, and the same two actions belong on a
                                // right-click.
                                .contextMenu {
                                    Button(role: .destructive) {
                                        // Through `save(while:)`, as the book
                                        // screen's list does — a failed write says
                                        // so rather than appearing to work.
                                        app.save(while: "delete that bookmark") {
                                            try app.bookmarks.delete(id: bookmark.id)
                                        }
                                        // A tombstone, not a hole: this is what
                                        // carries the deletion off the device.
                                        // Without it the bookmark comes back from
                                        // whichever device still has it.
                                        app.syncToCloud()
                                        reload()
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    Button {
                                        renaming = bookmark
                                        draftLabel = bookmark.label ?? ""
                                    } label: {
                                        Label(bookmark.label == nil ? "Name" : "Rename",
                                              systemImage: "pencil")
                                    }
                                }

                                // A visible button as well as the context menu.
                                //
                                // The menu was the only way to name a bookmark,
                                // and a right-click is not a discoverable one —
                                // nothing on screen said naming existed, so as
                                // far as anybody using it was concerned, it did
                                // not. The Mac has no swipe actions to fall back
                                // on the way the phone does.
                                //
                                // Outside the seek button rather than inside it:
                                // a button nested in a button is one target on
                                // this platform, and it would be the wrong one.
                                Button {
                                    renaming = bookmark
                                    draftLabel = bookmark.label ?? ""
                                } label: {
                                    Image(systemName: "pencil")
                                        .foregroundStyle(theme.secondaryText)
                                }
                                .buttonStyle(.borderless)
                                .help(bookmark.label == nil ? "Name this bookmark" : "Rename")
                                .accessibilityLabel(
                                    bookmark.label == nil ? "Name this bookmark" : "Rename bookmark"
                                )
                            }
                        }
                    }
                }
            }
            .navigationTitle("Bookmarks")
            // Found in the same audit that added this to the iOS/iPadOS
            // sibling of this exact file, and to `BookDetailView`,
            // `PlayerView`, and the sign-in pickers on iOS: a `List` in its
            // own `NavigationStack`, presented as a sheet, with every color
            // already reading from `theme` except the background itself.
            .scrollContentBackground(.hidden)
            .background(theme.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert(renaming?.label == nil ? "Name this bookmark" : "Rename bookmark",
                   isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("Label", text: $draftLabel)
                Button("Save") {
                    if let renaming {
                        app.save(while: "rename that bookmark") {
                            try app.bookmarks.setLabel(draftLabel, id: renaming.id)
                        }
                        app.syncToCloud()
                    }
                    renaming = nil
                    reload()
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
        }
        .task { reload() }
        .onChange(of: app.bookmarkRevision) { _, _ in reload() }
    }

    private func reload() {
        guard let key = player.bookRatingKey else {
            bookmarks = []
            return
        }
        bookmarks = (try? app.bookmarks.bookmarks(bookRatingKey: key)) ?? []
    }
}
