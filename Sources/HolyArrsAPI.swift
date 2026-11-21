import Foundation

enum APIError: LocalizedError {
    case badAddress
    case signedOut
    case twoFactor
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .badAddress: return "The HolyArrs address is not valid. Open Settings and check it."
        case .signedOut: return "Signed out. Sign in to HolyArrs again."
        case .twoFactor: return "This account asks for a second step."
        case let .server(code, body):
            let j = try? JSON.parse(Data(body.utf8))
            if let text = j?["text"].string { return text }
            let plain = j?["error"].string ?? body
            return "HolyArrs answered \(code): \(plain.prefix(300))"
        }
    }
}

/// Talks to HolyArrs' own JSON API (/api/v1), signed in with a session cookie like its web app.
/// The cookie lives in the shared cookie store, so poster requests (AsyncImage) are signed in too.
/// Every state-changing request sends the session's CSRF token in X-CSRF-Token.
@MainActor
final class HolyArrs: ObservableObject {
    static let defaultAddress = "http://192.168.68.100:6262"

    @Published var address: String {
        didSet { UserDefaults.standard.set(address, forKey: "holyarrsAddress") }
    }
    @Published private(set) var me: Me?
    @Published private(set) var checking = true

    private var csrf = ""
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.httpCookieStorage = .shared
        config.httpShouldSetCookies = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    init() {
        address = UserDefaults.standard.string(forKey: "holyarrsAddress") ?? HolyArrs.defaultAddress
    }

