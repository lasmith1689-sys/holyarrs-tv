# Afterglow (was HolyArrs TV)

An Apple TV and iPhone app for [HolyArrs](https://github.com/HolyArrs/HolyArrs), live TV, sports and the RTX 4K
server, in the look of the RTX 4K player app. HolyArrs and the RTX 4K server run on the PC; this app is their front end
for the couch and the phone (shown on the home screen as "Afterglow" since 22 Nov 2026; the App Store Connect record and
TestFlight still say "HolyArrs TV").

One code base (`Sources/`), two targets: `HolyArrsTV` (tvOS 18+) and `HolyArrsPhone` (iOS 18+, iPhone), with the
same bundle ID, so both are the one App Store Connect app "HolyArrs TV". Screens are written at TV sizes;
`Sources/Platform.swift` scales them for the phone (`S`, `W`, `F`), stacks side-by-side layouts there, and keeps
the Siri Remote focus behaviour on tvOS only.

Five tabs, no More (since 22 Nov 2026; Explore, Requests and Settings were tabs before):
- **iPhone:** Home, Sports, TV, Downloads, Search. Settings opens from the gear at the top right of Home.
- **Apple TV:** Home, Sports, TV, Downloads as text, then Search and Settings as icons at the right.

Sports shows when Sportarr or Live TV is set up, TV when Live TV is. A tab saved by an older version still opens the
right place: Explore opens Home, Requests and Calendar open their page inside Downloads, and on iPhone Settings opens
on Home.

| Tab | What it does |
|---|---|
| Home | Trending hero (its trailer starts muted after a moment; Find opens Search), Continue Watching, Just arrived, New seasons, Shows you follow, Coming soon, a count of asks waiting for an OK, then **Browse** (what was Explore): All, Movies, Shows or Music, HolyArrs' own rows for each with the genre tiles (each opens its genre page) and more rows as you scroll |
| Sports | Live games through the PC on top (Your teams, with NFL RedZone pinned first; Live now; Later today; golf; racing; sports channels), every NFL and Premier League game card showing both teams' crests on their colours. Then from Sportarr: ready to watch, downloading, the next two weeks of your leagues, league pages (teams, automatic or schedule only), add a league, event pages with Play in 4K and Get it now. Never shows scores |
| TV | Live: the PC's short lineup with what's on now, and All channels (every category, search). On Demand: the IPTV plan's films and series (new releases, top films, new series, IMDb Top 250 and more, the plan's categories, search), film and series pages with Resume, all played through the PC |
| Downloads | Opens on the downloads list: progress, speed and time left; pause, resume, remove (people who manage the Library). At its top: **Requests** (approve or turn down asks, take back your own, act on movies HolyArrs is stuck on) and **Calendar** (the next 30 days of episodes, release dates and albums). People who don't manage the Library see Requests and Calendar |
| Search | Names as you type (Library, TMDB, people, music), or descriptions like "80s horror movies"; says where each title can be watched (In library, Get it, Watch now On Demand) |
| Settings (gear on iPhone Home; icon tab on Apple TV) | HolyArrs, RTX server and Sportarr addresses, Subscriptions (IPTV, Newshosting, NZBgeek and when each runs out; Home warns 14 days ahead), Rooms (the outdoor TV, picture setup guide), sign out |

Title pages: ask for a movie or a show (whole, chosen seasons, or only what airs from now on), take back an ask,
follow a show, watch the trailer, seasons and episodes, cast (opens the person), collection, similar titles, and
**Play in 4K** when the same film is in the RTX 4K server's library (matched by name and year here, else the
page asks the server's `GET /find`, and says why when there is no match), **Play outside** (the PC casts to the
outdoor Hisense; untested on the TV itself), and the 1080p / 4K choice when asking (HolyArrs' quality lines:
1080p uses the "1080p for RTX" pick rules, 4K uses "Best"). Artist pages: ask for the whole artist or picked
albums.

