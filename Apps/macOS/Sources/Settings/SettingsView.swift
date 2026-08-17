import SwiftUI
import Platform
import PlatformShared

/// The Settings window, reached with ⌘, like every other Mac app.
struct SettingsView: View {
    @State private var confirmingClear = false
    @State private var confirmingReset = false

    /// Built outside the view.
    ///
    /// A concatenation with a ternary inside it is one expression the type
    /// checker solves in a single go, and inside a section inside a form it gave
    /// up on the phone: "unable to type-check this expression in reasonable
    /// time". Nothing is wrong with the string; view builders are simply where
    /// this is most expensive.
    private var resetExplanation: String {
        let common = "Everything cached on this Mac: the library, downloads "
            + "and listening state. Fetched again from Plex"
        return app.iCloudSyncEnabled ? common + " and iCloud." : common + "."
    }

    private var resetConfirmationWithCloud: String {
        "Your library, downloads and listening state are removed from this Mac, "
            + "then fetched again from Plex and iCloud. Your other devices are "
            + "not affected."
    }

    private var resetConfirmationWithoutCloud: String {
        "Your library, downloads and listening state are removed from this Mac "
            + "and fetched again from Plex. Anything only this Mac knew is lost."
    }
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var themes = app.themes
        @Bindable var menuBar = app.menuBar

        Form {
            Section("Appearance") {
                // One control. "Match system" and the after-dark switch are
                // entries in the same list rather than a separate mode, so
                // there is one decision to make and nothing that can be set to
                // something with no effect.
                Picker("Theme", selection: $themes.selection) {
                    ForEach(ThemeSelection.all, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }

                Text(themes.selection.subtitle)
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
            }

            Section("Menu bar") {
                Picker("Icon", selection: $menuBar.style) {
                    Text("Monochrome").tag(MenuBarStyle.monochrome)
                    Text("Colour").tag(MenuBarStyle.colour)
                }
                .pickerStyle(.inline)

                // Also in the menu bar popup, which is the menu somebody is
                // already in when they want the window in front of everything
                // else — or out of the way.
                Toggle("Always on top", isOn: $menuBar.floatsAboveOtherApps)
                Text("Keeps the window above other apps, for following a book "
                     + "while you work in something else.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Toggle("Keep running when the window closes", isOn: $menuBar.staysResident)
                Text(menuBar.staysResident
                     ? "Closing the window leaves VocalisBook in the menu bar and playback continues."
                     : "Closing the window quits VocalisBook and stops playback.")
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
            }

            if PlatformCapabilities.supportsOfflineDownloads {
                Section("iCloud") {
                    // Said, not hidden.
                    //
                    // Sync being off because a previous launch died inside it is exactly
                    // the situation somebody needs told about — an app that quietly stops
                    // syncing is the complaint this whole area began with.
                    if app.cloudHeldBackAfterCrash {
                        Text("Sync was skipped this time because the last attempt did not "
                             + "finish. Your library and downloads are unaffected.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Try iCloud again") { app.retryCloudAfterCrash() }
                    }

                    Toggle("Sync with iCloud", isOn: Binding(
                        get: { app.iCloudSyncEnabled },
                        set: { app.iCloudSyncEnabled = $0 }
                    ))
                    Text("Keeps your place, bookmarks, history and per-book speed "
                         + "the same on your other devices. Your place also syncs "
                         + "through Plex, with or without this.")
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryText)
                    // What it has actually done.
                    //
                    // Sync fails quietly by design, so "not working" and
                    // "working, nothing to send" look the same from outside.
                    // This is the difference, and it is the first thing to look
                    // at when two devices disagree.
                    if let status = app.cloudStatus {
                        LabeledContent("Status") {
                            Text(status.isRunning ? "Running" : "Not started")
                        }
                        LabeledContent("Sent", value: "\(status.pushed)")
                        LabeledContent("Received", value: "\(status.fetched)")
                        if let error = status.lastError {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    } else if app.iCloudSyncEnabled {
                        Text("Not started — no iCloud account on this device, or "
                             + "it has not connected yet.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                // Above Downloads, so the destructive one is not the thing a
                // finger lands on next to "Remove finished books".
                // One button. Local always, iCloud too when this Mac syncs —
                // because if it syncs, the cloud copy *is* its state.
                // Both in one section, and named as a pair. Two headings for
                // one question — what do you want thrown away — where the labels
                // are what tell them apart, not the headings.
                Section("Data") {
                    Button("Clear Listening History…") { confirmingClear = true }
                    Text(app.iCloudSyncEnabled
                         ? "Your listening history on this Mac and in iCloud: what you "
                           + "were listening to, bookmarks and streaks. The library is "
                           + "kept."
                         : "Your listening history on this Mac: what you were listening "
                           + "to, bookmarks and streaks. The library is kept, and your "
                           + "other devices keep theirs.")
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryText)

                    Button("Clear Local Cache…") { confirmingReset = true }
                    Text(resetExplanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Downloads") {
                    LabeledContent(
                        "On this Mac",
                        value: ByteCountFormatter.string(
                            fromByteCount: Int64((try? app.downloadStore.totalBytes()) ?? 0),
                            countStyle: .file
                        )
                    )
                    // Points at the screen rather than describing a workaround.
                    // This said "remove a download from the book itself" because
                    // that was the only way; there is a Downloads item in the
                    // sidebar now.
                    Text("See and remove downloads under Downloads in the sidebar.")
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryText)
                    Button("Remove finished books") {
                        // One report for the action rather than one per book:
                        // somebody who pressed this is asking about the outcome
                        // of the whole thing, not the last file in the loop.
                        app.save(while: "remove those downloads") {
                            for key in try app.downloadStore.evictableFinished() {
                                try app.downloads.evict(bookRatingKey: key)
                            }
                        }
                    }
                }
            }

            Section("Playback") {
                Picker("Skip interval", selection: Binding(
                    get: { app.player.skipIntervalSeconds },
                    set: { app.setSkipInterval($0) }
                )) {
                    // Only the intervals SF Symbols ships an icon for. Anything
                    // else renders as a blank button in the transport bar.
                    ForEach([10, 15, 30, 45, 60], id: \.self) { seconds in
                        Text("\(seconds) seconds").tag(seconds)
                    }
                }

                Picker("Default speed", selection: Binding(
                    get: { app.defaultRate },
                    set: { app.defaultRate = $0 }
                )) {
                    ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0] as [Float], id: \.self) { rate in
                        Text(Format.speed(rate)).tag(rate)
                    }
                }
            }
        }
        .formStyle(.grouped)
        // Polled while this screen is open, not read once on appear.
        //
        // Somebody watching this line is watching it *because* they are testing
        // whether a push happens — and a number that only updates when you leave
        // and come back is one that says nothing at the moment it matters.
        .task {
            while !Task.isCancelled {
                await app.refreshCloudStatus()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .confirmationDialog(
            "Clear listening history?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) { app.clearListeningHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your library and downloads are kept. Opening a book still picks "
                 + "up where Plex says you were.")
        }
        .confirmationDialog(
            "Clear local cache?",
            isPresented: $confirmingReset,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { app.clearAllLocalData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(app.iCloudSyncEnabled
                 ? resetConfirmationWithCloud
                 : resetConfirmationWithoutCloud)
        }
        // Fills whatever the window is, rather than sitting at 460 in the
        // middle of it. The window's size is set where the scene is declared,
        // which is the only place a `Settings` scene can be sized from — a
        // frame in here left the window free to grow to its content and the
        // content marooned in the middle of it.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
