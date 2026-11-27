import AVKit
import SwiftUI

/// The PC's RTX 4K upscaling server (rtx-upscale-stream, src/server.py), the same one the RTX 4K app plays from.
/// Its film list is matched to HolyArrs titles by name and year, so a Library movie that is also there gets
/// "Play in 4K". The player code is the RTX 4K app's.
@MainActor
final class RTXServer: ObservableObject {
    static let defaultAddress = "http://192.168.68.100:8787"

    @Published var address: String { didSet { UserDefaults.standard.set(address, forKey: "rtxAddress") } }
    /// Play in 4K is how Afterglow plays movies (Plex is no longer the player), so it is always on. It used to be a
    /// switch in Settings; switched off, a movie the PC had showed no way to play it.
    let enabled = true
    @Published private(set) var films: [RTXFilm] = []
    /// Sportarr's downloaded games and races on the PC (GET /sports), matched to events by file name.
    @Published private(set) var sports: [String: RTXFilm] = [:]
    /// What the outdoor TV is doing, as the PC last read it from the TV (GET /cast/status).
    @Published private(set) var outside: CastState?
    /// The last result of sending something outside (shown under the play buttons).
    @Published var outsideNote: String?
    @Published private(set) var castingFilm: String?
    @Published private(set) var error: String?
    /// Live TV is set up on the PC (an IPTV login saved there): shows the TV tab and the live part of Sports.
    @Published private(set) var liveTV = false
    /// NFL and Premier League teams with their crests and colours (GET /tv/teams), for Sportarr's game cards.
    @Published private(set) var teams: [String: [LiveTeam]] = [:]
    /// What the setup pays for, and when each runs out (GET /subscriptions).
    @Published private(set) var subscriptions: [Subscription] = []

    /// Whether the PC answered the last time it was asked (nil: not asked yet). Home says so when it didn't.
    @Published private(set) var reachable: Bool?
    @Published private(set) var checking = false

    init() {
        address = UserDefaults.standard.string(forKey: "rtxAddress") ?? RTXServer.defaultAddress
        UserDefaults.standard.removeObject(forKey: "rtxEnabled")  // the old Show Play in 4K switch
        Resume.server = base
        loadLastGood()
    }

    /// The last answers that worked, shown at launch before the PC answers and kept while it doesn't, so Continue
    /// Watching, Play in 4K and the TV tab never vanish because the PC is asleep or restarting.
    private func loadLastGood() {
        if let j = LastGood.read("library") { films = j["films"].array.compactMap(RTXFilm.init) }
        if let j = LastGood.read("sports") { sports = RTXServer.sportsByName(j) }
        if let j = LastGood.read("tv-status") { liveTV = j["configured"].bool }
        if let j = LastGood.read("subscriptions") { subscriptions = j["items"].array.compactMap(Subscription.init) }
        if let j = LastGood.read("teams") { teams = RTXServer.teamsByLeague(j) }
    }

    var base: URL? { Away.shared.route(homeBase) }

