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
    @Published private(set) var error: String?

    init() {
        address = UserDefaults.standard.string(forKey: "rtxAddress") ?? RTXServer.defaultAddress
        enabled = UserDefaults.standard.object(forKey: "rtxEnabled") as? Bool ?? true
    }

    var base: URL? {
        let t = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: t), url.scheme != nil, url.host != nil else { return nil }
        return url
    }

    func refresh() async {
        guard let base else { films = []; error = "address not valid"; return }
        do {
            let j = try await RTXAPI(base: base).get("library")
            films = j["films"].array.compactMap(RTXFilm.init)
            error = nil
            await refreshSports()
        } catch {
            films = []
            self.error = "not reachable"
        }
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

struct RTXFilm: Identifiable, Hashable {
    let id: String
    let title: String
    let year: Int?
    let duration: Double
    let upscale: Bool
    let range: String?

    init?(_ j: JSON) {
        guard let id = j["id"].string, let title = j["title"].string else { return nil }
        self.id = id
        self.title = title
        year = j["year"].int
        duration = j["duration_s"].double ?? 0
        upscale = j["upscale"].bool
        range = j["range"].string
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
}

/// Full-screen playback in the system player. For an RTX film it asks the PC for the stream (answered once the
/// first seconds are upscaled), saves the position every 10 s, and stops the PC's encoder on leaving.
struct PlayerScreen: View {
    let request: PlayRequest
    @EnvironmentObject private var rtx: RTXServer
    @EnvironmentObject private var api: HolyArrs
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = PlaybackModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player = model.player {
                SystemPlayer(player: player).ignoresSafeArea()
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
        .task { await model.load(request: request, rtx: rtx.base, cookies: api.cookies) }
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

    func load(request: PlayRequest, rtx: URL?, cookies: [HTTPCookie]) async {
        if let trailer = request.trailer {
            // HolyArrs' trailer stream is behind its sign-in; AVFoundation needs the cookies handed over.
            let asset = AVURLAsset(url: trailer, options: [AVURLAssetHTTPCookiesKey: cookies])
            start(AVPlayerItem(asset: asset))
            return
        }
        guard let film = request.film else { return }
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
        player = p
    }

    private func savePosition(_ seconds: Double) {
        guard let film, !finished, seconds.isFinite else { return }
        Resume.save(film.id, seconds, duration: film.duration)
    }

    private func ended() {
        if let film { Resume.clear(film.id) }
        finished = true
    }

    func close() {
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
    private static func key(_ id: String) -> String { "resume.\(id)" }

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
        }
    }

    static func clear(_ id: String) {
        UserDefaults.standard.removeObject(forKey: key(id))
        UserDefaults.standard.removeObject(forKey: "resume.at.\(id)")
    }

    static func label(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct SystemPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let c = AVPlayerViewController()
        c.player = player
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
