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
/// Deliberately a banner and not a modal: downloaded books still play and
/// positions still queue, so blocking the whole UI would be a lie about what
/// the app can currently do.
struct DegradedBanner: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.isDegraded {
            banner(
                icon: "wifi.exclamationmark",
                message: "Can't reach your server. Downloads still play, and your place is being saved.",
                tint: .yellow
            )
        }

        // A failed *write* is a different thing from a failed request, and worse.
        //
        // The server going away is temporary and costs nothing: positions queue
        // in the outbox and go out later. A write that did not land has lost
        // something, and until now said nothing at all — the app layer was 123
        // `try?` against about forty places that showed anybody anything.
        //
        // Neither red nor a failure: the offline switch doing what it says.
        //
        // Yellow like the degraded banner, because both describe a state the app
        // is in rather than something that went wrong, and dismissible because a
        // note about a book you deliberately stopped does not need to sit there.
        if let notice = app.offlineNotice {
            HStack(spacing: 8) {
                Image(systemName: "icloud.slash")
                Text(notice).font(.footnote)
                Spacer(minLength: 0)
                Button {
                    app.clearOfflineNotice()
                } label: {
                    Image(systemName: "xmark").font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.yellow.opacity(0.2), in: .rect(cornerRadius: 10))
            .padding(.horizontal)
        }

        // Red rather than yellow, and dismissible rather than automatic: this
        // one wants acknowledging, not waiting out.
        if let failure = app.storageFailure {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(failure)
                    .font(.footnote)
                Spacer(minLength: 0)
                Button {
                    app.clearStorageFailure()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.red.opacity(0.18), in: .rect(cornerRadius: 10))
            .padding(.horizontal)
        }
    }

    private func banner(icon: String, message: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(message).font(.footnote)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.2), in: .rect(cornerRadius: 10))
        .padding(.horizontal)
    }
}


/// The tabs.
///
/// Home, Browse, Settings — three, because Authors and Collections have no
/// screens behind them yet and a tab that opens an empty list is worse than a
/// tab that is not there.
///
/// `selection` is lifted here so tapping a book on Home opens it in the same
/// navigation stack rather than pushing a second copy of the detail screen.
struct MainTabs: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var selection: String?
    /// Which tab is showing.
    ///
    /// The `TabView` had no binding, so nothing could bring a tab forward. That
    /// was fine while every route started from a tab the user was already on —
    /// and stopped being fine when the downloads list, three levels inside a
    /// modal, needed to open a book on Home.
    @State private var tab: MainTab = .home
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showingPlayer = false

    var body: some View {
        Group {
            // A bar of our own on iPad, the system's on iPhone.
            //
            // iPadOS 26 puts a `TabView`'s bar across the top, floating, and
            // offers no supported way to move it. On a phone the same code gives
            // the bottom bar everyone knows, so the phone keeps the system's —
            // with its keyboard shortcuts, its minimise-on-scroll behaviour and
            // whatever Apple does to it next.
            //
            // The iPad gets a bar drawn here instead, in the same place and the
            // same shape as the phone's. That is a trade, not a free win: what
            // is drawn here has to be maintained here.
            //
            // Both shapes show the *same* screens. `content(for:)` is the only
            // place a tab's view is named, so the two bars cannot come to
            // disagree about what a tab contains.
            if sizeClass == .regular {
                // An inset, not a stacked row.
                //
                // In a `VStack` the bar took layout space of its own, so the
                // grid stopped dead above it, the strip below filled with the
                // window's background, and the capsule sat in a solid slab
                // instead of floating. `safeAreaInset` is what the mini player
                // already uses: content scrolls *under* the bar and stops
                // short of it, which is what makes the phone's look like glass
                // over a library rather than a panel bolted underneath.
                content(for: tab)
                    .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
            } else {
                TabView(selection: $tab) {
                    ForEach(MainTab.allCases, id: \.self) { item in
                        content(for: item)
                            .tabItem { Label(item.title, systemImage: item.symbol) }
                            .tag(item)
                    }
                }
            }
        }
        .sheet(isPresented: $showingPlayer) { PlayerView() }
    }

    @ViewBuilder
    private func content(for item: MainTab) -> some View {
        switch item {
        case .home: home.miniPlayerInset(active: hasNowPlaying) { showingPlayer = true }
        case .books: LibraryView().miniPlayerInset(active: hasNowPlaying) { showingPlayer = true }
        case .browse: BrowseView().miniPlayerInset(active: hasNowPlaying) { showingPlayer = true }
        }
    }

    /// The iPad's tab bar.
    ///
    /// Shaped after the phone's: a capsule holding four items, the selected one
    /// tinted and sitting on a filled capsule of its own. Not a pixel copy —
    /// that would be a promise to keep matching a moving target — but the same
    /// arrangement in the same place, so a habit from the phone carries.
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(MainTab.allCases, id: \.self) { item in
                Button {
                    tab = item
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 20))
                        Text(item.title)
                            .font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        tab == item ? theme.surface : .clear,
                        in: .capsule
                    )
                    .foregroundStyle(tab == item ? theme.accent : theme.secondaryText)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == item ? [.isSelected, .isButton] : .isButton)
            }
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        // `.ultraThinMaterial`, so the covers behind it show through. `.bar`
        // reads as opaque against a dark theme, which is what made this look
        // bolted on rather than floating.
        .background(.ultraThinMaterial, in: .capsule)
        .overlay(
            Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        )
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    /// Home.
    ///
    /// One shape, on every size of screen.
    ///
    /// This was a `NavigationSplitView` on regular width for a few hours, and an
    /// iPad showed why that was wrong: Home is *content* — a streak, a card, a
    /// row of covers — and content does not belong in a sidebar. The sidebar is
    /// for choosing what to look at, so putting a screen in it squeezed the
    /// screen into a column and left two thirds of the iPad saying "Nothing
    /// open".
    ///
    /// A phone layout is not the enemy on an iPad. A phone layout *at phone
    /// dimensions* is. The fix is to let this content use the width it is given,
    /// which is a matter of grids and columns rather than of split views.
    private var home: some View {
        NavigationStack {
            homeContent
                .navigationDestination(item: $selection) { BookDetailView(ratingKey: $0) }
        }
    }

    /// Everything both shapes share. Only where a chosen book appears differs.
    private var homeContent: some View {
        HomeView(selection: $selection)
            .navigationTitle("VocalisBook")
            .accountToolbar()
            .onChange(of: app.requestedBook) { _, requested in
                // Cleared as it is honoured: an unchanged value publishes
                // nothing, so asking for the same book twice in a row would
                // otherwise do nothing the second time.
                guard let requested else { return }
                // Home first: the request can come from anywhere, including a
                // sheet over another tab, and setting a selection on a stack
                // nobody is looking at does nothing visible.
                tab = .home
                selection = requested
                app.requestedBook = nil
            }
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .history: HistoryView()
                }
            }
    }

    private var hasNowPlaying: Bool { app.player.bookRatingKey != nil }
}

