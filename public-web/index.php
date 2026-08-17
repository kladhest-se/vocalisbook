<?php
/**
 * vocalisbook.kladhest.se — one page.
 *
 * PHP rather than static HTML because the screenshots are a directory: the
 * shelves below read what is actually in `screenshots/`, so adding a file to
 * that folder adds it to the page and removing one removes it. A hand-written
 * list of fourteen <img> tags is a list that goes stale the first time somebody
 * retakes a screenshot.
 *
 * No framework and no build step. One file, one stylesheet, one folder of
 * images — which is the whole of what this needs to be, and means it can be
 * dropped on any host with PHP and nothing else.
 *
 * Two routes, not one. `/?privacy` renders the privacy policy instead of the
 * marketing page. A query string rather than `/privacy` because a path would
 * need a rewrite rule, and a rewrite rule is a second file on the host that has
 * to survive whoever configures it next — the App Store field takes either, and
 * this one cannot be broken by a server move.
 */

declare(strict_types=1);

/**
 * Which page this request is for.
 *
 * Only the key is read; the value is never used or printed, so there is nothing
 * here to escape.
 */
$isPrivacy = isset($_GET['privacy']);

/**
 * When the policy last changed, by hand.
 *
 * Not `date()`. A policy that stamps itself with today's date claims to have
 * been reviewed today, every day, which is untrue on all but one of them — and
 * the date is the one part of a privacy policy a reader is entitled to trust.
 * Changing the text below means changing this line.
 */
const PRIVACY_UPDATED = '16 August 2026';

/** Where the apps live once they are published. */
const STORES = [
    'ios' => [
        'name' => 'iPhone & iPad',
        'store' => 'App Store',
        'url' => null,
    ],
    'macos' => [
        'name' => 'Mac',
        'store' => 'Mac App Store',
        'url' => null,
    ],
    'tvos' => [
        'name' => 'Apple TV',
        'store' => 'App Store',
        'url' => null,
    ],
];

const GITHUB = 'https://github.com/kladhest-se/vocalisbook';
const SPOKENMETA = 'https://github.com/kladhest-se/SpokenMeta';

/**
 * The screenshots for one platform, in filename order.
 *
 * Filenames carry the order and the caption: `iphone-2-library.jpg` is the
 * second iPhone shot and is of the library. Sorting is what puts them in the
 * intended order, so renaming a file reorders the shelf and nothing else needs
 * touching.
 */
function screenshots(string $platform): array
{
    $files = glob(__DIR__ . "/screenshots/{$platform}-*.jpg") ?: [];
    sort($files);

    return array_map(static function (string $path): array {
        $stem = pathinfo($path, PATHINFO_FILENAME);
        $parts = explode('-', $stem, 3);

        return [
            'src' => 'screenshots/' . basename($path),
            'caption' => ucfirst(str_replace('-', ' ', $parts[2] ?? $stem)),
        ];
    }, $files);
}

