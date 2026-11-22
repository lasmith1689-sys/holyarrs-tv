import XCTest

/// Opens every screen against ci/mock_server.py and saves a screenshot of each (plus the accessibility tree)
/// to $SHOTS_DIR, so the layout can be checked by eye without an Apple TV. Each tab is opened by launching
/// with -tab <name>; the title, person and season pages are reached with the Siri Remote.
final class ScreenTour: XCTestCase {
    private let remote = XCUIRemote.shared
    private var app: XCUIApplication!
    private var step = 0
    private var server: String { ProcessInfo.processInfo.environment["MOCK_SERVER"] ?? "http://127.0.0.1:8799" }

    override func setUp() {
        continueAfterFailure = true
    }

    private func launch(tab: String, signedIn: Bool = true, explore: String = "All", page: String = "requests", tvPage: String = "live") {
        app?.terminate()
        app = XCUIApplication()
        app.launchArguments += ["-holyarrsAddress", server, "-rtxAddress", server, "-sportarrAddress", server, "-outsideOn", "YES", "-tab", tab, "-exploreKind", explore, "-requestsPage", page, "-tvPage", tvPage]
        if signedIn { app.launchArguments += ["-testSignIn", "luke:test-password-1"] }
        app.launch()
        sleep(4)
    }

    private func shot(_ name: String) {
        step += 1
        let label = String(format: "%02d-%@", step, name)
        let screenshot = XCUIScreen.main.screenshot()
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

    func testTour() {
        // Signed out: the sign-in screen.
        launch(tab: "home", signedIn: false)
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
        shot("home")
        press(.down, 3)
        shot("home-rows")

        // A Library movie's page (The Matrix: in the RTX library too, so Play in 4K shows).
        launch(tab: "home")
        _ = app.buttons["More info"].waitForExistence(timeout: 15)
        let matrix = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'The Matrix'")).firstMatch
        // Tab bar -> hero buttons -> Continue Watching -> Just arrived (The Matrix is its first card).
        press(.down)
        sleep(1)
        press(.down)
        sleep(1)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Resume The Matrix'")).firstMatch.exists,
                      "Continue Watching card for the part-watched Matrix")
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

        // Explore, a genre, and Music.
        launch(tab: "explore")
        sleep(2)
        shot("explore")
        press(.down, 5)
        shot("explore-rows")
        launch(tab: "explore", explore: "Music")
        sleep(2)
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

        // Search, Requests (with Downloads and Calendar inside), Settings.
        launch(tab: "search")
        shot("search")
        launch(tab: "requests")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Dune: Part Two'")).firstMatch.waitForExistence(timeout: 10), "an ask waiting for an OK")
        shot("requests-waiting")
        launch(tab: "requests", page: "downloads")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'The Last of Us'")).firstMatch.waitForExistence(timeout: 10), "a download")
        shot("downloads")
        launch(tab: "requests", page: "calendar")
        XCTAssertTrue(app.staticTexts["Coming up"].waitForExistence(timeout: 10), "calendar inside Requests")
        shot("calendar")
        launch(tab: "settings")
        shot("settings")
        press(.down, 6)
        shot("settings-subscriptions")
    }
}
