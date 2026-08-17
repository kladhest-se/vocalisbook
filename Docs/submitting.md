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

**Enable Push Notifications on the App ID.** Done. The entitlement asks for it
and the portal has to grant it, or signing fails with a profile that does not
match.

**Deploy the CloudKit schema to Production.** Done. Everything tested before that
ran against the development container. A build shipped before the schema is
deployed syncs nothing, silently, which is the failure mode this app has spent
the most effort eliminating everywhere else.

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
> Questions: <https://github.com/kladhest-se/vocalisbook>

## Before pressing Upload

- The version is 1.0.0 in `Config`, and the build number increments per port.
- `make publish-all` passes, including the tests.
- A real device has run the build, not only a simulator.
- Sync has been checked between two devices — pause on one, and the other should
  follow within a second or two.