    /// The address as set (home); `base` swaps in the PC's Tailscale name while away.
    var homeBase: URL? {
        let t = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: t), url.scheme != nil, url.host != nil else { return nil }
        return url
    }

    private var refreshedAt: Date?

    /// Re-reads the PC's lists when they are older than `maxAge` (new downloads appear there within 5 minutes).
    func refreshIfStale(maxAge: TimeInterval = 60) async {
        if let at = refreshedAt, Date().timeIntervalSince(at) < maxAge { return }
        await refresh()
    }

    func refresh() async {
        refreshedAt = Date()
        if reachable != true || Away.shared.active { await Away.shared.check(home: homeBase) }
        guard let base else { error = "address not valid"; reachable = false; return }
        checking = true
        defer { checking = false }
        do {
            let (j, raw) = try await RTXAPI(base: base, quick: true).fetch("library")
            films = j["films"].array.compactMap(RTXFilm.init)
            LastGood.write("library", raw)
            error = nil
            reachable = true
            Resume.server = base
            await syncPositions()
            await refreshSports()
            // Only the PC's answer changes the TV tab: a failed check leaves it as it was.
            if case let (s, raw)? = try? await RTXAPI(base: base, quick: true).fetch("tv/status") {
                liveTV = s["configured"].bool
                LastGood.write("tv-status", raw)
            }
            if case let (s, raw)? = try? await RTXAPI(base: base, quick: true).fetch("subscriptions") {
                subscriptions = s["items"].array.compactMap(Subscription.init)
                LastGood.write("subscriptions", raw)
            }
            if teams.isEmpty, case let (t, raw)? = try? await RTXAPI(base: base, quick: true).fetch("tv/teams") {
                teams = RTXServer.teamsByLeague(t)
                LastGood.write("teams", raw)
            }
        } catch {
            // Keep what we had (films, Continue Watching, the TV tab); Home says the PC isn't answering.
            reachable = false
            self.error = "not reachable"
        }
    }

    nonisolated static func teamsByLeague(_ t: JSON) -> [String: [LiveTeam]] {
        var out: [String: [LiveTeam]] = [:]
        for (league, list) in t["leagues"].object { out[league] = list.array.compactMap(LiveTeam.init) }
        return out
    }

    nonisolated static func sportsByName(_ j: JSON) -> [String: RTXFilm] {
        var byName: [String: RTXFilm] = [:]
        for f in j["files"].array {
            if let name = f["name"].string, let film = RTXFilm(f) { byName[name.lowercased()] = film }
        }
        return byName
    }

    /// Where everything was left on any screen (kept on the PC), merged with this device's own notes: progress
    /// made offline goes up to the PC instead of being overwritten by it.
    func syncPositions() async {
        guard let base, let j = try? await RTXAPI(base: base, quick: true).get("positions") else { return }
        let (merged, push) = Resume.merge(j["positions"], cleared: j["cleared"])
        for p in push {
            let q = [URLQueryItem(name: "id", value: p.id), URLQueryItem(name: "t", value: String(format: "%.1f", p.t)),
                     URLQueryItem(name: "d", value: String(format: "%.1f", p.d)),
                     URLQueryItem(name: "where", value: Resume.here), URLQueryItem(name: "at", value: String(format: "%.3f", p.at))]
            _ = try? await RTXAPI(base: base, quick: true).get("position", q)
        }
        continueList = RTXServer.entries(merged)
        odList = ODContinue.list(j["positions"])
    }

    /// On Demand left part-way on any screen, with what a card needs (Release 3; newest first).
    @Published private(set) var odList: [ODContinue] = []

    /// Takes an On Demand title off Continue Watching on every screen (the PC clears a position under a minute).
    func forget(_ od: ODContinue) {
        odList.removeAll { $0.id == od.id }
        guard let base else { return }
        let q = [URLQueryItem(name: "key", value: od.key), URLQueryItem(name: "t", value: "0"),
                 URLQueryItem(name: "d", value: String(format: "%.1f", od.duration)), URLQueryItem(name: "where", value: Resume.here)]
        Task { _ = try? await RTXAPI(base: base, quick: true).get("tv/ondemand/position", q) }
    }

    /// Live TV or On Demand another screen is watching now (the plan's one stream), or nil.
    func otherStream() async -> (name: String, place: String)? {
        guard let base, let j = try? await RTXAPI(base: base, quick: true).get("tv/active") else { return nil }
        let other = j["active"].array.first { ($0["where"].string ?? "") != Resume.here }
        return other.map { (LiveTV.clean($0["name"].string ?? "live TV"), $0["where"].string ?? "") }
    }

    /// Continue Watching's entries, newest first.
    nonisolated static func entries(_ list: [String: Resume.Entry]) -> [ContinueEntry] {
        list.filter { $0.value.t > 0 }
            .map { ContinueEntry(id: $0.key, seconds: $0.value.t, duration: $0.value.d, at: Date(timeIntervalSince1970: $0.value.at), place: $0.value.place) }
            .sorted { $0.at > $1.at }
    }

    /// Everything left part-way on any screen, newest first (from the PC's positions).
    @Published private(set) var continueList: [ContinueEntry] = RTXServer.entries(Resume.local())

    /// Both teams of a Sportarr game, when the PC knows them ("Buffalo Bills", "Manchester United"): the longest of
    /// a team's names found as whole words wins.
    func matchup(league: String, home: String?, away: String?) -> (away: LiveTeam, home: LiveTeam)? {
        guard let home, let away else { return nil }
        let l = league.lowercased()
        guard let key = l.contains("nfl") ? "NFL" : l.contains("premier") ? "Premier League" : nil, let list = teams[key] else { return nil }
        func norm(_ s: String) -> String {
            " " + s.lowercased().replacingOccurrences(of: #"[^a-z0-9']+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces) + " "
        }
        func find(_ name: String) -> LiveTeam? {
            let n = norm(name)
            var best: LiveTeam?
            var size = 0
            for t in list {
                for a in t.aliases {
                    let k = norm(a)
                    if k.count > size, k.count > 2, n.contains(k) { best = t; size = k.count }
                }
            }
            return best
        }
        guard let a = find(away), let h = find(home), a != h else { return nil }
        return (a, h)
    }

    func film(id: String) -> RTXFilm? {
        films.first { $0.id == id } ?? sports.values.first { $0.id == id }
    }

    /// Takes a film off Continue Watching here and on the PC (a position under a minute clears it everywhere).
    func forget(_ id: String, duration: Double) {
        Resume.clear(id)
        Resume.send(id, 0, duration: duration)
        continueList.removeAll { $0.id == id }
    }

    /// A HolyArrs show's episodes the PC can play (GET /show: HolyArrs' own records of which file holds each), in
    /// order; empty when it has none or doesn't answer.
    func show(titleId: Int) async -> [RTXEpisode] {
        guard let base, let j = try? await RTXAPI(base: base, quick: true).get("show", [URLQueryItem(name: "title", value: String(titleId))])
        else { return [] }
        return j["episodes"].array.compactMap(RTXEpisode.init)
    }

    /// Asks the PC itself for a title's film (its own matching), for when the list here has no match.
    func find(name: String, year: Int?) async -> RTXFilm? {
        guard let base else { return nil }
        var q = [URLQueryItem(name: "title", value: name)]
        if let year { q.append(URLQueryItem(name: "year", value: String(year))) }
        guard let j = try? await RTXAPI(base: base).get("find", q) else { return nil }
        return RTXFilm(j["film"])
    }

    /// Why a Library movie has no Play in 4K, in plain words (shown on its page).
    var diagnosis: String {
        if reachable == false { return "Can't reach the PC right now. Check that it's on, then try again from Home." }
        if let error { return "The RTX server is \(error) at \(address)." }
        return "Not on the RTX server yet (\(films.count) films loaded from it). New downloads appear there within 5 minutes."
    }

    func refreshOutside() async {
        guard let base, let j = try? await RTXAPI(base: base).get("cast/status") else { return }
        outside = CastState(j)
    }

    /// Plays a film on the outdoor TV from `seconds`. The PC wakes the TV, starts the stream and waits until the
    /// TV itself says it is playing; the note says what actually happened.
    func playOutside(_ film: RTXFilm, label: String, seconds: Double) async {
        guard let base else { outsideNote = "The RTX server address is not valid."; return }
        castingFilm = film.id
        outsideNote = "Starting \(label) on the outdoor TV..."
        defer { castingFilm = nil }
        let j: JSON
        do {
            j = try await RTXAPI(base: base).get("cast", [URLQueryItem(name: "id", value: film.id),
                                                          URLQueryItem(name: "t", value: String(format: "%.1f", max(0, seconds)))])
        } catch APIError.server(_, let body) {
            j = (try? JSON.parse(Data(body.utf8))) ?? .null
        } catch {
            outsideNote = "Couldn't reach the PC: \(error.localizedDescription)"
            return
        }
        let st = CastState(j)
        outside = st
        if st?.state == "playing" {
            outsideNote = "Playing outside" + (st?.startupS.map { String(format: " (started in %.0f s)", $0) } ?? "") + "."
        } else {
            outsideNote = st?.error ?? j["error"].string ?? "The outdoor TV didn't start."
        }
    }

    func stopOutside() async {
        guard let base else { return }
        if let j = try? await RTXAPI(base: base).get("cast/stop") { outside = CastState(j) }
        await syncPositions()
        outsideNote = "Stopped outside."
    }

    func refreshSports() async {
        guard let base, case let (j, raw)? = try? await RTXAPI(base: base, quick: true).fetch("sports") else { return }
        sports = RTXServer.sportsByName(j)
        LastGood.write("sports", raw)
    }

    /// The RTX copy of a Sportarr event: the first of its files the PC can play.
    func sport(for event: SportEvent) -> RTXFilm? {
        guard enabled else { return nil }
        return event.fileNames.lazy.compactMap { self.sports[$0.lowercased()] }.first
    }

    /// The RTX film for a title: same name (ignoring case, punctuation and a leading The/A/An) and a year within one.
    func match(name: String, year: Int?) -> RTXFilm? {
        guard enabled else { return nil }
        let key = RTXServer.key(name)
        return films.first { f in
            RTXServer.key(f.title) == key && (year == nil || f.year == nil || abs((f.year ?? 0) - (year ?? 0)) <= 1)
        }
    }

    static func key(_ s: String) -> String {
        var t = s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        for a in ["the ", "a ", "an "] where t.hasPrefix(a) { t.removeFirst(a.count) }
        return t.filter { $0.isLetter || $0.isNumber }
    }
}

