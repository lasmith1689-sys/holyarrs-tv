import AVKit
import SwiftUI

// Live TV through the PC (rtx-upscale-stream: src/tvlineup.py, tvguide.py, tvstream.py). The PC keeps the IPTV
// login and turns a channel into a stream this app plays; the app never sees the login. The plan allows one stream
// at a time, so starting a channel stops whatever else was playing.

/// A programme from the guide (now or next on a channel).
struct LiveShow: Hashable {
    let title: String
    let start: Date
    let end: Date

    init?(_ j: JSON) {
        guard let t = j["title"].string, let s = j["start"].double, let e = j["end"].double else { return nil }
        title = t
        start = Date(timeIntervalSince1970: s)
        end = Date(timeIntervalSince1970: e)
    }

    /// How far through the programme it is now (0 to 1).
    var progress: Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(1, max(0, Date().timeIntervalSince(start) / total))
    }
}

struct LiveChannel: Identifiable, Hashable {
    let id: String
    let name: String
    let logo: String?
    let alt: [String]
    let now: LiveShow?
    let next: LiveShow?

    init?(_ j: JSON) {
        guard let id = j["id"].string else { return nil }
        self.id = id
        name = LiveTV.clean(j["name"].string ?? id)
        logo = j["logo"].string
        alt = j["alt"].array.compactMap(\.string)
        now = LiveShow(j["now"])
        next = LiveShow(j["next"])
    }
}

struct LiveGroup: Identifiable, Hashable {
    let id: String
    let name: String
    let channels: [LiveChannel]

    init?(_ j: JSON) {
        guard let id = j["id"].string else { return nil }
        self.id = id
        name = j["name"].string ?? id
        channels = j["channels"].array.compactMap(LiveChannel.init)
    }
}

/// A game or race with its own feed (the provider's event channels), from the PC's guide.
struct LiveEvent: Identifiable, Hashable {
    let id: String
    let title: String
    let league: String
    let start: Date
    let end: Date
    let mine: Bool
    let alt: [String]

    init?(_ j: JSON) {
        guard let id = j["id"].string, let title = j["title"].string, let s = j["start"].double else { return nil }
        self.id = id
        self.title = title
        league = j["league"].string ?? ""
        start = Date(timeIntervalSince1970: s)
        end = Date(timeIntervalSince1970: j["end"].double ?? s + 3 * 3600)
        mine = !j["mine"].array.isEmpty
        alt = j["alt"].array.compactMap(\.string)
    }

    var live: Bool {
        let now = Date()
        return start <= now && now < end
    }

    /// "Live now", "Today 1:00 PM", "Tomorrow 8:15 PM", "Sun, Nov 29 9:50 AM".
    var when: String {
        if live { return "Live now" }
        let time = DateFormatter()
        time.dateFormat = "h:mm a"
        let cal = Calendar.current
        if cal.isDateInToday(start) { return "Today \(time.string(from: start))" }
        if cal.isDateInTomorrow(start) { return "Tomorrow \(time.string(from: start))" }
        let day = DateFormatter()
        day.dateFormat = "EEE, MMM d"
        return "\(day.string(from: start)) \(time.string(from: start))"
    }
}

struct LiveCategory: Identifiable, Hashable {
    let id: String
    let name: String
    let count: Int
}

enum LiveRoute: Hashable {
    case all
    case category(LiveCategory)
}

/// What to play full screen: a channel or an event feed, with spare feeds to try if the first will not start.
struct LiveRequest: Identifiable {
    let id = UUID()
    let stream: String
    let title: String
    var alt: [String] = []
}

enum LiveTV {
    /// Provider names carry tags like "ᴴᴰ", "⁶⁰ᶠᵖˢ" and "◉": dropped for display.
    static func clean(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            let v = u.value
            if (0x1D00...0x1DBF).contains(v) || (0x2070...0x209F).contains(v) || (0x25A0...0x25FF).contains(v)
                || v == 0xB2 || v == 0xB3 || v == 0xB9 { continue }
            out.unicodeScalars.append(u)
        }
        out = out.replacingOccurrences(of: "|", with: " · ")
        out = out.replacingOccurrences(of: #"\s*/\s*(?=\s|$)"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: CharacterSet(charactersIn: " ·:-"))
    }

