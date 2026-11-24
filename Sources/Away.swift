import Foundation

/// Away from home (Release 5): when the PC's home address is silent, the same PC is tried by its Tailscale name
/// (Tailscale signed in on the PC and on this iPhone), and HolyArrs, the RTX server and Sportarr all follow.
/// Films and episodes then play as the PC's away stream (1080p, a few Mbps, straight from the file: /play?away=1)
/// instead of the 4K upscale, which cellular and a home upload can't carry. At home nothing changes.
@MainActor
final class Away: ObservableObject {
    static let shared = Away()
    static let defaultHost = "luke-primary-desktop.tail804d7f.ts.net"  // the PC on Luke's tailnet (MagicDNS, 2026-11-24)

    /// The home address didn't answer and the Tailscale name did: every base below uses the Tailscale name.
    @Published private(set) var active = false
    @Published var host: String {
        didSet { UserDefaults.standard.set(host, forKey: "awayHost") }
    }
    private var checking: Task<Void, Never>?

    private init() {
        host = UserDefaults.standard.string(forKey: "awayHost") ?? Away.defaultHost
    }

    /// `url` with the Tailscale name in place of its host while away (same scheme, port and path).
    func route(_ url: URL?) -> URL? {
        guard let url, active else { return url }
        return Away.swap(url, host: host)
    }

    nonisolated static func swap(_ url: URL, host: String) -> URL {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        c.host = h
        return c.url ?? url
    }

    /// Home first (3 s), then the Tailscale name (8 s). One check at a time: callers join the one running.
    func check(home: URL?) async {
        if let checking { return await checking.value }
        let task = Task { @MainActor in
            defer { self.checking = nil }
            guard let home, Device.isTV == false else { self.active = false; return }
            if await Away.answers(home, timeout: 3) { self.active = false; return }
            self.active = await Away.answers(Away.swap(home, host: self.host), timeout: 8)
        }
        checking = task
        await task.value
    }

    nonisolated static func answers(_ base: URL, timeout: TimeInterval) async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("positions"))
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
}