/// The outdoor TV, as reported by the PC from the TV's own media status (never assumed).
struct CastState: Equatable {
    let film: String?
    let title: String?
    let state: String
    let position: Double?
    let error: String?
    let device: String?
    let startupS: Double?
    let stalls: Int

    init?(_ j: JSON) {
        guard let state = j["state"].string else { return nil }
        self.state = state
        film = j["film"].string
        title = j["title"].string
        position = j["position"].double
        error = j["error"].string
        device = j["device"].string
        startupS = j["startup_s"].double
        stalls = j["stalls"].int ?? 0
    }

    var active: Bool { ["starting", "playing", "buffering", "paused"].contains(state) }
}

struct RTXFilm: Identifiable, Hashable {
    let id: String
    let title: String
    let year: Int?
    let duration: Double
    let upscale: Bool
    let range: String?
    /// The PC's poster for it (a path on the RTX server), if it has one.
    let poster: String?

    init?(_ j: JSON) {
        guard let id = j["id"].string, let title = j["title"].string else { return nil }
        self.id = id
        self.title = title
        year = j["year"].int
        duration = j["duration_s"].double ?? 0
        upscale = j["upscale"].bool
        range = j["range"].string
        poster = j["poster"].string
    }

    var label: String { upscale ? "4K UPSCALE" : "4K" }
}

