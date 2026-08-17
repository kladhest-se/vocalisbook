import SwiftUI
import PlexKit
import Platform

struct SignInView: View {
    @Environment(AppModel.self) private var app
    @State private var model = SignInModel()

    var body: some View {
        VStack(spacing: 22) {
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
                .frame(width: 88, height: 88)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("VocalisBook").font(.largeTitle.weight(.semibold))
                Text("A third-party audiobook player for Plex Media Server.")
                    .foregroundStyle(.secondary)
            }

            switch model.state {
            case .idle, .failed:
                Button("Sign in with Plex") {
                    Task { await model.begin(app: app) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            case .waiting:
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Waiting for you to approve this device…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Cancel") { model.cancel() }
                }
            }

            if case .failed(let message) = model.state {
                Text(message).font(.callout).foregroundStyle(.red)
            }

            Spacer()
            Text("Not affiliated with Plex Inc. “Plex” is a trademark of Plex Inc.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: 420)
        .padding(40)
    }
}

@MainActor
@Observable
final class SignInModel {
    enum State: Equatable { case idle, waiting, failed(String) }

    private(set) var state: State = .idle
    private var task: Task<Void, Never>?
    private let presenter = WebSignInPresenter()

    /// Same PIN flow as the phone, and for the same reason: the page is shown by
    /// `ASWebAuthenticationSession`, which runs out of process so this app never
    /// sees the password, and which can be dismissed from here the moment the
    /// poll reports the PIN claimed.
    func begin(app: AppModel) async {
        state = .waiting
        let authenticator = PlexPinAuthenticator(
            transport: PlexTransport(client: URLSessionHTTPClient.foreground(), identity: app.identity),
            identity: app.identity
        )
        presenter.onDismissedByUser = { [weak self] in self?.cancel() }

        task = Task {
            do {
                let pin = try await authenticator.requestPin()
                presenter.present(authenticator.authorizationURL(for: pin))
                let token = try await authenticator.waitForToken(pin: pin)
                guard !Task.isCancelled else { return }
                presenter.finish()
                await app.signIn(token: token)
            } catch is CancellationError {
                presenter.cancel(); state = .idle
            } catch PlexError.authorizationTimedOut {
                presenter.cancel(); state = .failed("That sign-in request expired. Try again.")
            } catch {
                presenter.cancel(); state = .failed(error.plexExplanation)
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
