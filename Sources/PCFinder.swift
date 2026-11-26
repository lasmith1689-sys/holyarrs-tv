import Foundation

/// Finds the PC again when its home address changes. The router handed the PC a new address one night
/// (192.168.68.100 became .96 at 3:55 AM, Nov 26 2026) and every screen kept calling the old one. When the saved RTX
/// address doesn't answer, this asks every address on this device's own network (its /24) for the RTX server at the
/// same port, all at once with a short timeout, and moves HolyArrs, the RTX server and Sportarr (all on the PC) to
/// the address that answered. Only addresses that pointed at the old host are changed.
@MainActor
enum PCFinder {
    private static var running: Task<Bool, Never>?

    /// True when the PC was found at a new address (the addresses were updated).
    @discardableResult
    static func relocate(rtx: RTXServer, api: HolyArrs, sportarr: Sportarr) async -> Bool {
        if let running { return await running.value }
        let task = Task { @MainActor () -> Bool in
            defer { running = nil }
            // Only a saved private IP address can go stale this way (not a name, not this machine in the screen check).
            guard let home = rtx.homeBase, let oldHost = home.host, isPrivate(oldHost) else { return false }
            if await Away.answers(home, timeout: 3) { return false }
            guard let prefix = localPrefix(), let found = await scan(prefix: prefix, port: home.port ?? 8787,
                                                                     skip: oldHost) else { return false }
            rtx.address = moved(rtx.address, from: oldHost, to: found)
            api.address = moved(api.address, from: oldHost, to: found)
            sportarr.address = moved(sportarr.address, from: oldHost, to: found)
            return true
        }
        running = task
        return await task.value
    }

    /// `address` with `to` as its host when its host is `from`; otherwise unchanged.
    nonisolated static func moved(_ address: String, from: String, to: String) -> String {
        let t = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var c = URLComponents(string: t), c.host == from else { return address }
        c.host = to
        return c.string ?? address
    }

    /// The first three parts of this device's private IPv4 address ("192.168.68"), from Wi-Fi or Ethernet (never
    /// cellular).
    nonisolated static func localPrefix() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: p.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let ip = String(cString: host)
            let parts = ip.split(separator: ".")
            guard parts.count == 4, isPrivate(ip) else { continue }
            if name.hasPrefix("en") { return parts.prefix(3).joined(separator: ".") }  // Wi-Fi or Ethernet only
        }
        return nil
    }

    nonisolated static func isPrivate(_ ip: String) -> Bool {
        let p = ip.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return false }
        return p[0] == 10 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && (16...31).contains(p[1]))
    }

    /// Every address on the /24 at once (1.5 s each); the first that answers like the RTX server wins.
    nonisolated static func scan(prefix: String, port: Int, skip: String) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            for n in 1...254 {
                let ip = "\(prefix).\(n)"
                if ip == skip { continue }
                group.addTask {
                    guard let url = URL(string: "http://\(ip):\(port)") else { return nil }
                    return await Away.answers(url, timeout: 1.5) ? ip : nil
                }
            }
            for await ip in group {
                if let ip {
                    group.cancelAll()
                    return ip
                }
            }
            return nil
        }
    }
}