function e(string $value): string
{
    return htmlspecialchars($value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

$phone = screenshots('iphone');
$mac = screenshots('macos');
$tv = screenshots('tvos');
?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<?php if ($isPrivacy): ?>
<title>Privacy policy — VocalisBook</title>
<meta name="description" content="VocalisBook collects nothing. No account, no analytics, no third-party services.">
<?php else: ?>
<title>VocalisBook — audiobooks from your own Plex server</title>
<meta name="description" content="A native audiobook player for Plex, on iPhone, iPad, Mac and Apple TV. Your library, your server, your listening — and nothing collected.">
<?php endif; ?>
<meta name="theme-color" content="#1e1e2e">

<meta property="og:title" content="VocalisBook">
<meta property="og:description" content="Audiobooks from your own Plex server, on iPhone, iPad, Mac and Apple TV.">
<meta property="og:image" content="https://vocalisbook.kladhest.se/logo.png">
<meta property="og:url" content="https://vocalisbook.kladhest.se">
<meta property="og:type" content="website">

<link rel="icon" href="logo.png" type="image/png">
<link rel="apple-touch-icon" href="logo.png">
<link rel="stylesheet" href="style.css">
</head>
<body>

<?php if ($isPrivacy): ?>

<header class="hero policy">
    <div class="wrap">
        <a href="./"><img class="logo" src="logo.png" alt="VocalisBook"></a>
        <h1>Privacy policy</h1>
        <p class="tagline">Last updated <?= e(PRIVACY_UPDATED) ?></p>
    </div>
</header>

<section>
    <div class="wrap prose">
        <p class="lede">
            VocalisBook does not collect, transmit or store any personal information.
        </p>

        <h2>What it talks to</h2>
        <p>
            The app talks to two services, and both of them are yours: the Plex Media
            Server you sign in to, and your own iCloud account. Your library, your
            listening position, your bookmarks and your history are held on your
            devices, on your server, and in your private iCloud database. The developer
            has no access to any of it, and there is no VocalisBook account to make.
        </p>

        <h2>What it does not do</h2>
        <p>
            There is no analytics, no crash reporting, no advertising and no
            third-party SDK of any kind. Nothing about your library or your listening
            is sent anywhere except the two services above.
        </p>

        <h2>Signing in</h2>
        <p>
            Signing in uses Plex's own authorisation flow. VocalisBook stores the
            resulting token in the system keychain on your device and sends it only to
            your own server.
        </p>

        <h2>Removing your data</h2>
        <p>
            Deleting the app removes everything it kept on that device. The app also
            has a setting that clears its local cache and downloads without deleting
            it. Anything held in your iCloud account can be removed from iCloud
            settings, and data on your Plex server is governed by Plex's own terms.
        </p>

        <h2>Questions</h2>
        <p>
            Ask on <a href="<?= e(GITHUB) ?>">the GitHub repository</a>, which is also
            where the source for all of the above can be read.
        </p>
    </div>
</section>

<?php else: ?>

<header class="hero">
    <div class="wrap">
        <img class="logo" src="logo.png" alt="VocalisBook">
        <h1>VocalisBook</h1>
        <p class="tagline">Audiobooks from your own Plex server — on iPhone, iPad, Mac and Apple TV.</p>

        <div class="stores">
            <?php foreach (STORES as $platform): ?>
                <?php if ($platform['url'] !== null): ?>
                <a class="store" href="<?= e($platform['url']) ?>">
                <?php else: ?>
                <span class="store pending">
                <?php endif; ?>
                    <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M16.5 12.6c0-2.3 1.9-3.4 2-3.5-1.1-1.6-2.8-1.8-3.4-1.8-1.4-.1-2.8.9-3.5.9s-1.8-.9-3-.8c-1.5 0-2.9.9-3.7 2.3-1.6 2.7-.4 6.8 1.1 9 .8 1.1 1.6 2.3 2.8 2.2 1.1 0 1.6-.7 2.9-.7s1.7.7 2.9.7 2-1.1 2.7-2.1c.9-1.2 1.2-2.4 1.3-2.4-.1 0-2.5-1-2.6-3.8zM14.3 5.3c.6-.8 1-1.8.9-2.9-.9 0-2 .6-2.6 1.4-.6.7-1.1 1.7-.9 2.7 1 .1 2-.5 2.6-1.2z"/></svg>
                    <span class="lines">
                        <span class="small"><?= $platform['url'] !== null ? 'Download on the' : 'Coming to the' ?></span>
                        <span class="big"><?= e($platform['store']) ?></span>
                        <span class="small"><?= e($platform['name']) ?></span>
                    </span>
                <?php if ($platform['url'] !== null): ?>
                </a>
                <?php else: ?>
                </span>
                <?php endif; ?>
            <?php endforeach; ?>
        </div>
    </div>
</header>

<section>
    <div class="wrap">
        <h2>Built for listening, not for browsing</h2>
        <p class="lede">
            Plex is very good at films. Audiobooks are a different problem: one book is
            often ninety files, a position has to be exact, and picking up where you left
            off matters more than anything on screen. VocalisBook is a native client that
            treats them as books.
        </p>

        <div class="features">
            <div class="feature">
                <h3>Your place, everywhere</h3>
                <p>Kept per book and to the millisecond, whether a book is one file or
                ninety. Your position goes back to Plex; the rest of your listening state
                travels through your own iCloud account.</p>
            </div>
            <div class="feature">
                <h3>Real chapters</h3>
                <p>From Plex's own data, the markers inside the file, or the file
                boundaries as a last resort — and the list shows what you have finished
                and what is playing.</p>
            </div>
            <div class="feature">
                <h3>Speed per book</h3>
                <p>A dense history and a novel do not want the same speed, so the app
                remembers one for each. The sleep timer fades rather than cutting, and can
                stop at the end of the chapter.</p>
            </div>
            <div class="feature">
                <h3>Offline</h3>
                <p>Download to your iPhone or Mac for a flight, then switch on offline
                mode to narrow the whole library to what will actually play.</p>
            </div>
            <div class="feature">
                <h3>Bookmarks and history</h3>
                <p>Mark a passage and find it on another device. Streaks, days listened
                and a history of what you finished, kept on your devices.</p>
            </div>
            <div class="feature">
                <h3>Nothing collected</h3>
                <p>No account with us, no analytics, no third-party services. Your
                library, your listening and your server stay yours.</p>
            </div>
        </div>
    </div>
</section>

<?php if ($phone || $mac || $tv): ?>
<section>
    <div class="wrap">
        <h2>On every screen</h2>
        <p class="lede">The same library, shaped for the device it is on.</p>

        <?php if ($phone): ?>
        <h3>iPhone and iPad</h3>
        <div class="shots phone">
            <?php foreach ($phone as $shot): ?>
            <figure>
                <img src="<?= e($shot['src']) ?>" alt="VocalisBook on iPhone — <?= e($shot['caption']) ?>" loading="lazy">
                <figcaption><?= e($shot['caption']) ?></figcaption>
            </figure>
            <?php endforeach; ?>
        </div>
        <?php endif; ?>

        <?php if ($mac): ?>
        <h3 style="margin-top:48px">Mac</h3>
        <div class="shots desktop">
            <?php foreach ($mac as $shot): ?>
            <figure>
                <img src="<?= e($shot['src']) ?>" alt="VocalisBook on Mac — <?= e($shot['caption']) ?>" loading="lazy">
                <figcaption><?= e($shot['caption']) ?></figcaption>
            </figure>
            <?php endforeach; ?>
        </div>
        <?php endif; ?>

        <?php if ($tv): ?>
        <h3 style="margin-top:48px">Apple TV</h3>
        <div class="shots desktop">
            <?php foreach ($tv as $shot): ?>
            <figure>
                <img src="<?= e($shot['src']) ?>" alt="VocalisBook on Apple TV — <?= e($shot['caption']) ?>" loading="lazy">
                <figcaption><?= e($shot['caption']) ?></figcaption>
            </figure>
            <?php endforeach; ?>
        </div>
        <?php endif; ?>
    </div>
</section>
<?php endif; ?>

<section>
    <div class="wrap">
        <div class="callout">
            <h2>Pair it with SpokenMeta</h2>
            <p>
                Plex's music agents describe albums, not books — so an audiobook library
                arrives with the narrator as the artist and no series, no author list and
                no edition. <a href="<?= e(SPOKENMETA) ?>">SpokenMeta</a> is a metadata
                agent for exactly this, and VocalisBook reads what it writes: authors,
                narrators, series and reading order, and a durable identity per book so
                your place follows the book rather than a row number on one server.
            </p>
            <p style="margin-bottom:0">
                It is recommended rather than required. Without it VocalisBook works from
                whatever Plex has; with it, the browsing screens have something to browse.
            </p>
        </div>
    </div>
</section>

<section>
    <div class="wrap">
        <h2>Requirements</h2>
        <div class="features">
            <div class="feature">
                <h3>A Plex Media Server</h3>
                <p>Your own, with an audiobook library. VocalisBook is a client and brings
                no content of its own.</p>
            </div>
            <div class="feature">
                <h3>iOS 17, macOS 14, tvOS 17</h3>
                <p>Or later. One app, three native builds — not a phone app stretched
                across a television.</p>
            </div>
            <div class="feature">
                <h3>iCloud, optionally</h3>
                <p>For listening state across devices. Off is a supported state: the app
                works from Plex alone.</p>
            </div>
        </div>
    </div>
</section>

<section>
    <div class="wrap author">
        <div class="body">
            <h2>Who made this</h2>
            <p class="lede" style="margin-bottom:16px">
                VocalisBook is written by <strong>Tommy Frössman</strong>, because the
                audiobooks on his own Plex server deserved a player that knew what a
                chapter was. It is developed in the open.
            </p>
            <p>
                <a href="<?= e(GITHUB) ?>">Source on GitHub</a> ·
                <a href="<?= e(SPOKENMETA) ?>">SpokenMeta</a>
            </p>
        </div>
    </div>
</section>

<?php endif; ?>

<footer>
    <div class="wrap">
        <p>
            VocalisBook is not affiliated with Plex Inc. Plex is a trademark of its owner.<br>
            © <?= date('Y') ?> Tommy Frössman ·
            <a href="<?= e(GITHUB) ?>">github.com/kladhest-se/vocalisbook</a> ·
            <?php if ($isPrivacy): ?>
            <a href="./">Home</a>
            <?php else: ?>
            <a href="?privacy">Privacy</a>
            <?php endif; ?>
        </p>
    </div>
</footer>

</body>
</html>
