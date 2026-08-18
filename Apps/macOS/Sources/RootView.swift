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
                    Group {
                        if geometry.size.width < WindowSizer.compactWidth {
                            CompactPlayerView()
                        } else {
                            LibraryView()
                        }
                    }
                    // Pinned to the exact measured size, not only given a
                    // minimum — the same gap as the minimum below, one
                    // level higher. A `GeometryReader` proposes its
                    // measured size to its child; it does not force that
                    // child to actually stay inside the proposal, so
                    // `CompactPlayerView` was free to settle on whatever
                    // size its own content wanted rather than shrinking
                    // with the window past a certain point. The symptom was
                    // a debug label inside it reporting the exact same
                    // width and height across screenshots at visibly
                    // different window sizes — not stale, frozen, because
                    // the measurement feeding it had genuinely stopped
                    // moving. The same fix already went one level further
                    // in, on the `ZStack` `CompactPlayerView` builds its
                    // own content in; it did not help, because this level
                    // was never pinned either, and a child three levels
                    // down being pinned to a parent that is itself still
                    // free to drift does not constrain anything.
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
                // Without this, nothing tells AppKit that shrinking the window
                // past a certain point is even valid.
                //
                // `.windowResizability(.contentSize)` derives the window's
                // minimum draggable size from *this* content — and a bare
                // `GeometryReader` reports no intrinsic size of its own; it
                // takes whatever space its parent offers and passes nothing
                // back up, regardless of what its children would prefer. A
                // `.frame(minWidth:minHeight:)` on `CompactPlayerView` itself,
                // one level inside this, had no effect for exactly that
                // reason — the GeometryReader wrapping it broke the
                // propagation before it ever reached the window. This is the
                // level that actually gets measured. 140×160 sits comfortably
                // under the ultra-minimal player's own 260pt height
                // threshold, so there is real room to drag into once reached
                // rather than the window stopping right at the boundary.
                .frame(minWidth: 140, minHeight: 160)
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
    @State private var isReconnecting = false

    /// The first sentence only, not the paragraph of troubleshooting detail
    /// that sometimes follows it.
    ///
    /// `plexExplanation` joins a short description to a longer `failureReason`
    /// with a blank line between them — genuinely useful detail in the places
    /// that already show it, like the server picker, where somebody is
    /// actively troubleshooting a specific connection. A full-screen failure
    /// is not that moment: it wants one plain sentence and something to press,
    /// not a paragraph about local network permissions read while wondering
    /// whether the app has actually gotten stuck.
    private var summary: String {
        message.components(separatedBy: "\n\n").first ?? message
    }

    var body: some View {
        ContentUnavailableView {
            Label("Something went wrong", systemImage: "exclamationmark.triangle")
        } description: {
            Text(summary)
        } actions: {
            // Retries the whole connection from scratch rather than
            // whatever step failed — see `retryConnection`'s own comment for
            // why that is the more useful behaviour, not a lesser one.
            Button {
                isReconnecting = true
                Task {
                    await app.retryConnection()
                    isReconnecting = false
                }
            } label: {
                if isReconnecting {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Reconnect")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isReconnecting)

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
