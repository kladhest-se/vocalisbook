# Changelog

## 1.0.1 - Unreleased

Not released. Everything under this heading is in the working tree and has not
been submitted to Apple. `MARKETING_VERSION` in `Config` already reads 1.0.1, so
a development build is never mistaken for the one on the Store.

When this ships, the heading becomes `## 1.0.1 - <date>` and a fresh
`## 1.0.2 - Unreleased` opens above it.

### A library over 500 books showed 500 of them

`books(sectionID:)` had `limit: Int = 500` and all three grids took the default.
Sorted by title, the missing ones were a contiguous run from somewhere in the
alphabet to the end, and nothing on screen said so — it reads as books failing to
sync rather than as a screen declining to show what it already had.

The limit is `Int?` now and defaults to nil, meaning every book. It stays
available because paging is a reasonable thing for a caller to want later, and
`offset` is only meaningful beside it; nil maps to SQLite's `LIMIT -1`, which is
how it spells "no limit" while still honouring an offset.

Search is unchanged and still returns at most fifty matches. That one is a
product decision about a text field rather than a screen quietly truncating a
library.

### A series drilled into every library at once

`series(sectionID:)` builds the list of series from one library section.
`books(inSeries:)` had no section at all and built the books behind each entry
from every section cached on the device — a second audiobook library, or one
still cached from a server signed out of. The row said two books and the page
showed four.

It takes a section now. The next-in-series walk is confined the same way, taking
the section from the book it is asked about rather than from a caller, since
"what comes after this one" is a question about one library. Finishing Dune #1
could otherwise have offered Dune #2 from a server the screen was not looking
at.

### A collection's order no longer calls itself a series

Both sources of "next" said the same thing on screen — "Next in Dune" —
regardless of whether the position came from the agent's `Sequence:` tag or from
the order somebody dragged books into a Plex collection. `NextInSeries.source`
existed to tell them apart and nothing read it.

A tag now says "Next in Dune" and a collection says "Next in the Dune
collection". Both are still offered; only one of them claims to know the reading
order. The client contract asks that collections be treated as user data and
that a series not be derived from them alone, and the label was the one place a
person would ever have seen the difference.

### A truncated LibriVox GUID was a shared book identity

`librivox:` alone — the prefix with nothing after it — parsed as the identity
`spokenmeta:librivox:`, which is portable and strong and which every book with a
truncated GUID in a library would have shared. Progress, bookmarks and
completion all key on this, so they would have merged across those books and the
merge would have synced.

The other three forms are guarded by a length: an ISBN is thirteen characters, a
local fingerprint sixteen, an ASIN ten. LibriVox ids are any length, and both
remaining checks pass vacuously on an empty string — `"".first` is not `"0"`,
and `allSatisfy` on nothing is true. It now requires a non-empty value.

Digit and hex checks tightened to ASCII in the same pass. `isNumber` is also
true for Arabic-Indic digits and vulgar fractions, and `isHexDigit` for the
fullwidth forms; the contract's regexes are `[0-9]` and `[0-9a-f]`.

### Every Plex tag was being thrown away

Narrators were empty. So, silently, were genres, co-authors, series tags,
language, edition, work identity and every contributor — anything VocalisMeta
writes as a `Genre`, `Mood` or `Style` child on an album.

Plex sends those as `{"id": 1201, "filter": "style=1201", "tag": "Scott Brick"}`.
The `id` is a number. `PlexBook.Tag` declared it `String?` — it has to be a
string, because a `Guid` child carries its value there — and the synthesised
decoder asks `decodeIfPresent(String.self)`, which throws on a number rather
than returning nil. `plexArray` decodes element by element and skips whatever
throws, which is the right behaviour for one bad entry in a good list and
exactly the wrong one here: every entry had a numeric id, so every entry was
skipped. A fully tagged book decoded to empty lists with no error anywhere.

`Tag` now decodes its id through the same lenient helpers every other field in
the package uses, so it reads as a string whether Plex sends a number or one.

The `tag` field stays strict, and the asymmetry is the point. `id` is genuinely
sent two ways — a number on a Genre, Mood or Style child, a string on a `Guid`
child — while `tag` is always a string, so a numeric one is malformed rather
than a second dialect. Reading it leniently as well turned `{"tag": 12345}` into
an author called "12345".

Every fixture in the decoding tests was written as `{"tag": "..."}` with no id
— a shape Plex never sends — so they all agreed with each other and none of
them agreed with the server. Four tests added against the real shape, including
a twelve-narrator book, a narrator with no `Contributor-ID` (Style alone is
enough to be a narrator; the identity is an addition, never a condition), and a
`Guid` child, which is why `Tag.id` is a string in the first place.

