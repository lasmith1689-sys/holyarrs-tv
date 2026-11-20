# HolyArrs TV

An Apple TV app for [HolyArrs](https://github.com/HolyArrs/HolyArrs), in the look of the RTX 4K player app.
HolyArrs runs on the PC; this app is its couch front end.

| Tab | What it does |
|---|---|
| Home | Trending hero (its trailer starts muted after a moment), Just arrived, New seasons, Shows you follow, Coming soon, and a count of asks waiting for an OK |
| Explore | HolyArrs' own Explore page for All, Movies, Shows or Music, with genre pages and more rows as you scroll |
| Search | Names as you type (Library, TMDB, people, music), or descriptions like "80s horror movies" |
| Requests | Approve or turn down asks, take back your own, and act on movies HolyArrs is stuck on |
| Downloads | Progress, speed and time left; pause, resume, remove (people who manage the Library) |
| Calendar | The next 30 days of episodes, release dates and albums |
| Settings | HolyArrs and RTX server addresses, sign out |

Title pages: ask for a movie or a show (whole, chosen seasons, or only what airs from now on), take back an ask,
follow a show, watch the trailer, seasons and episodes, cast (opens the person), collection, similar titles, and
**Play in 4K** when the same film is in the RTX 4K server's library (matched by name and year). Artist pages:
ask for the whole artist or picked albums.

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

## Checks
- **Screen check** (runs on every push to the app): compiles for a device, then opens every screen in an
  Apple TV simulator against a stand-in HolyArrs (`ci/mock_server.py`, answers in `ci/fixtures`, made by
  `ci/make_fixtures.py`). Screenshots are pushed to the `ci-screens` branch.
- **TestFlight**: Actions > TestFlight > Run workflow. Uses repository secrets `APPLE_TEAM_ID`, `ASC_KEY_ID`,
  `ASC_ISSUER_ID`, `ASC_KEY_P8` (the same App Store Connect key as RTX 4K) and the App Store Connect app
  "HolyArrs TV": spare slot 03, bundle ID `com.lasmith1689.slot03` (repository variable `HOLYARRS_BUNDLE_ID`),
  claimed with `claim_slot.py claim 03 "HolyArrs TV"`, tvOS platform added through the API, TestFlight group `Me`.
  Each build number is `<run number> x 10 + <attempt>`. On the Apple TV: TestFlight > HolyArrs TV.

## Files
| File | What it is |
|---|---|
| `Sources/HolyArrsAPI.swift` | Sign-in, requests, CSRF, picture addresses, trailers |
| `Sources/Components.swift` | The RTX 4K look: theme, poster and wide cards, badges, rows |
| `Sources/*View.swift`, `TitlePage.swift` | The screens |
| `Sources/RTX.swift` | The RTX 4K server: film matching and the player (from the RTX 4K app) |
| `make_assets.py` | Layered app icon and Top Shelf images |
| `project.yml` | XcodeGen spec (tvOS 18+) |
