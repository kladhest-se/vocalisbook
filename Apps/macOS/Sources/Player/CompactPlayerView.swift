import SwiftUI
import Audiobooks
import Platform
import PlatformShared

/// The whole window, when the window is small.
///
/// Not a narrower library — a different thing entirely. Below a certain width a
/// grid of covers stops being browsable and a docked transport bar stops having
/// room for its labels, so the window becomes what Plexamp's mini player is: one
/// book, large, with the controls under it and the chapter list below that.
///
/// Reached by dragging the window narrow. There is no separate mode to remember
/// and no toggle to get stuck in the wrong state — the layout follows the size,
/// and the expand button just resizes the window.
/// The four sizes `CompactPlayerView`'s content can be, smallest to largest —
/// see the comment inside `body` for what each one shows and why.
private enum Tier: Int, Comparable {
    case artOnly = 0
    case withProgress = 1
    case withControls = 2
    case full = 3

    static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Thresholds worked out from element heights, not guessed a second time.
    ///
    /// The first attempt at these numbers (220/340/460) only ever scaled the
    /// cover — everything else in a tier's content is fixed height, and as
    /// the window shrank toward the *bottom* of a tier's own range, that
    /// fixed content increasingly did not fit in what was left over. Checked
    /// in Python against rough element heights this time: `withProgress`
    /// needs about 225pt for a legible cover, `withControls` about 361,
    /// `full` about 517. These thresholds are each comfortably above the
    /// corresponding number, but the estimates themselves are still just
    /// that — font sizes and control heights guessed from their SwiftUI
    /// modifiers, not measured against a running app.
    init(height: CGFloat) {
        switch height {
        case ...240: self = .artOnly
        case ...380: self = .withProgress
        case ...540: self = .withControls
        default: self = .full
        }
    }

    /// The same idea, sideways — and the one this file was missing entirely
    /// until a narrow-but-tall window exposed it. Every threshold above was
    /// chosen against *height* alone, so a window dragged narrow while
    /// staying reasonably tall could compute `withControls` or `full` from
    /// its height and try to fit a six-button transport row into whatever
    /// width happened to be left — which is the cover, the scrubber and the
    /// titles all being cropped or squeezed in the screenshots this was
    /// reported against. `body` takes the smaller of this and the
    /// height-based tier, so either dimension being too small is enough to
    /// drop a level, and both have to agree before a tier is allowed to grow.
    ///
    /// Checked in Python again rather than guessed: the transport row's six
    /// items and five gaps alone need about 316pt including padding, which
    /// is comfortably under `withControls`'s threshold here.
    init(width: CGFloat) {
        switch width {
        case ...190: self = .artOnly
        case ...260: self = .withProgress
        case ...360: self = .withControls
        default: self = .full
        }
    }

    /// How much of the available height the cover claims before the rest of
    /// the tier's own elements ask for theirs — decreasing as more of them
    /// need room. `artOnly`'s case is unused, since that tier never reaches
    /// the code path this feeds; the cover *is* the whole view there.
    var coverFraction: CGFloat {
        switch self {
        case .artOnly: 1.0
        case .withProgress: 0.5
        case .withControls: 0.38
        case .full: 0.32
        }
    }
}

