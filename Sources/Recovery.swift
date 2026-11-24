import Foundation

/// Release 3: a film or episode that drops comes back by itself, and every failure says what happened.
/// The rules and the words live here (no UI, no AVFoundation) so the logic check on the Mac tests them:
///   swiftc Sources/JSON.swift Sources/Resume.swift Sources/Recovery.swift ci/logic/main.swift
struct Recovery {
    /// Waits before each try to rebuild the stream: three tries over about half a minute, then Try again or Back.
    static let delays: [Double] = [3, 10, 20]
    /// Buffering this long while the viewer wants it to play counts as a drop.
    static let stallLimit: Double = 15
    /// A slow start says so after this long (the PC upscales the first minutes before it answers).
    static let slowStart: Double = 20
    /// Playing this long without trouble starts the try count over.
    static let healthy: Double = 60

    private(set) var tries = 0

    /// The wait before the next try, or nil when the tries are used up.
    mutating func next() -> Double? {
        guard tries < Recovery.delays.count else { return nil }
        defer { tries += 1 }
        return Recovery.delays[tries]
    }

    mutating func reset() { tries = 0 }

    static var limit: Int { delays.count }

    /// Buffering since `since` (nil: not buffering) has gone on long enough to rebuild the stream.
    static func stalled(since: Date?, now: Date = Date()) -> Bool {
        guard let since else { return false }
        return now.timeIntervalSince(since) > stallLimit
    }

    /// "the Apple TV", "the iPhone", or "another screen" (the PC's name for the screen, from /play's where=).
    static func screen(_ place: String) -> String {
        switch place.lowercased() {
        case "apple-tv", "appletv", "apple tv": return "the Apple TV"
        case "iphone": return "the iPhone"
        case "ipad": return "the iPad"
        case "web", "tablet": return "the tablet"
        default: return "another screen"
        }
    }

    static func lost(at seconds: Double, attempt: Int) -> String {
        "Lost the PC at \(Resume.label(seconds)). Trying again (\(attempt) of \(limit))"
    }

    static func gaveUp(at seconds: Double) -> String {
        "Lost the PC at \(Resume.label(seconds)). It didn't come back after \(limit) tries."
    }

    /// Another screen has the PC's one 4K film: before starting (busy) or after it took this one (taken).
    static func busy(title: String, place: String, taken: Bool) -> String {
        let who = title.isEmpty ? "another film" : title
        return taken ? "The PC switched to \(who) for \(screen(place))." : "The PC is upscaling \(who) for \(screen(place))."
    }

    static let busyNote = "It upscales one 4K film at a time. Playing here stops it there."
    static let slowLine = "Still starting. The PC is upscaling the first minutes, which can take up to 4 minutes."
}