/// One TV episode on the PC: played like a film (same player, same positions), known by show, season and episode.
struct RTXEpisode: Identifiable, Hashable {
    let film: RTXFilm
    let season: Int
    let episode: Int
    let name: String

    var id: String { film.id }
    /// "S1 E3"
    var code: String { "S\(season) E\(episode)" }

    init?(_ j: JSON) {
        guard let film = RTXFilm(j), let s = j["season"].int, let e = j["episode"].int else { return nil }
        self.film = film
        season = s
        episode = e
        name = j["name"].string ?? "Episode \(e)"
    }
}

struct RTXAPI {
    let base: URL
    /// Lists and notes (library, positions, status): a short timeout, so a PC that is asleep shows as such in
    /// seconds. Starting a stream keeps the long one.
    var quick = false

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 240  // /play answers once the first seconds are upscaled
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    private static let quickSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 10
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    func get(_ path: String, _ query: [URLQueryItem] = []) async throws -> JSON {
        try await fetch(path, query).0
    }

    /// The answer and its bytes (kept as the last good copy by the caller).
    func fetch(_ path: String, _ query: [URLQueryItem] = []) async throws -> (JSON, Data) {
        guard var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else { throw APIError.badAddress }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw APIError.badAddress }
        let (data, response) = try await (quick ? RTXAPI.quickSession : RTXAPI.session).data(from: url)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw APIError.server(code, String(data: data, encoding: .utf8) ?? "") }
        return (try JSON.parse(data), data)
    }

    /// Starts a film's stream at `seconds`. `ask`: the PC answers 409 "busy" (with the other film and screen)
    /// instead of stopping a film another screen is watching; `force` is the viewer's "Play here".
    func play(film: String, seconds: Double, ask: Bool = true, force: Bool = false) async throws -> (URL, String) {
        let r = try await start(film: film, seconds: seconds, ask: ask, force: force, away: false)
        return (r.url, r.session)
    }

    /// `away`: the PC's phone-sized stream from the file (Release 5), whose time 0 is `startS` in the film.
    func start(film: String, seconds: Double, ask: Bool = true, force: Bool = false, away: Bool)
        async throws -> (url: URL, session: String, startS: Double) {
        var q = [URLQueryItem(name: "id", value: film), URLQueryItem(name: "t", value: String(format: "%.1f", max(0, seconds))),
                 URLQueryItem(name: "where", value: Resume.here)]
        if away { q.append(URLQueryItem(name: "away", value: "1")) }
        if ask { q.append(URLQueryItem(name: "ask", value: "1")) }
        if force { q.append(URLQueryItem(name: "force", value: "1")) }
        let j = try await get("play", q)
        guard let u = j["url"].string, let url = URL(string: u, relativeTo: base)?.absoluteURL, let session = j["session"].string
        else { throw APIError.badAddress }
        return (url, session, away ? (j["start_s"].double ?? seconds) : 0)
    }

    func stop(session: String) async {
        _ = try? await get("stop", [URLQueryItem(name: "session", value: session)])
    }
}

/// What to play full screen: an upscaled film from the PC, or a trailer from HolyArrs.
struct PlayRequest: Identifiable {
    let id = UUID()
    let label: String
    var film: RTXFilm? = nil
    var seconds: Double = 0
    var trailer: URL? = nil
    var backdrop: String? = nil
    /// A copy downloaded to this iPhone (plays with no connection).
    var localFile: URL? = nil
}

extension PlayRequest {
    init(local: URL, item: OfflineItem) {
        let j = JSON.object(["id": .string(item.id), "title": .string(item.title), "duration_s": .number(item.duration)])
        self.init(label: item.title, film: RTXFilm(j), seconds: Resume.position(item.id) ?? 0, localFile: local)
    }
}

/// Full-screen playback in the system player. For an RTX film it asks the PC for the stream (answered once the
/// first seconds are upscaled), saves the position every 10 s, and stops the PC's encoder on leaving.
struct PlayerScreen: View {
    let request: PlayRequest
    @EnvironmentObject private var rtx: RTXServer
    @EnvironmentObject private var api: HolyArrs
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = PlaybackModel()
    @State private var showStats = false
    @AppStorage("outsideOn") private var outsideOn = false

