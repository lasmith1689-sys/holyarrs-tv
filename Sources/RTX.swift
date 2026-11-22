import AVKit
import SwiftUI

/// The PC's RTX 4K upscaling server (rtx-upscale-stream, src/server.py), the same one the RTX 4K app plays from.
/// Its film list is matched to HolyArrs titles by name and year, so a Library movie that is also there gets
/// "Play in 4K". The player code is the RTX 4K app's.
@MainActor
final class RTXServer: ObservableObject {
    static let defaultAddress = "http://192.168.68.100:8787"

    @Published var address: String { didSet { UserDefaults.standard.set(address, forKey: "rtxAddress") } }
    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "rtxEnabled") } }
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

    init() {
        address = UserDefaults.standard.string(forKey: "rtxAddress") ?? RTXServer.defaultAddress
        enabled = UserDefaults.standard.object(forKey: "rtxEnabled") as? Bool ?? true
    }

    var base: URL? {
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
        guard let base else { films = []; error = "address not valid"; return }
        do {
            let j = try await RTXAPI(base: base).get("library")
            films = j["films"].array.compactMap(RTXFilm.init)
            error = nil
            Resume.server = base
            await syncPositions()
            await refreshSports()
            liveTV = (try? await RTXAPI(base: base).get("tv/status"))?["configured"].bool ?? false
            if let s = try? await RTXAPI(base: base).get("subscriptions") {
                subscriptions = s["items"].array.compactMap(Subscription.init)
            }
            if teams.isEmpty, let t = try? await RTXAPI(base: base).get("tv/teams") {
                var out: [String: [LiveTeam]] = [:]
                for (league, list) in t["leagues"].object { out[league] = list.array.compactMap(LiveTeam.init) }
                teams = out
            }
        } catch {
            films = []
            liveTV = false
            self.error = "not reachable"
        }
    }

    /// Where everything was left on any screen (kept on the PC), merged with this device's own notes: progress
    /// made offline goes up to the PC instead of being overwritten by it.
    func syncPositions() async {
        guard let base, let j = try? await RTXAPI(base: base).get("positions") else { return }
        let (merged, push) = Resume.merge(j["positions"])
        for p in push {
            let q = [URLQueryItem(name: "id", value: p.id), URLQueryItem(name: "t", value: String(format: "%.1f", p.t)),
                     URLQueryItem(name: "d", value: String(format: "%.1f", p.d)),
                     URLQueryItem(name: "where", value: Device.isTV ? "apple-tv" : "iphone")]
            _ = try? await RTXAPI(base: base).get("position", q)
        }
        var list: [ContinueEntry] = []
        for (id, v) in merged where v.t > 0 {
            list.append(ContinueEntry(id: id, seconds: v.t, duration: v.d, at: Date(timeIntervalSince1970: v.at), place: v.place))
        }
        continueList = list.sorted { $0.at > $1.at }
    }

    /// Everything left part-way on any screen, newest first (from the PC's positions).
    @Published private(set) var continueList: [ContinueEntry] = []

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
        if !enabled { return "Play in 4K is turned off in Settings." }
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
        guard let base, let j = try? await RTXAPI(base: base).get("sports") else { return }
        var byName: [String: RTXFilm] = [:]
        for f in j["files"].array {
            if let name = f["name"].string, let film = RTXFilm(f) { byName[name.lowercased()] = film }
        }
        sports = byName
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

struct RTXAPI {
    let base: URL

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 240  // /play answers once the first seconds are upscaled
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    func get(_ path: String, _ query: [URLQueryItem] = []) async throws -> JSON {
        guard var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else { throw APIError.badAddress }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw APIError.badAddress }
        let (data, response) = try await RTXAPI.session.data(from: url)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw APIError.server(code, String(data: data, encoding: .utf8) ?? "") }
        return try JSON.parse(data)
    }

    func play(film: String, seconds: Double) async throws -> (URL, String) {
        let j = try await get("play", [URLQueryItem(name: "id", value: film), URLQueryItem(name: "t", value: String(format: "%.1f", max(0, seconds)))])
        guard let u = j["url"].string, let url = URL(string: u, relativeTo: base)?.absoluteURL, let session = j["session"].string
        else { throw APIError.badAddress }
        return (url, session)
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
                    if let error = model.error {
                        Text("Couldn't start").font(.title3.bold())
                        Text(error).foregroundStyle(Color.white.opacity(0.6)).multilineTextAlignment(.center).frame(maxWidth: W(1300))
                        Button("Back") { dismiss() }
                    } else {
                        ProgressView()
                        Text(request.trailer != nil ? "Loading the trailer..." :
                                request.seconds > 1 ? "Resuming at \(Resume.label(request.seconds))..." : "Upscaling to 4K on the PC...")
                            .foregroundStyle(Color.white.opacity(0.7))
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
    }
}