    /// The card colours for an event, by league.
    static func colors(_ league: String) -> [Color] {
        switch league {
        case "NFL": return [Color(red: 0.05, green: 0.16, blue: 0.36), Color(red: 0.02, green: 0.06, blue: 0.16)]
        case "Premier League": return [Color(red: 0.24, green: 0.05, blue: 0.32), Color(red: 0.09, green: 0.02, blue: 0.13)]
        case "Golf": return [Color(red: 0.06, green: 0.30, blue: 0.16), Color(red: 0.02, green: 0.11, blue: 0.06)]
        case "F1": return [Color(red: 0.42, green: 0.04, blue: 0.05), Color(red: 0.14, green: 0.02, blue: 0.02)]
        default: return [Color(white: 0.22), Color(white: 0.10)]
        }
    }

    static func logoURL(_ raw: String?, base: URL?) -> URL? {
        guard let raw, let base else { return nil }
        return URL(string: raw, relativeTo: base)?.absoluteURL
    }
}

/// The card look shared with the rest of the app: rounded, lit and lifted when focused.
private struct LiveCardChrome: ViewModifier {
    let focused: Bool

    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: S(14), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: S(14), style: .continuous)
                .stroke(Color.white.opacity(focused ? 0.9 : 0.08), lineWidth: focused ? 4 : 1))
            .shadow(color: .black.opacity(focused ? 0.7 : 0.35), radius: focused ? 30 : 10, y: focused ? 20 : 6)
            .scaleEffect(focused ? 1.06 : 1.0)
    }
}

struct LivePill: View {
    var body: some View {
        HStack(spacing: S(8)) {
            Circle().fill(Color.white).frame(width: S(10), height: S(10))
            Text("LIVE").font(.system(size: F(18), weight: .heavy)).tracking(1)
        }
        .padding(.horizontal, S(12)).padding(.vertical, S(6))
        .background(Color(red: 0.90, green: 0.16, blue: 0.20), in: Capsule())
        .foregroundStyle(Color.white)
    }
}

/// A 16:9 card for a game or race: league colours, LIVE when it is on, a star for your teams.
struct LiveEventCell: View {
    let event: LiveEvent
    @Environment(\.isFocused) private var focused

    var body: some View {
        VStack(alignment: .leading, spacing: S(10)) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: LiveTV.colors(event.league), startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(alignment: .leading, spacing: S(8)) {
                    Text(event.league.uppercased()).font(.system(size: F(18), weight: .bold)).tracking(1.2)
                        .foregroundStyle(Color.white.opacity(0.7))
                    Text(event.title).font(.system(size: F(30), weight: .heavy)).lineLimit(2).minimumScaleFactor(0.75)
                        .foregroundStyle(Color.white)
                }
                .padding(S(20))
            }
            .frame(width: W(480), height: S(270))
            .overlay(alignment: .topTrailing) {
                HStack(spacing: S(10)) {
                    if event.mine { Image(systemName: "star.fill").font(.system(size: F(22))).foregroundStyle(Theme.accent) }
                    if event.live { LivePill() }
                }
                .padding(S(14))
            }
            .modifier(LiveCardChrome(focused: focused))
            Text(event.when).font(.system(size: F(21))).foregroundStyle(event.live ? Color.white : Theme.dim).lineLimit(1)
                .frame(width: W(480), alignment: .leading)
                .offset(y: focused ? S(12) : 0)
        }
        .animation(.easeOut(duration: 0.18), value: focused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(event.title), \(event.when)")
    }
}

/// A channel card: its logo on a dark tile, what is on now with how far through it is, and the name.
struct LiveChannelCell: View {
    let channel: LiveChannel
    var wide = false
    @EnvironmentObject private var rtx: RTXServer
    @Environment(\.isFocused) private var focused

