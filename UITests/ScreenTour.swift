import UIKit
import XCTest

/// Opens every screen against ci/mock_server.py and saves a screenshot of each (plus the accessibility tree)
/// to $SHOTS_DIR, so the layout can be checked by eye without an Apple TV. Each tab is opened by launching
/// with -tab <name>; the title, person and season pages are reached with the Siri Remote. Saved tabs from older
/// layouts (explore, requests, calendar) are launched too, to check where they open now.
final class ScreenTour: XCTestCase {
    private let remote = XCUIRemote.shared
    private var app: XCUIApplication!
    private var step = 0
    private var server: String { ProcessInfo.processInfo.environment["MOCK_SERVER"] ?? "http://127.0.0.1:8799" }

    override func setUp() {
        continueAfterFailure = true
    }

    /// Launches on a tab. Pages are only passed when given: a value passed at launch can't be changed by the app,
    /// so passing one every time would hide what the app itself saves (Home's Browse choice, the Downloads page).
    /// `rtx` / `holyarrs`: another address for that server (a closed port: the PC or HolyArrs not answering).
    private func launch(tab: String, signedIn: Bool = true, explore: String? = nil, page: String? = nil, tvPage: String = "live",
                        rtx: String? = nil, holyarrs: String? = nil) {
        app?.terminate()
        app = XCUIApplication()
        app.launchArguments += ["-holyarrsAddress", holyarrs ?? server, "-rtxAddress", rtx ?? server, "-sportarrAddress", server,
                                "-outsideOn", "YES", "-tab", tab, "-tvPage", tvPage]
        if let explore { app.launchArguments += ["-exploreKind", explore] }
        if let page { app.launchArguments += ["-downloadsPage", page] }
        if signedIn { app.launchArguments += ["-testSignIn", "luke:test-password-1"] }
        app.launch()
        sleep(4)
    }

    /// An assertion that also prints its message, passed or failed, so the run log shows every check made.
    private func check(_ ok: Bool, _ message: String) {
        XCTAssertTrue(ok, message)
        print("CHECK \(ok ? "passed" : "FAILED"): \(message)")
    }

    /// The tab on screen: the tab bar's focused (just launched) or selected button.
    private func tabShown(_ name: String) -> Bool {
        let b = app.tabBars.firstMatch.buttons[name]
        guard b.waitForExistence(timeout: 10) else { return false }
        if b.hasFocus || b.isSelected { return true }
        // Home moves focus from the tab bar to its first Continue Watching card at launch: Home's own content shows.
        return name == "Home" && app.staticTexts["Continue Watching"].waitForExistence(timeout: 5)
    }