### The contract has four contributor sources; the client knew three

`metadata-contract-v3.json` lists `audible`, `librivox`, `openlibrary` and
`name` under `source_identifier_regex`. The client validated the first three and
rejected everything else, so every `Contributor-ID: narrator:name:...` Mood was
discarded as malformed — and that is most narrator credits on a real library,
since a narrator rarely has a provider page of their own. Dune sends twelve of
them and the client kept none.

`name` is now accepted, as sixteen lowercase hex digits. Spelled out as a
character set rather than `isHexDigit`, which also accepts uppercase and the
fullwidth forms — an identifier the contract calls malformed should stay
malformed.

Checked against the published contract itself rather than from memory of it,
which is also how the missing source was found.

### Narrators group by identity where there is one

The precedence, in order: a provider-backed narrator identity, then the
deterministic `name:` one, then the plain `Style` value. The contract draws that
line itself — a `name:` identifier is documented as a deterministic fallback
rather than an authoritative person id, so where both exist for one person the
provider-backed one wins.

`Style` alone is still enough to be a narrator. The identity is an addition to
one, never a condition for being one, and most narrators on most libraries have
none.

Identities are resolved across the whole library section rather than per book. A
narrator credited with an identity on one recording and with a bare `Style`
value on another is one person either way, and keying the second by name while
the first is keyed by identity would split them in two — worse than the
name-only grouping this replaces, not better. The map is name-first for the same
reason: it can merge two spellings that share a key, and can never split one
name across two entries.

A narrator's own page follows the same resolution, so the book count on a row
and the books behind it cannot disagree.

Two different provider-scoped keys are never merged because their display names
match — the integration document forbids it. Where two recordings credit one
name with two different keys, neither wins and the name does the grouping, which
puts both books under one entry without asserting that either catalogue entry is
the other. The precedence only ever chooses between two keys the agent attached
to the same credit.

The `name` source is narrator-only, as the integration document states: it is a
fingerprint of a narrator's normalized display name, and an author either has a
provider behind them or has no contributor identity at all.

### Books cached by the old decoder ask Plex again

Fixing the decoder changes nothing on a library already synced. A book is only
re-fetched when its `updatedAt` moves on Plex, and none of these moved — the
server was always right, the client could not read it. Left alone, the tags
would arrive only when each book happened to be edited in Plex, which for most
books is never.

Migration v12 clears `plex_updated_at` on every book, which is what makes that
comparison disagree, so each book gets one detail fetch. It touches one nullable
column and leaves every track, download, bookmark and position where it is —
dropping the tag tables instead would have emptied the browse screens until the
whole backfill finished rather than only until each book's turn.

Detail fetches stay capped at fifty per sync, so a large library fills in over
several syncs rather than hanging on one. Each sync leaves it more complete than
it found it.

### Authors are writers now, and nothing else

The list of authors was built from two sources unioned together: the writers
the VocalisMeta agent credits, and Plex's own album artist. The second one is
`parentTitle` — whatever the scanner made of the files' `ALBUMARTIST` tag — and
in an audiobook library that field is as often the narrator as the writer, or
both joined with a comma, or two co-writers as one string.

That put narrators on a screen headed Authors, and produced duplicates: a
library showed "Terry Pratchett" beside "Terry Pratchett, Stephen Baxter",
because nothing normalises names and the two are different strings. Splitting on
the comma would not have fixed it — `Last, First` and `Jr.` both contain one.

The album artist is no longer consulted. `authors` and `books(byAuthor:)` read
`book_author` alone, so the index and the page behind it agree about what an
author is. The cost is stated rather than hidden: a book the agent has not
matched carries no `Mood` credit, so it has no writer and appears under nobody.
A book's own screen still falls back to the album artist for the name under its
cover, because a blank label is worse than one that is only probably right — but
an index that claims someone writes books is worse than either.

All three platforms, since the change is in the store.

### One Browse tab in place of three, with the switch on the title

Authors, Series and Genres were three of the five tabs iOS allows, and they were
the same screen three times: a list of names, each with a cover and a count, and
a set of books behind it. Narrators made a fourth, hidden behind a segmented
control inside Authors because a sixth tab would have fallen into iOS's own
unthemed "More" bucket.

They are one screen now. Tapping the navigation title opens a menu — Writers,
Narrators, Series, Genres — the pattern Mail uses for mailboxes and Files for
locations. It costs no vertical space, where the segmented control took a strip
across the top of every list permanently, and it does not shrink its labels to
fit the way that control would have at four.

The tab bar is Home, Books and Browse. Books is the full library grid, every
book at once; Browse is the indexes into it.

