import XCTest

/// The iPhone screen check: opens every tab against ci/mock_server.py (each by launching with -tab <name>),
/// opens a title page by tapping, and saves a screenshot of each to $SHOTS_DIR. Saved tabs from older layouts
/// (explore, requests, calendar, settings) are launched too, to check where they open now. Ends in the live
/// player: what shows over a playing picture, and Other feeds.
final class PhoneTour: XCTestCase {
    private var app: XCUIApplication!
    private var step = 0
    private var server: String { ProcessInfo.processInfo.environment["MOCK_SERVER"] ?? "http://127.0.0.1:8799" }

    override func setUp() { continueAfterFailure = true }

    /// Launches on a tab. Pages are only passed when given: a value passed at launch can't be changed by the app,
    /// so passing one every time would hide what the app itself saves (Home's Browse choice, the Downloads page).
    private func launch(tab: String, signedIn: Bool = true, explore: String? = nil, page: String? = nil, tvPage: String = "live",
                        more: [String] = [], rtx: String? = nil) {
        app?.terminate()
        app = XCUIApplication()
        app.launchArguments += ["-holyarrsAddress", server, "-rtxAddress", rtx ?? server, "-sportarrAddress", server, "-outsideOn", "YES",
                                "-tab", tab, "-tvPage", tvPage] + more
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

    /// The tab bar's buttons, left to right.
    private func tabLabels() -> [String] {
        app.tabBars.firstMatch.buttons.allElementsBoundByIndex.map(\.label)
    }

    private func tabSelected(_ name: String) -> Bool {
        let b = app.tabBars.firstMatch.buttons[name]
        return b.waitForExistence(timeout: 10) && b.isSelected
    }

    /// Swipes until the element can be tapped: up to reach something further down the page, down if it is above.
    @discardableResult
    private func scrollTo(_ e: XCUIElement, limit: Int = 10) -> Bool {
        guard e.waitForExistence(timeout: 10) else { return false }
        for _ in 0..<limit where !e.isHittable {
            if e.frame.maxY < app.frame.height * 0.2 { app.swipeDown() } else { app.swipeUp() }
            usleep(500_000)
        }
        return e.exists && e.isHittable
    }

    /// The labels and identifiers of every button on screen, read in one snapshot.
    private func buttonNames() -> Set<String> {
        guard let root = try? app.snapshot() else { return [] }
        var out = Set<String>()
        func walk(_ e: XCUIElementSnapshot) {
            if e.elementType == .button { out.insert(e.label); out.insert(e.identifier) }
            e.children.forEach(walk)
        }
        walk(root)
        return out
    }

    /// Waits for the live player to tune in, then a moment for the picture to start.
    private func waitPlaying() {
        let tuning = app.staticTexts["Tuning in on the PC..."]
        _ = tuning.waitForExistence(timeout: 3)
        _ = tuning.waitForNonExistence(timeout: 25)
        sleep(4)
    }

    /// A tap on the picture (above the middle, clear of the system's play button).
    private func tapPicture() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
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
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Resume The Matrix'")).firstMatch.exists,
                      "Continue Watching card for the part-watched Matrix")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Runs out in 9 days'")).firstMatch.exists,
                      "subscription warning on Home")
        let tabs = tabLabels()
        check(tabs == ["Home", "Sports", "TV", "Downloads", "Search"] && !app.tabBars.firstMatch.buttons["More"].exists,
              "iPhone tab bar has exactly 5 items, Home, Sports, TV, Downloads, Search, and no More (found \(tabs))")
        check(app.navigationBars.buttons["Settings"].exists, "Settings gear in Home's toolbar")
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Resume The Matrix'")).firstMatch
        let bar = app.tabBars.firstMatch
        check(card.exists && card.frame.minY > 0 && card.frame.maxY < bar.frame.minY,
              "Continue Watching card on the first screen, above the tab bar (card \(card.frame), tab bar top \(bar.frame.minY))")
        let warning = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Runs out in 9 days'")).firstMatch
        check(app.staticTexts["Continue Watching"].frame.minY < warning.frame.minY, "Continue Watching comes before the subscription warning")
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
            XCTAssertTrue(app.buttons["Play now while it downloads"].waitForExistence(timeout: 10),
                          "the 4K copy coming in shows on the page, playable while it downloads")
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

        // A Library show whose episodes are on the PC (Breaking Bad; S5 E3 left 20 minutes in): Resume on its page,
        // and its episodes play from the season sheet.
        launch(tab: "home")
        let show = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Breaking Bad'")).firstMatch
        if scrollTo(show) {
            show.tap()
            check(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Resume S5 E3'")).firstMatch.waitForExistence(timeout: 10),
                  "a show with episodes on the PC offers Resume S5 E3 at the top of its page")
            shot("title-show")
            let season = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Season 5'")).firstMatch
            if scrollTo(season) {
                season.tap()
                check(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Resume S5 E3'")).firstMatch.waitForExistence(timeout: 10)
                      && app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play S5 E4'")).firstMatch.exists,
                      "the season's episodes play from the PC: Resume S5 E3, Play S5 E4")
                shot("show-episodes")
            } else {
                XCTFail("no Season 5 on Breaking Bad's page")
            }
        } else {
            XCTFail("Breaking Bad not on Home")
        }

        // The PC not answering (a closed port): Continue Watching and the TV tab stay, Home says so.
        launch(tab: "home", rtx: "http://127.0.0.1:9")
        check(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Resume The Matrix'")).firstMatch.waitForExistence(timeout: 15),
              "PC not answering: Continue Watching keeps The Matrix")
        check(app.staticTexts["PC not answering"].waitForExistence(timeout: 25), "PC not answering: Home says so")
        check(app.tabBars.firstMatch.buttons["TV"].exists, "PC not answering: the TV tab stays")
        shot("home-pc-down")

        // Explore is Browse on Home now: a saved "explore" opens Home; Music and the genres are one tap from there.
        launch(tab: "explore")
        check(tabSelected("Home"), "saved tab explore opens Home")
        let browseAll = app.buttons["browse-all"]
        check(scrollTo(browseAll), "Browse on Home, under Home's rows")
        check(browseAll.isSelected, "Browse starts on All")
        shot("explore")
        app.swipeUp()
        sleep(1)
        check(app.buttons.matching(NSPredicate(format: "label == 'Science Fiction'")).firstMatch.exists, "Browse by genre tiles on Home")
        shot("explore-rows")
        let music = app.buttons["browse-music"]
        if scrollTo(music) {
            music.tap()
            sleep(2)
            check(music.isSelected && app.staticTexts["Top albums"].waitForExistence(timeout: 10), "Music one tap from Home: its rows")
        } else {
            XCTFail("no Music in Browse")
        }
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
            for _ in 0..<6 where !race.isHittable { app.swipeUp() }  // below the live rows
            race.tap()
            XCTAssertTrue(app.buttons["Play in 4K"].waitForExistence(timeout: 10), "Play in 4K on a downloaded race")
            sleep(2)
            shot("sports-event")
        } else {
            XCTFail("the Las Vegas race is not on Sports")
        }
        launch(tab: "sports")
        XCTAssertTrue(app.staticTexts["Your teams"].waitForExistence(timeout: 15), "sports: your teams live")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'NFL RedZone' AND label ENDSWITH 'pinned'")).firstMatch.exists,
                      "NFL RedZone pinned in Your teams")
        shot("sports-live")
        launch(tab: "tv")
        XCTAssertTrue(app.staticTexts["Live TV"].waitForExistence(timeout: 15), "TV tab")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'ESPN'")).firstMatch.waitForExistence(timeout: 10), "a channel in the lineup")
        shot("tv")
        app.swipeUp()
        sleep(1)
        shot("tv-rows")
        let all = app.buttons["All channels"]
        if all.waitForExistence(timeout: 5) {
            app.swipeDown()
            all.tap()
            XCTAssertTrue(app.staticTexts["All channels"].waitForExistence(timeout: 10), "All channels page")
            sleep(1)
            shot("tv-all")
        } else {
            XCTFail("no All channels button")
        }
        // On Demand: rows, a part-watched film (Resume), a series' seasons and episodes.
        launch(tab: "tv", tvPage: "ondemand")
        XCTAssertTrue(app.staticTexts["New releases"].waitForExistence(timeout: 15), "On Demand rows")
        shot("tv-ondemand")
        let odyssey = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'The Odyssey'")).firstMatch
        if odyssey.waitForExistence(timeout: 5) {
            odyssey.tap()
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Resume'")).firstMatch.waitForExistence(timeout: 10),
                          "Resume on a part-watched On Demand film")
            sleep(2)
            shot("ondemand-movie")
            // Cast: the PC lists its Cast TVs; picking one plays it there (the stand-in TV reports playing).
            let cast = app.buttons["Cast"]
            if cast.waitForExistence(timeout: 5) {
                cast.tap()
                let tv = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Patio TV'")).firstMatch
                XCTAssertTrue(tv.waitForExistence(timeout: 15), "a Cast TV in the list")
                shot("cast-devices")
                tv.tap()
                XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Playing on Patio TV'")).firstMatch
                    .waitForExistence(timeout: 15), "cast reported playing")
                shot("cast-playing")
            } else {
                XCTFail("no Cast button on an On Demand film")
            }
        } else {
            XCTFail("The Odyssey not in On Demand")
        }
        launch(tab: "tv", tvPage: "ondemand")
        let farm = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'The Witch Farm'")).firstMatch
        if farm.waitForExistence(timeout: 10) {
            for _ in 0..<3 where !farm.isHittable { app.swipeUp() }
            farm.tap()
            XCTAssertTrue(app.buttons["Season 2"].waitForExistence(timeout: 10), "a series' seasons")
            sleep(2)
            shot("ondemand-series")
        } else {
            XCTFail("The Witch Farm not in On Demand")
        }
        launch(tab: "search")
        shot("search")
        // Downloads opens on the downloads list (nothing saved yet); saved Requests and Calendar tabs open their page in it.
        launch(tab: "downloads")
        check(tabSelected("Downloads") && app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'The Last of Us'")).firstMatch
            .waitForExistence(timeout: 10), "Downloads tab opens on the downloads list")
        launch(tab: "requests")
        check(tabSelected("Downloads"), "saved tab requests opens Downloads")
        check(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Dune: Part Two'")).firstMatch.waitForExistence(timeout: 10),
              "saved tab requests opens the Requests page: an ask waiting for an OK")
        shot("requests-waiting")
        launch(tab: "downloads", page: "downloads")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'The Last of Us'")).firstMatch.waitForExistence(timeout: 10), "a download")
        shot("downloads")
        launch(tab: "calendar")
        check(tabSelected("Downloads") && app.staticTexts["Coming up"].waitForExistence(timeout: 10), "saved tab calendar opens Calendar inside Downloads")
        shot("calendar")
        // Settings was a tab: a saved "settings" opens it on Home. Back on Home, the gear opens it.
        launch(tab: "settings")
        let settingsBar = app.navigationBars["Settings"]
        check(settingsBar.waitForExistence(timeout: 10) && tabSelected("Home"), "saved tab settings opens Settings on Home")
        settingsBar.buttons.firstMatch.tap()
        check(app.buttons["More info"].waitForExistence(timeout: 10), "back from Settings to Home")
        launch(tab: "home")
        let gear = app.navigationBars.buttons["Settings"]
        check(gear.waitForExistence(timeout: 15), "Settings gear on Home")
        gear.tap()
        check(app.navigationBars["Settings"].waitForExistence(timeout: 10), "the gear opens Settings")
        sleep(1)
        shot("settings")
        app.swipeUp()
        sleep(1)
        shot("settings-subscriptions")
        let guide = app.buttons["Picture setup guide"]
        for _ in 0..<4 where !guide.isHittable { app.swipeUp() }
        if guide.waitForExistence(timeout: 5) {
            guide.tap()
            sleep(1)
            shot("setup-guide")
        } else {
            XCTFail("no Picture setup guide")
        }

        // The live player: nothing of the app's own over a playing picture; a tap on it shows Close, Feeds and Cast
        // (and they go again by themselves); Other feeds lists the game's feeds and switches to the one picked.
        let feeds = app.buttons["Other feeds"]
        let cast = app.buttons["Cast to a Chromecast or Google TV"]
        launch(tab: "sports")
        let bears = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Saints at Bears'")).firstMatch
        if bears.waitForExistence(timeout: 15) {
            bears.tap()
            waitPlaying()
            check(!feeds.exists && !cast.exists, "live player: nothing of the app's own over the playing picture until it is tapped")
            tapPicture()
            check(feeds.waitForExistence(timeout: 3), "live player: a tap on the picture shows Feeds")
            feeds.tap()
            let first = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Feed 1'")).firstMatch
            let second = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Feed 2'")).firstMatch
            let third = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Feed 3'")).firstMatch
            check(first.waitForExistence(timeout: 5) && first.label.hasSuffix("1080p60 (best)") && first.isSelected,
                  "Other feeds: Feed 1, 1080p60 (best), marked playing (found \(first.label))")
            check(second.label.hasSuffix("720p60") && third.label.hasSuffix("not measured yet") && !second.isSelected,
                  "Other feeds: the game's other two feeds (found \(second.label); \(third.label))")
            shot("live-feeds")
            second.tap()
            waitPlaying()
            tapPicture()
            // Read every button from one snapshot: the buttons hide again after 4 s, and asking for them one by one
            // took 4.4 s on a slow runner (run 45236765575).
            let shown = feeds.waitForExistence(timeout: 3) ? buttonNames() : []
            check(shown.contains("Other feeds") && shown.contains("Cast to a Chromecast or Google TV") && shown.contains("Close Button")
                  && !shown.contains("xmark"),
                  "live player: after switching, a tap shows Feeds and Cast, with the system's Close (no second Close of the app's)")
            shot("live-player")
            check(feeds.waitForNonExistence(timeout: 8), "live player: the buttons go again by themselves")
            tapPicture()
            if feeds.waitForExistence(timeout: 3) {
                feeds.tap()
                check(second.waitForExistence(timeout: 5) && second.isSelected && !first.isSelected, "Other feeds: Feed 2 now playing")
                shot("live-feed-switched")
                app.buttons["Done"].tap()
            } else {
                XCTFail("no Feeds after the second tap")
            }
        } else {
            XCTFail("the Bears game is not on Sports")
        }
        // A channel with a spare feed (ESPN) offers it too.
        launch(tab: "tv")
        let espn = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'ESPN'")).firstMatch
        if espn.waitForExistence(timeout: 15) {
            espn.tap()
            waitPlaying()
            tapPicture()
            if feeds.waitForExistence(timeout: 3) {
                feeds.tap()
                let main = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Feed 1'")).firstMatch
                let spare = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Feed 2'")).firstMatch
                check(main.waitForExistence(timeout: 5) && main.label.hasSuffix("main") && spare.label.hasSuffix("spare"),
                      "a channel's Other feeds: its main and spare feeds (found \(main.label); \(spare.label))")
                shot("live-channel-feeds")
                app.buttons["Done"].tap()
                // The system's Close (the only Close over a picture since iOS 26) closes the player, and the next
                // channel opens.
                sleep(1)
                let systemClose = app.buttons["Close Button"]
                let video = app.otherElements["Video"]  // the system player's picture, there with or without its controls
                // The system's controls show and hide with each tap and fade out by themselves: let each tap settle,
                // and tap Close where it is while it is there. A tap that lands after they faded only shows them
                // again, so try a few times.
                var closed = false
                for _ in 0..<4 where !closed {
                    tapPicture()
                    sleep(1)
                    if !systemClose.exists { tapPicture(); sleep(1) }
                    if systemClose.exists {
                        let f = systemClose.frame
                        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.midX, dy: f.midY)).tap()
                    }
                    closed = video.waitForNonExistence(timeout: 5)
                }
                if closed {
                    check(!feeds.exists && !cast.exists, "the system's Close closes the live player")
                    let cnn = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'CNN'")).firstMatch
                    if scrollTo(cnn) {
                        cnn.tap()
                        waitPlaying()
                        tapPicture()
                        // Run 45073480679 once saw no buttons after this first tap (the channel was playing: the PC
                        // served it). Say what the screen had, then try one more tap, and report which it took.
                        var shown = cast.waitForExistence(timeout: 3)
                        if !shown {
                            print("NOTE first tap on the second player showed no buttons: video \(video.exists), system controls \(systemClose.exists)")
                            shot("live-after-close-first-tap")
                            tapPicture()
                            shown = cast.waitForExistence(timeout: 3)
                        }
                        check(shown, "after the system's Close, the next channel opens and plays (a tap shows Cast)")
                    } else {
                        XCTFail("CNN is not on TV")
                    }
                } else {
                    XCTFail("the system's Close did not close the live player")
                }
            } else {
                XCTFail("no Feeds on a channel with a spare feed")
            }
        } else {
            XCTFail("ESPN is not on TV")
        }

        // Play in 4K can no longer be switched off: an old build's saved "off" (given here at launch) still leaves the
        // movie playable, and Settings has no such switch.
        launch(tab: "home", more: ["-rtxEnabled", "NO"])
        // Settings was left open on Home by the gear above (the app keeps it open across launches).
        let settingsOpen = app.navigationBars["Settings"]
        if settingsOpen.waitForExistence(timeout: 8) {
            check(!app.switches["Show Play in 4K"].exists, "Settings has no Show Play in 4K switch")
            settingsOpen.buttons.firstMatch.tap()
        }
        let film = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'The Matrix'")).firstMatch
        if scrollTo(film) {
            film.tap()
            check(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Resume in 4K'")).firstMatch.waitForExistence(timeout: 15)
                  && !app.buttons["Turn on Play in 4K"].exists,
                  "an old saved Play in 4K off no longer hides Resume in 4K")
            shot("title-4k-always")
        } else {
            XCTFail("The Matrix not on Home")
        }
    }
}
