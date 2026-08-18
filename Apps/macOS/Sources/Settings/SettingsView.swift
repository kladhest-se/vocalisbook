import SwiftUI
import Platform
import PlatformShared

/// The Settings window, reached with ⌘, like every other Mac app.
struct SettingsView: View {
    @State private var confirmingClear = false
    @State private var confirmingReset = false
    @State private var showingThemePicker = false

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
                // A swatch grid in a popover, matching iOS and tvOS, rather
                // than the plain dropdown this used to be. The names meant
                // nothing until seen — "Ink" and "Ember" said nothing about
                // which was dark and which was warm — and a colour scheme is
                // the one setting where the preview actually is the
                // description, on every platform this app has, not just two
                // of the three.
                Button {
                    showingThemePicker = true
                } label: {
                    HStack {
                        Text("Theme")
                        Spacer()
                        Text(themes.selection.title)
                            .foregroundStyle(theme.secondaryText)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingThemePicker, arrowEdge: .trailing) {
                    ThemePicker(selection: $themes.selection)
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

/// Themes as swatches in a popover, matching the grid iOS and tvOS both
/// already use for the same screen.
///
/// A popover rather than a pushed screen: this Mac app's Settings is a
/// single `Form` window, not a navigation stack with somewhere to push to,
/// and a popover is the native way to offer more than a `Form` row holds
/// without leaving Settings.
struct ThemePicker: View {
    @Binding var selection: ThemeSelection
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(ThemeSelection.all, id: \.self) { candidate in
                    Button {
                        selection = candidate
                        dismiss()
                    } label: {
                        ThemeSwatch(option: candidate, isSelected: candidate == selection)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
        }
        .frame(width: 420, height: 360)
        .background(theme.background)
    }
}

/// One theme, previewed at roughly the proportions it appears on screen:
/// page, surface, text, accent — not a name that means nothing until it has
/// been tried.
///
/// A macOS-sized copy of iOS's own `ThemeSwatch` rather than a shared type —
/// the two apps' `SettingsView.swift` are separate targets, and this one
/// sits in a fixed-size popover rather than filling a phone screen, which
/// wants smaller tiles than iOS's own 150–220pt range in exchange for
/// showing more of the grid without scrolling.
struct ThemeSwatch: View {
    let option: ThemeSelection
    let isSelected: Bool

    /// The automatic entries preview what they will most often look like
    /// rather than showing an empty tile.
    private var theme: Theme { option.previewTheme }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(theme.text)
                    .frame(width: 50, height: 5)
                RoundedRectangle(cornerRadius: 3)
                    .fill(theme.secondaryText)
                    .frame(width: 34, height: 4)
                Spacer(minLength: 0)
                Capsule()
                    .fill(theme.accent)
                    .frame(height: 12)
            }
            .padding(8)
            .frame(height: 62)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(option.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(theme.text)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(theme.accent)
                    }
                }
                Text(option.subtitle)
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(2, reservesSpace: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.background)
        }
        .clipShape(.rect(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? theme.accent : .clear, lineWidth: 2)
        )
    }
}