    private var width: CGFloat { wide ? W(480) : W(400) }
    private var height: CGFloat { wide ? S(270) : S(225) }

    var body: some View {
        VStack(alignment: .leading, spacing: S(10)) {
            ZStack {
                LinearGradient(colors: [Color(white: 0.19), Color(white: 0.09)], startPoint: .top, endPoint: .bottom)
                if let url = LiveTV.logoURL(channel.logo, base: rtx.base) {
                    AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: 0.2))) { phase in
                        if let image = phase.image {
                            image.resizable().aspectRatio(contentMode: .fit).padding(.horizontal, S(44)).padding(.vertical, S(40))
                        } else {
                            nameStandIn
                        }
                    }
                } else {
                    nameStandIn
                }
            }
            .frame(width: width, height: height)
            .overlay(alignment: .bottom) {
                if let now = channel.now {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.white.opacity(0.15))
                            Rectangle().fill(Theme.accent).frame(width: g.size.width * now.progress)
                        }
                    }
                    .frame(height: S(6))
                }
            }
            .modifier(LiveCardChrome(focused: focused))
            VStack(alignment: .leading, spacing: S(4)) {
                Text(channel.name).font(.system(size: F(22), weight: .semibold)).lineLimit(1)
                Text(channel.now?.title ?? " ").font(.system(size: F(20))).foregroundStyle(Theme.dim).lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
            .offset(y: focused ? S(12) : 0)
        }
        .animation(.easeOut(duration: 0.18), value: focused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(channel.now.map { "\(channel.name), \($0.title)" } ?? channel.name)
    }

    private var nameStandIn: some View {
        Text(channel.name).font(.system(size: F(28), weight: .bold)).multilineTextAlignment(.center)
            .foregroundStyle(Color.white.opacity(0.85)).padding(S(20))
    }
}

/// A titled row of game cards, then (optionally) channel cards.
struct LiveRow: View {
    let title: String
    var events: [LiveEvent] = []
    var channels: [LiveChannel] = []
    var wideChannels = false
    let play: (LiveRequest) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: S(18)) {
            Text(title).font(.system(size: F(34), weight: .bold)).padding(.horizontal, Theme.sidePadding)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: S(40)) {
                    ForEach(events) { e in
                        Button { play(LiveRequest(stream: e.id, title: e.title, alt: e.alt)) } label: { LiveEventCell(event: e) }
                            .buttonStyle(QuietButtonStyle())
                    }
                    ForEach(channels) { c in
                        Button { play(LiveRequest(stream: c.id, title: c.name, alt: c.alt)) } label: {
                            LiveChannelCell(channel: c, wide: wideChannels)
                        }
                        .buttonStyle(QuietButtonStyle())
                    }
                }
                .padding(.vertical, S(30))
                .padding(.horizontal, Theme.sidePadding)
            }
            .tvFocusSection()
        }
    }
}

