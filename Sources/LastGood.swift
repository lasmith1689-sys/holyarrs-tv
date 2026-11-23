import Foundation

/// The last answer that worked from the PC or HolyArrs, kept in Caches so a screen can show it at launch and while
/// the PC is asleep or restarting, instead of an empty list. The system may clear Caches; that only costs a blank
/// screen until the next answer, as before.
enum LastGood {
    private static var folder: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let f = caches.appendingPathComponent("last-good", isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }

    static func write(_ name: String, _ data: Data) {
        guard let f = folder else { return }
        try? data.write(to: f.appendingPathComponent(name + ".json"), options: .atomic)
    }

    static func read(_ name: String) -> JSON? {
        guard let f = folder, let data = try? Data(contentsOf: f.appendingPathComponent(name + ".json")) else { return nil }
        return try? JSON.parse(data)
    }

    static func remove(_ name: String) {
        guard let f = folder else { return }
        try? FileManager.default.removeItem(at: f.appendingPathComponent(name + ".json"))
    }
}
