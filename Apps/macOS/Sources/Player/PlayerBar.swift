import SwiftUI
import Audiobooks
import Platform
import PlatformShared

/// The player, docked at the bottom of the window.
///
/// Always visible rather than living in a sheet — on a Mac there is room for it,
/// and hiding transport controls behind a modal is a phone compromise that has
/// no reason to be carried over.
struct PlayerBar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var scrubbing: Double?
    @State private var showingChapters = false
    @State private var showingBookmarks = false

    private var player: AudiobookPlayer { app.player }

    /// What fits at this width.
    ///
    /// The bar was a fixed row of everything, so narrowing the window clipped it
    /// from the right — the sleep timer went, then the chapter list, then the
    /// bookmark, silently and mid-control. Controls that vanish by being cut in
    /// half look like a rendering fault rather than a decision.
    ///
    /// Dropped in order of how easily each is reached elsewhere. Sleep and
    /// chapters are both in the Playback menu with keyboard shortcuts; bookmark
    /// is on the book. Speed stays longest because it has no other home. The
    /// transport and the scrubber never go — below the point where those stop
    /// fitting, the window is a compact player instead.
    private enum Density {
        case full        // everything
        case tight       // no sleep timer
        case minimal     // transport, scrubber, speed

        static func forWidth(_ width: CGFloat) -> Density {
            if width >= 980 { .full }
            else if width >= 820 { .tight }
            else { .minimal }
        }
    }

    var body: some View {
        // Measured rather than guessed from the window: this bar sits inside the
        // detail column, whose width is the window minus the sidebar, and the
        // sidebar can be collapsed.
        GeometryReader { geometry in
            content(density: .forWidth(geometry.size.width))
        }
        .frame(height: 76)
    }

    @ViewBuilder
    private func content(density: Density) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 16) {
                CoverImage(thumb: app.nowPlayingThumb)
                    .frame(width: 52, height: 52)
                    .clipShape(.rect(cornerRadius: 6))

                if density != .minimal {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.nowPlayingTitle ?? "").font(.callout.weight(.medium)).lineLimit(1)
                        Text(player.currentChapter?.title ?? "")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    // Flexible rather than a fixed 220: the title was the one
                    // thing that could not give up any room, so everything else
                    // paid for it. Widened further — 220/260 to 280/380 — to
                    // take the room freed by capping the scrubber's `Slider`
                    // at 360pt instead of leaving it fully flexible; the two
                    // changes are a pair; either alone just moves which
                    // element ends up with the space nobody wanted.
                    .frame(minWidth: 120, idealWidth: 280, maxWidth: 380, alignment: .leading)
                }

                transport

                scrubber

                HStack(spacing: 14) {
                    Menu {
                        ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0], id: \.self) { rate in
                            Button {
                                player.rate = Float(rate)
                                app.rememberRate(Float(rate))
                            } label: {
                                Text(Format.speed(rate))
                            }
                        }
                    } label: {
                        Text(Format.speed(player.rate)).monospacedDigit()
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    if PlatformCapabilities.localStoreIsDurable, density == .full {
                        // Opens the list rather than saving silently. The sheet
                        // has "Bookmark 1:23:45" at the top, so saving is one
                        // press away — and what is already saved is visible,
                        // which it was not.
                        Button {
                            showingBookmarks = true
                        } label: {
                            Image(systemName: "bookmark")
                        }
                        .buttonStyle(.borderless)
                        .help("Bookmarks")
                        // `.help` is a tooltip, and VoiceOver reads it as a
                        // hint. The control still needs a name.
                        .accessibilityLabel("Bookmarks")
                        .sheet(isPresented: $showingBookmarks) {
                            PlayerBookmarksSheet()
                                .environment(app)
                                .frame(width: 420, height: 520)
                        }
                    }

                    if PlatformCapabilities.supportsAirPlayPicker {
                        // Kept at every density. Where the sound comes out is
                        // not a secondary concern on a machine that is often
                        // driving a speaker in another room, and unlike the
                        // sleep timer and the chapter list it has no menu
                        // equivalent to fall back on.
                        AirPlayRoutePicker(tint: theme.secondaryText, activeTint: theme.accent)
                            .frame(width: 26, height: 22)
                            .accessibilityLabel("AirPlay")
                    }

                    if density != .minimal {
                        Button { showingChapters = true } label: {
                            Image(systemName: "list.bullet")
                        }
                        .buttonStyle(.borderless)
                        .disabled((player.timeline?.chapters.count ?? 0) < 2)
                        .accessibilityLabel("Chapters")
                    }

                    if density == .full {
                        Menu {
                            Button("End of chapter") { player.setSleepTimer(.endOfChapter) }
                            ForEach([15, 30, 45, 60], id: \.self) { minutes in
                                Button("\(minutes) minutes") {
                                    player.setSleepTimer(.duration(TimeInterval(minutes * 60)))
                                }
                            }
                            if player.sleepTimer != nil {
                                Divider()
                                Button("Turn off") { player.setSleepTimer(nil) }
                            }
                        } label: {
                            Image(systemName: player.sleepTimer == nil ? "moon" : "moon.fill")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .accessibilityLabel("Sleep timer")
                        .accessibilityValue(player.sleepTimer == nil ? "Off" : "On")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.bar)
        .popover(isPresented: $showingChapters, arrowEdge: .top) {
            ChapterList().frame(width: 340, height: 420)
        }
    }

    /// Labelled throughout.
    ///
    /// VoiceOver reads an unlabelled icon button by guessing from the symbol
    /// name — "backward end fill", "gobackward 30". Not a rough edge on an
    /// audiobook client: blind and low-vision listeners are a large part of who
    /// audiobooks are for, and these five controls are the app.
    private var transport: some View {
        HStack(spacing: 14) {
            Button { player.skipToPreviousChapter() } label: {
                Image(systemName: "backward.end.fill")
            }
            .accessibilityLabel("Previous chapter")

            Button { player.skip(bySeconds: -player.skipIntervalSeconds) } label: {
                Image(systemName: "gobackward.\(player.skipIntervalSeconds)")
            }
            .accessibilityLabel("Skip back \(player.skipIntervalSeconds) seconds")

            Button { app.togglePlayPauseRespectingOffline() } label: {
                if player.state == .buffering {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: player.state == .playing ? "pause.fill" : "play.fill")
                        .font(.title2)
                }
            }
            .frame(width: 28)
            // Describes what pressing it will do, not what the app is doing.
            .accessibilityLabel(player.state == .playing ? "Pause" : "Play")
            .accessibilityValue(player.state == .buffering ? "Buffering" : "")

            Button { player.skip(bySeconds: player.skipIntervalSeconds) } label: {
                Image(systemName: "goforward.\(player.skipIntervalSeconds)")
            }
            .accessibilityLabel("Skip forward \(player.skipIntervalSeconds) seconds")

            Button { player.skipToNextChapter() } label: {
                Image(systemName: "forward.end.fill")
            }
            .accessibilityLabel("Next chapter")

            // The bar, as well as the compact player.
            //
            // Stop went into `CompactPlayerView` and not here, which is the one
            // the Mac shows most of the time — so on the platform where the
            // dashboard fills with paused sessions, the button was in the window
            // somebody was not looking at.
            if player.state != .idle {
                Button { player.stop() } label: {
                    Image(systemName: "stop.fill")
                }
                .accessibilityLabel("Stop")
                .help("Stop playback and end the session")
            }
        }
        .buttonStyle(.borderless)
    }

    /// Scrubs the whole book, not the current file.
    ///
    /// While dragging, the label follows the pointer rather than the player —
    /// otherwise the number fights the periodic time observer and the control
    /// feels broken.
    private var scrubber: some View {
        HStack(spacing: 10) {
            Text(Format.duration(ms: Int(scrubbing ?? Double(player.absoluteMs))))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { scrubbing ?? Double(player.absoluteMs) },
                    set: { scrubbing = $0 }
                ),
                in: 0...Double(max(player.totalDurationMs, 1)),
                onEditingChanged: { editing in
                    if !editing, let target = scrubbing {
                        player.seek(toAbsoluteMs: Int(target))
                        scrubbing = nil
                    }
                }
            )
            // Capped rather than left fully flexible. A `Slider` with no
            // width of its own happily claims every point of space nothing
            // else wants, at the title area's direct expense — the two sit
            // in the same `HStack`, so whatever the slider does not take is
            // the whole of what the title has to grow into. 360pt is
            // comfortably more than a scrubber needs to be precisely
            // usable; the room that frees up is exactly what the title's
            // own `maxWidth`, in `body`, was raised by.
            .frame(maxWidth: 360)

            Text("-" + Format.duration(
                ms: player.totalDurationMs - Int(scrubbing ?? Double(player.absoluteMs))
            ))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 62, alignment: .leading)
        }
    }
}

