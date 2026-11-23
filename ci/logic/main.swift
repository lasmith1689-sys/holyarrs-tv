// Merge rules for Continue Watching (Sources/Resume.swift), run on the Mac in the screen check:
//   swiftc -o logic Sources/JSON.swift Sources/Resume.swift ci/logic/main.swift && ./logic
// Each case is one device's view: its own notes (UserDefaults) and what GET /positions answered.
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print((ok ? "CHECK passed: " : "CHECK FAILED: ") + what)
    if !ok { failures += 1 }
}

func fresh() {
    Resume.store = UserDefaults(suiteName: "afterglow-logic-\(UUID().uuidString)")!
}

func entry(_ t: Double, _ d: Double, _ at: Double, _ place: String = "iphone") -> JSON {
    .object(["t": .number(t), "duration": .number(d), "at": .number(at), "where": .string(place)])
}

let now = Date().timeIntervalSince1970

// 1. The bug from 2026-11-23: this device mirrored The Matrix earlier; the iPhone then removed it, so the PC has no
//    position, only a tombstone. Before the fix this device sent it straight back.
fresh()
_ = Resume.merge(.object(["matrix": entry(3120, 8160, now - 3600)]))
var r = Resume.merge(.object([:]), cleared: .object(["matrix": .number(now - 60)]))
check(r.positions["matrix"] == nil && r.push.isEmpty, "a title cleared on another screen stays cleared here (no re-send)")
check(Resume.position("matrix") == nil && Resume.local()["matrix"] == nil, "and this device forgets its own copy")

// 2. Progress made here while the PC was away, newer than anything the PC holds: it goes up, with its time.
fresh()
Resume.save("dune", 2500, duration: 9300)
let savedAt = Resume.savedAt("dune") ?? 0
r = Resume.merge(.object(["dune": entry(1000, 9300, now - 7200, "apple-tv")]))
check(r.positions["dune"]?.t == 2500 && r.push == [Resume.Push(id: "dune", t: 2500, d: 9300, at: savedAt)],
      "offline progress newer than the PC's is sent up with the time it was saved")

// 3. The PC's note is newer: it wins, nothing is sent.
fresh()
Resume.save("heat", 1200, duration: 10200)
r = Resume.merge(.object(["heat": entry(5400, 10200, now + 30, "apple-tv")]))
check(r.positions["heat"]?.t == 5400 && r.push.isEmpty, "a newer position from another screen replaces this one")
check(r.positions["heat"]?.place == "apple-tv", "and keeps where it was watched")

// 4. Finished here (or removed here) after the PC's note: the clear goes up, with its time.
fresh()
Resume.save("alien", 3000, duration: 7000)
Resume.clear("alien")
let clearedAt = Resume.savedAt("alien") ?? 0
r = Resume.merge(.object(["alien": entry(3000, 7000, now - 600)]))
check(r.positions["alien"] == nil && r.push == [Resume.Push(id: "alien", t: 0, d: 7000, at: clearedAt)],
      "a clear made here reaches the PC with its time")

// 5. Watched again here after another screen cleared it: this device's newer save wins and goes up.
fresh()
Resume.save("jaws", 900, duration: 7440)
r = Resume.merge(.object([:]), cleared: .object(["jaws": .number(now - 3600)]))
check(r.positions["jaws"]?.t == 900 && r.push.count == 1, "watching again after a clear elsewhere brings it back")

// 6. An older PC that sends no "cleared": behaves as before (offline progress still goes up).
fresh()
Resume.save("big", 700, duration: 6200)
r = Resume.merge(.object([:]))
check(r.positions["big"]?.t == 700 && r.push.count == 1, "with an older PC, progress it lacks is still sent")

// 7. On Demand entries are not this list's, and the local copy (Continue Watching before the PC answers) matches.
fresh()
r = Resume.merge(.object(["od:movie-1": entry(600, 5400, now), "matrix": entry(3120, 8160, now)]))
check(r.positions["od:movie-1"] == nil, "On Demand positions stay out of the films' list")
check(Resume.local() == r.positions, "the copy kept here is the merged list")

print(failures == 0 ? "All logic checks passed." : "\(failures) logic check(s) failed.")
exit(failures == 0 ? 0 : 1)
