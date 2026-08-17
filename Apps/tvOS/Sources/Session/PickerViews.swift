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
    @State private var error: String?

    var body: some View {
        VStack(spacing: 32) {
            Text("Choose a server").font(.system(size: 56, weight: .semibold))
            ForEach(servers) { server in
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
                    VStack(spacing: 4) {
                        Text(server.name).font(.title2)
                        Text(server.ownership)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minWidth: 420)
                }
            }
            Button("Sign out") { app.signOut() }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        }
        .padding(80)
    }
}

struct LibraryPickerView: View {
    let sections: [PlexLibrarySection]
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 32) {
            Text("Choose a library").font(.system(size: 56, weight: .semibold))
            // Anything that is not a music-type library was filtered out
            // already; audiobooks cannot live anywhere else.
            ForEach(sections) { section in
                Button {
                    guard let serverID = app.keychain.read(.serverIdentifier) else { return }
                    app.select(section: section, serverIdentifier: serverID)
                } label: {
                    Text(section.title).font(.title2).frame(minWidth: 420)
                }
            }
        }
        .padding(80)
    }
}
