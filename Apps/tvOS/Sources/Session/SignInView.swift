import SwiftUI
import PlexKit
import Platform

/// Sign-in on a television.
///
/// There is no browser here, so `authorizationURL(for:)` is unusable and
/// `ASWebAuthenticationSession` does not exist. The PIN itself is the interface:
/// it goes on screen at a size readable from a sofa, the viewer types it into
/// plex.tv/link on a phone, and this screen polls the same endpoint the other
/// ports do. `PlexPinAuthenticator` needs no change — only the presentation.
struct SignInView: View {
    @Environment(AppModel.self) private var app
    @State private var model = SignInModel()

    var body: some View {
        VStack(spacing: 40) {
            // Larger than the phone's: this is read from a sofa, and the mark
            // is the only thing on the screen that survives being looked at
            // from three metres away.
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 180, height: 180)
                .accessibilityHidden(true)

            VStack(spacing: 12) {
                Text("VocalisBook").font(.system(size: 76, weight: .semibold))
                Text("A third-party audiobook player for Plex Media Server.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            switch model.state {
            case .idle:
                Button("Sign in with Plex") { Task { await model.begin(app: app) } }
                    .buttonStyle(.borderedProminent)

            case .waiting(let code):
                VStack(spacing: 24) {
                    Text("Go to plex.tv/link on your phone")
                        .font(.title2)

                    // Wide letter spacing and a monospaced face: this is read
                    // across a room and typed on another device, so O/0 and I/1
                    // being distinguishable matters more than looking tidy.
                    //
                    // Shown exactly as the API returned it, not upper-cased for
                    // looks — whether plex.tv/link compares case-insensitively
                    // is not worth betting someone's sign-in on.
                    Text(code)
                        .font(.system(size: 140, weight: .bold, design: .monospaced))
                        .tracking(20)
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                        .padding(.horizontal, 64)
                        .padding(.vertical, 32)
                        .background(.thinMaterial, in: .rect(cornerRadius: 24))

                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Waiting for you to approve this device…")
                            .foregroundStyle(.secondary)
                    }
                    Button("Cancel") { model.cancel() }
                }

            case .failed(let message):
                VStack(spacing: 20) {
                    Text(message).font(.title3).foregroundStyle(.red)
                    Button("Try again") { Task { await model.begin(app: app) } }
                        .buttonStyle(.borderedProminent)
                }
            }

            Text("Not affiliated with Plex Inc. “Plex” is a trademark of Plex Inc.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(80)
    }
}

@MainActor
@Observable
final class SignInModel {
    enum State: Equatable {
        case idle
        case waiting(code: String)
        case failed(String)
    }

    private(set) var state: State = .idle
    private var task: Task<Void, Never>?

    func begin(app: AppModel) async {
        state = .idle
        let authenticator = PlexPinAuthenticator(
            transport: PlexTransport(client: URLSessionHTTPClient.foreground(), identity: app.identity),
            identity: app.identity
        )

        task = Task {
            do {
                // Not a strong PIN. That kind is long and opaque because it is
                // meant to ride inside the app.plex.tv URL; here a person reads
                // it off a television and types it at plex.tv/link, so it has to
                // be the short one.
                let pin = try await authenticator.requestPin(strong: false)
                state = .waiting(code: pin.code)

                let token = try await authenticator.waitForToken(pin: pin)
                guard !Task.isCancelled else { return }
                await app.signIn(token: token)
            } catch is CancellationError {
                state = .idle
            } catch PlexError.authorizationTimedOut {
                state = .failed("That code expired. Try again for a new one.")
            } catch {
                state = .failed(error.plexExplanation)
            }
        }
        await task?.value
    }

    func cancel() {
        task?.cancel()
        state = .idle
    }
}
