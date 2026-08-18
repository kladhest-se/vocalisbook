import SwiftUI
import PlexKit
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
                MainTabs()
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
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 64))
            Text("Something went wrong").font(.title)
            Text(message).font(.title3).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Sign out") { app.signOut() }
        }
        .padding(80)
    }
}

struct DegradedBanner: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.isDegraded {
            HStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark")
                Text("Can't reach your server. Your place is still being saved.")
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.yellow.opacity(0.2), in: .rect(cornerRadius: 12))
        }

        // A failed write is worse than a failed request: a position that did not
        // reach the server queues and goes out later, one that did not reach the
        // database is gone. It matters most here, where the database is a cache
        // the system may purge.
        if let failure = app.storageFailure {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(failure)
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.red.opacity(0.2), in: .rect(cornerRadius: 12))
        }
    }
}
/// The tabs.
///
/// The phone's five, plus History, so a habit from the phone carries to the
/// television. tvOS puts them across the top rather than the bottom, which is
/// the platform's own convention and not something to fight.
///
/// History is a tab here and a sidebar entry on the Mac, and reached from Home
/// on the phone. That is not inconsistency for its own sake: a pushed screen on
/// tvOS collapses the tab bar while it is open, so anything worth returning to
/// belongs in the bar rather than behind it.
struct MainTabs: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app

        TabView(selection: $app.selectedTab) {
            // Home is where you left off; Books is every book.
            //
            // These were the wrong way round: Home was the library, complete
            // with a search field, and this tab was the same grid without one.
            HomeView()
                .tabItem { Label("Home", systemImage: "house") }
                .tag(MainTab.home)
            LibraryView()
                // `books.vertical` moved here from Series, and Series took a
                // distinct icon — `square.stack` — in exchange. The two used
                // to share a visual vocabulary close enough that a shelf of
                // books stood for both "all the books" and "books grouped by
                // series", which stopped being clear once this tab was
                // actually named Books.
                .tabItem { Label("Books", systemImage: "books.vertical") }
                .tag(MainTab.books)
            AuthorsView()
                .tabItem { Label("Authors", systemImage: "person") }
                .tag(MainTab.authors)
            SeriesView()
                .tabItem { Label("Series", systemImage: "square.stack") }
                .tag(MainTab.series)

            // Genres sits after Series: all three group the same books, and
            // this is the one that groups by what a book is rather than by
            // who wrote it or what it follows.
            GenresView()
                .tabItem { Label("Genres", systemImage: "theatermasks") }
                .tag(MainTab.genres)

            // A tab, not a pushed screen.
            //
            // History was reached by a `NavigationLink` from the streak card on
            // Home, and tvOS collapses the tab bar when a stack pushes — so
            // opening it made the bar slide away and back, which reads as the
            // menu moving rather than as navigation.
            //
            // Nothing pushes now: selecting a tab leaves the bar exactly where
            // it is. It also matches the Mac, where History has been a sidebar
            // entry all along, and gives the screen a way in that does not
            // depend on having a streak to click.
            HistoryView()
                .tabItem { Label("History", systemImage: "flame") }
                .tag(MainTab.history)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(MainTab.settings)

            // Appears only while something is loaded.
            //
            // A television has no room for a persistent transport bar, and no
            // pointer to put one under — so the way back to the player is a tab,
            // which the remote already knows how to reach. The Plex client does
            // the same thing with a thumbnail in the corner; a tab is the same
            // idea in the place tvOS puts navigation.
            if app.player.bookRatingKey != nil {
                PlayerView(showsDoneButton: false)
                    .tabItem { Label("Playing", systemImage: "waveform") }
                    .tag(MainTab.nowPlaying)
            }
        }
    }
}

/// The tabs, so one can be selected in code.
///
/// Pressing play jumps straight to the player rather than leaving you on the
/// book screen wondering whether anything happened.
enum MainTab: Hashable {
    case home, books, authors, series, genres, history, settings, nowPlaying
}
