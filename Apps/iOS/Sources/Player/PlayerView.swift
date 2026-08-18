import SwiftUI
import MediaPlayer
import PlatformShared
import Audiobooks
import Platform

struct PlayerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var scrubbing: Double?
    @State private var showingChapters = false
    @State private var showingBookmarks = false
    @State private var showingSleepTimer = false
    @State private var route = AudioRouteMonitor()

    private var player: AudiobookPlayer { app.player }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(.tertiary)
                .frame(width: 40, height: 5)
                .padding(.top, 8)

            // Side by side when the screen is wider than it is tall.
            //
            // Stacked, the artwork and six rows of controls need height, and in
            // landscape there is none — everything compressed towards nothing
            // and the cover ended up a postage stamp above a wall of buttons.
            // Turned on its side the same pieces fit comfortably.
            //
            // `verticalSizeClass == .compact` is a phone in landscape;
            // `horizontalSizeClass == .regular` is an iPad, where there is room
            // for the wide arrangement in either orientation.
            if verticalSizeClass == .compact || horizontalSizeClass == .regular {
                wide
            } else {
                tall
            }
        }
        .padding(.bottom, 24)
        // Missing here the same way it was missing from `BookDetailView` —
        // this sheet fell back to its default system material regardless of
        // theme, which is the plain black background in the report rather
        // than whichever theme was actually active.
        .background(theme.background.ignoresSafeArea())
        .sheet(isPresented: $showingChapters) { ChapterListSheet() }
        .sheet(isPresented: $showingBookmarks) { PlayerBookmarksSheet() }
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

    /// Split out of `body`, along with the two control rows below.
    ///
    /// Not only for reading: a single `VStack` holding all of this is what the
    /// type checker gives up on, and "unable to type-check this expression in
    /// reasonable time" names no line and suggests no cause.
    /// Artwork above, controls below. The phone in portrait.
    private var tall: some View {
        // Measured, because the artwork was claiming the space first.
        //
        // `layoutPriority(1)` on the cover made it take what it wanted and leave
        // the remainder to the controls — so on a shorter screen, or in the
        // iPad's player sheet, the transport and the row beneath it went off the
        // bottom. A cover somebody cannot pause is worse than a smaller cover.
        //
        // Capped against the height instead: as large as fits with the controls
        // still on screen, and no larger. The priority is gone, so the controls
        // are laid out first and the artwork takes what is left.
        GeometryReader { geometry in
        VStack(spacing: 0) {
            Spacer(minLength: 12)

            cover
                .frame(maxWidth: 520, maxHeight: max(120, geometry.size.height * 0.44))
                .padding(.horizontal, 32)

            Spacer(minLength: 12)

            titleBlock
                .padding(.horizontal)
                .padding(.bottom, 18)

            scrubber
                .padding(.bottom, 22)

            transport
                .padding(.bottom, 26)

            secondaryControls
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Artwork beside the controls. Landscape, and any iPad.
    ///
    /// The same pieces in the same order, read left to right instead of top to
    /// bottom — nothing here is a second implementation of anything, which is
    /// the only reason having two arrangements is affordable.
    private var wide: some View {
        HStack(spacing: 28) {
            // Bounded by height as well as width. In a short window — an iPad
            // sheet, or a landscape phone — a 360pt square is taller than the
            // space, and the column beside it then has nowhere to put the
            // transport.
            cover
                .frame(maxWidth: 360, maxHeight: 360)

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                titleBlock
                    .padding(.bottom, 18)

                scrubber
                    .padding(.bottom, 20)

                transport
                    .padding(.bottom, 22)

                secondaryControls

                Spacer(minLength: 0)
            }
            .frame(maxWidth: 520)
        }
        .padding(.horizontal, 28)
        .padding(.top, 12)
    }

    /// One cover, however it is arranged.
    private var cover: some View {
        // The square comes from an empty shape, not from the picture.
        //
        // `aspectRatio` on the image asks the image to be square; a
        // `scaledToFill` image answers by filling and spilling, and the spill is
        // drawn over whatever is next in the stack — which is why the title sat
        // on top of the cover rather than under it.
        //
        // `Color.clear` has no opinion about its size, so the ratio is decided
        // by the layout and the picture is clipped into it. The frame this ends
        // up with is the frame it draws in, whatever the artwork's proportions.
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                CoverImage(thumb: app.nowPlayingThumb)
            }
            .clipShape(.rect(cornerRadius: 18))
            .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
    }

    /// The title, and a way back to the book it belongs to.
    ///
    /// The player was a room with no door: it knows which book is playing and
    /// offered no way to reach that book's own screen — its chapters, its
    /// summary, its author, the rest of the series. Getting there meant
    /// dismissing the player, remembering where the book was, and finding it
    /// again.
    ///
    /// The title is the button, because that is the thing on screen that names
    /// the destination. The chevron is there so it looks like one.
    private var titleBlock: some View {
        VStack(spacing: 4) {
            Button {
                guard let key = player.bookRatingKey else { return }
                // The same request the downloads list uses: the sheet closes,
                // the book opens where books open.
                app.open(bookRatingKey: key)
                dismiss()
            } label: {
                HStack(spacing: 6) {
                    Text(app.nowPlayingTitle ?? "")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(player.bookRatingKey == nil)
            .accessibilityLabel(app.nowPlayingTitle ?? "This book")
            .accessibilityHint("Opens the book")

            if let chapter = player.currentChapter {
                Text(chapter.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// Labelled throughout.
    ///
    /// Every control here is an icon with no text, which VoiceOver reads by
    /// guessing from the symbol name: "backward end fill", "gobackward 30". For
    /// an audiobook client that is not a rough edge — blind and low-vision
    /// listeners are a large part of who audiobooks are for, and this screen is
    /// where they live.
    private var transport: some View {
        HStack(spacing: 36) {
            Button { player.skipToPreviousChapter() } label: {
                Image(systemName: "backward.end.fill")
            }
            .accessibilityLabel("Previous chapter")

            Button { player.skip(bySeconds: -player.skipIntervalSeconds) } label: {
                Image(systemName: "gobackward.\(player.skipIntervalSeconds)")
                    .font(.title2)
            }
            .accessibilityLabel("Skip back \(player.skipIntervalSeconds) seconds")

            Button { app.togglePlayPauseRespectingOffline() } label: {
                ZStack {
                    Circle().fill(.tint).frame(width: 68, height: 68)
                    if player.state == .buffering {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: player.state == .playing ? "pause.fill" : "play.fill")
                            .font(.title)
                            .foregroundStyle(.white)
                    }
                }
            }
            // The label follows the state, so it always describes what pressing
            // it will do rather than what the app is currently doing.
            .accessibilityLabel(player.state == .playing ? "Pause" : "Play")
            .accessibilityValue(player.state == .buffering ? "Buffering" : "")


            Button { player.skip(bySeconds: player.skipIntervalSeconds) } label: {
                Image(systemName: "goforward.\(player.skipIntervalSeconds)")
                    .font(.title2)
            }
            .accessibilityLabel("Skip forward \(player.skipIntervalSeconds) seconds")

            Button { player.skipToNextChapter() } label: {
                Image(systemName: "forward.end.fill")
            }
            .accessibilityLabel("Next chapter")

            // Stop, beside pause rather than instead of it.
            //
            // They are different things to the server: a pause holds the book
            // and leaves a session open — which is why a Plex dashboard fills
            // with paused VocalisBook sessions nobody is listening to — and a stop
            // ends it. Your place is written either way, so stopping is not
            // losing anything.
            //
            // Shown only while a book is loaded: there is nothing to stop
            // otherwise, and a permanently dead control reads as a broken one.
            if player.state != .idle {
                Button { player.stop() } label: {
                    Image(systemName: "stop.fill")
                }
                .accessibilityLabel("Stop")
            }
        }
        .buttonStyle(.plain)
        .font(.title3)
    }

    /// Two rows, evenly divided, rather than one cramped line.
    ///
    /// It was a single `HStack` of five controls with mixed label styles — four
    /// with text, one bare icon that read as a rendering fault beside them — and
    /// a screenful of empty space underneath it. Everything was too small to hit
    /// comfortably and the row still ran to the edges.
    ///
    /// Now a four-up grid of equal cells with the icon above its caption, and a
    /// full-width AirPlay row under it. The route deserves the width: it is the
    /// only one of these whose *value* is worth reading at a glance, and "Playing
    /// on Kitchen" is a sentence rather than an icon state.
    private var secondaryControls: some View {
        VStack(spacing: 14) {
            HStack(spacing: 0) {
                speedControl

                if PlatformCapabilities.localStoreIsDurable {
                    bookmarkControl
                }

                controlCell(
                    title: "Chapters",
                    systemImage: "list.bullet",
                    isOn: false
                ) { showingChapters = true }

                controlCell(
                    title: player.sleepTimer == nil ? "Sleep" : "Sleep on",
                    systemImage: player.sleepTimer == nil ? "moon" : "moon.fill",
                    isOn: player.sleepTimer != nil
                ) { showingSleepTimer = true }
            }

            if PlatformCapabilities.supportsAirPlayPicker {
                airPlayControl
            }
        }
        .padding(.horizontal, 20)
    }

    /// One cell of the grid. Equal width, icon over caption, a tap target the
    /// size of the cell rather than the size of the glyph.
    @ViewBuilder
    private func controlCell(
        title: String,
        systemImage: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 17))
                    .frame(height: 20)
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .foregroundStyle(isOn ? theme.accent : theme.text)
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var speedControl: some View {
        Menu {
            ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0], id: \.self) { rate in
                Button {
                    player.rate = Float(rate)
                    app.rememberRate(Float(rate))
                } label: {
                    Label(
                        Format.speed(rate),
                        systemImage: player.rate == Float(rate) ? "checkmark" : ""
                    )
                }
            }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: "speedometer")
                    .font(.system(size: 17))
                    .frame(height: 20)
                Text(Format.speed(player.rate))
                    .font(.caption2)
                    .monospacedDigit()
            }
            .foregroundStyle(player.rate == 1 ? theme.text : theme.accent)
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .accessibilityLabel("Speed")
        .accessibilityValue(Format.spokenSpeed(player.rate))
    }

    /// Opens the list rather than saving silently.
    ///
    /// It used to save and flash "Saved" for a second and a half, which is a
    /// control that does something invisible: the only way to see what had been
    /// saved was to leave the player, find the book and open its screen. The
    /// button that makes bookmarks and the place that shows them were in
    /// different parts of the app.
    ///
    /// The sheet has "Bookmark 1:23:45" at the top, so saving is still one press
    /// away — one press and one tap, in exchange for seeing what is there.
    private var bookmarkControl: some View {
        controlCell(
            title: "Bookmarks",
            systemImage: "bookmark",
            isOn: false
        ) {
            showingBookmarks = true
        }
    }

    /// The AirPlay row.
    ///
    /// The system picker *is* the button — not a styled button of ours that
    /// presses a hidden one, which is what this was. That version existed to
    /// work around taps not landing, and taps were never the problem: the
    /// Simulator has no routes to offer, so the picker has nothing to present
    /// there no matter how it is wired.
    ///
    /// 44pt, because it is a real tap target rather than an icon. The label
    /// beside it is not tappable and does not pretend to be — a full-width row
    /// that only responds in one corner is worse than a control that looks like
    /// one.
    private var airPlayControl: some View {
        HStack(spacing: 10) {
            AirPlayRoutePicker(tint: theme.text, activeTint: theme.accent)
                .frame(width: 44, height: 44)
                .accessibilityLabel("AirPlay")
                .accessibilityValue(route.name ?? "This device")

            VStack(alignment: .leading, spacing: 1) {
                Text(route.isExternal ? "Playing on" : "AirPlay")
                    .font(.caption2)
                    .foregroundStyle(theme.tertiaryText)
                Text(route.isExternal ? (route.name ?? "another device") : "This device")
                    .font(.footnote)
                    .lineLimit(1)
                    .foregroundStyle(route.isExternal ? theme.accent : theme.text)
            }
            .accessibilityHidden(true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(theme.surface, in: .rect(cornerRadius: 10))
    }

    /// Scrubs the whole book, not the current file.
    ///
    /// While the user is dragging, the label follows their finger rather than
    /// the player — otherwise the number jitters against the periodic time
    /// observer and the control feels broken.
    private var scrubber: some View {
        VStack(spacing: 4) {
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
            // Without this the slider announces a percentage of 122 million
            // milliseconds, which is true and useless. A position in a book is
            // hours and minutes, and the remaining time is the number anyone
            // actually wants at this control.
            .accessibilityLabel("Position")
            .accessibilityValue(
                Format.spoken(ms: Int(scrubbing ?? Double(player.absoluteMs)))
                    + ", "
                    + Format.spoken(
                        ms: player.totalDurationMs - Int(scrubbing ?? Double(player.absoluteMs))
                    )
                    + " remaining"
            )
            HStack {
                Text(Format.duration(ms: Int(scrubbing ?? Double(player.absoluteMs))))
                Spacer()
                Text("-" + Format.duration(
                    ms: player.totalDurationMs - Int(scrubbing ?? Double(player.absoluteMs))
                ))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
    }
}

struct ChapterListSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            // Opens where you are, not at chapter one.
            //
            // A forty-chapter book opened at the top and left you scrolling for
            // the one already playing — which the list marks, so the information
            // was there and simply off screen.
            //
            // `.center` rather than `.top`: the reason to open this list is
            // usually to go back one or forward one, and both of those want the
            // neighbours visible.
            ScrollViewReader { scroll in
                List(app.player.timeline?.chapters ?? []) { chapter in
                    Button {
                        app.player.seek(toAbsoluteMs: chapter.startMs)
                        dismiss()
                    } label: {
                        // The same three states the book screen shows.
                        //
                        // This marked the chapter playing and nothing else, so
                        // the list said where you are and not how far you have
                        // come — which on a forty-chapter book is most of what
                        // somebody opens it to see.
                        let standing = ChapterStanding.of(
                            chapterStartMs: chapter.startMs,
                            chapterEndMs: chapter.endMs,
                            positionMs: app.player.absoluteMs,
                            isFinished: false
                        )
                        HStack {
                            // A fixed column, so titles do not shift along as
                            // chapters are finished.
                            Group {
                                switch standing {
                                case .done:
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.secondary)
                                case .playing:
                                    Image(systemName: "waveform").foregroundStyle(.tint)
                                case .ahead:
                                    Color.clear
                                }
                            }
                            .font(.caption)
                            .frame(width: 18)

                            VStack(alignment: .leading) {
                                Text(chapter.title).lineLimit(1)
                                Text(Format.duration(ms: chapter.startMs))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .id(chapter.id)
                }
                .navigationTitle("Chapters")
                .navigationBarTitleDisplayMode(.inline)
                .task {
                    // One hop first, so there are rows to scroll to. Scrolling
                    // an empty List does nothing and says nothing, which is
                    // indistinguishable from not having written this.
                    await Task.yield()
                    guard let current = app.player.currentChapter else { return }
                    scroll.scrollTo(current.id, anchor: .center)
                }
            }
        }
    }
}

/// A scrubber small enough for a bar.
///
/// Its own type because the full player's is bound to that screen's `scrubbing`
/// state, and a second copy of drag handling is a second place for it to go
/// wrong.
private struct MiniScrubber: View {
    @Environment(AppModel.self) private var app
    @State private var scrubbing: Double?

    var body: some View {
        let total = Double(app.player.totalDurationMs)
        let position = scrubbing ?? Double(app.player.absoluteMs)

        HStack(spacing: 8) {
            Text(Format.duration(ms: Int(position)))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

            Slider(
                value: Binding(
                    get: { position },
                    set: { scrubbing = $0 }
                ),
                in: 0...max(total, 1)
            ) { editing in
                // Committed on release, not continuously: seeking on every
                // pixel of a drag rebuilds the queue dozens of times.
                if !editing, let target = scrubbing {
                    app.player.seek(toAbsoluteMs: Int(target))
                    scrubbing = nil
                }
            }

            Text("-" + Format.duration(ms: max(app.player.totalDurationMs - Int(position), 0)))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

struct MiniPlayerBar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    let onTap: () -> Void

    var body: some View {
        // Two rows on an iPad, one on a phone.
        //
        // A phone's mini player is one line because a phone has one line to
        // spare: title, chapter, play. Squeezing a transport, a scrubber and a
        // volume slider onto that same line left the title clipped to a few
        // characters and the artwork the size of a postage stamp — everything
        // present and nothing readable.
        //
        // Two rows gives the book its name back and the controls their room: who
        // is playing above, what you can do about it below.
        Group {
            if sizeClass == .regular {
                VStack(spacing: 10) {
                    HStack(spacing: 14) {
                        CoverImage(thumb: app.nowPlayingThumb)
                            .frame(width: 52, height: 52)
                            .clipShape(.rect(cornerRadius: 8))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.nowPlayingTitle ?? "")
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            if let author = app.nowPlayingAuthor {
                                Text(author)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            if let chapter = app.player.currentChapter?.title {
                                Text(chapter)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer(minLength: 0)

                        // Opens the full player. The strip's tap gesture is gone
                        // on iPad — it would take the taps meant for the
                        // controls — so the way in has to be a control of its
                        // own.
                        Button(action: onTap) {
                            Image(systemName: "chevron.up")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open player")
                    }

                    HStack(spacing: 18) {
                        transport
                        scrubber
                        SystemVolumeSlider()
                            .frame(width: 120, height: 24)
                    }
                }
            } else {
                HStack(spacing: 12) {
                    compactRow
                }
            }
        }
        .padding(.horizontal, sizeClass == .regular ? 18 : 12)
        .padding(.vertical, sizeClass == .regular ? 10 : 8)
        // A card on an iPad, a strip on a phone.
        //
        // A full-width slab of material sitting under a floating capsule tab bar
        // is two visual languages stacked: the bar below floats, this did not,
        // and the join between them read as a mistake.
        //
        // Rounded, inset and on the same material as the tab bar, it becomes the
        // upper half of one floating control rather than a panel with a pill
        // stuck to it. On a phone the strip is right: it spans a screen that has
        // no width to give away, and the tab bar there is the system's.
        .background(
            sizeClass == .regular ? AnyShapeStyle(.ultraThinMaterial)
                                  : AnyShapeStyle(.regularMaterial),
            in: .rect(cornerRadius: sizeClass == .regular ? 20 : 0)
        )
        // Clipped before the border is drawn, or the stroke loses its outer half
        // to its own clip.
        .overlay(alignment: .top) {
            GeometryReader { geometry in
                Rectangle()
                    .fill(.tint)
                    .frame(width: geometry.size.width * app.player.progressFraction, height: 2)
            }
            .frame(height: 2)
        }
        .clipShape(.rect(cornerRadius: sizeClass == .regular ? 20 : 0))
        .overlay {
            if sizeClass == .regular {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
            }
        }
        .padding(.horizontal, sizeClass == .regular ? 20 : 0)
        .padding(.bottom, sizeClass == .regular ? 6 : 0)
        .contentShape(.rect)
        // Only where there is nothing else to press.
        //
        // On an iPad the card holds five buttons, a draggable scrubber and a
        // volume slider, and a tap gesture over all of it would take the taps
        // meant for them. The chevron in the top row is the way into the full
        // player there.
        .onTapGesture { if sizeClass != .regular { onTap() } }
        // Combined on a phone, where the whole strip is one button that opens
        // the player. Not on an iPad: there are seven real controls in it now,
        // and combining them would hide every one behind a single label.
        .accessibilityElement(children: sizeClass == .regular ? .contain : .combine)
        .accessibilityLabel(app.nowPlayingTitle ?? "Now playing")
        .accessibilityValue(app.player.currentChapter?.title ?? "")
        .accessibilityHint(sizeClass == .regular ? "" : "Opens the player")
    }

    /// The Mac's arrangement, at a bar's size.
    private var transport: some View {
        HStack(spacing: 16) {
            Button { app.player.skipToPreviousChapter() } label: {
                Image(systemName: "backward.end.fill")
            }
            .accessibilityLabel("Previous chapter")

            // The configured interval, not thirty. The full player has always
            // used `skipIntervalSeconds`; a bar that ignored it would skip a
            // different distance from the same book.
            Button { app.player.skip(bySeconds: -app.player.skipIntervalSeconds) } label: {
                Image(systemName: "gobackward.\(app.player.skipIntervalSeconds)")
            }
            .accessibilityLabel("Back \(app.player.skipIntervalSeconds) seconds")

            Button { app.togglePlayPauseRespectingOffline() } label: {
                Image(systemName: app.player.state == .playing ? "pause.fill" : "play.fill")
                    .font(.title3)
            }
            .accessibilityLabel(app.player.state == .playing ? "Pause" : "Play")

            Button { app.player.skip(bySeconds: app.player.skipIntervalSeconds) } label: {
                Image(systemName: "goforward.\(app.player.skipIntervalSeconds)")
            }
            .accessibilityLabel("Forward \(app.player.skipIntervalSeconds) seconds")

            Button { app.player.skipToNextChapter() } label: {
                Image(systemName: "forward.end.fill")
            }
            .accessibilityLabel("Next chapter")
        }
        .buttonStyle(.plain)
    }

    private var scrubber: some View { MiniScrubber() }

    /// The phone's one line: cover, title, chapter, play.
    @ViewBuilder
    private var compactRow: some View {
        CoverImage(thumb: app.nowPlayingThumb)
            .frame(width: 40, height: 40)
            .clipShape(.rect(cornerRadius: 6))

        VStack(alignment: .leading, spacing: 1) {
            Text(app.nowPlayingTitle ?? "")
                .font(.footnote.weight(.medium))
                .lineLimit(1)
            Text(app.player.currentChapter?.title ?? "")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }

        Spacer(minLength: 8)

        Button { app.togglePlayPauseRespectingOffline() } label: {
            Image(systemName: app.player.state == .playing ? "pause.fill" : "play.fill")
                .font(.title3)
        }
        .buttonStyle(.plain)
    }
}

/// The system volume, not the player's.
///
/// `AVPlayer.volume` exists and is the wrong thing to put on a slider here: the
/// sleep timer already uses it to fade out, so a slider bound to it would fight
/// the fade and end up somewhere neither meant. It is also per-app, which means
/// it would disagree with the hardware buttons and with Control Centre.
///
/// `MPVolumeView` is the system's own control. There is no SwiftUI equivalent —
/// wrapping the UIKit view is the supported way, and Apple does not allow setting
/// the volume programmatically at all, which is why this is a view rather than a
/// binding.
///
/// It does nothing in the Simulator, which has no volume to change.
struct SystemVolumeSlider: UIViewRepresentable {
    // `showsRouteButton` was deprecated in iOS 13 in favour of
    // `AVRoutePickerView` — but that is a separate, additive control for
    // *showing* a route button, not a setting on `MPVolumeView` for
    // suppressing its own. `AirPlayRoutePicker` above already wraps
    // `AVRoutePickerView` and is on screen elsewhere in the player; without
    // this line `MPVolumeView` defaults to `true` and draws a second, redundant
    // route button beside the volume slider. There is no non-deprecated way to
    // ask for the first without the second, so the deprecated call is kept and
    // silenced here rather than worked around with something that reads as
    // accidental.
    @available(iOS, deprecated: 13.0, message: "kept: no replacement hides MPVolumeView's own route button")
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        // The route button belongs to AirPlay, which the full player already
        // has. Two of them is one too many.
        view.showsRouteButton = false
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {}
}