    var base: URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else { return nil }
        return url
    }

    // MARK: Sign-in

    /// Reads who is signed in from the saved cookie; tries the saved name and password once if the cookie expired.
    func restore() async {
        checking = true
        defer { checking = false }
        if await loadMe() { return }
        // The simulator screen check signs in to its stand-in server with a launch argument
        // (-testSignIn name:password). Only honoured for a server on this machine.
        if let t = UserDefaults.standard.string(forKey: "testSignIn"), ["127.0.0.1", "localhost"].contains(base?.host ?? ""),
           let i = t.firstIndex(of: ":") {
            try? await signIn(name: String(t[..<i]), password: String(t[t.index(after: i)...]), remember: false)
            return
        }
        if let saved = Keychain.load(), !saved.password.isEmpty {
            try? await signIn(name: saved.name, password: saved.password, remember: true)
        }
    }

    @discardableResult
    private func loadMe() async -> Bool {
        guard let j = try? await get("auth/me") else { me = nil; return false }
        csrf = j["csrf"].string ?? csrf
        me = Me(j)
        return true
    }

    /// Signs in with name and password. Throws `.twoFactor` with the ticket kept for `finishTwoFactor`.
    func signIn(name: String, password: String, remember: Bool) async throws {
        let j = try await send("POST", "auth/login", body: ["name": name, "password": password], csrf: false)
        if let ticket = j.first("ticket", "two_factor_ticket").string {
            pendingTicket = ticket
            pendingSave = remember ? (name, password) : nil
            throw APIError.twoFactor
        }
        csrf = j["csrf"].string ?? ""
        if remember { Keychain.save(name: name, password: password) } else { Keychain.clear() }
        await loadMe()
    }

    private var pendingTicket: String?
    private var pendingSave: (String, String)?

    func finishTwoFactor(code: String) async throws {
        guard let ticket = pendingTicket else { throw APIError.signedOut }
        let j = try await send("POST", "auth/login/two-factor", body: ["ticket": ticket, "code": code], csrf: false)
        csrf = j["csrf"].string ?? ""
        if let (n, p) = pendingSave { Keychain.save(name: n, password: p) }
        pendingTicket = nil
        pendingSave = nil
        await loadMe()
    }

    // MARK: Plex sign-in

    /// A HolyArrs on this machine (only the simulator screen check's stand-in).
    var isLocalServer: Bool { ["127.0.0.1", "localhost"].contains(base?.host ?? "") }

    /// How this HolyArrs lets people in (GET /auth/state, no sign-in needed): whether it still has no owner, and
    /// which ways are on ("password", "plex", ...).
    func signInState() async -> (needsSetup: Bool, ways: Set<String>, setupWays: Set<String>)? {
        guard let j = try? await send("GET", "auth/state", csrf: false) else { return nil }
        return (j["needs_setup"].bool, Set(j["ways"].array.compactMap(\.string)), Set(j["setup_ways"].array.compactMap(\.string)))
    }

    /// Starts a Plex sign-in: HolyArrs asks Plex for a PIN and answers with Plex's page to approve it on.
    /// With `setup`, approving it makes that Plex account HolyArrs' owner (first run only).
    func plexStart(setup: Bool) async throws -> (id: Int, url: URL) {
        let j = try await send("POST", setup ? "auth/setup/plex/start" : "auth/plex/start", body: [:], csrf: false)
        guard let id = j["id"].int, let s = j["auth_url"].string, let url = URL(string: s) else {
            throw APIError.server(0, "HolyArrs did not start a Plex sign-in")
        }
        return (id, url)
    }

    /// Asks once whether the Plex sign-in was approved. False while waiting; true once signed in.
    func plexFinish(id: Int, setup: Bool) async throws -> Bool {
        let j: JSON
        do {
            j = try await send("POST", setup ? "auth/setup/plex/finish" : "auth/plex/finish", body: ["id": id], csrf: false)
        } catch APIError.server(429, _) {
            return false  // asked within a second of the last check
        }
        if j["waiting"].bool { return false }
        if let ticket = j.first("ticket", "two_factor_ticket").string {
            pendingTicket = ticket
            pendingSave = nil
            throw APIError.twoFactor
        }
        csrf = j["csrf"].string ?? ""
        Keychain.clear()  // a Plex sign-in keeps no password; the session cookie lasts up to 30 days
        await loadMe()
        return me != nil
    }

    func signOut() async {
        _ = try? await post("auth/logout")
        Keychain.clear()
        if let base { HTTPCookieStorage.shared.cookies(for: base)?.forEach { HTTPCookieStorage.shared.deleteCookie($0) } }
        csrf = ""
        me = nil
    }

    // MARK: Requests

    func get(_ path: String, _ query: [String: String] = [:]) async throws -> JSON {
        try await send("GET", path, query: query)
    }

    @discardableResult
    func post(_ path: String, _ body: [String: Any]? = nil) async throws -> JSON {
        try await send("POST", path, body: body ?? [:])
    }

    @discardableResult
    func put(_ path: String, _ body: [String: Any]? = nil) async throws -> JSON {
        try await send("PUT", path, body: body)
    }

    @discardableResult
    func delete(_ path: String) async throws -> JSON {
        try await send("DELETE", path)
    }

    private func send(_ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil,
                      csrf sendCSRF: Bool = true, retried: Bool = false) async throws -> JSON {
        guard let base, var comps = URLComponents(url: base.appendingPathComponent("api/v1/" + path), resolvingAgainstBaseURL: false)
        else { throw APIError.badAddress }
        if !query.isEmpty { comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = comps.url else { throw APIError.badAddress }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en", forHTTPHeaderField: "X-HolyArrs-Language")
        if let body {
            req.httpBody = JSON.body(body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if method != "GET", sendCSRF, !csrf.isEmpty { req.setValue(csrf, forHTTPHeaderField: "X-CSRF-Token") }
        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401, path != "auth/me", path != "auth/login" {
            // The session ended (7 days idle). Sign in again once with the saved password, then repeat the call.
            if !retried, let saved = Keychain.load(), (try? await signIn(name: saved.name, password: saved.password, remember: true)) != nil {
                return try await send(method, path, query: query, body: body, csrf: sendCSRF, retried: true)
            }
            me = nil
            throw APIError.signedOut
        }
        guard (200..<300).contains(code) else { throw APIError.server(code, String(data: data, encoding: .utf8) ?? "") }
        if data.isEmpty { return .null }
        return (try? JSON.parse(data)) ?? .null
    }

    // MARK: Pictures

    /// HolyArrs keeps its own cache of TMDB pictures (/api/v1/artwork/tmdb/<size>/<file>); TV screens use it so the
    /// Apple TV never calls TMDB. Other addresses (already proxied, or HolyArrs' own) are made absolute.
    func image(_ raw: String?, width: Int = 342) -> URL? {
        guard let raw, !raw.isEmpty, let base else { return nil }
        if let r = raw.range(of: #"image\.tmdb\.org/t/p/[a-z0-9]+/"#, options: .regularExpression) {
            let file = raw[r.upperBound...]
            let size = [92, 154, 185, 300, 342, 500, 780, 1280].contains(width) ? "w\(width)" : "w500"
            return base.appendingPathComponent("api/v1/artwork/tmdb/\(size)/\(file)")
        }
        if raw.hasPrefix("http") { return URL(string: raw) }
        return URL(string: raw.hasPrefix("/") ? String(raw.dropFirst()) : raw, relativeTo: base.appendingPathComponent("/"))?.absoluteURL
    }

    func absolute(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty, let base else { return nil }
        if raw.hasPrefix("http") { return URL(string: raw) }
        return URL(string: raw, relativeTo: base.appendingPathComponent("/"))?.absoluteURL
    }

    /// Cookies to hand to AVFoundation, which does not read the shared cookie store for HLS segments.
    var cookies: [HTTPCookie] {
        base.flatMap { HTTPCookieStorage.shared.cookies(for: $0) } ?? []
    }
}

/// The signed-in person (GET /auth/me): name, role and what they may do.
struct Me: Equatable {
    let id: Int
    let name: String
    let role: String
    let permissions: Set<String>

    init(_ j: JSON) {
        id = j["id"].int ?? 0
        name = j["name"].string ?? "?"
        role = j["role"].string ?? ""
        // "perms" is the caller's effective permissions (webserver.Caller.Effective), already expanded for the role.
        permissions = Set(j.first("perms", "permissions").array.compactMap(\.string))
    }

    var isOwner: Bool { role == "owner" }
    func may(_ permission: String) -> Bool { isOwner || permissions.contains(permission) }
    var canManage: Bool { may("manage_library") }
    var canApprove: Bool { may("approve") }
    var canAsk: Bool { may("ask") || canManage }
}

// MARK: - Trailers

/// A title's trailer as HolyArrs found it (GET /trailer/{kind}/{tmdb}): YouTube's HLS manifest or an MP4, and
/// HolyArrs' own relay (proxy_url), which carries sound in the same stream. tvOS plays HLS natively, like Safari,
/// so the order follows HolyArrs' web app for Safari: the direct stream when it has sound, else the relay.
struct Trailer {
    let withSound: URL
    let muted: URL

    @MainActor
    static func find(_ api: HolyArrs, kind: Card.Kind, tmdb: String) async -> Trailer? {
        guard kind != .artist else { return nil }
        let lang = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
        guard let s = try? await api.get("trailer/\(kind.rawValue)/\(tmdb)", ["language": lang]) else { return nil }
        let direct = api.absolute(s["url"].string)
        let mp4 = api.absolute(s["mp4_url"].string)
        let relay = api.absolute(s["proxy_url"].string)
        let directHasSound = s["audio"].bool
        guard let any = direct ?? relay ?? mp4 else { return nil }
        let sound = directHasSound ? (direct ?? any) : (relay ?? (s["mp4_audio"].bool ? mp4 : nil) ?? any)
        return Trailer(withSound: sound, muted: direct ?? mp4 ?? any)
    }
}