/// The top of the Sports tab: your teams' games, what is live and later today, golf, racing and the sports
/// channels, all playable live. Replays (Sportarr) follow underneath. Hidden when Live TV isn't set up on the PC.
struct LiveSportsSection: View {
    @EnvironmentObject private var rtx: RTXServer
    @State private var yours: [LiveEvent] = []
    @State private var live: [LiveEvent] = []
    @State private var today: [LiveEvent] = []
    @State private var golf: [LiveEvent] = []
    @State private var racing: [LiveEvent] = []
    @State private var groups: [String: LiveGroup] = [:]
    @State private var watching: LiveRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: S(46)) {
            if !yours.isEmpty { LiveRow(title: "Your teams", events: yours, play: { watching = $0 }) }
            if !live.isEmpty { LiveRow(title: "Live now", events: live, play: { watching = $0 }) }
            if !today.isEmpty { LiveRow(title: "Later today", events: today, play: { watching = $0 }) }
            if !golf.isEmpty || groups["golf"] != nil {
                LiveRow(title: "Golf", events: golf, channels: groups["golf"]?.channels ?? [], wideChannels: true, play: { watching = $0 })
            }
            if !racing.isEmpty || groups["racing"] != nil {
                LiveRow(title: "Racing", events: racing, channels: groups["racing"]?.channels ?? [], wideChannels: true,
                        play: { watching = $0 })
            }
            if let sports = groups["sports"] {
                LiveRow(title: "Sports channels", channels: sports.channels, wideChannels: true, play: { watching = $0 })
            }
        }
        .task(id: "\(rtx.liveTV)|\(rtx.address)") {
            guard rtx.liveTV else { return }
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
        .fullScreenCover(item: $watching) { LivePlayerScreen(request: $0) }
    }

    private func load() async {
        guard let base = rtx.base, let j = try? await RTXAPI(base: base).get("tv/sports") else { return }
        let order: (LiveEvent, LiveEvent) -> Bool = { a, b in
            a.live != b.live ? a.live : a.start < b.start
        }
        yours = j["yours"].array.compactMap(LiveEvent.init).sorted(by: order)
        live = j["live"].array.compactMap(LiveEvent.init).sorted(by: order)
        today = j["today"].array.compactMap(LiveEvent.init).sorted(by: order)
        golf = j["golf"].array.compactMap(LiveEvent.init).sorted(by: order)
        racing = j["racing"].array.compactMap(LiveEvent.init).sorted(by: order)
        var g: [String: LiveGroup] = [:]
        for x in j["channels"].array.compactMap(LiveGroup.init) where !x.channels.isEmpty { g[x.id] = x }
        groups = g
    }
}

/// The TV tab: the short lineup (sports, golf, racing, news, entertainment, cooking and home, documentary, New
/// York), what is on now on each, and every channel the plan has under All channels.
struct TVView: View {
    @EnvironmentObject private var rtx: RTXServer
    @State private var groups: [LiveGroup] = []
    @State private var loading = true
    @State private var error: String?
    @State private var watching: LiveRequest?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: S(46)) {
                AdaptiveStack(spacing: S(30)) {
                    Text("Live TV").font(.system(size: F(64), weight: .bold))
                    if Device.isTV { Text("Through your PC").font(.title3).foregroundStyle(Theme.dim) }
                    Spacer()
                    NavigationLink(value: LiveRoute.all) {
                        Label("All channels", systemImage: "magnifyingglass").font(.system(size: F(28), weight: .semibold))
                    }
                }
                .padding(.horizontal, Theme.sidePadding)
                .tvFocusSection()
                ForEach(groups) { g in
                    LiveRow(title: g.name, channels: g.channels, play: { watching = $0 })
                }
                if groups.isEmpty {
                    LoadState(loading: loading, error: error, empty: "No channels yet.", retry: { Task { await load() } })
                }
            }
            .padding(.vertical, S(40))
        }
        .refreshable { await load() }
        .task(id: rtx.address) {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(nanoseconds: 300_000_000_000)  // what's on now, every 5 minutes
            }
        }
        .navigationDestination(for: LiveRoute.self) { route in
            switch route {
            case .all: AllChannelsView()
            case let .category(c): CategoryChannelsView(category: c)
            }
        }
        .fullScreenCover(item: $watching) { LivePlayerScreen(request: $0) }
    }

    private func load() async {
        defer { loading = false }
        guard let base = rtx.base else { error = "The PC's address isn't set. Open Settings."; return }
        do {
            let j = try await RTXAPI(base: base).get("tv/lineup")
            groups = j["groups"].array.compactMap(LiveGroup.init).filter { !$0.channels.isEmpty }
            error = nil
        } catch {
            self.error = "Couldn't reach Live TV on the PC."
        }
    }
}

/// A full-width row for the All channels lists.
struct LiveListRow: View {
    let title: String
    var detail: String? = nil
    var logo: URL? = nil
    var chevron = false
    @Environment(\.isFocused) private var focused