Searching clears when the mode changes: a search for "Pratchett" carried into
Genres filters every genre away and reads as a library with no genres in it.

iPhone and iPad only. The Mac and the television have room for the tabs they
have and a different problem to solve.

## 1.0.0

The first release. Everything below is new.

### Listening

- Plays audiobooks from a Plex Media Server on iPhone, iPad, Mac and Apple TV.
- Keeps your place in book-absolute time, so a book split across ninety files
  behaves like one book.
- Chapters from Plex, from the file's own metadata, or from track boundaries —
  whichever the book actually has, and the screen says which.
- Adjustable speed, remembered per book.
- Sleep timer, by duration or to the end of the chapter, fading out rather than
  cutting.
- Smart rewind: a longer pause rewinds further, up to a cap.
- Bookmarks, with labels, on all three platforms.
- Next in series, taken from the Plex collection's own order.
- Mark a book finished or unfinished by hand, and start one again from the
  beginning.

### Finding things

- Library grid, with search by title or author.
- Browse by author, genre or collection.
- Continue listening, on the home screen.
- Listening history: a streak, this week, all-time totals and a best day.

### Siri and Shortcuts

- "Continue listening in VocalisBook" resumes the book you were last in. iPhone and
  iPad only for now — the Mac has the Shortcuts app but not the phrase, and tvOS
  has neither.

- Narrators, series, language and abridgment appear on a book's screen, from the
  tags the VocalisMeta agent writes. Plex has no field for any of them, so that
  agent stores narrators as Style and the rest as Mood, and VocalisBook reads them
  where they are. Anything the agent could not determine is left out rather than
  guessed at.

- Bookmarks, playback speeds and listening history follow a book rather than a
  server, the same way your place already did — so a second Plex server holding
  the same audiobook shows the same bookmarks rather than someone else's.
- Your place follows a book rather than a server. Where the VocalisMeta agent has
  matched a book, progress syncs under that book's own identity — so the same
  audiobook on a second Plex server picks up where you left off instead of
  starting again.

- "Next in series" uses the series position the metadata agent recorded, so it
  follows the actual reading order — including novellas numbered 3.5. Plex
  collections are still used for libraries the agent has not matched.

- A book's screen says where it sits in its series — "Discworld · Book 6 of 9 in
  your library". The count is of the books your library holds, which is why it
  says so: the metadata agent does not know how many a series contains.
- A Series tab, on all three. Fetching series is one request per series, so the
  screen says what it is doing and how far along while it works. Every series in your library, and the books in
  each in the order the metadata agent recorded — including novellas numbered
  3.5. A book the agent placed in a series without saying where still appears,
  at the end, rather than being given a made-up number.

- A stop button beside pause. Pausing keeps the book loaded and leaves a session
  open on your Plex server; stopping ends it. Your place is kept either way.

- When this device and your server disagree about where you are in a book,
  VocalisBook asks instead of choosing. It happens only when both moved while they
  could not reach each other.
- An author's page now includes books they co-wrote, not only the ones Plex
  filed under their name.

- Settings has one pair of buttons on every platform: Clear listening history,
  and Clear local cache.
- Settings can remove everything cached on a device: the library, downloads and
  listening state. It is fetched again from Plex, and from iCloud where you sync
  — for when something local has gone wrong and starting over is easiest.

- Changes from another device arrive as soon as they are made, rather than
  within a few seconds: the app now receives iCloud's notifications instead of
  only asking on a timer.

- The player no longer opens when a book cannot start — including when VocalisBook
  needs to ask which position to keep, a question that could not be asked while
  the player was covering it.
- Book titles, author names and other metadata containing accented characters
  no longer display as garbled text (e.g. "GarcÃa" instead of "García") when
  Plex's metadata agent has stored them with the wrong encoding.
- Signing out and into a different Plex server no longer leaves the old
  server's books showing in Continue listening. Downloads from a server you've
  since switched away from are also reclaimed rather than sitting unseen.
- Fixed a crash when two devices were playing at once, which then repeated on
  every launch until the app was reinstalled.

- Home has a "Recently listened to" section: the books you have finished, most
  recent first. Finishing one used to be the moment it left the app.
- The chapter list marks what you have finished and what is playing, so it says
  where you are in a book rather than only what the book contains.
- A book's screen has a tick instead of a More menu: press it to mark a book
  finished, press it again to put it back to the beginning. Your server is told
  either way, so a book you finish here shows as played in Plex — and one you
  un-finish goes back to unplayed rather than staying at 100%.