    /// Hands the film to the outdoor TV from where it is now: this player stops (its position is kept on the PC)
    /// and the PC starts the TV, which reports back whether it is really playing.
    private func continueOutside() {
        guard let film = request.film else { return }
        let t = model.currentSeconds ?? request.seconds
        model.close(stopServer: false)  // the PC reuses the same stream for the TV
        dismiss()
        Task { await rtx.playOutside(film, label: request.label, seconds: t) }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player = model.player {
                SystemPlayer(player: player, model: model, outside: request.film == nil || !outsideOn ? nil : { continueOutside() })
                    .ignoresSafeArea()
                #if os(iOS)
                PhonePlayerBar(model: model, showStats: $showStats, close: { dismiss() },
                               outside: request.film == nil || !outsideOn ? nil : { continueOutside() })
                #endif
            } else {
                Color.clear.overlay { Artwork(raw: request.backdrop, width: 780).blur(radius: S(70)).opacity(0.35) }.clipped().ignoresSafeArea()
                VStack(spacing: S(34)) {
                    Text(request.label).font(.system(size: F(60), weight: .bold)).multilineTextAlignment(.center)
                    if let busy = model.busy {
                        // Another screen has the PC's one 4K film: say who, and let the viewer choose (never automatic).
                        Text(busy.line).font(.title3.bold()).multilineTextAlignment(.center)
                        Text(Recovery.busyNote).foregroundStyle(Color.white.opacity(0.6)).multilineTextAlignment(.center)
                        HStack(spacing: S(30)) {
                            Button(busy.taken ? "Take it back" : "Play here") { model.playHere() }
                            Button("Back") { dismiss() }.accessibilityIdentifier("player-back")
                        }
                    } else if let error = model.error {
                        Text(model.canRetry ? "Lost the connection" : "Couldn't start").font(.title3.bold())
                        Text(error).foregroundStyle(Color.white.opacity(0.6)).multilineTextAlignment(.center).frame(maxWidth: W(1300))
                        HStack(spacing: S(30)) {
                            if model.canRetry { Button("Try again") { model.tryAgain() } }
                            Button("Back") { dismiss() }.accessibilityIdentifier("player-back")
                        }
                    } else {
                        ProgressView()
                        Text(model.notice ?? (request.trailer != nil ? "Loading the trailer..." :
                                request.seconds > 1 ? "Resuming at \(Resume.label(request.seconds))..." : "Upscaling to 4K on the PC..."))
                            .foregroundStyle(Color.white.opacity(0.7)).multilineTextAlignment(.center)
                    }
                }
                .padding(S(100))
                #if os(iOS)
                VStack {
                    HStack {
                        Button { dismiss() } label: { Image(systemName: "xmark").font(.title2.weight(.semibold)) }
                            .accessibilityLabel("Close")
                        Spacer()
                        AirPlayButton().frame(width: 44, height: 44)
                    }
                    .padding(.horizontal, 20)
                    Spacer()
                    Text("Pick an Apple TV with the AirPlay button to watch there.")
                        .font(.footnote).foregroundStyle(Color.white.opacity(0.6)).padding(.bottom, 30)
                }
                #endif
            }
        }
        .task {
            await model.load(request: request, rtx: rtx.base, cookies: api.cookies)
            await model.describe(title: request.label, art: api.image(request.backdrop, width: 780))
        }
        .onChange(of: model.finished) { _, finished in if finished { dismiss() } }
        .onDisappear { model.close() }
        .fullScreenPlayer()  // background trailers wait while this plays
    }
}

