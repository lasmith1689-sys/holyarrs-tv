# HolyArrs TV

An Apple TV and iPhone app for [HolyArrs](https://github.com/HolyArrs/HolyArrs), in the look of the RTX 4K
player app. HolyArrs runs on the PC; this app is its front end for the couch and the phone.

One code base (`Sources/`), two targets: `HolyArrsTV` (tvOS 18+) and `HolyArrsPhone` (iOS 18+, iPhone), with the
same bundle ID, so both are the one App Store Connect app "HolyArrs TV". Screens are written at TV sizes;
`Sources/Platform.swift` scales them for the phone (`S`, `W`, `F`), stacks side-by-side layouts there, and keeps
the Siri Remote focus behaviour on tvOS only. On iPhone, Requests, Downloads, Calendar and Settings sit under More; on Apple TV the
tab bar slides sideways to reach Calendar and Settings.

| Tab | What it does |
|---|---|
| Home | Trending hero (its trailer starts muted after a moment), Just arrived, New seasons, Shows you follow, Coming soon, and a count of asks waiting for an OK |
| Explore | HolyArrs' own Explore page for All, Movies, Shows or Music, with genre pages and more rows as you scroll |
| Sports | Live games through the PC on top (Your teams, with NFL RedZone pinned first; Live now; Later today; golf; racing; sports channels), every NFL and Premier League game card showing both teams' crests on their colours. Then from Sportarr: ready to watch, downloading, the next two weeks of your leagues, league pages (teams, automatic or schedule only), add a league, event pages with Play in 4K and Get it now. Never shows scores |
| TV | Live: the PC's short lineup with what's on now, and All channels (every category, search). On Demand: the IPTV plan's films and series (new releases, top films, new series, IMDb Top 250 and more, the plan's categories, search), film and series pages with Resume, all played through the PC |
| Search | Names as you type (Library, TMDB, people, music), or descriptions like "80s horror movies" |
| Requests | Approve or turn down asks, take back your own, and act on movies HolyArrs is stuck on |
| Downloads | Progress, speed and time left; pause, resume, remove (people who manage the Library) |
| Calendar | The next 30 days of episodes, release dates and albums |
| Settings | HolyArrs, RTX server and Sportarr addresses, Subscriptions (IPTV, Newshosting, NZBgeek and when each runs out; Home warns 14 days ahead), Rooms (the outdoor TV, picture setup guide), sign out |

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
- **Screen check** (runs on every push to the app): compiles each app for a device, then opens every screen in an
  Apple TV simulator and an iPhone simulator against a stand-in HolyArrs (`ci/mock_server.py`, answers in `ci/fixtures`, made by
  `ci/make_fixtures.py`). Screenshots are pushed to the `ci-screens` (TV) and `ci-screens-phone` branches.
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
