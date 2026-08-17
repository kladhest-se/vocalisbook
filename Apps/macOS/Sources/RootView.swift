import SwiftUI
import PlexKit
import Platform
import PlatformShared

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            switch app.phase {
            case .launching:
                ProgressView("Connecting…")
            case .signedOut:
                SignInView()
            case .choosingServer:
                ServerPickerView(servers: app.servers)
            case .choosingLibrary:
                LibraryPickerView(sections: app.sections)
            case .ready:
                // The layout follows the window, not a saved mode. Drag it
                // narrow and it becomes the compact player; drag it wide and the
                // library comes back. Nothing to remember, nothing to get stuck
                // in.
                GeometryReader { geometry in
                    if geometry.size.width < WindowSizer.compactWidth {
                        CompactPlayerView()
                    } else {
                        LibraryView()
                    }
                }
            case .failed(let message):
                FailureView(message: message)
            }
        }
        .animation(.default, value: app.phase)
    }
}

struct FailureView: View {
    let message: String
    @Environment(AppModel.self) private var app

    var body: some View {
        ContentUnavailableView {
            Label("Something went wrong", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Sign out") { app.signOut() }
        }
    }
}

/// Shown when the server is unreachable or the token was rejected.
///
/// A banner, not a modal: downloaded books still play and positions still queue,
/// so blocking the window would misrepresent what the app can currently do.
struct DegradedBanner: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.isDegraded {
            HStack(spacing: 8) {
                Image(systemName: "wifi.exclamationmark")
                Text("Can't reach your server. Downloads still play, and your place is being saved.")
                    .font(.callout)
                Spacer(minLength: 0)
                Button("Dismiss") { app.clearDegraded() }
                    .buttonStyle(.link)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.yellow.opacity(0.18))
        }

        if let notice = app.offlineNotice {
            HStack(spacing: 8) {
                Image(systemName: "icloud.slash")
                Text(notice).font(.callout)
                Spacer(minLength: 0)
                Button("Dismiss") { app.clearOfflineNotice() }
                    .buttonStyle(.link)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.yellow.opacity(0.18))
        }

        // A failed write is a different thing from a failed request, and worse:
        // the server going away costs nothing, because positions queue and go
        // out later. A write that did not land has lost something.
        if let failure = app.storageFailure {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(failure).font(.callout)
                Spacer(minLength: 0)
                Button("Dismiss") { app.clearStorageFailure() }
                    .buttonStyle(.link)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.red.opacity(0.16))
        }
    }
}
