import SwiftUI
import Platform
import PlatformShared

struct SettingsView: View {
    @State private var confirmingClear = false
    @State private var confirmingReset = false

    /// Built here rather than inside the view.
    ///
    /// Five concatenations with a ternary inside them is one expression the type
    /// checker has to solve in a single go, and inside a `Section` inside a
    /// `Form` it gave up: "unable to type-check this expression in reasonable
    /// time". Nothing was wrong with it — string concatenation in a view body is
    /// simply the thing SwiftUI is worst at.
    ///
    /// A computed property is checked on its own, where the surrounding view
    /// builder is not part of the problem.
    /// Also built outside the view, for the reason `resetExplanation` gives.
    ///
    /// This one has the ternary outermost rather than buried in a concatenation,
    /// which is the shape that has always compiled here — but it sits in a
    /// message closure inside a dialog inside a form, and that is the same stack
    /// of builders that defeated the other one.
    private var resetConfirmation: String {
        let removed = "Your library, downloads and listening state are removed "
            + "from this device"

        if app.iCloudSyncEnabled {
            return removed + ", then fetched again from Plex and iCloud. Your "
                + "other devices are not affected."
        }
        return removed + " and fetched again from Plex. Anything only this "
            + "device knew is lost."
    }

    private var resetExplanation: String {
        let common = "Everything cached on this device: the library, your "
            + "downloads, and your listening state. The library is fetched "
            + "again from Plex"

        if app.iCloudSyncEnabled {
            return common + " and your listening state from iCloud."
        }
        return common + ". Your listening state is not in iCloud, so it will "
            + "be taken from Plex where Plex knows it."
    }
    /// Shown as a sheet from the toolbar rather than as a tab, so it needs a way
    /// out. The parameter exists because the same view is a tab on the Apple TV,
    /// where a Done button would be a dead control.
    var showsDoneButton = false

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var themes = app.themes

        NavigationStack {
            List {
                Section("Appearance") {
                    // One control. "Match system" and the after-dark switch are
                    // entries in the same list rather than a separate mode.
                    NavigationLink {
                        ThemePicker(selection: $themes.selection)
                    } label: {
                        LabeledContent("Theme", value: themes.selection.title)
                    }

                    Text(themes.selection.subtitle)
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryText)
                }

                if AppIconStore.isSupported {
                    Section("App icon") {
                        AppIconPicker()
                    }
                }

                Section("Playback") {
                    Picker("Skip interval", selection: Binding(
                        get: { app.player.skipIntervalSeconds },
                        set: { app.setSkipInterval($0) }
                    )) {
                        // Only the intervals SF Symbols actually ships an icon
                        // for. Anything else renders as a blank button.
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

                if PlatformCapabilities.supportsOfflineDownloads {
                    Section("Downloads") {
                        // Says when it applies, because it cannot apply now.
                        //
                        // A background URLSession reads its configuration once,
                        // when the session is made, and the session is made at
                        // launch. A toggle that quietly did nothing until the
                        // next launch would be worse than one that says so.
                        Toggle(
                            "Download over cellular",
                            isOn: Binding(
                                get: { AppModel.allowsExpensiveDownloads },
                                set: { AppModel.allowsExpensiveDownloads = $0 }
                            )
                        )

                        Text(AppModel.allowsExpensiveDownloads
                             ? "New downloads may use cellular. Takes effect next time the app starts."
                             : "Downloads wait for Wi-Fi. The system holds them rather than failing them.")
                            .font(.footnote)
                            .foregroundStyle(theme.tertiaryText)

                        // The full picture — every book, sizes, remove one or
                        // all, transfers in progress — is a level down rather
                        // than repeated here. `StorageRow` keeps the total and
                        // the one shortcut worth having inline: clearing what
                        // is already finished. "What is taking up twelve
                        // gigabytes" is a glance; managing it is a task, and a
                        // task earns its own screen.
                        //
                        // A quicker glance at what is downloaded, without the
                        // management, lives in Browse now — a toggle beside
                        // search rather than a trip through here.
                        StorageRow()
                        NavigationLink("Manage Downloads") {
                            OfflineView()
                        }
                    }
                }

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
                        .foregroundStyle(.secondary)
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

                // Below Downloads and above About, which is where a thing you
                // press once in a year and want to find quickly belongs.
                // One button. Local always, iCloud too when this device syncs
                // — because if it syncs, the cloud copy *is* its state, and
                // clearing one without the other only means waiting a few
                // seconds for it to come back.
                // Both in one section, and named as a pair.
                //
                // They were "History data" and "Local data", one button each,
                // which is two headings for what is one question: what do you
                // want thrown away. The earlier reasoning was that separating
                // them stops the wrong one being pressed — but the label is what
                // stops that, and "History data" did not say what it would do
                // while "Local data" did not say what it would keep.
                //
                // The descriptions still distinguish them, because they are
                // genuinely different: one throws away the original, the other
                // throws away a copy that comes back.
                Section("Data") {
                    Button("Clear listening history", role: .destructive) {
                        confirmingClear = true
                    }
                    Text(app.iCloudSyncEnabled
                         ? "Your listening history on this device and in iCloud: what you "
                           + "were listening to, bookmarks and streaks. The library is "
                           + "kept."
                         : "Your listening history on this device: what you were listening "
                           + "to, bookmarks and streaks. The library is kept, and your "
                           + "other devices keep theirs.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button("Clear local cache", role: .destructive) {
                        confirmingReset = true
                    }
                    Text(resetExplanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                // About, where a phone keeps it: the foot of Settings, since
                // there is no About panel on iOS to put it in.
                Section("About") {
                    LabeledContent("Version", value: AppIdentity.versionAndBuild)
                    LabeledContent("By", value: AppIdentity.author)
                    Link(destination: AppIdentity.repository) {
                        LabeledContent("Source", value: "github.com/kladhest-se/vocalisbook")
                    }

                    Text(AppIdentity.disclaimer)
                        .font(.footnote)
                        .foregroundStyle(theme.tertiaryText)
                }
            }
            .navigationTitle("Settings")
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
            // A confirmation, because this cannot be undone from inside the app
            // — and the message says what comes back, since "clear local data"
            // sounds like losing your place forever and mostly is not.
            .confirmationDialog(
                "Clear listening history?",
                isPresented: $confirmingClear,
                titleVisibility: .visible
            ) {
                Button("Clear", role: .destructive) { app.clearListeningHistory() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("What you were listening to is cleared. Opening a book "
                     + "still picks up where Plex says you were. Downloads are "
                     + "kept.")
            }
            .confirmationDialog(
                "Clear local cache?",
                isPresented: $confirmingReset,
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) { app.clearAllLocalData() }
                Button("Cancel", role: .cancel) {}
            } message: {
                // Says what goes and what comes back, in that order, because the
                // second half is what makes the first half safe to press.
                Text(resetConfirmation)
            }
            // No `accountToolbar` here any more: this *is* reached from that
            // toolbar now, and an account button inside the sheet it opened
            // would be a loop.
            .toolbar {
                if showsDoneButton {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.background.ignoresSafeArea())
        }
    }
}

/// Themes as swatches rather than a list of names.
///
/// The names mean nothing until you have seen them, and a colour scheme is the
/// one setting where the preview *is* the description.
struct ThemePicker: View {
    @Binding var selection: ThemeSelection
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 14)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
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
            .padding(16)
        }
        .navigationTitle("Theme")
        .navigationBarTitleDisplayMode(.inline)
        .background(theme.background.ignoresSafeArea())
    }
}