    var body: some View {
        HStack(spacing: S(24)) {
            if let logo {
                AsyncImage(url: logo) { phase in
                    if let image = phase.image { image.resizable().aspectRatio(contentMode: .fit) } else { Color.clear }
                }
                .frame(width: S(96), height: S(54))
            }
            Text(title).font(.system(size: F(28), weight: .semibold)).lineLimit(1)
            Spacer()
            if let detail { Text(detail).font(.system(size: F(24))).foregroundStyle(Theme.dim) }
            if chevron { Image(systemName: "chevron.right").foregroundStyle(Theme.dim) }
        }
        .padding(.horizontal, S(28)).padding(.vertical, S(18))
        .background(Color.white.opacity(focused ? 0.18 : 0.06), in: RoundedRectangle(cornerRadius: S(14), style: .continuous))
        .scaleEffect(focused ? 1.02 : 1)
        .animation(.easeOut(duration: 0.15), value: focused)
    }
}

/// Everything the plan has: its categories, or every channel matching a search.
struct AllChannelsView: View {
    @EnvironmentObject private var rtx: RTXServer
    @State private var query = ""
    @State private var categories: [LiveCategory] = []
    @State private var results: [LiveChannel] = []
    @State private var loading = true
    @State private var error: String?
    @State private var watching: LiveRequest?

    var body: some View {
        ZStack {
            Backdrop()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: S(14)) {
                    Text(query.isEmpty ? "All channels" : "Channels matching \u{201C}\(query)\u{201D}")
                        .font(.system(size: F(48), weight: .bold)).padding(.bottom, S(16))
                    if query.isEmpty {
                        ForEach(categories) { c in
                            NavigationLink(value: LiveRoute.category(c)) {
                                LiveListRow(title: c.name, detail: "\(c.count)", chevron: true)
                            }
                            .buttonStyle(QuietButtonStyle())
                        }
                        if categories.isEmpty { LoadState(loading: loading, error: error, retry: { Task { await loadCategories() } }) }
                    } else {
                        ForEach(results) { c in
                            Button { watching = LiveRequest(stream: c.id, title: c.name) } label: {
                                LiveListRow(title: c.name, logo: LiveTV.logoURL(c.logo, base: rtx.base))
                            }
                            .buttonStyle(QuietButtonStyle())
                        }
                        if results.isEmpty { LoadState(loading: loading, error: error, empty: "No channel by that name.") }
                    }
                }
                .padding(.horizontal, Theme.sidePadding)
                .padding(.vertical, S(40))
            }
        }
        .searchable(text: $query, prompt: "Search every channel")
        .task { await loadCategories() }
        .task(id: query) {
            guard !query.isEmpty else { return }
            try? await Task.sleep(nanoseconds: 400_000_000)  // wait for typing to pause
            guard !Task.isCancelled else { return }
            await search(query)
        }
        .fullScreenCover(item: $watching) { LivePlayerScreen(request: $0) }
    }

    private func loadCategories() async {
        defer { loading = false }
        guard let base = rtx.base else { return }
        do {
            let j = try await RTXAPI(base: base).get("tv/categories")
            categories = j["categories"].array.compactMap { c -> LiveCategory? in
                guard let id = c["id"].string, let name = c["name"].string else { return nil }
                let n = c["count"].int ?? 0
                return n > 0 ? LiveCategory(id: id, name: LiveTV.clean(name), count: n) : nil
            }
            error = nil
        } catch {
            self.error = "Couldn't reach Live TV on the PC."
        }
    }

    private func search(_ q: String) async {
        guard let base = rtx.base else { return }
        loading = true
        defer { loading = false }
        if let j = try? await RTXAPI(base: base).get("tv/channels", [URLQueryItem(name: "q", value: q)]) {
            results = j["channels"].array.compactMap(LiveChannel.init)
        }
    }
}

/// One category's channels.
struct CategoryChannelsView: View {
    let category: LiveCategory
    @EnvironmentObject private var rtx: RTXServer
    @State private var channels: [LiveChannel] = []
    @State private var loading = true
    @State private var watching: LiveRequest?

