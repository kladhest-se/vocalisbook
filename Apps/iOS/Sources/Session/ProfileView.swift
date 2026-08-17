import SwiftUI
import PlexKit
import PlatformShared

/// Who is signed in, and to what.
///
/// One place for the three things people look for when something is wrong: whose
/// account this is, which server it is talking to, and the way out. Signing out
/// lives here rather than in settings because it is an account action, not a
/// preference.
struct ProfileView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                AsyncImage(url: app.account?.thumb.flatMap(URL.init(string:))) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    default:
                        Circle().fill(theme.surface).overlay(
                            Image(systemName: "person.fill").foregroundStyle(theme.secondaryText)
                        )
                    }
                }
                .frame(width: 52, height: 52)
                .clipShape(.circle)

                VStack(alignment: .leading, spacing: 2) {
                    Text(app.account?.displayName ?? "Signed in")
                        .font(.headline)
                        .foregroundStyle(theme.text)
                    if let email = app.account?.email {
                        Text(email)
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                if let name = app.serverName {
                    LabeledContent("Server", value: name)
                }
                if let connection = app.connectionDescription {
                    LabeledContent("Connection", value: connection)
                }

                // What to do about it, where the fact is.
                //
                // "Relay (slow)" is accurate and useless on its own: the relay
                // is chosen only when *every* local address failed, and on this
                // platform the usual reason is Local Network permission — which
                // is asked for once, and denied for ever if that prompt was
                // dismissed. The app cannot ask again and cannot read the
                // answer, so the one thing it can do is say where the switch is.
                if app.isOnRelay {
                    Text("Every local address failed, so VocalisBook is going "
                         + "through Plex's relay — which is slower to start and "
                         + "to seek. If your server is on this network, check "
                         + "this device's Local Network permission for "
                         + "VocalisBook.")
                        .font(.footnote)
                        .foregroundStyle(theme.tertiaryText)
                }
                if let library = app.libraryName {
                    LabeledContent("Library", value: library)
                }
            }
            .font(.callout)
            .foregroundStyle(theme.secondaryText)

            Divider()

            Button("Sign out", role: .destructive) { app.signOut() }

            Text("VocalisBook is an independent client and is not affiliated with Plex Inc.")
                .font(.caption2)
                .foregroundStyle(theme.tertiaryText)
        }
        .padding(18)
        .task { await app.loadAccount() }
    }
}