struct ThemeSwatch: View {
    let option: ThemeSelection
    let isSelected: Bool

    /// The automatic entries preview what they will most often look like rather
    /// than showing an empty tile.
    private var theme: Theme { option.previewTheme }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // A miniature of the thing it will actually look like: page,
            // surface, text, accent, in the proportions they appear on screen.
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(theme.text)
                    .frame(width: 60, height: 6)
                RoundedRectangle(cornerRadius: 3)
                    .fill(theme.secondaryText)
                    .frame(width: 40, height: 5)
                Spacer(minLength: 0)
                Capsule()
                    .fill(theme.accent)
                    .frame(height: 14)
            }
            .padding(10)
            .frame(height: 74)
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
                            .foregroundStyle(theme.accent)
                    }
                }
                Text(option.subtitle)
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(2, reservesSpace: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.background.ignoresSafeArea())
        }
        .clipShape(.rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? theme.accent : .clear, lineWidth: 2)
        )
    }
}


/// Picking an app icon.
///
/// Shown as artwork for the same reason themes are: the names are meaningless
/// until you have seen them. iOS puts up its own alert confirming the change,
/// which cannot be suppressed — so the row does not also announce it.
struct AppIconPicker: View {
    @Environment(\.theme) private var theme
    @State private var current = AppIconStore.current
    @State private var failure: String?

    var body: some View {
        HStack(spacing: 14) {
            ForEach(AppIcon.allCases, id: \.self) { icon in
                Button {
                    Task { await select(icon) }
                } label: {
                    VStack(spacing: 6) {
                        Image(icon.previewAssetName)
                            .resizable()
                            .frame(width: 54, height: 54)
                            .clipShape(.rect(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(icon == current ? theme.accent : .clear, lineWidth: 2)
                            )
                        Text(icon.title)
                            .font(.caption2)
                            .foregroundStyle(icon == current ? theme.text : theme.secondaryText)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)

        if let failure {
            Text(failure).font(.footnote).foregroundStyle(.red)
        }
    }

    private func select(_ icon: AppIcon) async {
        do {
            try await AppIconStore.set(icon)
            current = AppIconStore.current
            failure = nil
        } catch {
            // Almost always a name that does not match the build setting.
            // Saying so beats leaving the old icon and looking broken.
            failure = error.plexExplanation
        }
    }
}

/// What downloads are taking up, and the one action worth offering.
///
/// Finished books are the obvious thing to clear: they are the largest files
/// nobody is going to open again. Everything else is per-book, on the book, where
/// the decision has context.
struct StorageRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var bytes = 0
    @State private var finished: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent(
                "On this device",
                value: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            )

            if !finished.isEmpty {
                Button("Remove \(finished.count) finished book\(finished.count == 1 ? "" : "s")") {
                    app.save(while: "remove those downloads") {
                        for key in finished {
                            try app.downloads.evict(bookRatingKey: key)
                        }
                    }
                    refresh()
                }
                .foregroundStyle(theme.accent)
            }
        }
        .task { refresh() }
        .onChange(of: app.downloads.revision) { _, _ in refresh() }
    }

    private func refresh() {
        bytes = (try? app.downloadStore.totalBytes()) ?? 0
        finished = (try? app.downloadStore.evictableFinished()) ?? []
    }
}