@MainActor
final class PlaybackModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var error: String?
    @Published var finished = false
    private var session: String?
    private var base: URL?
    private var film: RTXFilm?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    /// Measured from the player (never estimated): picture size, frame rate, bitrates, stalls, dropped frames.
    @Published private(set) var stats: [StatRow] = []
    /// Paused by the viewer (the iPhone shows its extra buttons only then, never over a playing movie).
    @Published private(set) var paused = false
    private var statsTimer: Timer?
    private var loadStarted = Date()
    private var startup: Double?
    private var rateObserver: NSKeyValueObservation?

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
        do {
            let (url, id) = try await RTXAPI(base: rtx).play(film: film.id, seconds: request.seconds)
            if Task.isCancelled { await RTXAPI(base: rtx).stop(session: id); return }
            session = id
            let item = AVPlayerItem(url: url)
            item.preferredForwardBufferDuration = 30
            start(item)
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    /// The title and picture the system player shows (the Apple TV info panel, the iPhone lock screen and
    /// Control Center) instead of a blank "Unknown".
    func describe(title: String, art: URL?) async {
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
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1), queue: .main) { [weak self] t in
            Task { @MainActor in self?.savePosition(t.seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.ended() }
        }
        rateObserver = p.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in
                guard let self else { return }
                self.paused = status == .paused
                if status == .playing, self.startup == nil { self.startup = Date().timeIntervalSince(self.loadStarted) }
            }
        }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateStats() }
        }
        player = p
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

    private func savePosition(_ seconds: Double) {
        guard let film, !finished, seconds.isFinite else { return }
        Resume.save(film.id, seconds, duration: film.duration)
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
        return t
    }

    func close(stopServer: Bool = true) {
        statsTimer?.invalidate()
        statsTimer = nil
        rateObserver = nil
        if !stopServer { session = nil }
        if let p = player {
            savePosition(p.currentTime().seconds)
            p.pause()
            if let o = timeObserver { p.removeTimeObserver(o) }
        }
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        timeObserver = nil
        endObserver = nil
        player = nil
        if let session, let base { Task { await RTXAPI(base: base).stop(session: session) } }
        session = nil
    }
}

/// Where each RTX film was left in this app (UserDefaults, per RTX film id). Not kept for the first minute or the last 4.
enum Resume {
    /// The RTX server, which keeps every screen's positions (set once the server answers).
    @MainActor static var server: URL?
    private static func key(_ id: String) -> String { "resume.\(id)" }

