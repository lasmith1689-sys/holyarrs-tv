import Foundation
import Security

/// Sportarr (the sports PVR on the PC, port 1867): its native JSON API under /api, with its API key in X-Api-Key.
/// While Sportarr's own login is off (the default on a home network) it hands the key to its web page through
/// /initialize.json, so the app picks it up by itself; with a login on, the key can be pasted in Settings.
@MainActor
final class Sportarr: ObservableObject {
    static let defaultAddress = "http://192.168.68.100:1867"

    enum State: Equatable {
        case checking, ready, needsKey, unreachable(String)
    }

    @Published var address: String { didSet { UserDefaults.standard.set(address, forKey: "sportarrAddress") } }
    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "sportarrEnabled") } }
    @Published private(set) var state: State = .checking
    @Published private(set) var version: String?
    private var key: String?

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    init() {
        address = UserDefaults.standard.string(forKey: "sportarrAddress") ?? Sportarr.defaultAddress
        enabled = UserDefaults.standard.object(forKey: "sportarrEnabled") as? Bool ?? true
        key = SportarrKey.load()
    }

    var base: URL? {
        let t = address.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: t), url.scheme != nil, url.host != nil else { return nil }
        return Away.shared.route(url)
    }

    var ready: Bool { state == .ready }

    /// Finds the key (Sportarr's /initialize.json, else the one saved here) and checks it with /api/system/status.
    func connect() async {
        guard enabled else { return }
        guard let base else { state = .unreachable("The Sportarr address is not valid."); return }
        state = .checking
        do {
            let (data, _) = try await session.data(from: base.appendingPathComponent("initialize.json"))
            if let k = (try? JSON.parse(data))?["apiKey"].string, !k.isEmpty { key = k }
        } catch {
            state = .unreachable("Sportarr is not reachable at \(address).")
            return
        }
        guard key != nil else { state = .needsKey; return }
        do {
            let s = try await get("system/status")
            version = s["version"].string
            state = .ready
        } catch SportarrError.unauthorized {
            state = .needsKey
        } catch {
            state = .unreachable(error.localizedDescription)
        }
    }

    func useKey(_ k: String) async {
        let t = k.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        key = t
        SportarrKey.save(t)
        await connect()
    }

    func get(_ path: String, _ query: [String: String] = [:]) async throws -> JSON {
        try await send("GET", path, query: query)
    }

    @discardableResult
    func post(_ path: String, _ body: [String: Any]? = nil) async throws -> JSON {
        try await send("POST", path, body: body ?? [:])
    }

    @discardableResult
    func put(_ path: String, _ body: [String: Any]) async throws -> JSON {
        try await send("PUT", path, body: body)
    }

    @discardableResult
    func delete(_ path: String, _ query: [String: String] = [:]) async throws -> JSON {
        try await send("DELETE", path, query: query)
    }

    private func send(_ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil) async throws -> JSON {
        guard let base, var comps = URLComponents(url: base.appendingPathComponent("api/" + path), resolvingAgainstBaseURL: false)
        else { throw SportarrError.badAddress }
        if !query.isEmpty { comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = comps.url else { throw SportarrError.badAddress }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key { req.setValue(key, forHTTPHeaderField: "X-Api-Key") }
        if let body {
            req.httpBody = JSON.body(body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw SportarrError.unauthorized }
        guard (200..<300).contains(code) else { throw SportarrError.server(code, String(data: data, encoding: .utf8) ?? "") }
        if data.isEmpty { return .null }
        return (try? JSON.parse(data)) ?? .null
    }
}

enum SportarrError: LocalizedError {
    case badAddress, unauthorized
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .badAddress: return "The Sportarr address is not valid. Check Settings."
        case .unauthorized: return "Sportarr turned down the key. Paste it again in Settings."
        case let .server(code, body):
            let j = try? JSON.parse(Data(body.utf8))
            let text = j?["error"].string ?? j?["message"].string ?? j?["detail"].string ?? String(body.prefix(300))
            return "Sportarr answered \(code): \(text)"
        }
    }
}

/// A pasted Sportarr key (only needed when Sportarr's own login is on), kept in the keychain.
enum SportarrKey {
    private static let service = "sportarr.key"