struct CompactPlayerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var scrubbing: Double?

    var body: some View {
        VStack(spacing: 0) {
            header

            if app.player.bookRatingKey == nil {
                nothingPlaying
            } else {
                // Four tiers, not two — each one gives up the least useful
                // thing first as the window shrinks, and gets it back first
                // as it grows. Below the first there is nothing left to give
                // up but the art itself, so that is where it stops.
                //
                //   full         cover, scrubber, titles, transport,
                //                secondary, and chapters past 640pt
                //   withControls cover, scrubber, titles, transport
                //   withProgress cover, scrubber, one line of title
                //   artOnly      the cover alone, filling every point of
                //                the window there is
                //
                // Measured against both dimensions rather than given fixed
                // sizes, and against the smaller of the two — see
                // `Tier.init(width:)` for why one alone was not enough. Each
                // tier is as large as the space allows and no larger, so the
                // window can go as small as somebody drags it and every tier
                // stays legible for as long as there is room for it.
                GeometryReader { geometry in
                let height = geometry.size.height
                // The smaller of the two: either dimension being too small
                // for a tier's content is enough to drop a level, and both
                // have to agree before growing. See `Tier.init(width:)` for
                // why this was missing before and what it fixes.
                let tier = min(Tier(height: height), Tier(width: geometry.size.width))

                if tier == .artOnly {
                    // The full content area, not the full window — `header`
                    // stays above this regardless of tier, deliberately.
                    // Traffic lights are hidden throughout the compact
                    // player, so that row's close button is the only way to
                    // close the window without a keyboard shortcut; losing
                    // it at exactly the smallest size, where the window is
                    // easiest to lose track of, would trade one convenience
                    // for a real one.
                    //
                    // No padding — the whole available rect is handed
                    // straight to `CoverImage`. `contentMode: .fit` rather
                    // than the default fill: at every other size the cover
                    // is one square tile among other content, and cropping
                    // an off-ratio one to fill its frame is the right trade
                    // there. Here the cover *is* the content, so losing part
                    // of a tall or wide cover to a crop would be losing the
                    // one thing this tier exists to show in full — a letterboxed
                    // band on either side is the honest cost of a window that
                    // is not the same shape as the artwork, not a defect to
                    // hide.
                    CoverImage(thumb: app.nowPlayingThumb, contentMode: .fit)
                        .frame(width: geometry.size.width, height: height)
                        .contentShape(.rect)
                        .onTapGesture { app.togglePlayPauseRespectingOffline() }
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            // Tapping the cover toggles play and pause at
                            // every tier smaller than full — there is
                            // nowhere else to aim at `withProgress`, and
                            // losing the gesture the moment a transport
                            // appears at `withControls` would be a control
                            // that quietly stops working rather than one
                            // that was never offered.
                            cover
                                .frame(maxHeight: max(64, height * tier.coverFraction))
                                .contentShape(.rect)
                                .onTapGesture {
                                    if tier != .full { app.togglePlayPauseRespectingOffline() }
                                }
                            scrubber

                            if tier == .withProgress {
                                // The book's own title only — not the
                                // chapter, not the author, both of which
                                // `titles` shows from `withControls` up. One
                                // line is what is left once the question
                                // this asks is "what am I listening to", not
                                // "where exactly am I in it".
                                Text(app.nowPlayingTitle ?? "")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(theme.text)
                                    .lineLimit(1)
                                    .multilineTextAlignment(.center)
                            } else {
                                titles
                                transport
                                if tier == .full {
                                    secondary
                                }
                            }

                            // Chapters need the most room, and give it up
                            // first — the last thing added going up, and the
                            // first thing dropped going down.
                            if height > 640 {
                                chapters
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.bottom, 18)
                    }
                }
                }
            }
        }
        .background(theme.background.ignoresSafeArea())
        // A thin border, because the chrome is gone.
        //
        // With the title bar transparent and the traffic lights hidden, the
        // window has no visible edge — on a dark desktop it reads as a floating
        // rectangle of artwork with no boundary. A hairline gives it one without
        // giving back the strip of empty bar.
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(theme.secondaryText.opacity(0.25), lineWidth: 1)
                .ignoresSafeArea()
        }
        // A second trigger, alongside `WindowSizer.followResizes`'s
        // notification observers, for the same chrome this view already
        // depends on being applied.
        //
        // Those observers fire on `didResize` and `didBecomeKey` — reliable
        // for a window somebody is dragging or switching to, and not
        // guaranteed for one that simply *appears* already this size, which
        // is what closing the mini player and reopening it from the menu bar
        // does: SwiftUI builds a new window at the remembered small frame,
        // and if that happens to land before either notification fires, the
        // title bar and traffic lights come back over content that has no
        // room for them. This view only ever exists inside the compact
        // window, so applying compact chrome the moment it appears is safe
        // unconditionally — there is no case where `CompactPlayerView` is on
        // screen and the library's full chrome is the right one.
        //
        // `onAppear`, not `task`: `task` schedules onto the concurrency
        // system and can run a beat later than the view actually appearing,
        // which is exactly the gap this exists to close. `applyChromeWhenReady`
        // rather than `applyChrome` directly, because AppKit's own notion of
        // whether the window is visible can itself lag behind SwiftUI
        // inserting this view — a fresh window and a fresh view competing to
        // be ready first, with no guarantee which wins.
        .onAppear {
            WindowSizer.applyChromeWhenReady(compact: true)
        }
        // The one thing observed reliably being different when the title bar
        // has come back is playback stopping — a book finishing, or being
        // stopped, while the window is already the small one. `onAppear`
        // fires once, for this view's own lifetime, and nothing else here
        // changes that lifetime when a book starts or ends; whatever the
        // exact mechanism turns out to be, re-asserting compact chrome at
        // the one moment content meaningfully changes shape is cheap and
        // cannot make an already-correct title bar wrong.
        .onChange(of: app.player.bookRatingKey) { _, _ in
            WindowSizer.applyChromeWhenReady(compact: true)
        }
    }

    private var header: some View {
        HStack {
            Button {
                WindowSizer.expand()
            } label: {
                Label("Library", systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Back to the library")

            Spacer()
            Text("Now Playing")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.secondaryText)
            Spacer()

            // A way out, because the traffic lights are hidden at this size.
            //
            // ⌘W still works and the menu still closes it, but a window with no
            // visible close button and no menu bar of its own needs one on
            // screen — the alternative is knowing a shortcut.
            Button {
                NSApp.keyWindow?.performClose(nil)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close")

            // Balances the leading button so the title stays centred.
            Image(systemName: "chevron.left").opacity(0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Scaled against the available height for the same reason the playing
    /// state is: fixed sizes here overflowed the window the moment it could
    /// actually reach the sizes `windowMinSize` now allows, which nothing
    /// caught earlier only because nothing before this could get that small
    /// to expose it.
    ///
    /// `Spacer(minLength: 0)` rather than a bare `Spacer()` — a bare one has
    /// an implicit floor of its own and was part of what would not compress,
    /// fighting a `VStack` that already had too little room to give it.
    private var nothingPlaying: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            VStack(spacing: max(6, min(14, height * 0.06))) {
                Spacer(minLength: 0)
                Image(systemName: "headphones")
                    .font(.system(size: max(18, min(40, height * 0.18))))
                    .foregroundStyle(theme.tertiaryText)
                // Text and the button are the first things to go, in that
                // order, the same principle as the playing state's tiers:
                // give up the least useful thing first. The icon alone still
                // answers "is something supposed to be here" even with
                // nothing else on screen.
                if height > 130 {
                    Text("Nothing playing")
                        .font(.callout)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
                if height > 95 {
                    Button("Open the library") { WindowSizer.expand() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(height > 200 ? .regular : .small)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
        }
    }

    private var cover: some View {
        // The square comes from an empty shape, not from the picture: a
        // `scaledToFill` image asked to be square answers by filling and
        // spilling, and the spill draws over whatever is next in the stack.
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                CoverImage(thumb: app.nowPlayingThumb)
            }
            .clipShape(.rect(cornerRadius: 10))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }

    /// Position within the whole book.
    ///
    /// While dragging, the labels follow the pointer rather than the player —
    /// otherwise the numbers fight the periodic time observer and the control
    /// feels broken.
    private var scrubber: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { scrubbing ?? Double(app.player.absoluteMs) },
                    set: { scrubbing = $0 }
                ),
                in: 0...Double(max(app.player.totalDurationMs, 1)),
                onEditingChanged: { editing in
                    if !editing, let target = scrubbing {
                        app.player.seek(toAbsoluteMs: Int(target))
                        scrubbing = nil
                    }
                }
            )
            HStack {
                Text(Format.duration(ms: Int(scrubbing ?? Double(app.player.absoluteMs))))
                Spacer()
                Text("-" + Format.duration(
                    ms: app.player.totalDurationMs - Int(scrubbing ?? Double(app.player.absoluteMs))
                ))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(theme.secondaryText)
        }
    }

    private var titles: some View {
        VStack(spacing: 3) {
            if let chapter = app.player.currentChapter {
                Text(chapter.title)
                    .font(.headline)
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
            }
            Text(app.nowPlayingTitle ?? "")
                .font(.subheadline)
                .foregroundStyle(theme.accent)
                .lineLimit(1)
            if let author = app.nowPlayingAuthor {
                Text(author)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private var transport: some View {
        HStack(spacing: 22) {
            Button { app.player.skipToPreviousChapter() } label: {
                Image(systemName: "backward.end.fill")
            }
            Button { app.player.skip(bySeconds: -app.player.skipIntervalSeconds) } label: {
                Image(systemName: "gobackward.\(app.player.skipIntervalSeconds)")
                    .font(.title3)
            }
            Button { app.togglePlayPauseRespectingOffline() } label: {
                ZStack {
                    Circle().fill(theme.accent).frame(width: 52, height: 52)
                    if app.player.state == .buffering {
                        ProgressView().controlSize(.small).tint(theme.background)
                    } else {
                        Image(systemName: app.player.state == .playing ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .foregroundStyle(theme.background)
                    }
                }
            }
            Button { app.player.skip(bySeconds: app.player.skipIntervalSeconds) } label: {
                Image(systemName: "goforward.\(app.player.skipIntervalSeconds)")
                    .font(.title3)
            }
            Button { app.player.skipToNextChapter() } label: {
                Image(systemName: "forward.end.fill")
            }

            // Stop, beside pause rather than instead of it. A pause leaves a
            // session open on the server; a stop ends it. Your place is written
            // either way.
            if app.player.state != .idle {
                Button { app.player.stop() } label: {
                    Image(systemName: "stop.fill")
                }
                .accessibilityLabel("Stop")
                .help("Stop playback and end the session")
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(theme.text)
    }

    private var secondary: some View {
        HStack(spacing: 20) {
            Menu {
                ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0], id: \.self) { rate in
                    Button(Format.speed(rate)) {
                        app.player.rate = Float(rate)
                        app.rememberRate(Float(rate))
                    }
                }
            } label: {
                Text(Format.speed(app.player.rate)).monospacedDigit()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Menu {
                Button("End of chapter") { app.player.setSleepTimer(.endOfChapter) }
                ForEach([15, 30, 45, 60], id: \.self) { minutes in
                    Button("\(minutes) minutes") {
                        app.player.setSleepTimer(.duration(TimeInterval(minutes * 60)))
                    }
                }
                if app.player.sleepTimer != nil {
                    Divider()
                    Button("Turn off") { app.player.setSleepTimer(nil) }
                }
            } label: {
                Image(systemName: app.player.sleepTimer == nil ? "moon" : "moon.fill")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .font(.callout)
        .foregroundStyle(theme.secondaryText)
    }

    /// The chapter list, in place of Plexamp's queue.
    ///
    /// A book has no queue — the next thing is always the next chapter — so this
    /// is the equivalent: where you are, and everywhere you could jump to.
    @ViewBuilder
    private var chapters: some View {
        let all = app.player.timeline?.chapters ?? []
        if all.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                Text("Chapters")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.top, 4)

                ForEach(all) { chapter in
                    // The same three states the book screen shows. This marked
                    // the chapter playing and nothing else, so the list said
                    // where you are and not how far you have come.
                    let standing = ChapterStanding.of(
                        chapterStartMs: chapter.startMs,
                        chapterEndMs: chapter.endMs,
                        positionMs: app.player.absoluteMs,
                        isFinished: false
                    )
                    let isCurrent = standing == .playing
                    Button {
                        app.player.seek(toAbsoluteMs: chapter.startMs)
                    } label: {
                        HStack(spacing: 8) {
                            // A fixed column, so titles do not shift along as
                            // chapters are finished.
                            Group {
                                switch standing {
                                case .done:
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(theme.secondaryText)
                                case .playing:
                                    Image(systemName: "waveform")
                                        .foregroundStyle(theme.accent)
                                case .ahead:
                                    Color.clear
                                }
                            }
                            .font(.caption)
                            .frame(width: 14)

                            Text(chapter.title)
                                .font(.callout)
                                .foregroundStyle(isCurrent ? theme.accent : theme.text)
                                .lineLimit(1)
                            Spacer()
                            Text(Format.duration(ms: chapter.startMs))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(theme.tertiaryText)
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 8)
                        .background(
                            isCurrent ? theme.accent.opacity(0.12) : .clear,
                            in: .rect(cornerRadius: 6)
                        )
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
