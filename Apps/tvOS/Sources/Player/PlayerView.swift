import SwiftUI
import Audiobooks
import Platform
import PlatformShared

/// The full-screen player.
///
/// Built around the remote: the whole screen is the play/pause target, left and
/// right scrub, and the transport row below is reachable by focus. There is no
/// mini player on this platform — a television shows one thing at a time.
struct PlayerView: View {
    /// False when the player is a tab rather than a cover: there is nothing to
    /// dismiss, and a Done button that does nothing is worse than none.
    var showsDoneButton = true

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var showingSleepTimer = false
    @State private var showingChapters = false
    @State private var showingBookmarks = false

    private var player: AudiobookPlayer { app.player }

    /// One control: a glyph, centred, with no caption.
    ///
    /// These were a glyph above a word, which on a television is a caption to
    /// read from a sofa and a button that is mostly text. The transport above
    /// them has never had captions — skip, play, next are glyphs and are
    /// understood — and these sat under them looking like a different kind of
    /// control.
    ///
    /// The word survives as the accessibility label, where it is the useful
    /// form: VoiceOver reads "Bookmark", and a state that matters is in the
    /// value rather than shortening the title.
    @ViewBuilder
    private func iconControl(_ label: String, systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.title2)
            .frame(width: 64, height: 64)
            .accessibilityLabel(label)
    }

    var body: some View {
        ZStack {
            // Cover art as the backdrop, heavily blurred so the text over it
            // stays legible on any artwork.
            CoverImage(thumb: app.nowPlayingThumb)
                .scaledToFill()
                .blur(radius: 60)
                .overlay(.black.opacity(0.55))
                .ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                CoverImage(thumb: app.nowPlayingThumb)
                    .frame(width: 300, height: 300)
                    .clipShape(.rect(cornerRadius: 14))
                    .shadow(radius: 30)

                VStack(spacing: 8) {
                    Text(app.nowPlayingTitle ?? "").font(.title.weight(.semibold))
                    if let chapter = player.currentChapter {
                        Text(chapter.title).font(.title3).foregroundStyle(.secondary)
                    }
                }

                progress

                // Labelled throughout. VoiceOver on a television reads these
                // aloud to a room, and an unlabelled icon button is announced
                // from its symbol name — "gobackward 30".
                HStack(spacing: 40) {
                    Button { player.skipToPreviousChapter() } label: {
                        Image(systemName: "backward.end.fill")
                    }
                    .accessibilityLabel("Previous chapter")

                    Button { player.skip(bySeconds: -player.skipIntervalSeconds) } label: {
                        Image(systemName: "gobackward.\(player.skipIntervalSeconds)")
                    }
                    .accessibilityLabel("Skip back \(player.skipIntervalSeconds) seconds")

                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.state == .playing ? "pause.fill" : "play.fill")
                            .font(.largeTitle)
                    }
                    .accessibilityLabel(player.state == .playing ? "Pause" : "Play")

                    Button { player.skip(bySeconds: player.skipIntervalSeconds) } label: {
                        Image(systemName: "goforward.\(player.skipIntervalSeconds)")
                    }
                    .accessibilityLabel("Skip forward \(player.skipIntervalSeconds) seconds")

                    Button { player.skipToNextChapter() } label: {
                        Image(systemName: "forward.end.fill")
                    }
                    .accessibilityLabel("Next chapter")

                    // Stop rather than pause: a pause leaves a session open on
                    // the server, and a television left paused leaves it open
                    // until somebody comes back to the room.
                    if player.state != .idle {
                        Button { player.stop() } label: {
                            Image(systemName: "stop.fill")
                        }
                        .accessibilityLabel("Stop")
                    }
                }

                // Caption under the icon, not beside it.
                //
                // A row of `Label`s puts the text to the right of each glyph, so
                // every control is as wide as its longest word and the row grows
                // sideways until it runs out of screen. Stacked, each control is
                // the width of its icon and the captions line up under them —
                // which is also what the focus ring then surrounds, rather than
                // an icon with a word trailing off it.
                HStack(alignment: .top, spacing: 48) {
                    Menu {
                        ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0], id: \.self) { rate in
                            Button(Format.speed(rate)) {
                                player.rate = Float(rate)
                                app.rememberRate(Float(rate))
                            }
                        }
                    } label: {
                        // The number rather than a glyph: the speed *is* the
                        // state, and "speedometer" would say only that a speed
                        // exists.
                        Text(Format.speed(player.rate))
                            .font(.title3.weight(.medium))
                            .frame(width: 64, height: 64)
                    }
                    .accessibilityLabel("Speed")
                    .accessibilityValue(Format.speed(player.rate))

                    // Saving a bookmark, which this platform could not do at
                    // all. The database, the sync and the list have been there
                    // since the beginning; only the button was missing, so a
                    // bookmark made on the phone appeared on the television and
                    // one made here could not exist.
                    // Opens the list rather than saving silently. The sheet
                    // has "Bookmark 1:23:45" at the top, so saving is still one
                    // press away — and what is already saved is visible, which
                    // it was not.
                    Button {
                        showingBookmarks = true
                    } label: {
                        iconControl("Bookmarks", systemImage: "bookmark")
                    }

                    // Chapters, which this screen could not reach.
                    //
                    // The list existed on the book screen and nowhere else, so
                    // moving between chapters while playing meant leaving the
                    // player, finding the book, and coming back. The player
                    // already holds the timeline; it needed a way in.
                    Button {
                        showingChapters = true
                    } label: {
                        iconControl("Chapters", systemImage: "list.bullet")
                    }
                    .disabled(player.timeline?.chapters.isEmpty ?? true)

                    Button {
                        showingSleepTimer = true
                    } label: {
                        iconControl(
                            player.sleepTimer == nil ? "Sleep timer" : "Sleep timer on",
                            systemImage: player.sleepTimer == nil ? "moon" : "moon.fill"
                        )
                    }

                    if showsDoneButton {
                        Button {
                            dismiss()
                        } label: {
                            iconControl("Done", systemImage: "chevron.down")
                        }
                    }
                }

                Spacer()
            }
            .padding(60)
        }
        .sheet(isPresented: $showingBookmarks) {
            PlayerBookmarksSheet()
                .environment(app)
        }
        .sheet(isPresented: $showingChapters) {
            PlayerChapterList()
                .environment(app)
        }
        .confirmationDialog("Sleep timer", isPresented: $showingSleepTimer) {
            Button("End of chapter") { player.setSleepTimer(.endOfChapter) }
            ForEach([15, 30, 45, 60], id: \.self) { minutes in
                Button("\(minutes) minutes") {
                    player.setSleepTimer(.duration(TimeInterval(minutes * 60)))
                }
            }
            if player.sleepTimer != nil {
                Button("Turn off", role: .destructive) { player.setSleepTimer(nil) }
            }
        }
    }

    /// Position within the whole book, not the current file.
    ///
    /// Read-only: scrubbing on a television is done with the remote's swipe on
    /// the system transport bar, and a focusable Slider fights that rather than
    /// helping.
    private var progress: some View {
        VStack(spacing: 8) {
            ProgressView(value: player.progressFraction)
                .frame(maxWidth: 900)
            HStack {
                Text(Format.duration(ms: player.absoluteMs))
                Spacer()
                Text("-" + Format.duration(ms: player.totalDurationMs - player.absoluteMs))
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(maxWidth: 900)
        }
    }
}

