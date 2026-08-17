import SwiftUI
import AppKit
import PlexKit
import PlatformShared

/// What a server picker has to say.
///
/// Two facts: what it is called, and whose it is. Everything else was noise or
/// worse — it claimed "On this network" from
/// `connections.contains(where: \.local)`, and Plex sets `local` on a connection
/// whose *address* is a private one, as the server sees itself. Every server has
/// one of those, including a friend's sitting on their own LAN, so the badge was
/// true for everything and meant nothing.
///
/// There is no honest way to answer it from this list either. Whether a server is
/// reachable on this network is something the connection racer finds out by
/// trying, and it says so afterwards — the account popup shows "On this network"
/// from the connection that actually resolved, which is the same words meaning
/// something.
/// The first thing anybody sees, and it looked like a debug screen.
///
/// A bare `List` inside a `VStack` on a window with no other content: rows with
/// no inset, a title with no weight behind it, and an app whose own name and
/// icon appeared nowhere. These are the two screens between signing in and using
/// the app, and they were the least finished in it.
///
/// The icon comes from the bundle rather than a new asset. It is already there,
/// it is already the right thing, and a second copy would be one more file to
/// keep in step.
struct PickerChrome<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                if let icon = NSImage(named: "AppIcon") {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 72, height: 72)
                        .clipShape(.rect(cornerRadius: 16))
                        .shadow(radius: 8, y: 2)
                }

                Text(AppIdentity.name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.text)

                Text(title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(theme.text)

                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 48)
            .padding(.bottom, 28)

            ScrollView {
                VStack(spacing: 10) {
                    content
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
    }
}

/// One choice, as a card rather than a table row.
struct PickerRow: View {
    let title: String
    let detail: String
    let systemImage: String
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(theme.accent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(theme.text)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.tertiaryText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(hovering ? theme.accent.opacity(0.12) : theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(theme.track, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct ServerPickerView: View {
    let servers: [PlexResource]
    @Environment(AppModel.self) private var app
    @State private var error: String?

    var body: some View {
        PickerChrome(
            title: "Choose a server",
            subtitle: "Where your audiobooks live."
        ) {
            ForEach(servers) { server in
                PickerRow(
                    title: server.name,
                    detail: server.ownership,
                    systemImage: "server.rack"
                ) {
                    Task {
                        do { try await app.select(server: server) }
                        // The explanation, not only the description: a server
                        // that cannot be reached is where local network
                        // permission shows up, and "none of the addresses
                        // answered" does not lead anybody to Settings.
                        catch { self.error = error.plexExplanation }
                    }
                }
            }

            Button("Sign out") { app.signOut() }
                .buttonStyle(.link)
                .padding(.top, 12)
        }
        .alert("Couldn't connect", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }
}

struct LibraryPickerView: View {
    let sections: [PlexLibrarySection]
    @Environment(AppModel.self) private var app

    var body: some View {
        // Anything that is not a music-type library has already been filtered
        // out; audiobooks cannot live anywhere else.
        PickerChrome(
            title: "Choose a library",
            subtitle: "Which one holds your audiobooks."
        ) {
            ForEach(sections) { section in
                PickerRow(
                    title: section.title,
                    detail: "",
                    systemImage: "books.vertical"
                ) {
                    guard let serverID = app.keychain.read(.serverIdentifier) else { return }
                    try? app.select(section: section, serverIdentifier: serverID)
                }
            }
        }
    }
}
