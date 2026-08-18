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
                // The artwork gives way, and the controls do not — down to a
                // point. Below that point the controls are what gives way
                // instead, because a transport too small to press is worse
                // than no transport at all.
                //
                // A square cover across the full width is as tall as the window
                // is wide, so shrinking the window shortened the space *and*
                // kept the cover — pushing the transport off the bottom and
                // making the mini player unusable at exactly the size somebody
                // shrank it to reach.
                //
                // Measured against the height rather than given a fixed size:
                // the cover is as large as the space allows and no larger, so
                // the window can go as small as somebody drags it and the
                // controls stay legible for as long as there is room for them.
                GeometryReader { geometry in
                let isMinimal = geometry.size.height <= 260
                ScrollView {
                    VStack(spacing: 16) {
                        // The bare minimum: art and a way to see, and change,
                        // where you are — nothing that needs to be read or
                        // aimed at with a pointer this small. Tapping the
                        // cover still toggles play and pause, so playback
                        // stays reachable without expanding the window; the
                        // ordinary size does not carry the same gesture,
                        // since a transport already does that job there and a
                        // cover that silently doubles as a button when one is
                        // not expected is a worse surprise than a missing one.
                        cover
                            .frame(maxHeight: max(64, geometry.size.height * (isMinimal ? 0.62 : 0.40)))
                            .contentShape(.rect)
                            .onTapGesture {
                                if isMinimal { app.togglePlayPauseRespectingOffline() }
                            }
                        scrubber

                        if !isMinimal {
                            titles
                            transport
                            secondary
                        }

                        // Chapters need the most room, and give it up first.
                        //
                        // Below this the window is a transport with a picture
                        // on it, which is what somebody dragging it this
                        // small is asking for — a list they cannot read two
                        // rows of is not worth the height it takes from the
                        // controls.
                        if geometry.size.height > 520 {
                            chapters
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
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
        .task {
            WindowSizer.applyChrome(compact: true)
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

    private var nothingPlaying: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "headphones")
                .font(.system(size: 40))
                .foregroundStyle(theme.tertiaryText)
            Text("Nothing playing")
                .foregroundStyle(theme.secondaryText)
            Button("Open the library") { WindowSizer.expand() }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity)
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
