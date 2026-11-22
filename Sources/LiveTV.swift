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

/// One team on a game card: its crest (kept on the PC, from ESPN's lists) and colours (src/teams.py).
struct LiveTeam: Hashable {
    let abbr: String
    let short: String
    let color: String
    let alt: String
    let logo: String?
    /// Lower-case names it goes by (only in /tv/teams, for matching Sportarr's team names).
    var aliases: [String] = []

    init?(_ j: JSON) {
        guard let abbr = j["abbr"].string else { return nil }
        self.abbr = abbr
        short = j["short"].string ?? abbr
        color = j["color"].string ?? "333333"
        alt = j["alt"].string ?? "ffffff"
        logo = j["logo"].string
        aliases = j["aliases"].array.compactMap(\.string)
    }

    /// The card colour: the team's main colour, its second one when the main is near white, else a dark grey.
    var cardColor: Color {
        for hex in [color, alt] {
            if let c = LiveTeam.rgb(hex), (0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2) < 0.78 {
                return Color(red: c.0, green: c.1, blue: c.2)
            }
        }
        return Color(white: 0.24)
    }

    static func rgb(_ hex: String) -> (Double, Double, Double)? {
        guard hex.count == 6, let n = Int(hex, radix: 16) else { return nil }
        return (Double((n >> 16) & 255) / 255, Double((n >> 8) & 255) / 255, Double(n & 255) / 255)
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
    /// The two teams (away or first, then home) when the PC knows both: the card shows their crests.
    let teams: [LiveTeam]
    /// Every feed of the game, best first (the PC ranks them by measured picture and reliability).
    let feeds: [LiveFeed]

    init?(_ j: JSON) {
        guard let id = j["id"].string, let title = j["title"].string, let s = j["start"].double else { return nil }
        self.id = id
        self.title = title
        league = j["league"].string ?? ""
        start = Date(timeIntervalSince1970: s)
        end = Date(timeIntervalSince1970: j["end"].double ?? s + 3 * 3600)
        mine = !j["mine"].array.isEmpty
        alt = j["alt"].array.compactMap(\.string)
        let t = j["teams"].array.compactMap(LiveTeam.init)
        teams = t.count == 2 ? t : []
        feeds = j["feeds"].array.compactMap { f in f["id"].string.map { LiveFeed(id: $0, quality: f["quality"].string) } }
    }

    /// "Dolphins at Bills" (away at home) rather than "Liverpool vs Manchester United".
    var isAt: Bool { title.range(of: #"\sat\s|@"#, options: [.regularExpression, .caseInsensitive]) != nil }

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

/// What to play full screen: a channel or an event feed, with spare feeds to try if the first will not start, or
/// an On Demand film or episode (played through the PC from `start`).
struct LiveRequest: Identifiable {
    let id = UUID()
    let stream: String
    let title: String
    var alt: [String] = []
    var vod: VODRef? = nil
    /// A download still in progress (its release name): played from the PC's growing copy (GET /grow/play).
    var grow: String? = nil
    /// Every feed of a game, best first, with its measured picture ("1080p60"), for Other feeds.
    var feeds: [LiveFeed] = []
}

/// One feed of a game: the provider's stream and its picture as the PC measured it (nil: not measured yet).
struct LiveFeed: Hashable, Identifiable {
    let id: String
    let quality: String?
}

/// An On Demand title to play: "movie" or "episode", the provider's id and file type, where to start.
struct VODRef: Hashable {
    let kind: String
    let id: String
    let ext: String
    var start: Double = 0
    var duration: Double? = nil

    /// Its key in the PC's positions ("od:movie-123"), shared by every screen.
    var positionKey: String { "\(kind)-\(id)" }
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

    /// A large faint symbol behind a card with no crests (golf, racing, a game whose teams aren't known).
    static func symbol(_ league: String) -> String? {
        switch league {
        case "Golf": return "figure.golf"
        case "F1": return "flag.checkered"
        case "NFL": return "football.fill"
        case "Premier League": return "soccerball"
        default: return nil
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

/// Two crests on the teams' own colours, split down the middle, with "AT" or "VS" between them.
struct MatchupArt: View {
    let first: LiveTeam
    let second: LiveTeam
    var at = true
    var crest: CGFloat = S(132)
    @EnvironmentObject private var rtx: RTXServer

    var body: some View {
        ZStack {
            LinearGradient(stops: [.init(color: first.cardColor, location: 0), .init(color: first.cardColor, location: 0.45),
                                   .init(color: second.cardColor, location: 0.55), .init(color: second.cardColor, location: 1)],
                           startPoint: UnitPoint(x: 0, y: 0.35), endPoint: UnitPoint(x: 1, y: 0.65))
            LinearGradient(colors: [.white.opacity(0.10), .clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
            HStack(spacing: 0) {
                badge(first).frame(maxWidth: .infinity)
                Text(at ? "AT" : "VS").font(.system(size: F(20), weight: .heavy)).tracking(2)
                    .foregroundStyle(Color.white.opacity(0.75))
                badge(second).frame(maxWidth: .infinity)
            }
            .padding(.horizontal, S(16))
        }
    }

    private func badge(_ t: LiveTeam) -> some View {
        AsyncImage(url: LiveTV.logoURL(t.logo, base: rtx.base), transaction: Transaction(animation: .easeIn(duration: 0.2))) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(contentMode: .fit)
            } else {
                Text(t.abbr).font(.system(size: F(38), weight: .heavy)).foregroundStyle(Color.white)
            }
        }
        .frame(width: crest, height: crest)
        .shadow(color: .black.opacity(0.45), radius: S(10), y: S(6))
        .accessibilityHidden(true)
    }
}

/// A 16:9 card for a game or race: both teams' crests on their colours (else the league's colours and the title),
/// LIVE when it is on, a star for your teams.
struct LiveEventCell: View {
    let event: LiveEvent
    @Environment(\.isFocused) private var focused

    var body: some View {
        VStack(alignment: .leading, spacing: S(10)) {
            ZStack(alignment: .bottomLeading) {
                if event.teams.count == 2 {
                    MatchupArt(first: event.teams[0], second: event.teams[1], at: event.isAt)
                } else {
                    LinearGradient(colors: LiveTV.colors(event.league), startPoint: .topLeading, endPoint: .bottomTrailing)
                    if let symbol = LiveTV.symbol(event.league) {
                        Image(systemName: symbol).font(.system(size: F(150), weight: .light))
                            .foregroundStyle(Color.white.opacity(0.10))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                            .padding(.trailing, S(24))
                    }
                    Text(event.title).font(.system(size: F(30), weight: .heavy)).lineLimit(2).minimumScaleFactor(0.75)
                        .foregroundStyle(Color.white)
                        .padding(S(20))
                }
            }
            .frame(width: W(480), height: S(270))
            .overlay(alignment: .topLeading) {
                Text(event.league.uppercased()).font(.system(size: F(18), weight: .bold)).tracking(1.2)
                    .foregroundStyle(Color.white.opacity(0.75)).padding(S(18))
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: S(10)) {
                    if event.mine { Image(systemName: "star.fill").font(.system(size: F(22))).foregroundStyle(Theme.accent) }
                    if event.live { LivePill() }
                }
                .padding(S(14))
            }
            .modifier(LiveCardChrome(focused: focused))
            VStack(alignment: .leading, spacing: S(4)) {
                if event.teams.count == 2 {
                    Text(event.title).font(.system(size: F(22), weight: .semibold)).lineLimit(1)
                }
                Text(event.when).font(.system(size: F(21))).foregroundStyle(event.live ? Color.white : Theme.dim).lineLimit(1)
            }
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
    /// Pinned to the front of Your teams (NFL RedZone): marked with a pin.
    var pinned = false
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
            .overlay(alignment: .topLeading) {
                if pinned {
                    Image(systemName: "pin.fill").font(.system(size: F(20), weight: .semibold)).foregroundStyle(Theme.accent)
                        .padding(S(16))
                }
            }
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
        .accessibilityLabel((channel.now.map { "\(channel.name), \($0.title)" } ?? channel.name) + (pinned ? ", pinned" : ""))
    }

    private var nameStandIn: some View {
        Text(channel.name).font(.system(size: F(28), weight: .bold)).multilineTextAlignment(.center)
            .foregroundStyle(Color.white.opacity(0.85)).padding(S(20))
    }
}

/// A titled row of game cards, then (optionally) channel cards; pinned channels come before the games.
struct LiveRow: View {
    let title: String
    var events: [LiveEvent] = []
    var channels: [LiveChannel] = []
    var wideChannels = false
    var pinned: [LiveChannel] = []
    let play: (LiveRequest) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: S(18)) {
            Text(title).font(.system(size: F(34), weight: .bold)).padding(.horizontal, Theme.sidePadding)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: S(40)) {
                    ForEach(pinned) { c in
                        Button { play(LiveRequest(stream: c.id, title: c.name, alt: c.alt)) } label: {
                            LiveChannelCell(channel: c, wide: true, pinned: true)
                        }
                        .buttonStyle(QuietButtonStyle())
                    }
                    ForEach(events) { e in
                        Button { play(LiveRequest(stream: e.id, title: e.title, alt: e.alt, feeds: e.feeds)) } label: { LiveEventCell(event: e) }
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
    @State private var pinned: [LiveChannel] = []
    @State private var yours: [LiveEvent] = []
    @State private var live: [LiveEvent] = []
    @State private var today: [LiveEvent] = []
    @State private var golf: [LiveEvent] = []
    @State private var racing: [LiveEvent] = []
    @State private var groups: [String: LiveGroup] = [:]
    @State private var watching: LiveRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: S(46)) {
            if !yours.isEmpty || !pinned.isEmpty {
                LiveRow(title: "Your teams", events: yours, pinned: pinned, play: { watching = $0 })
            }
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
        pinned = j["pinned"].array.compactMap(LiveChannel.init)
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

/// The TV tab: Live (the short lineup: sports, golf, racing, news, entertainment, cooking and home, documentary,
/// New York, what is on now on each, and every channel under All channels) or On Demand (the plan's films and
/// series), picked at the top.
struct TVView: View {
    @EnvironmentObject private var rtx: RTXServer
    @AppStorage("tvPage") private var page = "live"
    @State private var groups: [LiveGroup] = []
    @State private var loading = true
    @State private var error: String?
    @State private var watching: LiveRequest?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: S(46)) {
                AdaptiveStack(spacing: S(30)) {
                    Text(page == "ondemand" ? "On Demand" : "Live TV").font(.system(size: F(64), weight: .bold))
                    Picker("Show", selection: $page) {
                        Text("Live").tag("live")
                        Text("On Demand").tag("ondemand")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: W(520))
                    Spacer()
                    if page == "ondemand" {
                        NavigationLink(value: ODRoute.search) {
                            Label("Search", systemImage: "magnifyingglass").font(.system(size: F(28), weight: .semibold))
                        }
                    } else {
                        NavigationLink(value: LiveRoute.all) {
                            Label("All channels", systemImage: "magnifyingglass").font(.system(size: F(28), weight: .semibold))
                        }
                    }
                }
                .padding(.horizontal, Theme.sidePadding)
                .tvFocusSection()
                if page == "ondemand" {
                    OnDemandRows()
                } else {
                    ForEach(groups) { g in
                        LiveRow(title: g.name, channels: g.channels, play: { watching = $0 })
                    }
                    if groups.isEmpty {
                        LoadState(loading: loading, error: error, empty: "No channels yet.", retry: { Task { await load() } })
                    }
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
        #if os(iOS)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search every channel")
        #else
        .searchable(text: $query, prompt: "Search every channel")
        #endif
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
    private var timeObserver: Any?
    private var base: URL?
    /// The PC's session (tv-...): stopped when the player closes, so the plan's one stream is free at once.
    private var session: String?
    private var vod: VODRef?
    /// On Demand: where the PC's stream starts in the film (the player's time 0).
    private var offset: Double = 0
    /// The feed that started (the request's own, or a spare one).
    private var tuned: String?

    /// Asks the PC to start the channel (answered once the first seconds are ready), trying spare feeds in turn,
    /// or the On Demand title from where it was left.
    func tune(_ request: LiveRequest, base: URL?) async {
        error = nil
        self.base = base
        guard let base else { error = "The PC's address isn't set. Open Settings."; return }
        if let vod = request.vod {
            await tuneVOD(vod, title: request.title, base: base)
            return
        }
        if let grow = request.grow {
            do {
                let j = try await RTXAPI(base: base).get("grow/play", [URLQueryItem(name: "name", value: grow),
                                                                    URLQueryItem(name: "title", value: request.title)])
                guard let u = j["url"].string, let url = URL(string: u, relativeTo: base)?.absoluteURL else {
                    error = "The PC didn't send a stream."
                    return
                }
                session = j["session"].string
                start(url)
            } catch APIError.server(let code, let body) {
                // 409: not far enough along yet; 404: no video file yet; 503: the PC couldn't start it
                error = (try? JSON.parse(Data(body.utf8)))?["error"].string ?? (code == 409 ? "Not far enough along to play yet." : "The PC couldn't start it.")
            } catch {
                self.error = "Couldn't reach the PC."
            }
            return
        }
        var busy = false
        for stream in [request.stream] + request.alt {
            do {
                let j = try await RTXAPI(base: base).get("tv/play", [URLQueryItem(name: "stream", value: stream)])
                guard let u = j["url"].string, let url = URL(string: u, relativeTo: base)?.absoluteURL else { continue }
                session = j["session"].string
                tuned = stream
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

    private func tuneVOD(_ vod: VODRef, title: String, base: URL) async {
        let q = [URLQueryItem(name: "kind", value: vod.kind), URLQueryItem(name: "id", value: vod.id),
                 URLQueryItem(name: "ext", value: vod.ext), URLQueryItem(name: "t", value: String(Int(max(0, vod.start)))),
                 URLQueryItem(name: "title", value: title)]
        do {
            let j = try await RTXAPI(base: base).get("tv/ondemand/play", q)
            guard let u = j["url"].string, let url = URL(string: u, relativeTo: base)?.absoluteURL else {
                error = "The PC didn't send a stream."
                return
            }
            session = j["session"].string
            offset = j["start_s"].double ?? vod.start
            var v = vod
            if v.duration == nil { v.duration = j["duration_s"].double }
            self.vod = v
            start(url)
        } catch APIError.server(let code, _) where code == 503 {
            error = "It didn't start. Your plan plays one stream at a time: if live TV is on another screen, stop it there and try again."
        } catch {
            self.error = "Couldn't reach On Demand on the PC."
        }
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
        if vod != nil {  // On Demand: every 15 s the PC hears where it is, so any screen resumes it
            timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 15, preferredTimescale: 1), queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.savePosition() }
            }
        }
        player = p  // SystemPlayer starts it
    }

    /// What to hand to a Chromecast or Google TV: the same channel, or the title from where it is now.
    func castTarget(_ request: LiveRequest) -> CastTarget {
        if let v = vod ?? request.vod {
            let now = player?.currentTime().seconds ?? 0
            let t = now.isFinite && now > 0 ? now + offset : v.start
            return CastTarget(title: request.title, path: "tv/ondemand/cast", query: [
                URLQueryItem(name: "kind", value: v.kind), URLQueryItem(name: "id", value: v.id), URLQueryItem(name: "ext", value: v.ext),
                URLQueryItem(name: "t", value: String(Int(max(0, t)))), URLQueryItem(name: "title", value: request.title),
                URLQueryItem(name: "d", value: String(format: "%.0f", v.duration ?? 0))])
        }
        return CastTarget(title: request.title, path: "tv/cast", query: [
            URLQueryItem(name: "stream", value: tuned ?? request.stream), URLQueryItem(name: "title", value: request.title)])
    }

    private func savePosition() {
        guard let vod, let base, let p = player else { return }
        let t = p.currentTime().seconds
        guard t.isFinite, t > 0 else { return }
        let q = [URLQueryItem(name: "key", value: vod.positionKey), URLQueryItem(name: "t", value: String(format: "%.1f", t + offset)),
                 URLQueryItem(name: "d", value: String(format: "%.1f", vod.duration ?? 0)),
                 URLQueryItem(name: "where", value: Device.isTV ? "apple-tv" : "iphone")]
        Task { _ = try? await RTXAPI(base: base).get("tv/ondemand/position", q) }
    }

    /// Other feeds: plays this feed of the game instead (the PC hands over the plan's one stream).
    func switchFeed(_ feed: String, request: LiveRequest, base: URL?) async {
        close()
        error = nil
        let all = [request.stream] + request.alt
        await tune(LiveRequest(stream: feed, title: request.title, alt: all.filter { $0 != feed }, feeds: request.feeds), base: base)
    }

    /// The feed playing now (for marking it in Other feeds).
    var currentFeed: String? { tuned }

    func close() {
        savePosition()
        if let o = timeObserver { player?.removeTimeObserver(o) }
        timeObserver = nil
        player?.pause()
        rateObserver = nil
        player = nil
        if let session, let base {
            Task { _ = try? await RTXAPI(base: base).get("tv/stop", [URLQueryItem(name: "session", value: session)]) }
        }
        session = nil
    }
}

/// Full-screen live playback in the system player. The PC stops the channel a few minutes after nobody watches.
struct LivePlayerScreen: View {
    let request: LiveRequest
    @EnvironmentObject private var rtx: RTXServer
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = LivePlayerModel()
    @State private var attempt = 0
    @State private var casting = false
    @State private var castStarted = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player = model.player {
                SystemPlayer(player: player, menu: feedActions).ignoresSafeArea()
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
        .fullScreenPlayer()  // background trailers wait while this plays
        #if os(iOS)
        // Cast: the PC hands the same stream to the TV; once it plays there, this player closes.
        .sheet(isPresented: $casting, onDismiss: { if castStarted { dismiss() } }) {
            CastSheet(target: model.castTarget(request), started: { castStarted = true })
        }
        #endif
    }

    /// "Feed 1 · 1080p60 (best)", "Feed 2 · not measured yet".
    private func feedName(_ i: Int, _ f: LiveFeed) -> String {
        "Feed \(i + 1) \u{00B7} " + (f.quality ?? "not measured yet") + (i == 0 ? " (best)" : "")
    }

    /// Other feeds in the Apple TV player's menu (swipe down while playing); nothing when the game has one feed.
    private var feedActions: [UIAction] {
        guard request.feeds.count > 1 else { return [] }
        return request.feeds.enumerated().map { i, f in
            UIAction(title: feedName(i, f), image: UIImage(systemName: f.id == model.currentFeed ? "checkmark" : "antenna.radiowaves.left.and.right")) { _ in
                Task { await model.switchFeed(f.id, request: request, base: rtx.base) }
            }
        }
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
                if request.feeds.count > 1 {
                    Menu {
                        ForEach(Array(request.feeds.enumerated()), id: \.element.id) { i, f in
                            Button {
                                Task { await model.switchFeed(f.id, request: request, base: rtx.base) }
                            } label: {
                                Label(feedName(i, f), systemImage: f.id == model.currentFeed ? "checkmark" : "antenna.radiowaves.left.and.right")
                            }
                        }
                    } label: {
                        Label("Feeds", systemImage: "antenna.radiowaves.left.and.right").font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .accessibilityLabel("Other feeds")
                }
                if request.grow == nil {
                    Button { casting = true } label: {
                        Label("Cast", systemImage: "tv.badge.wifi").font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .accessibilityLabel("Cast to a Chromecast or Google TV")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 54)
            Spacer()
        }
        .tint(.white)
    }
    #endif
}