private extension View {
    /// Puts the mini player above the tab bar rather than on top of it.
    ///
    /// This was `.safeAreaInset(edge: .bottom)` on the `TabView`, which reads
    /// correctly and is not: the inset is placed at the bottom edge of the
    /// TabView's *own* frame, and the tab bar is drawn inside that same frame.
    /// So the bar landed squarely on the tabs and hid all five — the app looked
    /// like it had no navigation at all, and the only way back to Settings was
    /// to finish the book.
    ///
    /// Applied to each tab's content instead, the inset sits at the bottom of
    /// the content area, which is above the tab bar. The cost is repeating it
    /// per tab; the alternative reads better and does not work.
    func miniPlayerInset(active: Bool, onTap: @escaping () -> Void) -> some View {
        safeAreaInset(edge: .bottom) {
            if active {
                MiniPlayerBar(onTap: onTap)
            }
        }
    }
}


/// Where Home can go that is not a book.
///
/// A distinct type rather than a `String`: the book destination is already
/// keyed on `String`, and two destinations for the same type means whichever
/// was declared last silently wins.
enum HomeRoute: Hashable {
    case history
}

/// The offline switch, next to the account button.
///
/// A toggle rather than something the app decides. Detection cannot do this
/// job — a captive-portal Wi-Fi looks connected and answers every request with a
/// login page — and more to the point the reason for the mode is often not
/// "there is no network" but "show me what will actually play".
///
/// It changes what the library *contains*, which is a large thing to do from a
/// small button, so the state is spelled out rather than left to a colour: a
/// filled cloud with a slash when on, and the tab bar underneath showing a
/// noticeably shorter library.
struct OfflineToggle: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app

        Button {
            app.isOffline.toggle()
        } label: {
            Label(
                app.isOffline ? "Offline mode on" : "Offline mode off",
                systemImage: app.isOffline ? "icloud.slash.fill" : "icloud"
            )
        }
        .tint(app.isOffline ? .orange : nil)
        .accessibilityLabel("Offline mode")
        .accessibilityValue(app.isOffline ? "On, showing downloaded books only" : "Off")
    }
}

