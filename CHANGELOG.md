# Changelog

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
  tags the SpokenMeta agent writes. Plex has no field for any of them, so that
  agent stores narrators as Style and the rest as Mood, and VocalisBook reads them
  where they are. Anything the agent could not determine is left out rather than
  guessed at.

- Bookmarks, playback speeds and listening history follow a book rather than a
  server, the same way your place already did — so a second Plex server holding
  the same audiobook shows the same bookmarks rather than someone else's.
- Your place follows a book rather than a server. Where the SpokenMeta agent has
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
