import SwiftUI
import PlexKit

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
struct ServerPickerView: View {
    let servers: [PlexResource]
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List(servers) { server in
                Button {
                    Task {
                        do { try await app.select(server: server) }
                        // The explanation, not only the description: a server
                        // that cannot be reached is where local network
                        // permission shows up, and "none of the addresses
                        // answered" does not lead anybody to Settings.
                        catch { self.error = error.plexExplanation }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(server.name)
                        Text(server.ownership)
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                    }
                }
            }
            .navigationTitle("Choose a server")
            // Found in the same pass that added this to `BookDetailView`,
            // `PlayerView` and `PlayerBookmarksSheet` — a sign-in screen with
            // no theme awareness at all, not just a missing background: text
            // read `.secondary`, a system color, rather than anything from
            // `theme`. Both fixed together rather than leaving the color
            // half of the same gap in place.
            .scrollContentBackground(.hidden)
            .background(theme.background.ignoresSafeArea())
            .toolbar {
                Button("Sign out") { app.signOut() }
            }
            .alert("Couldn't connect", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
    }
}

struct LibraryPickerView: View {
    let sections: [PlexLibrarySection]
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            List(sections) { section in
                Button {
                    guard let serverID = app.keychain.read(.serverIdentifier) else { return }
                    app.select(section: section, serverIdentifier: serverID)
                } label: {
                    Label(section.title, systemImage: "books.vertical")
                }
            }
            .navigationTitle("Choose a library")
            // Audiobooks live in a music-type library, so anything else has
            // already been filtered out before this screen is shown.
            .listStyle(.insetGrouped)
            // Same gap as its sibling above, fixed the same way.
            .scrollContentBackground(.hidden)
            .background(theme.background.ignoresSafeArea())
        }
    }
}