/// Chapters, from the player's own timeline.
///
/// Separate from `ChapterListView` on the book screen, which needs a
/// `BookDetailModel` and a rating key — neither of which the player has, and
/// neither of which it should acquire to show a list it already holds the data
/// for.
///
/// The marks are the same rule the book screen uses: passed, playing, ahead.
struct PlayerChapterList: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    private var player: AudiobookPlayer { app.player }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Chapters")
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(theme.text)
                .padding(.horizontal, 60)
                .padding(.top, 40)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(player.timeline?.chapters ?? []) { chapter in
                        Button {
                            player.seek(toAbsoluteMs: chapter.startMs)
                            dismiss()
                        } label: {
                            HStack {
                                // A fixed column, so titles do not shift along
                                // as chapters are finished.
                                Group {
                                    // The same rule the book screens use, from
                                    // the same place — this was the fourth copy
                                    // of one comparison, and four copies is how
                                    // the phone comes to disagree with the
                                    // television about which chapter is playing.
                                    //
                                    // Not finished here: a book being played is
                                    // not a finished book, and the player has no
                                    // finished flag to consult.
                                    switch ChapterStanding.of(
                                        chapterStartMs: chapter.startMs,
                                        chapterEndMs: chapter.endMs,
                                        positionMs: player.absoluteMs,
                                        isFinished: false
                                    ) {
                                    case .done:
                                        Image(systemName: "checkmark")
                                    case .playing:
                                        Image(systemName: "speaker.wave.2.fill")
                                    case .ahead:
                                        Color.clear
                                    }
                                }
                                .frame(width: 32)

                                Text(chapter.title).lineLimit(1)
                                Spacer()
                                Text(Format.duration(ms: chapter.startMs))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 60)
                .padding(.bottom, 60)
            }
        }
        .background(theme.background.ignoresSafeArea())
    }
}