    /// The share of a screenshot that is black: about 0.99 for the simulator's boot screen (an Apple logo and a
    /// progress bar on black), under 0.1 for any screen of the app. Measured on a small copy of the picture.
    private func blackShare(_ s: XCUIScreenshot) -> Double {
        guard let cg = s.image.cgImage else { return 0 }
        let w = 96, h = 54
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return 0 }
        var dark = 0
        for i in stride(from: 0, to: px.count, by: 4) where Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2]) <= 12 { dark += 1 }
        return Double(dark) / Double(w * h)
    }

    /// A screenshot of what the app shows: never the simulator's boot screen or a black frame (run 45216775979 saved
    /// 19 boot screens while the app was on the right page). Retakes for a while, then fails the check.
    private func appScreenshot(wait: Int = 3) -> XCUIScreenshot {
        var s = XCUIScreen.main.screenshot()
        var tries = 0
        while blackShare(s) > 0.95 && tries < wait {
            tries += 1
            sleep(5)
            s = XCUIScreen.main.screenshot()
        }
        return s
    }

    private func shot(_ name: String) {
        step += 1
        let label = String(format: "%02d-%@", step, name)
        let screenshot = appScreenshot()
        let share = blackShare(screenshot)
        check(share <= 0.95, "screenshot \(label) shows the app, not a boot or black screen (black share \(String(format: "%.2f", share)))")
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = label
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SHOTS_DIR"] {
            let folder = URL(fileURLWithPath: dir)
            try? screenshot.pngRepresentation.write(to: folder.appendingPathComponent("\(label).png"))
            try? app.debugDescription.write(to: folder.appendingPathComponent("\(label).txt"), atomically: true, encoding: .utf8)
        }
    }

    private func press(_ b: XCUIRemote.Button, _ n: Int = 1) {
        for _ in 0..<n { remote.press(b); usleep(600_000) }
    }

    /// Moves focus until the element has it.
    @discardableResult
    private func focus(_ e: XCUIElement, _ dir: XCUIRemote.Button, limit: Int = 14) -> Bool {
        for _ in 0..<limit {
            if e.exists && e.hasFocus { return true }
            press(dir)
            usleep(400_000)  // let focus settle before reading it
        }
        return e.exists && e.hasFocus
    }

    /// Presses Down until a card of the row with these titles has focus.
    private func reachRow(_ titles: [String], limit: Int = 6) -> Bool {
        func inRow() -> Bool {
            titles.contains { t in
                let e = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", t)).firstMatch
                return e.exists && e.hasFocus
            }
        }
        for _ in 0..<limit {
            if inRow() { return true }
            press(.down)
            usleep(400_000)
        }
        return inRow()
    }

    /// Release 4: a Top Shelf card's link (afterglow://play) opens straight into the player for that film.
    func testTopShelfLink() {
        launch(tab: "home")
        _ = app.buttons["More info"].waitForExistence(timeout: 15)
        app.open(URL(string: "afterglow://play?id=matrix&t=3120&d=8160&title=The%20Matrix")!)
        // The stand-in PC answers that another screen has its one 4K film: proof the player started for this one.
        check(app.staticTexts["The PC is upscaling Dune for the Apple TV."].waitForExistence(timeout: 20),
              "a Top Shelf link opens the film's player straight from the Home Screen")
        shot("top-shelf-link")
    }

    /// Release 6: Movies (HolyArrs' downloaded films and the PC-only ones) and the Guide grid.
    func testLibraryAndGuide() {
        launch(tab: "movies")
        check(app.staticTexts["Movies"].waitForExistence(timeout: 15), "Movies tab")
        check(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Alien'")).firstMatch.waitForExistence(timeout: 10)
              && app.buttons.matching(NSPredicate(format: "label CONTAINS 'The Matrix'")).firstMatch.exists,
              "Movies: HolyArrs' downloaded films and the films only on the PC")
        shot("movies")
        launch(tab: "tv", tvPage: "guide")
        check(app.staticTexts["Guide"].waitForExistence(timeout: 15), "Live & On Demand: the Guide page")
        check(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'ESPN: SportsCenter'")).firstMatch.waitForExistence(timeout: 10),
              "the guide shows each channel's programmes (ESPN: SportsCenter)")
        sleep(2)
        shot("guide")
    }

    func testTour() {
        // Signed out: the sign-in screen. First, wait for the simulator to show the app at all (up to 8 minutes):
        // a first boot can keep its progress screen up for minutes after the app is running.
        launch(tab: "home", signedIn: false)
        let first = appScreenshot(wait: 96)
        check(blackShare(first) <= 0.95, "the simulator shows the app before the tour starts")
        let plex = app.buttons["Sign in with Plex"]
        XCTAssertTrue(plex.waitForExistence(timeout: 10), "sign-in screen with Plex")
        shot("sign-in")
        // Sign in with Plex: the stand-in answers "waiting" once, then approves.
        focus(plex, .up, limit: 4)
        press(.select)
        XCTAssertTrue(app.images["QR code for Plex sign-in"].waitForExistence(timeout: 8), "Plex QR code")
        shot("plex-qr")
        XCTAssertTrue(app.buttons["More info"].waitForExistence(timeout: 20), "signed in through Plex")
        shot("plex-signed-in")

        // Home with its hero and rows.
        launch(tab: "home")
        XCTAssertTrue(app.buttons["More info"].waitForExistence(timeout: 15), "home hero")
        // The stand-in PC says the IPTV plan runs out in 9 days: Home warns.
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Runs out in 9 days'")).firstMatch
            .waitForExistence(timeout: 10), "subscription warning on Home")
        let bar = app.tabBars.firstMatch
        let tabs = bar.buttons.allElementsBoundByIndex.map(\.label)
        check(tabs == ["Home", "Live & On Demand", "TV Shows", "Movies", "Sports", "Downloads", "Search", "Settings"],
              "Apple TV tab bar: Home, Live & On Demand, TV Shows, Movies, Sports, then Downloads, Search and Settings (found \(tabs))")
        let widths = Dictionary(bar.buttons.allElementsBoundByIndex.map { ($0.label, $0.frame.width) }, uniquingKeysWith: { a, _ in a })
        check(["Downloads", "Search", "Settings"].allSatisfy { (widths[$0] ?? 999) < 70 }
              && ["Home", "Live & On Demand", "TV Shows", "Movies", "Sports"].allSatisfy { (widths[$0] ?? 0) > 80 },
              "Apple TV tab bar: the media tabs as text, Downloads, Search and Settings as icons (widths \(widths))")
        shot("home")
        press(.down, 3)
        shot("home-rows")

        // A Library movie's page (The Matrix: in the RTX library too, so Play in 4K shows).
        launch(tab: "home")
        _ = app.buttons["More info"].waitForExistence(timeout: 15)
        let matrix = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'The Matrix'")).firstMatch
        let resumeCard = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Resume The Matrix'")).firstMatch
        XCTAssertTrue(resumeCard.waitForExistence(timeout: 10), "Continue Watching card for the part-watched Matrix")
        // At launch focus is on the first Continue Watching card; Down goes to Just arrived (The Matrix is its first card).
        sleep(1)
        check(resumeCard.hasFocus, "the Apple TV starts on the first Continue Watching card")
        if !resumeCard.hasFocus { _ = reachRow(["Resume The Matrix"]) }
        press(.down)
        sleep(1)
        if focus(matrix, .left, limit: 3) {
            press(.select)
            // The stand-in PC has The Matrix part-watched, so it offers Resume (and Start over) instead of Play.
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Resume in 4K'")).firstMatch.waitForExistence(timeout: 10),
                          "Resume in 4K on a part-watched film")
            XCTAssertTrue(app.buttons["Start over"].exists, "Start over next to Resume")
            XCTAssertTrue(app.buttons["Play outside"].exists, "Play outside next to Play in 4K")
            XCTAssertTrue(app.buttons["Play now while it downloads"].waitForExistence(timeout: 10),
                          "the 4K copy coming in shows on the page, playable while it downloads")
            sleep(2)
            shot("title-movie")
            // Release 4: Back from a page lands on the card it was opened from.
            press(.menu)
            sleep(2)
            check(matrix.hasFocus, "Back from a film's page returns focus to its card on Home")
            if !matrix.hasFocus { _ = focus(matrix, .left, limit: 3) }
            press(.select)
            _ = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Resume in 4K'")).firstMatch.waitForExistence(timeout: 10)
            sleep(1)
            press(.down, 2)
            shot("title-cast")
            let person = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Keanu Reeves'")).firstMatch
            if focus(person, .down, limit: 4) {
                press(.select)
                sleep(3)
                shot("person")
            }
        } else {
            XCTFail("could not focus The Matrix on Home")
        }

        // The PC not answering (a closed port): the last good lists stay, the TV tab stays, Home says so.
        launch(tab: "home", rtx: "http://127.0.0.1:9")
        check(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Resume The Matrix'")).firstMatch.waitForExistence(timeout: 15),
              "PC not answering: Continue Watching keeps The Matrix")
        check(app.staticTexts["PC not answering"].waitForExistence(timeout: 25), "PC not answering: Home says so")
        check(app.tabBars.firstMatch.buttons["Live & On Demand"].exists, "PC not answering: the Live & On Demand tab stays")
        shot("home-pc-down")
        // HolyArrs not answering: the tabs and Home (with the PC's rows), not the sign-in screen.
        launch(tab: "home", holyarrs: "http://127.0.0.1:9")
        check(app.staticTexts["HolyArrs not answering"].waitForExistence(timeout: 25), "HolyArrs not answering: Home says so")
        check(!app.buttons["Sign in with Plex"].exists && app.tabBars.firstMatch.buttons["Home"].exists,
              "HolyArrs not answering: the app opens on its tabs, not the sign-in screen")
        check(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Resume The Matrix'")).firstMatch.exists,
              "HolyArrs not answering: Continue Watching still plays from the PC")
        shot("home-holyarrs-down")

        // Explore is Browse on Home now: a saved "explore" opens Home; Music is one press from there.
        launch(tab: "explore")
        check(tabShown("Home"), "saved tab explore opens Home")
        _ = app.buttons["More info"].waitForExistence(timeout: 15)
        let kinds = ["all", "movies", "shows", "music"].map { app.buttons["browse-\($0)"] }
        var reached = false
        for _ in 0..<16 {
            if kinds.contains(where: { $0.exists && $0.hasFocus }) { reached = true; break }
            press(.down)
            usleep(400_000)
        }
        check(reached && focus(kinds[0], .left, limit: 4), "Browse on Home, under Home's rows, reached with the remote")
        check(kinds[0].isSelected, "Browse starts on All")
        sleep(1)
        shot("explore")
        press(.down, 5)
        shot("explore-rows")
        launch(tab: "home")
        _ = app.buttons["More info"].waitForExistence(timeout: 15)
        for _ in 0..<16 where !kinds.contains(where: { $0.exists && $0.hasFocus }) {
            press(.down)
            usleep(400_000)
        }
        if focus(kinds[3], .right, limit: 4) {
            press(.select)
            sleep(2)
            check(kinds[3].isSelected && app.staticTexts["Top albums"].waitForExistence(timeout: 10), "Music one press from Home: its rows")
        } else {
            XCTFail("could not focus Music in Browse")
        }
        shot("explore-music")

        // Sports (Sportarr): ready to watch, downloading, the next two weeks, leagues; an event with Play in 4K.
        launch(tab: "sports")
        XCTAssertTrue(app.staticTexts["Ready to watch"].waitForExistence(timeout: 15), "sports: ready to watch")
        shot("sports")
        press(.down, 4)
        shot("sports-rows")
        launch(tab: "sports")
        _ = app.staticTexts["Ready to watch"].waitForExistence(timeout: 15)
        let race = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Las Vegas Grand Prix - Race'")).firstMatch
        // Tab bar -> down past the live rows to Ready to watch (the race is its first card).
        press(.down)
        sleep(1)
        if focus(race, .down, limit: 10) || focus(race, .left, limit: 3) {
            press(.select)
            XCTAssertTrue(app.buttons["Play in 4K"].waitForExistence(timeout: 10), "Play in 4K on a downloaded race")
            sleep(2)
            shot("sports-event")
        } else {
            XCTFail("could not focus the Las Vegas race")
        }

        // Live TV: the live part of Sports, then the TV tab's short lineup with what's on now.
        launch(tab: "sports")
        XCTAssertTrue(app.staticTexts["Your teams"].waitForExistence(timeout: 15), "sports: your teams live")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Saints at Bears'")).firstMatch.exists, "the Bears game")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'NFL RedZone' AND label ENDSWITH 'pinned'")).firstMatch.exists,
                      "NFL RedZone pinned in Your teams")
        shot("sports-live")
        press(.down, 2)
        shot("sports-live-crests")
        launch(tab: "tv")
        XCTAssertTrue(app.staticTexts["Live TV"].waitForExistence(timeout: 15), "TV tab")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'ESPN'")).firstMatch.waitForExistence(timeout: 10), "a channel in the lineup")
        shot("tv")
        press(.down, 4)
        shot("tv-rows")

        // On Demand: the plan's films and series, a film part-way through (Resume), a series' episodes.
        launch(tab: "tv", tvPage: "ondemand")
        XCTAssertTrue(app.staticTexts["New releases"].waitForExistence(timeout: 15), "On Demand rows")
        shot("tv-ondemand")
        let odyssey = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'The Odyssey'")).firstMatch
        // Down from the tab bar past the Live / On Demand picker (never sideways there: that would switch pages)
        // into the first row, then left to its first card.
        if reachRow(["The Odyssey", "Nimrods", "The Fix", "Heartland", "Kalocsa", "The Beast"]) && focus(odyssey, .left, limit: 7) {
            press(.select)
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Resume'")).firstMatch.waitForExistence(timeout: 10),
                          "Resume on a part-watched On Demand film")
            XCTAssertTrue(app.buttons["Start over"].exists, "Start over next to Resume")
            sleep(2)
            shot("ondemand-movie")
        } else {
            XCTFail("could not focus The Odyssey in On Demand")
        }
        launch(tab: "tv", tvPage: "ondemand")
        _ = app.staticTexts["New series"].waitForExistence(timeout: 15)
        let farm = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'The Witch Farm'")).firstMatch
        if reachRow(["The Witch Farm", "Slow Horses", "Severance"]) && focus(farm, .left, limit: 4) {
            press(.select)
            XCTAssertTrue(app.buttons["Season 2"].waitForExistence(timeout: 10), "a series' seasons")
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Episode 1'")).firstMatch.exists, "its episodes")
            sleep(2)
            shot("ondemand-series")
        } else {
            XCTFail("could not focus The Witch Farm in On Demand")
        }

        // Search, Downloads (opens on the downloads list; Requests and Calendar inside; saved tabs for those open
        // their page), Settings.
        launch(tab: "search")
        shot("search")
        launch(tab: "downloads")
        check(tabShown("Downloads") && app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'The Last of Us'")).firstMatch
            .waitForExistence(timeout: 10), "Downloads tab opens on the downloads list")
        launch(tab: "requests")
        check(tabShown("Downloads"), "saved tab requests opens Downloads")
        check(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Dune: Part Two'")).firstMatch.waitForExistence(timeout: 10),
              "saved tab requests opens the Requests page: an ask waiting for an OK")
        shot("requests-waiting")
        launch(tab: "downloads", page: "downloads")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'The Last of Us'")).firstMatch.waitForExistence(timeout: 10), "a download")
        shot("downloads")
        launch(tab: "calendar")
        check(tabShown("Downloads") && app.staticTexts["Coming up"].waitForExistence(timeout: 10), "saved tab calendar opens Calendar inside Downloads")
        shot("calendar")
        launch(tab: "settings")
        shot("settings")
        press(.down, 6)
        shot("settings-subscriptions")
    }
}
