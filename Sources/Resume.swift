import Foundation

/// Where each RTX film was left, as this device knows it (UserDefaults, per RTX film id), kept in step with the PC's
/// list (GET /positions). Not kept for the first minute or the last 4. Plain Foundation, so the merge rules are
/// unit-tested on their own (ci/logic/main.swift); talking to the PC is in RTX.swift.
///
/// Every save and clear carries the time it happened ("at"), and the PC keeps a title it saw cleared as a tombstone
/// (GET /positions answers them in "cleared"). Before 2026-11-23 the PC deleted a cleared title and each device
/// re-sent whatever the PC lacked, so a film finished or taken off Continue Watching on one screen came back at
/// the next refresh of another.
enum Resume {
    struct Entry: Equatable {
        var t: Double
        var d: Double
        var at: Double
        var place: String
    }

    /// Something the PC hasn't heard yet: a position (t > 0) or a clear (t == 0), with when it happened here.
    struct Push: Equatable {
        let id: String
        let t: Double
        let d: Double
        let at: Double
    }

    /// Where the values live (tests use their own suite).
    nonisolated(unsafe) static var store: UserDefaults = .standard

    /// How this device names itself to the PC.
    static var here: String {
        #if os(tvOS)
        return "apple-tv"
        #else
        return "iphone"
        #endif
    }

    private static func key(_ id: String) -> String { "resume.\(id)" }

    /// Merges the PC's positions with this device's: for each title, whichever screen saved or cleared it last wins.
    /// `pc` is GET /positions' "positions", `cleared` its "cleared" (id -> when; empty from an older PC).
    /// Returns the merged list and what the PC hasn't heard yet (progress or clears made here, offline or while it
    /// was unreachable), so the caller can send those up with their times.
    static func merge(_ pc: JSON, cleared: JSON = .null) -> (positions: [String: Entry], push: [Push]) {
        let d = store
        var out: [String: Entry] = [:]
        var push: [Push] = []
        if case let .object(o) = pc {
            for (id, v) in o where !id.hasPrefix("od:") {  // On Demand titles keep their own (OnDemand.swift)
                guard let t = v["t"].double, t > 0 else { continue }
                out[id] = Entry(t: t, d: v["duration"].double ?? 0, at: v["at"].double ?? 0, place: v["where"].string ?? "")
            }
        }
        var pcCleared: [String: Double] = [:]
        if case let .object(o) = cleared {
            for (id, v) in o { pcCleared[id] = v.double ?? 0 }
        }
        let keys = Array(d.dictionaryRepresentation().keys)
        // Titles finished or started over here after the PC's note: clear them there too.
        for k in keys where k.hasPrefix("resume.cleared.") {
            let id = String(k.dropFirst("resume.cleared.".count))
            let when = d.double(forKey: k)
            if let p = out[id], p.at < when {
                out[id] = nil
                push.append(Push(id: id, t: 0, d: p.d, at: when))
            } else {
                d.removeObject(forKey: k)  // settled: the PC agrees, or another screen watched it since
            }
        }
        // Positions saved here after the PC's note (or that the PC never got), unless the PC saw it cleared later.
        for k in keys where k.hasPrefix("resume.") && !k.hasPrefix("resume.at.") && !k.hasPrefix("resume.d.")
            && !k.hasPrefix("resume.cleared.") && !k.hasPrefix("resume.where.") {
            let id = String(k.dropFirst("resume.".count))
            let t = d.double(forKey: k), at = d.double(forKey: "resume.at.\(id)")
            guard t > 0 else { continue }
            if let p = out[id], p.at >= at { continue }
            if let c = pcCleared[id], c >= at { continue }  // finished or removed on another screen after this save
            let dur = d.double(forKey: "resume.d.\(id)")
            let e = Entry(t: t, d: dur > 0 ? dur : (out[id]?.d ?? 0), at: at, place: here)
            out[id] = e
            push.append(Push(id: id, t: t, d: e.d, at: at))
        }
        // This device now mirrors the merged list.
        for k in keys where k.hasPrefix("resume.") && !k.hasPrefix("resume.cleared.") { d.removeObject(forKey: k) }
        for (id, p) in out {
            d.set(p.t, forKey: key(id))
            d.set(p.at, forKey: "resume.at.\(id)")
            d.set(p.place, forKey: "resume.where.\(id)")
            if p.d > 0 { d.set(p.d, forKey: "resume.d.\(id)") }
        }
        return (out, push)
    }

    /// This device's copy of the list (the last merge plus anything saved since), for Continue Watching before the
    /// PC answers or while it is away.
    static func local() -> [String: Entry] {
        let d = store
        var out: [String: Entry] = [:]
        for k in d.dictionaryRepresentation().keys where k.hasPrefix("resume.") && !k.hasPrefix("resume.at.")
            && !k.hasPrefix("resume.d.") && !k.hasPrefix("resume.cleared.") && !k.hasPrefix("resume.where.") {
            let id = String(k.dropFirst("resume.".count))
            let t = d.double(forKey: k)
            guard t > 0 else { continue }
            out[id] = Entry(t: t, d: d.double(forKey: "resume.d.\(id)"), at: d.double(forKey: "resume.at.\(id)"),
                            place: d.string(forKey: "resume.where.\(id)") ?? here)
        }
        return out
    }

    static func position(_ id: String) -> Double? {
        let v = store.double(forKey: key(id))
        return v > 0 ? v : nil
    }

    /// When this device last saved or cleared the title (what goes to the PC as at=).
    static func savedAt(_ id: String) -> Double? {
        let at = store.double(forKey: "resume.at.\(id)")
        if at > 0 { return at }
        let c = store.double(forKey: "resume.cleared.\(id)")
        return c > 0 ? c : nil
    }

    static func save(_ id: String, _ seconds: Double, duration: Double) {
        if seconds < 60 || (duration > 0 && seconds > duration - 240) {
            clear(id)
        } else {
            store.set(seconds, forKey: key(id))
            store.set(Date().timeIntervalSince1970, forKey: "resume.at.\(id)")
            store.set(here, forKey: "resume.where.\(id)")
            if duration > 0 { store.set(duration, forKey: "resume.d.\(id)") }
            store.removeObject(forKey: "resume.cleared.\(id)")
        }
    }

    static func clear(_ id: String) {
        for k in [key(id), "resume.at.\(id)", "resume.d.\(id)", "resume.where.\(id)"] { store.removeObject(forKey: k) }
        // Remembered until the PC has heard, so a finish watched offline isn't undone by the PC's older note.
        store.set(Date().timeIntervalSince1970, forKey: "resume.cleared.\(id)")
    }

    static func label(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
