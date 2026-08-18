import SwiftUI
import Platform
import PlatformShared

/// Settings, for a remote.
///
/// A tvOS `Form` is unusable at focus distance, so this is a plain list of large
/// rows that each open a full-screen chooser. Nothing here is typed and nothing
/// is a slider.
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
        let common = "Everything cached on this Apple TV: the library and your "
            + "listening state. Fetched again from Plex"
        return app.iCloudSyncEnabled ? common + " and iCloud." : common + "."
    }

    private var resetConfirmationWithCloud: String {
        "Your library and listening state are removed from this Apple TV, then "
            + "fetched again from Plex and iCloud. Your other devices are not "
            + "affected."
    }

    private var resetConfirmationWithoutCloud: String {
        "Your library and listening state are removed from this Apple TV and "
            + "fetched again from Plex. Anything only this device knew is lost."
    }
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Settings").font(.system(size: 56, weight: .semibold))

                    SettingsRow(
                        title: "Account",
                        value: app.account?.displayName ?? "Signed in",
                        detail: "Server, library and sign out"
                    ) {
                        ProfileView()
                    }

                    SettingsRow(
                        title: "Theme",
                        value: app.themes.selection.title,
                        detail: app.themes.selection.subtitle
                    ) {
                        ThemeChooser()
                    }

                    SettingsRow(
                        title: "Skip interval",
                        value: "\(app.player.skipIntervalSeconds) seconds",
                        detail: "How far the skip buttons move"
                    ) {
                        SkipIntervalChooser()
                    }

                    SettingsRow(
                        title: "Default speed",
                        value: String(format: "%g×", app.defaultRate),
                        detail: "Used for books you have not set a speed for"
                    ) {
                        SpeedChooser()
                    }

                    // The app icon is not here on purpose.
                    //
                    // tvOS has no alternate icon API — `setAlternateIconName`
                    // does not exist, because a tvOS icon is a layered stack the
                    // system parallaxes and cannot swap at runtime. A picker
                    // here would be a control that does nothing.

                    VStack(alignment: .leading, spacing: 6) {
                        Text("iCloud").font(.headline)
                        Text("Keeps your place, bookmarks, history and per-book "
                             + "speed the same on your other devices. Your place "
                             + "also syncs through Plex, with or without this.")
                            .font(.caption)
                            .foregroundStyle(theme.tertiaryText)
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
                        .padding(.top, 4)

                        // What it has actually done: sync fails quietly, so
                        // "not working" and "nothing to send" look the same.
                        if let status = app.cloudStatus {
                            Text(status.isRunning
                                 ? "Running · sent \(status.pushed) · received \(status.fetched)"
                                 : "Not started")
                                .font(.caption)
                                .foregroundStyle(theme.tertiaryText)
                            if let error = status.lastError {
                                Text(error).font(.caption).foregroundStyle(.red)
                            }
                        }
                    }

                    // Storage, above About.
                    //
                    // A button and a sentence rather than a section: this screen
                    // is a stack of headed groups, not a Form.
                    // One group with both, headed once. The labels tell them
                    // apart; two headings for one question did not.
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Data").font(.headline)
                        Text(app.iCloudSyncEnabled
                             ? "Your listening history on this Apple TV and in iCloud: what you "
                               + "were listening to, bookmarks and streaks. The library is "
                               + "kept."
                             : "Your listening history on this Apple TV: what you were listening "
                               + "to, bookmarks and streaks. The library is kept, and your "
                               + "other devices keep theirs.")
                            .font(.caption)
                            .foregroundStyle(theme.tertiaryText)
                        Button("Clear listening history") { confirmingClear = true }
                            .padding(.top, 4)

                        Text(resetExplanation)
                            .font(.caption)
                            .foregroundStyle(theme.tertiaryText)
                            .padding(.top, 12)
                        Button("Clear local cache") { confirmingReset = true }
                            .padding(.top, 4)
                    }

                    // About, at the foot of Settings — a television has no About
                    // panel either, and no way to open a link, so the address is
                    // there to be read and typed somewhere else.
                    VStack(alignment: .leading, spacing: 6) {
                        Text("About").font(.headline)
                        Text("\(AppIdentity.name) \(AppIdentity.versionAndBuild)")
                        Text("By \(AppIdentity.author)")
                        Text(AppIdentity.repository.absoluteString)
                        Text(AppIdentity.contactEmail)
                        Text(AppIdentity.disclaimer)
                            .font(.caption)
                            .foregroundStyle(theme.tertiaryText)
                            .padding(.top, 8)
                    }
                    .foregroundStyle(theme.secondaryText)
                    .padding(.top, 40)
                }
                .padding(.vertical, 40)
            }
        }
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
            Text("Your library is kept. Opening a book still picks up where Plex "
                 + "says you were.")
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
    }
}

