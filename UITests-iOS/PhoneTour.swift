import XCTest

/// The iPhone screen check: opens every tab against ci/mock_server.py (each by launching with -tab <name>),
/// opens a title page by tapping, and saves a screenshot of each to $SHOTS_DIR.
final class PhoneTour: XCTestCase {
    private var app: XCUIApplication!
    private var step = 0
    private var server: String { ProcessInfo.processInfo.environment["MOCK_SERVER"] ?? "http://127.0.0.1:8799" }

    override func setUp() { continueAfterFailure = true }

    private func launch(tab: String, signedIn: Bool = true, explore: String = "All") {
        app?.terminate()
        app = XCUIApplication()
        app.launchArguments += ["-holyarrsAddress", server, "-rtxAddress", server, "-sportarrAddress", server, "-outsideOn", "YES", "-tab", tab, "-exploreKind", explore]
        if signedIn { app.launchArguments += ["-testSignIn", "luke:test-password-1"] }
        app.launch()
        sleep(4)
    }

    private func shot(_ name: String) {
        step += 1
        let label = String(format: "p%02d-%@", step, name)
        let screenshot = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: screenshot)
        a.name = label
        a.lifetime = .keepAlways
        add(a)
        if let dir = ProcessInfo.processInfo.environment["SHOTS_DIR"] {
            let folder = URL(fileURLWithPath: dir)
            try? screenshot.pngRepresentation.write(to: folder.appendingPathComponent("\(label).png"))
            try? app.debugDescription.write(to: folder.appendingPathComponent("\(label).txt"), atomically: true, encoding: .utf8)
        }
    }

    func testTour() {
        launch(tab: "home", signedIn: false)
        let plex = app.buttons["Sign in with Plex"]
        XCTAssertTrue(plex.waitForExistence(timeout: 10), "sign-in screen with Plex")
        shot("sign-in")
        // Sign in with Plex: the stand-in answers "waiting" once, then approves.
        plex.tap()
        XCTAssertTrue(app.staticTexts["Waiting for Plex..."].waitForExistence(timeout: 8), "waiting for Plex")
        shot("plex-waiting")
        XCTAssertTrue(app.buttons["More info"].waitForExistence(timeout: 20), "signed in through Plex")
        shot("plex-signed-in")

        launch(tab: "home")
        XCTAssertTrue(app.buttons["More info"].waitForExistence(timeout: 15), "home hero")
        XCTAssertTrue(app.staticTexts["Continue Watching"].waitForExistence(timeout: 10), "Continue Watching row on Home")
        shot("home")
        app.swipeUp()
        sleep(1)
        shot("home-rows")

        // The Matrix: a Library movie that is also on the RTX server.
        let matrix = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'The Matrix'")).firstMatch
        if matrix.waitForExistence(timeout: 5) {
            matrix.tap()
            // The stand-in PC has The Matrix part-watched, so it offers Resume (and Start over) instead of Play.
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Resume in 4K'")).firstMatch.waitForExistence(timeout: 10),
                          "Resume in 4K on a part-watched film")
            XCTAssertTrue(app.buttons["Start over"].exists, "Start over next to Resume")
            sleep(2)
            shot("title-movie")
            // Play outside: the stand-in PC answers that the TV is playing.
            let outside = app.buttons["Play outside"]
            if outside.waitForExistence(timeout: 5) {
                outside.tap()
                XCTAssertTrue(app.buttons["Stop outside"].waitForExistence(timeout: 15), "outside TV reported playing")
                XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Continue here'")).firstMatch.exists, "Continue here offered")
                shot("title-outside")
            } else {
                XCTFail("no Play outside button")
            }
            app.swipeUp()
            sleep(1)
            shot("title-cast")
        } else {
            XCTFail("The Matrix not on Home")
        }

        launch(tab: "explore")
        shot("explore")
        app.swipeUp()
        sleep(1)
        shot("explore-rows")
        launch(tab: "explore", explore: "Music")
        shot("explore-music")
        launch(tab: "sports")
        XCTAssertTrue(app.staticTexts["Ready to watch"].waitForExistence(timeout: 15), "sports: ready to watch")
        shot("sports")
        app.swipeUp()
        sleep(1)
        shot("sports-rows")
        app.swipeUp()
        sleep(1)
        shot("sports-leagues")
        launch(tab: "sports")
        let race = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Las Vegas Grand Prix - Race'")).firstMatch
        if race.waitForExistence(timeout: 10) {
            race.tap()
            XCTAssertTrue(app.buttons["Play in 4K"].waitForExistence(timeout: 10), "Play in 4K on a downloaded race")
            sleep(2)
            shot("sports-event")
        } else {
            XCTFail("the Las Vegas race is not on Sports")
        }
        launch(tab: "search")
        shot("search")
        launch(tab: "requests")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Dune: Part Two'")).firstMatch.waitForExistence(timeout: 10), "an ask waiting for an OK")
        shot("requests-waiting")
        launch(tab: "downloads")
        shot("downloads")
        launch(tab: "calendar")
        shot("calendar")
        launch(tab: "settings")
        shot("settings")
        let guide = app.buttons["Picture setup guide"]
        for _ in 0..<4 where !guide.isHittable { app.swipeUp() }
        if guide.waitForExistence(timeout: 5) {
            guide.tap()
            sleep(1)
            shot("setup-guide")
        } else {
            XCTFail("no Picture setup guide")
        }
    }
}