- A book is credited to its author rather than to whoever the files were tagged
  with, where your metadata agent has named one. Audiobook files very often carry
  the narrator as the album artist, which is why a biography could appear under
  the name of the person who read it.

- Artwork no longer paints over the title and the controls beneath it. Covers
  that are not square were overflowing their frame.
- Chapter lists in the player mark what you have finished as well as what is
  playing, on every platform.

- The bookmark button in the player opens your bookmarks for that book, with a
  button at the top to save the place you are at. Previously it saved silently,
  and the list was only on the book's own screen.

- Stopping a book keeps your place. It ends the session on your server and in
  your history, and pressing play carries on where you stopped — which is the
  only thing that should differ between stop and pause.
- Stopping a book now tells your Plex server it stopped, so the session leaves
  the dashboard instead of sitting there as paused until it times out.

- When VocalisBook has fallen back to Plex's relay, the account screen says so and
  says what to check — the relay is slower to start and to seek, and it is only
  used when every local address failed.

- Four more themes: all of Catppuccin's flavours — Latte, Frappé, Macchiato and
  Mocha — taken from the published palette rather than approximated.

### Elsewhere

- Continue listening updates itself. Whatever changes it — this device, another
  device through iCloud, or Plex — the list follows without being told, on all
  three platforms.
- Continue listening is checked against Plex when the app opens and when it
  catches up: a book finished elsewhere leaves the list, and a position further
  along on the server is adopted.
- On the Mac, choosing a server and choosing a library show the app icon and
  name, with the choices as cards rather than table rows.
- Settings can clear your listening history: this device's, and the copy in
  iCloud when the device syncs. Your library and downloads are kept, and opening
  a book still picks up where Plex says you were.

- Your place syncs through Plex, so you can start on the phone and finish on the
  Apple TV.
- What you are listening to — the books on the go, where you are in each, and
  when you finished one — is the app's own record, kept the same on your devices
  through iCloud. Plex holds the position within a file and is told about it as
  you listen, so other Plex apps stay in step.
- iCloud sync can be turned off in Settings. Everything still works; positions
  still travel through Plex. Turning it back on is a full resync: this device's
  synced state is replaced by what iCloud holds.
- Settings shows what iCloud sync has actually done — running or not, records
  sent and received, and the last error if there was one.
- Home keeps up on its own: pause a book on one device and it appears on the
  others within a few seconds, without leaving and reopening the app.
- Downloaded books carry a badge on their cover, so the library shows what is on
  the device without opening anything.
- Offline downloads on iPhone, iPad and Mac. Downloads wait for Wi-Fi unless you
  say otherwise, and playback prefers a downloaded file without being told.
- Offline mode, which narrows the library to what will actually play.
- AirPlay, and the Now Playing controls on the Lock Screen, Control Centre and
  the Mac's menu bar.
- CarPlay is not supported yet.

On the Apple TV, History's recent days are cards along a row rather than a list
of thin rows — sized to be read from a sofa, with a bar for each day so a
fortnight can be compared at a glance.

On the Mac, starting a book — or clicking the artwork in the player bar — opens a
Now Playing panel where the sidebar was, with the cover, the controls and the
chapter list, and the book still on screen beside it.

On the Mac: the sidebar is fixed to the window edge and no longer collapses, the
toolbar and search sit together on the left and stay put, a button drops straight
to the mini player, and the mini player's artwork shrinks with the window so the
controls stay reachable however small you make it.

Previously on the Mac: search moved out of the toolbar and above the library it filters, so
the buttons beside it stop moving when the sidebar opens and closes. Continue
listening is on Home rather than repeated in the sidebar, the streak card opens
your history, and the window can be kept above other apps — from Settings or the
menu bar. The File, Edit, View and Help menus are gone, since the app had nothing
to put in them.

On the Apple TV: the sessions under an expanded day can be reached and read, and
Settings rows stay legible when selected — several themes put white text on the
system's white highlight.

Downloads management is a level inside Settings on iPhone and iPad, as it is a
sidebar row on the Mac: what is on this device, what it is taking up, and a way
to remove it. A quicker glance — what is already downloaded, while still
browsing — is a toggle beside search in Browse.

### Per platform

- **iPhone and iPad** — tabs, a mini player above them, a full player sheet. On
  an iPad the covers are larger and the player turns on its side.
- **Mac** — sidebar, grid, and the transport docked at the bottom of the window.
  Collapses to a compact player below 620pt wide. Browsing into an author,
  series or genre keeps a breadcrumb trail, so going back steps up one level
  rather than straight to the top.
- **Apple TV** — a focus-driven grid, a full-screen player, and search. Bookmarks
  are a list on the book, since a television has no swipe to delete with.