Playing: positions are kept on the RTX server (`/positions`), so every screen resumes the same place. While
playing: Stats (swipe down on Apple TV, chart button on iPhone; measured by the player) and Continue outside.
iPhone: AirPlay to an Apple TV (the TV fetches the PC's stream itself); a cast keeps going with the phone locked.
Cast (iPhone, live TV and On Demand): the PC lists the Chromecasts and Google TVs on the network and tells the chosen one
to play its own stream (`/cast/devices`, `/tv/cast`, `/tv/ondemand/cast`).

Live player: nothing of the app's own sits over a playing picture until you ask. **Other feeds** switches to another
feed of the same game (the PC ranks them by measured picture, "Feed 1 · 1080p60 (best)") or to a channel's spare feed
("Feed 2 · spare"); the PC hands the plan's one stream over, and if the picked feed won't start the next one plays.
Apple TV: in the player's menu with its controls. iPhone: tap the picture and Close, Feeds and Cast appear with the
system's controls (always while paused) and go again after a few seconds; Feeds opens the list.

Indexers, download apps, pick rules, keys and backups stay in HolyArrs' web page.

## How it talks to HolyArrs
Its JSON API under `/api/v1`, signed in like the web page: `POST /auth/login` sets the `holyarrs_session`
cookie and returns a CSRF token, sent as `X-CSRF-Token` on every change. Pictures go through HolyArrs' own
TMDB cache (`/api/v1/artwork/tmdb/...`). Answers are read loosely (`Sources/JSON.swift`), with the same field
fallbacks HolyArrs' web app uses, so new fields in a HolyArrs update don't break a screen.
"Stay signed in" keeps the name and password in the Apple TV keychain to sign in again after HolyArrs' 7-day
idle limit.

## The HolyArrs server on the PC
HolyArrs publishes no Windows build, so **Actions > HolyArrs server (Windows build) > Run workflow** builds
`holyarrs.exe` from the official source at a tag (default 1.2.0), the same steps as their Dockerfile.
On the PC it lives in `C:\HolyArrs` (`bin\holyarrs.exe -config C:\HolyArrs\config -addr :6262`).
Keep `C:\HolyArrs\config\holyarrs.key` safe: backups don't include it.

## Other services on the PC
All start hidden at sign-in (scheduled tasks), each with its own restart loop:
- **Sportarr** (`C:\Sportarr`, port 1867): sports PVR. Leagues: NFL and Premier League (picked teams), PGA Tour.
  Its key comes to the app from `/initialize.json` while Sportarr's login is off.
- **Prowlarr** (`C:\Prowlarr`, port 9696): its indexers (NZBgeek since 22 Nov 2026), synced to Sportarr as a Sonarr-type app.
- **SABnzbd** (`C:\SABnzbd`, 127.0.0.1:8085): Usenet downloads (Newshosting) for HolyArrs (NZBgeek as its source)
  and Sportarr. Since 22 Nov 2026 HolyArrs' torrent sources (Knaben, TorrentsCSV) and its qBittorrent client are off.
- **qBittorrent** (port 8080): shared by HolyArrs (category `holyarrs`) and Sportarr (`sportarr`). Stops seeding
  as soon as a download completes; both apps then import and remove the torrent. "qBittorrent keep-alive"
  reopens it within 5 minutes if it is closed.
- **RTX 4K server** (`H:\Projects\rtx-upscale-stream`, port 8787): rescans the film folders every 5 minutes and
  `D:\Sports` every 2, serves `/library`, `/sports`, `/find`, `/positions`, `/cast`, Live TV and On Demand (`/tv/...`,
  one IPTV stream at a time, encoded by the PC), team crests (`/tv/teams`), `/subscriptions`, and a web version of
  this app for the Samsung tablet at `/app`. While it pulls an IPTV stream it caps SABnzbd at 5 MB/s; otherwise
  SABnzbd runs at full speed.

## Checks
- **Screen check** (runs on every push to main; for a branch, Actions > Screen check > Run workflow, or
  `gh workflow run "Screen check" --ref <branch>`): compiles each app for a device, then opens every screen in an
  Apple TV simulator and an iPhone simulator against a stand-in HolyArrs (`ci/mock_server.py`, answers in `ci/fixtures`, made by
  `ci/make_fixtures.py`; it also serves a short real stream for the live player). Screenshots are pushed to the `ci-screens`
  (TV) and `ci-screens-phone` branches. Checks print `CHECK passed:` or `CHECK FAILED:` with what they looked at (the tab
  bars, where saved tabs open, the live player's buttons and Other feeds).
- **TestFlight**: Actions > TestFlight > Run workflow. Uses repository secrets `APPLE_TEAM_ID`, `ASC_KEY_ID`,
  `ASC_ISSUER_ID`, `ASC_KEY_P8` (the same App Store Connect key as RTX 4K) and the App Store Connect app
  "HolyArrs TV": spare slot 03, bundle ID `com.lasmith1689.slot03` (repository variable `HOLYARRS_BUNDLE_ID`),
  claimed with `claim_slot.py claim 03 "HolyArrs TV"`, tvOS platform added through the API, TestFlight group `Me`.
  Each run uploads both the tvOS and the iOS build, numbered `<run number> x 10 + <attempt>`.
  On the Apple TV or iPhone: TestFlight > HolyArrs TV.

## Files
| File | What it is |
|---|---|
| `Sources/HolyArrsAPI.swift` | Sign-in, requests, CSRF, picture addresses, trailers |
| `Sources/Components.swift` | The RTX 4K look: theme, poster and wide cards, badges, rows |
| `Sources/*View.swift`, `TitlePage.swift` | The screens |
| `Sources/RTX.swift` | The RTX 4K server: film matching, positions, casting, team crests, subscriptions, and the player (from the RTX 4K app) |
| `Sources/LiveTV.swift`, `OnDemand.swift` | The TV tab (Live and On Demand), the live rows on Sports, game cards with crests, the live and On Demand player |
| `Sources/Subscriptions.swift` | The Home warning and the Settings list of subscriptions |
| `Sources/SportarrAPI.swift`, `SportsView.swift` | Sportarr's API and the Sports tab |
| `Sources/Rooms.swift` | Play outside, Continue here, stats, the picture setup guide |
| `make_assets.py` | Layered tvOS icon, Top Shelf images and the iPhone icon |
| `Sources/Platform.swift` | TV and iPhone sizing, tvOS-only focus modifiers |
| `project.yml` | XcodeGen spec: tvOS and iOS apps, both UI test targets |