struct ChapterList: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        // See the iOS sheet: opens at the chapter playing rather than the first.
        ScrollViewReader { scroll in
            List(app.player.timeline?.chapters ?? []) { chapter in
                Button {
                    app.player.seek(toAbsoluteMs: chapter.startMs)
                } label: {
                    // The same three states as everywhere else. This popover
                    // marked the chapter playing and nothing else.
                    let standing = ChapterStanding.of(
                        chapterStartMs: chapter.startMs,
                        chapterEndMs: chapter.endMs,
                        positionMs: app.player.absoluteMs,
                        isFinished: false
                    )
                    HStack {
                        // A fixed column, so titles do not shift along.
                        Group {
                            switch standing {
                            case .done:
                                Image(systemName: "checkmark").foregroundStyle(.secondary)
                            case .playing:
                                Image(systemName: "waveform").foregroundStyle(.tint)
                            case .ahead:
                                Color.clear
                            }
                        }
                        .font(.caption)
                        .frame(width: 16)

                        VStack(alignment: .leading) {
                            Text(chapter.title).lineLimit(1)
                            Text(Format.duration(ms: chapter.startMs))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .id(chapter.id)
            }
            .task {
                await Task.yield()
                guard let current = app.player.currentChapter else { return }
                scroll.scrollTo(current.id, anchor: .center)
            }
        }
    }
}