    var body: some View {
        ZStack {
            Backdrop()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: S(14)) {
                    Text(category.name).font(.system(size: F(48), weight: .bold)).padding(.bottom, S(16))
                    ForEach(channels) { c in
                        Button { watching = LiveRequest(stream: c.id, title: c.name) } label: {
                            LiveListRow(title: c.name, logo: LiveTV.logoURL(c.logo, base: rtx.base))
                        }
                        .buttonStyle(QuietButtonStyle())
                    }
                    if channels.isEmpty { LoadState(loading: loading, error: nil, empty: "Nothing in this category right now.") }
                }
                .padding(.horizontal, Theme.sidePadding)
                .padding(.vertical, S(40))
            }
        }
        .task {
            defer { loading = false }
            guard let base = rtx.base else { return }
            if let j = try? await RTXAPI(base: base).get("tv/channels", [URLQueryItem(name: "cat", value: category.id)]) {
                channels = j["channels"].array.compactMap(LiveChannel.init)
            }
        }
        .fullScreenCover(item: $watching) { LivePlayerScreen(request: $0) }
    }
}

@MainActor
final class LivePlayerModel: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var error: String?
    @Published private(set) var paused = false
    private var rateObserver: NSKeyValueObservation?

    /// Asks the PC to start the channel (answered once the first seconds are ready), trying spare feeds in turn.
    func tune(_ request: LiveRequest, base: URL?) async {
        error = nil
        guard let base else { error = "The PC's address isn't set. Open Settings."; return }
        var busy = false
        for stream in [request.stream] + request.alt {
            do {
                let j = try await RTXAPI(base: base).get("tv/play", [URLQueryItem(name: "stream", value: stream)])
                guard let u = j["url"].string, let url = URL(string: u, relativeTo: base)?.absoluteURL else { continue }
                start(url)
                return
            } catch APIError.server(let code, _) where code == 503 {
                busy = true
            } catch {
                continue
            }
        }
        error = busy
            ? "The channel didn't start. Your plan plays one channel at a time: if it's on another screen, stop it there and try again."
            : "Couldn't reach Live TV on the PC."
    }

    private func start(_ url: URL) {
        let p = AVPlayer(url: url)
        #if os(iOS)
        p.allowsExternalPlayback = true
        p.usesExternalPlaybackWhileExternalScreenIsActive = true
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        rateObserver = p.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in self?.paused = status == .paused }
        }
        player = p
    }

    func close() {
        player?.pause()
        rateObserver = nil
        player = nil
    }
}

/// Full-screen live playback in the system player. The PC stops the channel a few minutes after nobody watches.
struct LivePlayerScreen: View {
    let request: LiveRequest
    @EnvironmentObject private var rtx: RTXServer
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = LivePlayerModel()
    @State private var attempt = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player = model.player {
                SystemPlayer(player: player).ignoresSafeArea()
                #if os(iOS)
                if model.paused { closeBar }
                #endif
            } else {
                VStack(spacing: S(34)) {
                    Text(request.title).font(.system(size: F(60), weight: .bold)).multilineTextAlignment(.center)
                    if let error = model.error {
                        Text(error).foregroundStyle(Color.white.opacity(0.65)).multilineTextAlignment(.center).frame(maxWidth: W(1300))
                        HStack(spacing: S(40)) {
                            Button("Try again") { attempt += 1 }
                            Button("Back") { dismiss() }
                        }
                    } else {
                        ProgressView()
                        Text("Tuning in on the PC...").foregroundStyle(Color.white.opacity(0.7))
                    }
                }
                .padding(S(100))
                #if os(iOS)
                closeBar
                #endif
            }
        }
        .task(id: attempt) { await model.tune(request, base: rtx.base) }
        .onDisappear { model.close() }
    }

    #if os(iOS)
    private var closeBar: some View {
        VStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .accessibilityLabel("Close")
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 54)
            Spacer()
        }
        .tint(.white)
    }
    #endif
}
