import SwiftUI
import PlexKit
import Platform

struct SignInView: View {
    @Environment(AppModel.self) private var app
    @State private var model = SignInModel()

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            // The mark, not a stock symbol.
            //
            // `books.vertical` was a placeholder that outlived its welcome: the
            // first screen anyone sees was borrowing Apple's icon for "some
            // books". Drawn at a fixed size rather than scaled to the type,
            // because it is artwork and Dynamic Type would make it wobble
            // against the title beneath it.
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("VocalisBook")
                    .font(.largeTitle.weight(.semibold))
                Text("A third-party audiobook player for Plex Media Server.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            switch model.state {
            case .idle, .failed:
                Button {
                    Task { await model.begin(app: app) }
                } label: {
                    Text("Sign in with Plex")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            case .waiting:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Waiting for you to approve this device…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Cancel") { model.cancel() }
                }
            }

            if case .failed(let message) = model.state {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Text("Not affiliated with Plex Inc. “Plex” is a trademark of Plex Inc.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
    }
}

@MainActor
@Observable
final class SignInModel {
    enum State: Equatable {
        case idle
        case waiting
        case failed(String)
    }

    private(set) var state: State = .idle
    private var task: Task<Void, Never>?
    private let presenter = WebSignInPresenter()

    /// Runs the PIN flow.
    ///
    /// The authorisation page is presented by `ASWebAuthenticationSession`, not
    /// handed to Safari with `openURL`. Both run out of process, so neither lets
    /// this app see the password — but only the session can be closed again from
    /// here, and it is closed the instant the poll reports the PIN claimed. With
    /// `openURL` the page stayed on screen afterwards saying "you may now close
    /// this window", which nothing except the user could act on.
    func begin(app: AppModel) async {
        state = .waiting

        let authenticator = PlexPinAuthenticator(
            transport: PlexTransport(
                client: URLSessionHTTPClient.foreground(),
                identity: app.identity
            ),
            identity: app.identity
        )

        presenter.onDismissedByUser = { [weak self] in
            // They closed the page without approving. Polling on for five more
            // minutes would leave the spinner up with nothing coming.
            self?.cancel()
        }

        task = Task {
            do {
                let pin = try await authenticator.requestPin()
                presenter.present(authenticator.authorizationURL(for: pin))

                let token = try await authenticator.waitForToken(pin: pin)
                guard !Task.isCancelled else { return }

                presenter.finish()
                await app.signIn(token: token)
            } catch is CancellationError {
                presenter.cancel()
                state = .idle
            } catch PlexError.authorizationTimedOut {
                presenter.cancel()
                state = .failed("That sign-in request expired. Try again.")
            } catch {
                presenter.cancel()
                state = .failed(error.plexExplanation)
            }
        }
        await task?.value
    }

    func cancel() {
        task?.cancel()
        presenter.cancel()
        state = .idle
    }
}