/// Text colours for a focused row.
///
/// tvOS paints a focused `.plain` button's background white and leaves the label
/// alone, so every theme with light text put white on white — the row somebody
/// had just selected was the one they could not read.
///
/// Dark rather than themed, because the focus background is the system's and is
/// light under every theme. A themed colour here would be right for some and
/// invisible for the rest, which is the bug being fixed.
///
/// Its own type rather than statics on `SettingsRow`, which is generic over its
/// destination: Swift has no static stored properties in a generic type, and
/// a static read through it gives the compiler nothing to infer the parameter
/// from. Two views need these anyway, so they belong to neither.
enum FocusedRow {
    static let text = Color(white: 0.08)
    static let dimText = Color(white: 0.08).opacity(0.72)
}

struct SettingsRow<Destination: View>: View {
    let title: String
    let value: String
    let detail: String
    @ViewBuilder var destination: Destination

    @Environment(\.theme) private var theme
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationLink {
            destination
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title3)
                        .foregroundStyle(isFocused ? FocusedRow.text : theme.text)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(isFocused ? FocusedRow.dimText : theme.secondaryText)
                }
                Spacer()
                Text(value)
                    .foregroundStyle(isFocused ? FocusedRow.dimText : theme.accent)
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .focused($isFocused)
    }


}

struct ThemeChooser: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    /// Which row has focus, so its text can be readable against the system's
    /// white focus background. `@FocusState` on a value rather than a `Bool`,
    /// because there is one of these for the whole list.
    @FocusState private var focusedOption: ThemeSelection?
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("Theme").font(.system(size: 48, weight: .semibold))
                // One list. "Match system" and the after-dark switch are entries
                // in it rather than a separate mode.
                ForEach(ThemeSelection.all, id: \.self) { option in
                    Button {
                        app.themes.selection = option
                        dismiss()
                    } label: {
                        HStack(spacing: 16) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(option.previewTheme.accent)
                                .frame(width: 44, height: 28)
                            VStack(alignment: .leading) {
                                Text(option.title)
                                    .foregroundStyle(
                                        focusedOption == option ? FocusedRow.text : theme.text
                                    )
                                Text(option.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(
                                        focusedOption == option
                                            ? FocusedRow.dimText : theme.secondaryText
                                    )
                            }
                            Spacer()
                            if option == app.themes.selection {
                                // The tick, in a colour that survives the focus
                                // background: an accent chosen to sit on a dark
                                // theme disappears on white.
                                Image(systemName: "checkmark")
                                    .foregroundStyle(
                                        focusedOption == option ? FocusedRow.text : theme.accent
                                    )
                            }
                        }
                        .frame(maxWidth: 700)
                        .padding(.vertical, 8)
                    }
                    // Without this, tvOS applies its default button style, which
                    // fills every row with the *current* theme's accent. Eight
                    // rows all filled read as eight selections, and the tick
                    // marking the real one is then accent on accent — invisible.
                    // `SettingsRow` is plain for the same reason; these rows sit
                    // one screen away from those and should look like them.
                    //
                    // Not a rule for the whole app: the player's transport and
                    // the sign-in pickers want the filled style, because there
                    // a button should look like a button.
                    .buttonStyle(.plain)
                    .focused($focusedOption, equals: option)
                }
            }
            .padding(.vertical, 40)
        }
    }
}

struct SkipIntervalChooser: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Skip interval").font(.system(size: 48, weight: .semibold))
            // Only the intervals SF Symbols ships an icon for; anything else
            // renders as a blank button in the player.
            ForEach([10, 15, 30, 45, 60], id: \.self) { seconds in
                Button("\(seconds) seconds") {
                    app.setSkipInterval(seconds)
                    dismiss()
                }
            }
        }
        .padding(60)
    }
}

struct SpeedChooser: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Default speed").font(.system(size: 48, weight: .semibold))
            ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0] as [Float], id: \.self) { rate in
                Button(String(format: "%g×", rate)) {
                    app.defaultRate = rate
                    dismiss()
                }
            }
        }
        .padding(60)
    }
}
