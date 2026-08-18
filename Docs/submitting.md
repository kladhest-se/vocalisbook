# Submitting to Apple

What App Store Connect asks for that is not in the build, and what has already
been answered inside it. Written down because a submission stalls on the fields
nobody prepared, not on the code.

## Already answered in the build

These need nothing at submission time. They are here so that a rejection
mentioning one of them is recognisable rather than mysterious.

| Asked | Where it is answered |
| --- | --- |
| Export compliance | `ITSAppUsesNonExemptEncryption` is `false` in every `Info.plist` |
| Privacy manifest | `PrivacyInfo.xcprivacy` in each app's `Sources` |
| Data collection | Declared as none — there is no analytics and no third-party SDK |
| Mac category | `LSApplicationCategoryType`, `public.app-category.music` |
| Copyright | `NSHumanReadableCopyright` on the Mac |
| Push capability | `aps-environment`, which the App ID must also have enabled |

## Still to do outside the build

**Enable Push Notifications on the new App ID.** Was done, for
`se.kladhest.plextales` — the rename to `se.kladhest.vocalisbook` means a new
App ID, and this has to be granted again on it. The entitlement asks for it and
the portal has to grant it, or signing fails with a profile that does not
match.

**Create the CloudKit container and deploy its schema to Production.** Also
done for the old container and not carried over — `iCloud.se.kladhest.vocalisbook`
is a genuinely separate container, not a renamed one, and starts with no
schema at all. Test against Development first, the same as before; a build
shipped before Production is deployed syncs nothing, silently, which is the
failure mode this app has spent the most effort eliminating everywhere else.

**Screenshots**, one set per device class. Apple now scales the largest size down
to cover the older classes, so the required sets are: iPhone 6.9" at 1320×2868,
iPad 13" at 2064×2752 — required because the iOS build ships
`TARGETED_DEVICE_FAMILY = 1,2` and so is an iPad app — Apple TV at 1920×1080, and
the Mac at 2880×1800. They live in `Docs/app-store/`, numbered in upload order.

Two things reject a screenshot outright regardless of its contents: an alpha
channel, and 16 bits per channel. Captures off a device have arrived with both.
The screens worth showing are Home with something part-way through, the player,
and a grid with real cover art in it — a filtered search or a screen holding
three books reads as an empty app on a 13" canvas.

**A privacy policy URL.** `https://vocalisbook.kladhest.se/?privacy`, served by
`public-web/index.php` — the same one file as the marketing page, branching on a
query string so no rewrite rule has to survive a server move. The text below is
what it says; changing one means changing the other, and the date at the top of
the page is set by hand rather than by `date()`.

**A support URL.** Somewhere a person can write to. The GitHub repository's
issues page is enough and is already public.

## App Review notes

A demo account is provided: a Plex account signed into a test server whose
library contains only public-domain and openly-licensed audiobooks. Built
specifically so the review copy shows no commercial cover art or protected
material at all — see item 7 below, which this removes rather than merely
answers.

A screen recording is attached alongside the credentials, not instead of
them — Apple's own request lists the two as separate items, and a working
account makes the recording more useful rather than less: it stops being
"trust us this works" and becomes a faithful preview of exactly what the
reviewer is about to reproduce themselves. Recorded continuously on a real
device rather than as edited clips, since a cut reads as hiding something.
Covers, in order: launching the app; signing in through Plex's PIN flow,
including the local network permission prompt — `NSLocalNetworkUsageDescription`
appears the moment the app looks for a server on the network, and it should be
left to appear on screen and be granted there rather than pre-approved before
recording starts, since it is the app's one prompt for sensitive device
access and Apple's list asks for it by name; browsing by author and series;
playing a book with real chapters and a bookmark; downloading a book and
switching to offline mode; and the listening history screen.

## Additional information for App Review

Apple's own seven-item list, from a previous submission's request for more
detail. Kept here rather than only in the notes field, since the field has a
character limit this does not.

**1. Screen recording.** See above.

**2. Devices and OS versions tested on.** _Tommy to fill in._

**3. What the app does, and for whom.** VocalisBook is a native audiobook
player for a Plex Media Server the user already owns and runs. Plex's own
apps present audiobooks as albums of music tracks — no book-level position, no
chapter navigation, no per-book playback speed. VocalisBook adds the layer a
Plex-based library needs to be listened to as audiobooks rather than browsed
as music: a position kept in book-absolute time across however many files a
book is split into, chapters from whichever source actually has them,
adjustable speed remembered per book, a fading sleep timer, labelled
bookmarks, and offline downloads. The audience is self-hosted media
enthusiasts who already run Plex and want their audiobook collection to
behave like one.