    /// Merges the PC's positions with this device's: for each title, whichever screen saved (or cleared) it
    /// last wins. Returns the merged list and what the PC hasn't heard yet (progress made offline, or while the
    /// PC was unreachable), so the caller can send those up. Before 2026-11-22 the PC's list simply replaced
    /// this device's, which wiped anything watched offline.
    static func merge(_ pc: JSON) -> (positions: [String: (t: Double, d: Double, at: Double, place: String)],
                                      push: [(id: String, t: Double, d: Double)]) {
        let d = UserDefaults.standard
        var out: [String: (t: Double, d: Double, at: Double, place: String)] = [:]
        var push: [(id: String, t: Double, d: Double)] = []
        if case let .object(o) = pc {
            for (id, v) in o where !id.hasPrefix("od:") {  // On Demand titles keep their own (OnDemand.swift)
                guard let t = v["t"].double else { continue }
                out[id] = (t, v["duration"].double ?? 0, v["at"].double ?? 0, v["where"].string ?? "")
            }
        }
        let keys = d.dictionaryRepresentation().keys
        // Titles finished or started over here after the PC's note: clear them there too.
        for k in keys where k.hasPrefix("resume.cleared.") {
            let id = String(k.dropFirst("resume.cleared.".count))
            let cleared = d.double(forKey: k)
            if let p = out[id], p.at < cleared {
                out[id] = nil
                push.append((id, 0, p.d))
            } else if out[id] == nil || out[id]!.at >= cleared {
                d.removeObject(forKey: k)  // settled: the PC agrees, or another screen watched it since
            }
        }
        // Positions saved here after the PC's note (or that the PC never got).
        for k in keys where k.hasPrefix("resume.") && !k.hasPrefix("resume.at.") && !k.hasPrefix("resume.d.")
            && !k.hasPrefix("resume.cleared.") {
            let id = String(k.dropFirst("resume.".count))
            let t = d.double(forKey: k), at = d.double(forKey: "resume.at.\(id)")
            guard t > 0 else { continue }
            if let p = out[id], p.at >= at { continue }
            let dur = d.double(forKey: "resume.d.\(id)")
            out[id] = (t, dur > 0 ? dur : (out[id]?.d ?? 0), at, Device.isTV ? "apple-tv" : "iphone")
            push.append((id, t, out[id]!.d))
        }
        // This device now mirrors the merged list.
        for k in keys where k.hasPrefix("resume.") && !k.hasPrefix("resume.cleared.") { d.removeObject(forKey: k) }
        for (id, p) in out {
            d.set(p.t, forKey: key(id))
            d.set(p.at, forKey: "resume.at.\(id)")
            if p.d > 0 { d.set(p.d, forKey: "resume.d.\(id)") }
        }
        return (out, push)
    }

    @MainActor static func send(_ id: String, _ seconds: Double, duration: Double) {
        guard let base = server else { return }
        let q = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "t", value: String(format: "%.1f", seconds)),
                 URLQueryItem(name: "d", value: String(format: "%.1f", duration)),
                 URLQueryItem(name: "where", value: Device.isTV ? "apple-tv" : "iphone")]
        Task { _ = try? await RTXAPI(base: base).get("position", q) }
    }

    static func position(_ id: String) -> Double? {
        let v = UserDefaults.standard.double(forKey: key(id))
        return v > 0 ? v : nil
    }

    static func save(_ id: String, _ seconds: Double, duration: Double) {
        if seconds < 60 || (duration > 0 && seconds > duration - 240) {
            clear(id)
        } else {
            UserDefaults.standard.set(seconds, forKey: key(id))
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "resume.at.\(id)")
            if duration > 0 { UserDefaults.standard.set(duration, forKey: "resume.d.\(id)") }
            UserDefaults.standard.removeObject(forKey: "resume.cleared.\(id)")
        }
    }

    static func clear(_ id: String) {
        UserDefaults.standard.removeObject(forKey: key(id))
        UserDefaults.standard.removeObject(forKey: "resume.at.\(id)")
        UserDefaults.standard.removeObject(forKey: "resume.d.\(id)")
        // Remembered until the PC has heard, so a finish watched offline isn't undone by the PC's older note.
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "resume.cleared.\(id)")
    }

    static func label(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct SystemPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    var model: PlaybackModel? = nil
    var outside: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let c = AVPlayerViewController()
        c.player = player
        #if os(tvOS)
        // Swipe down while playing: a Stats tab (measured from the player), and Continue outside in the menu.
        if let model {
            let h = UIHostingController(rootView: StatsPanel(model: model))
            h.title = "Stats"
            h.preferredContentSize = CGSize(width: 1800, height: 240)
            c.customInfoViewControllers = [h]
        }
        if let outside {
            c.transportBarCustomMenuItems = [UIAction(title: "Continue outside", image: UIImage(systemName: "sun.max")) { _ in outside() }]
        }
        #endif
        player.play()
        return c
    }

    func updateUIViewController(_ c: AVPlayerViewController, context: Context) {
        if c.player !== player { c.player = player }
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