    static func save(_ key: String) {
        clear()
        SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "sportarr",
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ] as CFDictionary, nil)
    }

    static func load() -> String? {
        var out: CFTypeRef?
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func clear() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}

/// One Sportarr event (a game, race session, fight card or golf round), read tolerantly.
struct SportEvent: Identifiable, Hashable {
    let id: Int
    let title: String
    let league: String
    let leagueId: Int?
    let leagueLogo: String?
    let sport: String
    let date: Date?
    /// Sportarr stores a date with no known start as midnight UTC.
    let timeKnown: Bool
    let venue: String?
    let home: String?
    let away: String?
    let thumb: String?
    let monitored: Bool
    let hasFile: Bool
    let fileNames: [String]
    let status: String?
    let quality: String?

    init?(_ j: JSON) {
        guard let id = j["id"].int else { return nil }
        self.id = id
        title = j["title"].string ?? "Event"
        league = j["leagueName"].string ?? j["league"]["name"].string ?? ""
        leagueId = j["leagueId"].int
        leagueLogo = j["leagueLogoUrl"].string ?? j["league"]["logoUrl"].string
        sport = j["sport"].string ?? ""
        let raw = j.first("eventDate", "broadcastDate").string
        date = Dates.parse(raw)
        timeKnown = !(raw ?? "").contains("T00:00:00")
        venue = j["venue"].string
        home = j["homeTeamName"].string ?? j["homeTeam"]["name"].string
        away = j["awayTeamName"].string ?? j["awayTeam"]["name"].string
        thumb = j["thumbUrl"].string ?? j["images"].array.first?.string ?? j["league"]["bannerUrl"].string
        monitored = j["monitored"].bool
        let files = j["files"].array
        var names = files.compactMap { f in (f.first("path", "relativePath", "filePath", "fileName").string).map(SportEvent.fileName) }
        if let p = j["filePath"].string { names.append(SportEvent.fileName(p)) }
        fileNames = Array(Set(names))
        hasFile = j["hasFile"].bool || !fileNames.isEmpty
        status = j["status"].string
        quality = j["quality"].string ?? files.first?["quality"].string
    }

    /// The last part of a Windows or POSIX path.
    static func fileName(_ path: String) -> String {
        String(path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last ?? Substring(path))
    }

    var matchup: String? {
        guard let home, let away else { return nil }
        return "\(away) at \(home)"
    }

    var whenLabel: String {
        guard let date else { return "Date to be set" }
        let f = DateFormatter()
        f.dateFormat = timeKnown ? "EEE MMM d, h:mm a" : "EEE MMM d"
        if !timeKnown { f.timeZone = TimeZone(identifier: "UTC") }
        return f.string(from: date)
    }

    var isPast: Bool { (date ?? .distantFuture) < Date().addingTimeInterval(-3 * 3600) }

    /// Never a score: Sportarr's events carry results, and the app keeps them out so nothing is spoiled.
    var stateLabel: String {
        if hasFile { return "READY" }
        if monitored { return isPast ? "LOOKING" : "WILL GET" }
        return ""
    }
}

struct SportLeague: Identifiable, Hashable {
    let id: Int
    let externalId: String?
    let name: String
    let sport: String
    let format: String
    let logo: String?
    let poster: String?
    let banner: String?
    let monitored: Bool
    let monitorType: String
    let eventCount: Int
    let upcoming: Int
    let files: Int

    init?(_ j: JSON) {
        guard let id = j["id"].int else { return nil }
        self.id = id
        externalId = j["externalId"].string
        name = j["name"].string ?? "League"
        sport = j["sport"].string ?? ""
        format = j["sportFormat"].string ?? ""
        logo = j["logoUrl"].string
        poster = j["posterUrl"].string
        banner = j["bannerUrl"].string
        monitored = j["monitored"].bool
        monitorType = j["monitorType"].string ?? "None"
        eventCount = j["eventCount"].int ?? 0
        upcoming = j["upcomingCount"].int ?? 0
        files = j["fileCount"].int ?? 0
    }

    var teamBased: Bool { format.lowercased().contains("team") }
}