@MainActor
final class PlaybackModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var error: String?
    @Published var finished = false
    /// What the waiting screen says while a stream starts or comes back (nil: the usual line).
    @Published private(set) var notice: String?
    /// Another screen has the PC's one 4K film (before this one started, or it took this one).
    @Published private(set) var busy: Busy?
    /// The error is a lost connection that Try again can rebuild.
    @Published private(set) var canRetry = false

    struct Busy: Equatable {
        let title: String
        let place: String
        let taken: Bool
        var line: String { Recovery.busy(title: title, place: place, taken: taken) }
    }

    private var session: String?
    /// The PC's name for this film's stream, known before /play answers, so Back can stop a start in progress.
    private var pending: String?
    private var base: URL?
    private var film: RTXFilm?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var itemObserver: NSKeyValueObservation?
    /// Measured from the player (never estimated): picture size, frame rate, bitrates, stalls, dropped frames.
    @Published private(set) var stats: [StatRow] = []
    /// Paused by the viewer (the iPhone shows its extra buttons only then, never over a playing movie).
    @Published private(set) var paused = false
    private var statsTimer: Timer?
    private var loadStarted = Date()
    private var startup: Double?
    private var rateObserver: NSKeyValueObservation?
    private var sentAt: Date?  // when the PC was last told the position
    // Recovery (streams from the PC only; trailers and downloads play as before).
    private var recovery = Recovery()
    private var lastGood: Double = 0  // the newest time seen playing
    private var waitingSince: Date?  // buffering while the viewer wants it to play
    private var playingSince: Date?
    private var recovering = false
    private var work: Task<Void, Never>?
    private var closed = false
    private var meta: (title: String, art: URL?)?
    /// Away from home: the stream starts at this point of the film (positions add it to the player's time).
    private var offset: Double = 0

    func load(request: PlayRequest, rtx: URL?, cookies: [HTTPCookie]) async {
        loadStarted = Date()
        if let trailer = request.trailer {
            // HolyArrs' trailer stream is behind its sign-in; AVFoundation needs the cookies handed over.
            let asset = AVURLAsset(url: trailer, options: [AVURLAssetHTTPCookiesKey: cookies])
            start(AVPlayerItem(asset: asset))
            return
        }
        guard let film = request.film else { return }
        if let local = request.localFile {
            // Downloaded to this iPhone: no PC involved (the position still reaches the PC when it is reachable).
            self.film = film
            start(AVPlayerItem(url: local))
            if request.seconds > 0 { await player?.seek(to: CMTime(seconds: request.seconds, preferredTimescale: 600)) }
            return
        }
        guard let rtx else { error = "The RTX server address is not valid. Check Settings."; return }
        base = rtx
        self.film = film
        lastGood = request.seconds
        _ = await begin(at: request.seconds)
    }

    /// Asks the PC for the stream at `t` and plays it. False when it didn't start (busy, or an error, which is
    /// shown unless this is a recovery try).
    private func begin(at t: Double, force: Bool = false) async -> Bool {
        guard let base, let film, !closed else { return false }
        pending = "film-\(film.id)"
        let started = Date()
        let slow = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Recovery.slowStart * 1e9))
            guard !Task.isCancelled, let self, self.player == nil, !self.recovering else { return }
            self.notice = Recovery.slowLine
        }
        defer { slow.cancel() }
        do {
            let away = Away.shared.active || sdrOnly(film)
            let r = try await RTXAPI(base: base).start(film: film.id, seconds: t, force: force, away: away)
            let (url, id) = (r.url, r.session)
            if Task.isCancelled || closed { await RTXAPI(base: base).stop(session: id); return false }
            session = id
            offset = r.startS
            let item = AVPlayerItem(url: url)
            item.preferredForwardBufferDuration = 30
            busy = nil
            error = nil
            canRetry = false
            if !recovering { notice = nil }
            if startup == nil { loadStarted = started }
            start(item)
            if let meta { Task { await self.describe(title: meta.title, art: meta.art) } }  // a rebuilt stream too
            return true
        } catch APIError.server(409, let body) {
            let j = (try? JSON.parse(Data(body.utf8))) ?? .null
            busy = Busy(title: j["busy"]["title"].string ?? "", place: j["busy"]["where"].string ?? "", taken: false)
            return false
        } catch {
            if !recovering && !Task.isCancelled && !closed { self.error = error.localizedDescription }
            return false
        }
    }

    /// "Play here" / "Take it back": the viewer chose to stop the other screen's film.
    func playHere() {
        guard let wasBusy = busy else { return }
        busy = nil
        notice = nil
        _ = wasBusy
        let t = lastGood
        work?.cancel()
        work = Task { [weak self] in
            guard let self else { return }
            if !(await self.begin(at: t, force: true)), self.busy == nil, self.error == nil {
                self.error = "The PC didn't start it."
            }
        }
    }

    func tryAgain() {
        error = nil
        canRetry = false
        recovery.reset()
        recover(checkTaken: false)
    }

    /// An HDR film this screen can't show as HDR plays the PC's SDR stream (1080p, tone-mapped, from the file:
    /// the away stream). The Apple TV in the living room fetched the 4K HDR10 playlists and never asked for a
    /// segment (Gilded Age S4, Nov 26 2026): with no SDR version in the playlist it had nothing it would play.
    /// Also after an HDR stream failed here once.
    private var hdrFailed = false
    private func sdrOnly(_ film: RTXFilm) -> Bool {
        guard let r = film.range, r != "SDR" else { return false }
        return hdrFailed || !AVPlayer.eligibleForHDRPlayback
    }

    /// The stream failed or buffered too long: rebuild it at the last good time, three tries, unless another
    /// screen took the PC's film (then ask, never retry into it).
    private func recover(checkTaken: Bool = true) {
        guard base != nil, film != nil, !closed, !recovering else { return }
        if let r = film?.range, r != "SDR" { hdrFailed = true }  // the retries use the SDR stream
        recovering = true
        let t = max(0, lastGood - 2)  // a little before, so nothing is missed
        teardown()
        notice = Recovery.lost(at: t, attempt: 1)
        work?.cancel()
        work = Task { [weak self] in
            guard let self else { return }
            defer { self.recovering = false }
            if checkTaken, let base = self.base, let sid = self.session ?? self.pending,
               let st = try? await RTXAPI(base: base, quick: true).get("status", [URLQueryItem(name: "session", value: sid)]),
               st["ended"]["reason"].string == "taken" {
                self.notice = nil
                self.busy = Busy(title: st["ended"]["by"].string ?? "", place: st["ended"]["where"].string ?? "", taken: true)
                return
            }
            while let wait = self.recovery.next() {
                self.notice = Recovery.lost(at: t, attempt: self.recovery.tries)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
                if Task.isCancelled || self.closed { return }
                if await self.begin(at: t) { self.lastGood = t; return }
                if self.busy != nil { self.notice = nil; return }
            }
            self.notice = nil
            self.canRetry = true
            self.error = Recovery.gaveUp(at: t)
        }
    }

    /// The title and picture the system player shows (the Apple TV info panel, the iPhone lock screen and
    /// Control Center) instead of a blank "Unknown".
    func describe(title: String, art: URL?) async {
        meta = (title, art)
        guard let item = player?.currentItem else { return }
        func entry(_ id: AVMetadataIdentifier, _ value: NSCopying & NSObjectProtocol) -> AVMetadataItem {
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value
            m.extendedLanguageTag = "und"
            return m
        }
        var items = [entry(.commonIdentifierTitle, title as NSString)]
        if let art, let data = try? await URLSession.shared.data(from: art).0 {
            let m = AVMutableMetadataItem()
            m.identifier = .commonIdentifierArtwork
            m.value = data as NSData
            m.dataType = kCMMetadataBaseDataType_JPEG as String
            m.extendedLanguageTag = "und"
            items.append(m)
        }
        item.externalMetadata = items
    }

    private func start(_ item: AVPlayerItem) {
        let p = AVPlayer(playerItem: item)
        #if os(iOS)
        // On iPhone the system player's AirPlay button sends the stream itself to an Apple TV (the TV fetches the
        // PC's 4K stream directly), not a mirror of the phone's screen.
        p.allowsExternalPlayback = true
        p.usesExternalPlaybackWhileExternalScreenIsActive = true
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let fromPC = session != nil
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1), queue: .main) { [weak self] t in
            Task { @MainActor in
                guard let self else { return }
                self.savePosition(t.seconds + self.offset)
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.ended() }
        }
        if fromPC {
            failObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.recover() }
            }
            itemObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                let failed = item.status == .failed
                Task { @MainActor in if failed { self?.recover() } }
            }
        }
        rateObserver = p.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in
                guard let self else { return }
                self.paused = status == .paused
                if status == .playing, self.startup == nil { self.startup = Date().timeIntervalSince(self.loadStarted) }
                if status == .playing {
                    self.waitingSince = nil
                    if self.playingSince == nil { self.playingSince = Date() }
                } else {
                    self.playingSince = nil
                    // Buffering after it has played: a drop if it goes on (paused by the viewer is not).
                    if status == .waitingToPlayAtSpecifiedRate, self.startup != nil {
                        if self.waitingSince == nil { self.waitingSince = Date() }
                    } else {
                        self.waitingSince = nil
                    }
                }
            }
        }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        player = p
    }

    private func tick() {
        updateStats()
        guard session != nil, let p = player else { return }
        let t = p.currentTime().seconds
        if p.timeControlStatus == .playing, t.isFinite, t > 0 { lastGood = t + offset }
        if let since = playingSince, Date().timeIntervalSince(since) > Recovery.healthy { recovery.reset() }
        if Recovery.stalled(since: waitingSince) { waitingSince = nil; recover() }
    }

    private func updateStats() {
        guard let p = player, let item = p.currentItem else { return }
        var rows: [StatRow] = []
        let size = item.presentationSize
        if size.width > 0 { rows.append(StatRow("Picture", "\(Int(size.width)) x \(Int(size.height))")) }
        if let fps = item.tracks.first(where: { $0.assetTrack?.mediaType == .video })?.currentVideoFrameRate, fps > 0 {
            rows.append(StatRow("Frame rate", String(format: "%.3f fps", fps)))
        }
        if let ev = item.accessLog()?.events.last {
            if ev.indicatedBitrate > 0 { rows.append(StatRow("Stream", StatRow.mbps(ev.indicatedBitrate))) }
            if ev.observedBitrate > 0 { rows.append(StatRow("Network", StatRow.mbps(ev.observedBitrate))) }
            rows.append(StatRow("Stalls", "\(max(0, ev.numberOfStalls))"))
            rows.append(StatRow("Dropped frames", "\(max(0, ev.numberOfDroppedVideoFrames))"))
        }
        if let startup { rows.append(StatRow("Started in", String(format: "%.1f s", startup))) }
        if p.isExternalPlaybackActive { rows.append(StatRow("Playing on", "AirPlay")) }
        if let e = item.errorLog()?.events.last, let c = e.errorComment { rows.append(StatRow("Last error", c)) }
        stats = rows
    }

    /// Saved here on every tick; the PC hears at most every 8 s (the time observer also fires on every skip, which
    /// sent it bursts of requests) and always on leaving.
    private func savePosition(_ seconds: Double, leaving: Bool = false) {
        // Only once the picture has played: a stream that fails before its first frame reads 0, and saving that
        // would wipe the resume spot (found by the iPhone tour's drop check, Release 3).
        guard let film, !finished, seconds.isFinite, seconds > 1, startup != nil else { return }
        Resume.save(film.id, seconds, duration: film.duration)
        if !leaving, let sentAt, Date().timeIntervalSince(sentAt) < 8 { return }
        sentAt = Date()
        Resume.send(film.id, seconds, duration: film.duration)
    }

    private func ended() {
        if let film {
            Resume.clear(film.id)
            Resume.send(film.id, 0, duration: film.duration)  // under a minute: the PC clears it too
        }
        finished = true
    }

    /// Where playback is now (for handing over to another room).
    var currentSeconds: Double? {
        guard let t = player?.currentTime().seconds, t.isFinite else { return nil }
        return t + offset
    }

    /// Drops the player (keeping the PC's stream, which a recovery asks for again).
    private func teardown() {
        statsTimer?.invalidate()
        statsTimer = nil
        rateObserver = nil
        itemObserver = nil
        if let p = player {
            let t = p.currentTime().seconds
            if t.isFinite, t > 0 { savePosition(t + offset, leaving: true) }
            p.pause()
            if let o = timeObserver { p.removeTimeObserver(o) }
        }
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        if let o = failObserver { NotificationCenter.default.removeObserver(o) }
        timeObserver = nil
        endObserver = nil
        failObserver = nil
        waitingSince = nil
        playingSince = nil
        player = nil
    }

    func close(stopServer: Bool = true) {
        closed = true
        work?.cancel()
        work = nil
        if !stopServer { session = nil; pending = nil }
        teardown()
        // A start still waiting for its first chunks is stopped too (backing out while it starts).
        if let sid = session ?? pending, let base { Task { await RTXAPI(base: base).stop(session: sid) } }
        session = nil
        pending = nil
    }
}

