# Daily listening statistics

Statistics count the union of elapsed wall-clock intervals in closed listening sessions for the selected library, including sessions received through iCloud. Playback speed and seeks do not change elapsed time: an hour at 1.5× counts as one hour of listening.

## Calendar days and weeks

A session crossing local midnight contributes only its overlapping portion to each day. For example, listening from 23:50 to 00:20 credits 10 minutes to the first day and 20 to the second. Both days appear in history, and both can contribute to a streak. A session ending exactly at midnight contributes nothing to the following day.

Day boundaries come from the display calendar and current time zone. They are not fixed 24-hour periods: clock-change days can have 23 or 25 hours, and some time zones change clocks at midnight. Changing the display time zone can move listening between dates; original timestamps remain intact so the results can be recomputed.

“This week” uses the calendar's week interval and first weekday. The chart, total and average use that same interval, including when it spans New Year. Future days display empty bars. The average divides by days with credited listening in the current week. Streak dots and recent history continue to show their rolling seven-day and fourteen-day windows.

The current streak can continue through yesterday when today is still empty. The longest streak counts consecutive calendar days with credited listening. Equal best-day totals consistently select the earliest date.

## Valid time and precision

Statistics never credit time after the requested `now`. Sessions with no end, reversed times or zero duration contribute nothing. An open session appears after playback pauses/stops and saves its end. Startup recovery closes an abandoned local session at its last confirmed checkpoint; older rows without checkpoints receive no guessed listening time. Buffering and playback failures end the active interval.

Session durations are accumulated at the database's millisecond precision and converted to whole seconds once per day. This retains short pause/resume intervals that used to be discarded individually. A daily remainder below one second is omitted from displayed totals; each detail row also displays its own whole-second duration.

Overlapping recordings from multiple devices count once in daily totals. Source session rows remain intact, so their individual durations may add up to more than the deduplicated daily total; the history view explains this when relevant. The selected day's details include sessions that began earlier but overlap that day. Their displayed start/end and duration are clipped to that day's portion. Original book offsets remain available on `SessionSummary` and are not interpolated across seeks or speed changes. No session rows are rewritten and no database migration is required.

Home and History refresh after local history updates, a calendar-day or time-zone change, and returning to the app. Changing the selected library clears the previous library's expanded history details.

## Verification

Regression tests cover midnight and multi-day sessions, exclusive midnight endpoints, Stockholm's spring/autumn transitions, a midnight clock change in São Paulo, changing display time zone, custom week starts, Sunday/Monday and New Year boundaries, short sessions, invalid/future/open rows, tied best days and library scoping. The tests verify original stored session rows remain unchanged. Tests use temporary databases without live accounts.

Validation passed: **529 package tests** (127 PlexKit, 306 Audiobooks, 53 Platform/Shared and 43 Mac platform), platform consistency checks and unsigned iOS/macOS/tvOS app builds. This includes 13 new daily-statistics tests. Native day/time-zone notifications and real playback remain device-level checks.