/// The account and offline controls, on every tab.
///
/// They lived inline in the Home tab's `NavigationStack` and therefore appeared
/// on Home alone — a toolbar belongs to the stack that shows it, and each tab
/// here has its own. So switching to Browse or Authors made both controls
/// vanish, which for the offline switch is worse than an inconvenience: it is a
/// mode the app is *in*, and a mode with no visible state on four screens out of
/// five is one people lose track of.
///
/// Self-contained rather than taking a binding: the sheet and its state live
/// here, so adding this to a screen is one line and there is no per-tab state to
/// keep in step.
/// Internal rather than private: `accountToolbar()` is internal and mentions
/// this type in its body. Opaque return types hide it from the signature, but
/// the access-level rules around that are subtle enough not to lean on for the
/// sake of one keyword.
struct AccountToolbar: ViewModifier {
    @Environment(AppModel.self) private var app
    @State private var showingProfile = false
    @State private var showingSettings = false
    @State private var showingDownloads = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                // Mode, then downloads, then configuration, then identity —
                // left to right, in rising order of how rarely each is
                // touched. Downloads ahead of Settings: checking on a
                // transfer or clearing space is something to do again and
                // again, where Settings is closer to a once-per-install
                // stop.
                ToolbarItem(placement: .topBarTrailing) {
                    OfflineToggle()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingDownloads = true
                    } label: {
                        Label("Downloads", systemImage: "arrow.down.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingProfile = true
                    } label: {
                        Label("Account", systemImage: "person.crop.circle")
                    }
                }
            }
            // A `NavigationStack` of its own, unlike the push from Settings —
            // `OfflineView` supplies none, by design, so whichever caller
            // presents it has to. Settings already had one to push into;
            // this button opens a sheet with nothing else in it yet.
            .sheet(isPresented: $showingDownloads) {
                NavigationStack {
                    OfflineView(showsDoneButton: true)
                }
            }
            // Settings was a tab, and a tab is a place you go back to. This is a
            // place you visit: the skip interval and the theme get set once, and
            // a fifth of the tab bar was reserved for them permanently. As a
            // sheet it is one tap from anywhere instead of one tap from
            // somewhere, and the bar is down to the four things that are
            // actually ways of looking at the library.
            .sheet(isPresented: $showingSettings) {
                SettingsView(showsDoneButton: true)
            }
            // Closed when something inside it asks for a book.
            //
            // `dismiss` from a screen *pushed* within the sheet pops that push
            // and leaves the sheet standing, so the request has to be honoured
            // by whoever presented it. That is here, which also means any screen
            // in the sheet gets the behaviour without knowing about it.
            .onChange(of: app.requestedBook) { _, requested in
                if requested != nil { showingSettings = false }
            }
            .sheet(isPresented: $showingProfile) {
                NavigationStack {
                    ProfileView()
                        .navigationTitle("Account")
                        .navigationBarTitleDisplayMode(.inline)
                }
                .presentationDetents([.medium])
            }
    }
}

extension View {
    /// Adds the offline switch and the account button. Must be applied *inside*
    /// a `NavigationStack`, because that is what a toolbar attaches to.
    func accountToolbar() -> some View {
        modifier(AccountToolbar())
    }
}

/// The tabs, as a value.
///
/// Only so a tab can be brought forward from elsewhere — the bar itself works
/// without it.
enum MainTab: Hashable, CaseIterable {
    // Authors, Series and Genres were three tabs and are now one. They were
    // three lists of names with a cover and a count, differing only in which
    // table the names came from, and spending three of the five tabs iOS
    // allows on that left no room for anything else. `BrowseView` holds all
    // four of them — narrators included, which used to hide behind a
    // segmented control inside Authors — behind a menu on the navigation
    // title.
    //
    // Collections and Downloads used to be tabs here too. Collections is
    // folded into Books as a filter — one of the ways of narrowing the same
    // grid, not a separate way of looking at the library — and Downloads
    // moved to a toolbar button beside Settings, storage management rather
    // than browsing.
    //
    // The distinction that named `books` rather than `browse` still holds,
    // and is now the distinction between the two tabs: Books is the full
    // library grid, every book at once; Browse is the indexes into it. Three
    // tabs is well clear of the five past which iOS buckets the remainder
    // into its own unthemed "More" screen, which is the constraint the old
    // arrangement was permanently up against.
    case home, books, browse

    var title: String {
        switch self {
        case .home: "Home"
        case .books: "Books"
        case .browse: "Browse"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        // `books.vertical` moved here from Series, and Series took a
        // distinct icon in exchange — the two used to share a visual
        // vocabulary close enough that a shelf of books stood for both "all
        // the books" and "books grouped by series", which stopped being
        // clear the moment the tab was actually named Books outright.
        case .books: "books.vertical"
        // A list against a shelf of books. The two tabs hold the same
        // library and the icons say how it is arranged: covers laid out, or
        // names to read down. A second grid icon here would have said they
        // were the same screen twice.
        case .browse: "list.bullet"
        }
    }
}