extension Resume {
    /// The RTX server, which keeps every screen's positions (set once the server answers).
    @MainActor static var server: URL?

    /// Tells the PC where this device left a title (seconds 0: cleared), with when that happened here, so an older
    /// note from another screen can't overwrite it and a stale one from here can't undo a clear made elsewhere.
    @MainActor static func send(_ id: String, _ seconds: Double, duration: Double, at: Double? = nil) {
        guard let base = server else { return }
        let when = at ?? savedAt(id) ?? Date().timeIntervalSince1970
        let q = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "t", value: String(format: "%.1f", seconds)),
                 URLQueryItem(name: "d", value: String(format: "%.1f", duration)),
                 URLQueryItem(name: "where", value: here), URLQueryItem(name: "at", value: String(format: "%.3f", when))]
        Task { _ = try? await RTXAPI(base: base, quick: true).get("position", q) }
    }
}

struct SystemPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    var model: PlaybackModel? = nil
    var outside: (() -> Void)? = nil
    /// More items for the Apple TV player's menu (Other feeds for a live game or channel), under one heading.
    var menu: [UIAction] = []
    /// iPhone: called on a tap on the picture (the same tap that shows or hides the system's controls), so a screen
    /// can show its own buttons only when asked. Taps on the system's buttons don't count.
    var onTap: (() -> Void)? = nil

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTap: (() -> Void)?

        @objc func tapped() { onTap?() }

        // Alongside the player's own tap (which shows its controls), never instead of it.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool { !(touch.view is UIControl) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let c = AVPlayerViewController()
        c.player = player
        #if os(iOS)
        context.coordinator.onTap = onTap
        if onTap != nil {
            let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
            tap.cancelsTouchesInView = false
            tap.delegate = context.coordinator
            c.view.addGestureRecognizer(tap)
        }
        #endif
        #if os(tvOS)
        // Swipe down while playing: a Stats tab (measured from the player), and Continue outside in the menu.
        if let model {
            let h = UIHostingController(rootView: StatsPanel(model: model))
            h.title = "Stats"
            h.preferredContentSize = CGSize(width: 1800, height: 240)
            c.customInfoViewControllers = [h]
        }
        var items: [UIMenuElement] = []
        if let outside {
            items.append(UIAction(title: "Continue outside", image: UIImage(systemName: "sun.max")) { _ in outside() })
        }
        if !menu.isEmpty {
            items.append(UIMenu(title: "Other feeds", image: UIImage(systemName: "antenna.radiowaves.left.and.right"), children: menu))
        }
        if !items.isEmpty { c.transportBarCustomMenuItems = items }
        #endif
        player.play()
        return c
    }

    func updateUIViewController(_ c: AVPlayerViewController, context: Context) {
        if c.player !== player { c.player = player }
        context.coordinator.onTap = onTap
    }
}

#if os(iOS)
/// The system AirPlay picker (lists the Apple TVs on the network).
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.prioritizesVideoDevices = true
        v.tintColor = .white
        v.activeTintColor = UIColor(red: 0.98, green: 0.74, blue: 0.20, alpha: 1)
        return v
    }

    func updateUIView(_ v: AVRoutePickerView, context: Context) {}
}
#endif