**4. Setup and access instructions.** Sign-in uses Plex's own account system
via plex.tv (`ASWebAuthenticationSession`, so the app never sees a password).
On first launch the app requests a PIN and opens a web view to complete
sign-in with the account below. Once signed in, the app lists the Plex
servers visible to that account; select the test server and the library
loads automatically.

    Test account:  _email / password, to fill in_
    Test server:   _name, reachable without VPN or local network access_
    Test library:  audiobooks that are entirely public-domain or openly licensed

**5. External services the app depends on for core functionality.**

- **Plex Media Server** — the user's own, self-hosted. Source of the
  audiobook library, artwork, and file streaming.
- **plex.tv** — Plex's authentication service. Sign-in only; no data beyond
  an auth token passes through it.
- **Apple CloudKit (iCloud)** — cross-device sync of bookmarks, playback
  position, and listening history, under the user's own iCloud account.
  Optional: the app functions fully with sync switched off.

No analytics, advertising, or third-party SDK of any kind. No payment
processor — the app is free with no in-app purchases.

**6. Regional differences.** None. Every screen is entirely a function of
what the connected Plex server's library contains, and there is no
server-side gating in the app itself. Functions consistently across all
regions.

**7. Regulated industry or protected third-party material.** VocalisBook is a
general-purpose media client, the same category as Plex's own official apps,
Infuse, and Swiftfin — it displays whatever content the connected server's
owner has legally added to their own library, and hosts, bundles, or
distributes nothing itself. The demo account's library contains only
public-domain and openly-licensed audiobooks specifically so the review copy
raises no question about protected material at all.

## Draft description

> VocalisBook plays the audiobooks on your own Plex server.
>
> It is built for listening rather than for browsing a media library: your place
> is kept per book and to the millisecond, whether a book is one file or ninety.
> Pick it up on your phone, your Mac or your Apple TV and it resumes where you
> stopped — your position goes back to Plex, and the rest of your listening
> state travels through your own iCloud account.
>
> Chapters come from wherever they exist: Plex's own data, the markers inside the
> file, or the file boundaries as a last resort. Speed is remembered per book,
> because a dense history and a novel do not want the same one. The sleep timer
> fades rather than cutting, and can stop at the end of the chapter.
>
> Download books to your iPhone or Mac for a flight, and switch on offline mode
> to narrow the whole library to what will actually play. Bookmark a passage and
> find it on another device. Browse by author, series or genre, and see which
> narrator read a book, when your metadata agent has provided them.
>
> VocalisBook collects nothing. There is no account with us, no analytics and no
> third-party services — your library, your listening and your server stay
> yours.
>
> Requires a Plex Media Server with an audiobook library.

## Draft keywords

Fewer than a hundred characters, comma separated, no spaces after commas, and no
words already in the app's name or subtitle:

    audiobook,plex,player,books,listening,chapters,bookmarks,sleep timer,offline

## Draft privacy policy

Publishable as-is at a URL of your choosing.

> **VocalisBook privacy policy**
>
> VocalisBook does not collect, transmit or store any personal information.
>
> The app talks to two services, both of which are yours: the Plex Media Server
> you sign in to, and your own iCloud account. Your library, your listening
> position, your bookmarks and your history are held on your devices, on your
> server, and in your private iCloud database. The developer has no access to
> any of it.
>
> There is no analytics, no crash reporting, no advertising and no third-party
> SDK of any kind.
>
> Signing in uses Plex's own authorisation flow. VocalisBook stores the resulting
> token in the system keychain on your device and sends it only to your own
> server.
>
> Deleting the app removes everything it kept on that device. Data held in your
> iCloud account can be removed from iCloud settings, and data on your Plex
> server is governed by Plex's own terms.
>
> Questions: <https://github.com/kladhest-se/vocalisbook>, or kladhest@tutamail.com

## Before pressing Upload

- The version is 1.0.0 in `Config`, and `make <port>-archive` bumps the build
  number and passes it to `xcodebuild archive` directly — Xcode's own Archive
  action alone would carry the deliberate `1` sentinel instead.
- `make publish-all` passes, including the tests.
- A real device has run the build, not only a simulator.
- Sync has been checked between two devices — pause on one, and the other should
  follow within a second or two.
