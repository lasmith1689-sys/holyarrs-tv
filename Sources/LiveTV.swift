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
    /// ESPN's id of the game (NFL, Premier League, Champions League): what Record asks the PC for.
    let game: String?
    /// The PC is set to record it ("scheduled") or is recording it ("recording").
    let rec: String?

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
        game = j["game"].string
        rec = j["rec"]["state"].string
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
    /// A recording on the PC (its id): from where it was left, ad breaks skipped (GET /rec/play).
    var rec: String? = nil
    /// Watch now, 4K when ready: the film's TMDB id. On Demand plays at once; the 4K copy HolyArrs fetches takes
    /// over at the same moment when it is in place (GET /upgrade/start, /upgrade/status).
    var upgrade: String? = nil
    /// Every feed of a game, best first, with its measured picture ("1080p60"), for Other feeds.
    var feeds: [LiveFeed] = []

    /// What Other feeds offers: a game's ranked feeds, else a channel's own stream and its spares (the PC's lineup
    /// lists them best first; not measured). Nothing for On Demand or a download.
    var switchable: [LiveFeed] {
        guard vod == nil, grow == nil, rec == nil else { return [] }
        if !feeds.isEmpty { return feeds }
        return ([stream] + alt).map { LiveFeed(id: $0, quality: nil) }
    }
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
    /// For Continue Watching cards on every screen (saved with the position on the PC).
    var poster: String? = nil
    var series: String? = nil

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
struct LiveCardChrome: ViewModifier {
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

/// REC on a game set to record (outlined) or recording now (filled).
struct RecPill: View {
    var recording: Bool
    var body: some View {
        HStack(spacing: S(8)) {
            Circle().fill(recording ? Color.white : Color(red: 0.90, green: 0.16, blue: 0.20)).frame(width: S(10), height: S(10))
            Text("REC").font(.system(size: F(18), weight: .heavy)).tracking(1)
        }
        .padding(.horizontal, S(12)).padding(.vertical, S(6))
        .background(recording ? Color(red: 0.90, green: 0.16, blue: 0.20) : Color.black.opacity(0.55), in: Capsule())
        .overlay(Capsule().stroke(Color(red: 0.90, green: 0.16, blue: 0.20), lineWidth: recording ? 0 : 2))
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
                    if event.rec != nil { RecPill(recording: event.rec == "recording") }
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
    /// Record or Cancel recording, from a game card's long-press menu (games ESPN knows).
    var record: ((LiveEvent) -> Void)? = nil

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
                            .contextMenu {
                                if let record, e.game != nil {
                                    Button { record(e) } label: {
                                        Label(e.rec == nil ? "Record" : e.rec == "recording" ? "Stop recording" : "Cancel recording",
                                              systemImage: e.rec == nil ? "record.circle" : "stop.circle")
                                    }
                                }
                            }
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
    @State private var recordings: [Recording] = []
    @State private var watching: LiveRequest?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: S(46)) {
            if let message {
                Text(message).font(.system(size: F(24))).foregroundStyle(Theme.dim).padding(.horizontal, Theme.sidePadding)
            }
            if !recordings.isEmpty {
                RecordingsRow(recordings: recordings, play: { watching = $0 }, act: { r, action in Task { await act(r, action) } })
            }
            if !yours.isEmpty || !pinned.isEmpty {
                LiveRow(title: "Your teams", events: yours, pinned: pinned, play: { watching = $0 }, record: { e in Task { await record(e) } })
            }
            if !live.isEmpty { LiveRow(title: "Live now", events: live, play: { watching = $0 }, record: { e in Task { await record(e) } }) }
            if !today.isEmpty { LiveRow(title: "Later today", events: today, play: { watching = $0 }, record: { e in Task { await record(e) } }) }
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
        .fullScreenCover(item: $watching, onDismiss: { Task { await load() } }) { LivePlayerScreen(request: $0) }
    }

    /// Record a game, or cancel / stop its recording (the PC records it through the plan's one stream).
    private func record(_ e: LiveEvent) async {
        guard let base = rtx.base, let game = e.game else { return }
        do {
            if e.rec == nil {
                _ = try await RTXAPI(base: base).get("rec/add", [URLQueryItem(name: "game", value: game)])
                message = "\(e.title) will record from 5 minutes before kickoff until the game ends, ad breaks skipped when you watch."
            } else if let r = recordings.first(where: { $0.game == game }) {
                _ = try await RTXAPI(base: base).get("rec/cancel", [URLQueryItem(name: "id", value: r.id)])
                message = e.rec == "recording" ? "Stopped recording \(e.title). What was recorded stays." : "\(e.title) won't record."
            }
        } catch {
            message = "Couldn't reach the PC."
        }
        await load()
    }

    private func act(_ r: Recording, _ action: String) async {
        guard let base = rtx.base else { return }
        _ = try? await RTXAPI(base: base).get("rec/\(action)", [URLQueryItem(name: "id", value: r.id)])
        message = action == "delete" ? "Deleted \(r.title)." : nil
        await load()
    }

    private func load() async {
        guard let base = rtx.base, let j = try? await RTXAPI(base: base).get("tv/sports") else { return }
        recordings = j["recordings"].array.compactMap(Recording.init)
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

    /// Live & On Demand (Release 6): everything streaming from the IPTV plan. Live channels by group, the Guide
    /// grid, and On Demand.
    private var header: some View {
        AdaptiveStack(spacing: S(30)) {
            Text(page == "ondemand" ? "On Demand" : page == "guide" ? "Guide" : "Live TV").font(.system(size: F(64), weight: .bold))
            Picker("Show", selection: $page) {
                Text("Live").tag("live")
                Text("Guide").tag("guide")
                Text("On Demand").tag("ondemand")
            }
            .pickerStyle(.segmented)
            .frame(width: W(720))
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
    }

    var body: some View {
        if page == "guide" {
            // Not inside a ScrollView: the guide scrolls its own rows under a fixed time ruler.
            VStack(alignment: .leading, spacing: S(24)) {
                header
                GuideView(play: { watching = $0 })
            }
            .padding(.top, S(40))
            .navigationDestination(for: LiveRoute.self) { route in
                switch route {
                case .all: AllChannelsView()
                case let .category(c): CategoryChannelsView(category: c)
                }
            }
            .fullScreenCover(item: $watching) { LivePlayerScreen(request: $0) }
        } else {
            list
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: S(46)) {
                header
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
    /// The feed playing now (the request's own, or a spare one): marked in Other feeds.
    @Published private(set) var currentFeed: String?
    /// What the waiting screen says while it comes back (nil: "Tuning in on the PC...").
    @Published private(set) var notice: String?
    /// Another screen took the plan's one stream: said, with Take it back (never retried on its own).
    @Published private(set) var taken: String?
    private var request: LiveRequest?
    private var recovery = Recovery()
    private var recovering = false
    private var closed = false
    private var waitingSince: Date?
    private var playingSince: Date?
    /// This stream has played: only then is a failure or stall a drop (one that never starts shows as before).
    private var played = false
    private var failObserver: NSObjectProtocol?
    /// A recording: its id, its ad breaks (start, end in seconds) and where to pick up after a drop.
    private var recID: String?
    private var breaks: [(Double, Double)] = []
    private var recResume: Double?
    private var lastT: Double = -1
    private var lastSaved = Date.distantPast
    private var itemObserver: NSKeyValueObservation?
    private var watchTimer: Timer?
    private var work: Task<Void, Never>?
    private static var here: String { Device.isTV ? "apple-tv" : "iphone" }

    /// Asks the PC to start the channel (answered once the first seconds are ready), trying spare feeds in turn,
    /// or the On Demand title from where it was left.
    func tune(_ request: LiveRequest, base: URL?) async {
        error = nil
        taken = nil
        if self.request == nil { self.request = request }
        self.base = base
        guard let base else { error = "The PC's address isn't set. Open Settings."; return }
        if let vod = request.vod {
            await tuneVOD(vod, title: request.title, base: base)
            return
        }
        if let rec = request.rec {
            do {
                var q = [URLQueryItem(name: "id", value: rec)]
                if let t = recResume { q.append(URLQueryItem(name: "t", value: String(format: "%.1f", t))) }
                let j = try await RTXAPI(base: base).get("rec/play", q)
                guard let u = j["url"].string, let url = URL(string: u, relativeTo: base)?.absoluteURL else {
                    error = "The PC didn't send the recording."
                    return
                }
                recID = rec
                breaks = j["breaks"].array.compactMap { b in
                    let x = b.array.compactMap(\.double)
                    return x.count == 2 ? (x[0], x[1]) : nil
                }
                session = nil  // nothing to stop: the recording carries on
                start(url)
            } catch APIError.server(_, let body) {
                error = (try? JSON.parse(Data(body.utf8)))?["error"].string ?? "The PC couldn't play the recording."
            } catch {
                self.error = "Couldn't reach the PC."
            }
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
                let j = try await RTXAPI(base: base).get("tv/play", [URLQueryItem(name: "stream", value: stream),
                                                                  URLQueryItem(name: "where", value: Self.here)])
                guard let u = j["url"].string, let url = URL(string: u, relativeTo: base)?.absoluteURL else { continue }
                session = j["session"].string
                currentFeed = stream
                start(url)
                return
            } catch APIError.server(let code, let body) where code == 503 {
                if let why = (try? JSON.parse(Data(body.utf8)))?["recording"]["title"].string, !why.isEmpty,
                   let text = (try? JSON.parse(Data(body.utf8)))?["error"].string {
                    error = text  // the PC is recording a game on the plan's one stream: said, not retried
                    return
                }
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
                 URLQueryItem(name: "title", value: title), URLQueryItem(name: "where", value: Self.here)]
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
            if let tmdb = request?.upgrade, upgradeID == nil { followUpgrade(tmdb: tmdb, vod: v, title: title, base: base) }
        } catch APIError.server(let code, _) where code == 503 {
            error = "It didn't start. Your plan plays one stream at a time: if live TV is on another screen, stop it there and try again."
        } catch {
            self.error = "Couldn't reach On Demand on the PC."
        }
    }

    /// Watch now, 4K when ready: follows the 4K copy every 20 s; when the PC has it, the film plays from the same
    /// moment (lined up by sound) and the On Demand stream stops, freeing the plan's one stream.
    /// Shown only in the player's info panel (Apple TV: swipe down), never over the picture.
    @Published private(set) var upgradeNote: String? {
        didSet {
            #if os(tvOS)
            guard let item = player?.currentItem else { return }
            let sub = AVMutableMetadataItem()
            sub.identifier = .iTunesMetadataTrackSubTitle
            sub.value = (upgradeNote ?? "") as NSString
            sub.extendedLanguageTag = "und"
            item.externalMetadata = upgradeNote == nil ? [] : [sub]
            #endif
        }
    }
    private var upgradeID: String?
    private var film: (id: String, session: String)?

    private func followUpgrade(tmdb: String, vod: VODRef, title: String, base: URL) {
        Task { [weak self] in
            guard let self else { return }
            let q = [URLQueryItem(name: "tmdb", value: tmdb), URLQueryItem(name: "title", value: title),
                     URLQueryItem(name: "kind", value: vod.kind), URLQueryItem(name: "id", value: vod.id),
                     URLQueryItem(name: "ext", value: vod.ext), URLQueryItem(name: "session", value: self.session ?? "")]
            guard let j = try? await RTXAPI(base: base).get("upgrade/start", q), let uid = j["upgrade"]["id"].string else { return }
            self.upgradeID = uid
            while !self.closed, self.film == nil {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !self.closed, let s = try? await RTXAPI(base: base, quick: true).get("upgrade/status", [URLQueryItem(name: "id", value: uid)]) else { continue }
                let u = s["upgrade"]
                switch u["state"].string ?? "" {
                case "downloading":
                    let pct = Int(u["pct"].double ?? 0)
                    if let eta = u["eta_s"].double, eta > 0 { self.upgradeNote = "4K in about \(max(1, Int(eta / 60))) min (\(pct)%)" }
                    else { self.upgradeNote = "4K downloading (\(pct)%)" }
                case "importing": self.upgradeNote = "4K almost ready"
                case "none": self.upgradeNote = nil; return  // no 4K copy: On Demand keeps playing
                case "ready":
                    if let fid = u["film"].string { await self.switchToFilm(fid, offset: u["offset"].double ?? 0, base: base) }
                default: self.upgradeNote = "Looking for a 4K copy"
                }
            }
        }
    }

    private func switchToFilm(_ fid: String, offset upOffset: Double, base: URL) async {
        guard let p = player, !closed else { return }
        let now = p.currentTime().seconds
        guard now.isFinite else { return }
        let asked = Date()
        let at = max(0, now + offset + upOffset)
        guard let (url, filmSession) = try? await RTXAPI(base: base).play(film: fid, seconds: at, ask: true, force: false), !closed else { return }
        let caughtUp = min(30, Date().timeIntervalSince(asked))  // the seconds On Demand played while the 4K film started
        let odSession = session
        teardown()  // saves the On Demand spot one last time
        if let odSession { _ = try? await RTXAPI(base: base).get("tv/stop", [URLQueryItem(name: "session", value: odSession)]) }
        let duration = vod?.duration ?? 0
        vod = nil
        offset = 0
        session = nil
        film = (fid, filmSession)
        upgradeNote = nil
        start(url)
        if caughtUp > 1, let np = player {
            np.seek(to: CMTime(seconds: at + caughtUp, preferredTimescale: 600), toleranceBefore: .zero,
                    toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600))
        }
        filmDuration = duration
    }

    private var filmDuration: Double = 0

    private func start(_ url: URL) {
        let p = AVPlayer(url: url)
        #if os(iOS)
        p.allowsExternalPlayback = true
        p.usesExternalPlaybackWhileExternalScreenIsActive = true
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        rateObserver = p.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in
                guard let self else { return }
                self.paused = status == .paused
                if status == .playing {
                    self.played = true
                    self.waitingSince = nil
                    if self.playingSince == nil { self.playingSince = Date() }
                } else {
                    self.playingSince = nil
                    if status == .waitingToPlayAtSpecifiedRate, self.played { if self.waitingSince == nil { self.waitingSince = Date() } }
                    else { self.waitingSince = nil }
                }
            }
        }
        // Release 3: a failed or stalled stream (over 15 s) is noticed, and handled by why it stopped.
        if let item = p.currentItem {
            failObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.dropped() }
            }
            itemObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                let failed = item.status == .failed
                Task { @MainActor in if failed { self?.dropped() } }
            }
        }
        watchTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let since = self.playingSince, Date().timeIntervalSince(since) > Recovery.healthy { self.recovery.reset() }
                if Recovery.stalled(since: self.waitingSince) { self.waitingSince = nil; self.dropped() }
            }
        }
        recovering = false
        notice = nil
        if let film {  // the 4K film after Watch now: its spot goes to the PC every 15 s, as in the film player
            timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 15, preferredTimescale: 1), queue: .main) { [weak self] t in
                MainActor.assumeIsolated {
                    guard let self, self.played, t.seconds.isFinite, t.seconds > 1 else { return }
                    Resume.send(film.id, t.seconds, duration: self.filmDuration)
                }
            }
        } else if recID != nil {  // a recording: ad breaks skipped as play reaches them, the spot saved every 15 s
            timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 10), queue: .main) { [weak self] t in
                MainActor.assumeIsolated { self?.recTick(t.seconds) }
            }
        } else if vod != nil {  // On Demand: every 15 s the PC hears where it is, so any screen resumes it
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
            URLQueryItem(name: "stream", value: currentFeed ?? request.stream), URLQueryItem(name: "title", value: request.title)])
    }

    /// Play crossing the start of an ad break jumps to its end. A seek that lands inside a break is left alone (the
    /// viewer went there), so a break found by mistake can always be watched.
    private func recTick(_ t: Double) {
        guard t.isFinite, let p = player else { return }
        if lastT >= 0, t > lastT, t - lastT < 2, let b = breaks.first(where: { lastT < $0.0 && $0.0 <= t + 0.25 }) {
            lastT = b.1
            p.seek(to: CMTime(seconds: b.1, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600))
            return
        }
        lastT = t
        if t > 1 { recResume = t }
        if played, t > 1, Date().timeIntervalSince(lastSaved) > 15, let base, let rec = recID {
            lastSaved = Date()
            let q = [URLQueryItem(name: "id", value: rec), URLQueryItem(name: "t", value: String(format: "%.1f", t)),
                     URLQueryItem(name: "where", value: Self.here)]
            Task { _ = try? await RTXAPI(base: base).get("rec/position", q) }
            Task { [weak self] in  // breaks found since it started (it may still be recording)
                guard let j = try? await RTXAPI(base: base, quick: true).get("rec/breaks", [URLQueryItem(name: "id", value: rec)]) else { return }
                let found: [(Double, Double)] = j["breaks"].array.compactMap { b in
                    let x = b.array.compactMap(\.double)
                    return x.count == 2 ? (x[0], x[1]) : nil
                }
                await MainActor.run { if found.count >= (self?.breaks.count ?? 0) { self?.breaks = found } }
            }
        }
    }

    private func savePosition() {
        guard let vod, let base, let p = player else { return }
        let t = p.currentTime().seconds
        guard played, t.isFinite, t > 1 else { return }  // never a 0 from a stream that hasn't played (it would clear)
        var q = [URLQueryItem(name: "key", value: vod.positionKey), URLQueryItem(name: "t", value: String(format: "%.1f", t + offset)),
                 URLQueryItem(name: "d", value: String(format: "%.1f", vod.duration ?? 0)),
                 URLQueryItem(name: "where", value: Device.isTV ? "apple-tv" : "iphone"),
                 URLQueryItem(name: "ext", value: vod.ext)]
        // What Continue Watching shows for it on every screen (Release 3).
        if let title = request?.title { q.append(URLQueryItem(name: "title", value: title)) }
        if let poster = vod.poster { q.append(URLQueryItem(name: "poster", value: poster)) }
        if let series = vod.series { q.append(URLQueryItem(name: "series", value: series)) }
        Task { _ = try? await RTXAPI(base: base).get("tv/ondemand/position", q) }
    }

    /// Other feeds: plays this feed instead (the PC hands over the plan's one stream). If it won't start, the others
    /// are tried in order, and Other feeds marks the one that played.
    func switchFeed(_ feed: String, request: LiveRequest, base: URL?) async {
        work?.cancel()
        recovering = false
        teardown()
        if let session, let base {
            Task { _ = try? await RTXAPI(base: base).get("tv/stop", [URLQueryItem(name: "session", value: session)]) }
        }
        session = nil
        taken = nil
        error = nil
        currentFeed = nil
        let others = request.switchable.map(\.id).filter { $0 != feed }
        await tune(LiveRequest(stream: feed, title: request.title, alt: others), base: base)
    }

    func close() {
        closed = true
        work?.cancel()
        work = nil
        teardown()
        if let session, let base {
            Task { _ = try? await RTXAPI(base: base).get("tv/stop", [URLQueryItem(name: "session", value: session)]) }
        }
        if let film, let base { Task { await RTXAPI(base: base).stop(session: film.session) } }
        session = nil
    }

    /// Drops the player here (not the PC's session).
    private func teardown() {
        savePosition()
        if let o = timeObserver { player?.removeTimeObserver(o) }
        timeObserver = nil
        if let o = failObserver { NotificationCenter.default.removeObserver(o) }
        failObserver = nil
        itemObserver = nil
        watchTimer?.invalidate()
        watchTimer = nil
        waitingSince = nil
        playingSince = nil
        player?.pause()
        rateObserver = nil
        player = nil
    }

    /// Where an On Demand title is now (in the film's time).
    private var vodNow: Double? {
        guard vod != nil, let t = player?.currentTime().seconds, t.isFinite, t > 0 else { return nil }
        return t + offset
    }

    /// The stream failed or stalled. The PC says why: another screen took the plan's one stream (say so, offer
    /// Take it back, never retry into it), or it dropped: On Demand comes back where it was (three tries), a channel
    /// or game tries its feed once more and then the next of Other feeds, saying which.
    private func dropped() {
        guard played, !recovering, !closed, let base, let request else { return }
        recovering = true
        played = false
        let sid = session
        let at = vodNow
        if var v = vod, let at { v.start = max(0, at - 2); vod = v }
        teardown()
        notice = "The stream stopped. Checking with the PC..."
        work?.cancel()
        work = Task { [weak self] in
            guard let self else { return }
            if let sid, let j = try? await RTXAPI(base: base, quick: true).get("tv/session", [URLQueryItem(name: "session", value: sid)]),
               j["ended"]["reason"].string == "taken" {
                let by = j["ended"]["by"].string ?? "Something else"
                self.notice = nil
                self.recovering = false
                self.taken = "\(LiveTV.clean(by)) started on \(Recovery.screen(j["ended"]["where"].string ?? "")). Your plan plays one stream at a time."
                return
            }
            self.session = nil
            if let v = self.vod {
                while let wait = self.recovery.next() {
                    self.notice = Recovery.lost(at: v.start, attempt: self.recovery.tries)
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
                    if Task.isCancelled || self.closed { return }
                    self.error = nil
                    await self.tuneVOD(v, title: request.title, base: base)
                    if self.player != nil { return }
                }
                self.recovering = false
                self.notice = nil
                self.error = Recovery.gaveUp(at: v.start)
                return
            }
            // A channel or a game: the same feed once, then the others in order (best first), saying which.
            let feeds = request.switchable.map(\.id)
            let cur = self.currentFeed ?? request.stream
            let order = [cur] + feeds.filter { $0 != cur }
            for (i, feed) in order.enumerated() {
                let n = (feeds.firstIndex(of: feed) ?? 0) + 1
                self.notice = i == 0 ? "The feed dropped. Trying it again..." : "Switching to Feed \(n)..."
                try? await Task.sleep(nanoseconds: UInt64((i == 0 ? 3 : 1) * 1e9))
                if Task.isCancelled || self.closed { return }
                if let j = try? await RTXAPI(base: base).get("tv/play", [URLQueryItem(name: "stream", value: feed),
                                                                       URLQueryItem(name: "where", value: Self.here)]),
                   let u = j["url"].string, let url = URL(string: u, relativeTo: base)?.absoluteURL {
                    self.session = j["session"].string
                    self.currentFeed = feed
                    self.start(url)
                    return
                }
            }
            self.recovering = false
            self.notice = nil
            self.error = "The channel dropped and no feed came back."
        }
    }

    /// Take it back: the viewer chose to take the plan's one stream from the other screen.
    func takeBack(base: URL?) async {
        taken = nil
        await retry(base: base)
    }

    /// Try again: from the feed last picked (or where On Demand was), not back at the first feed.
    func retry(base: URL?) async {
        guard let request else { return }
        work?.cancel()
        recovering = false
        recovery.reset()
        error = nil
        taken = nil
        teardown()
        let cur = currentFeed ?? request.stream
        let rest = ([request.stream] + request.alt).filter { $0 != cur }
        var again = LiveRequest(stream: cur, title: request.title, alt: rest, vod: vod ?? request.vod, grow: request.grow,
                                rec: request.rec, upgrade: request.upgrade, feeds: request.feeds)
        if vod == nil, let v = request.vod { again.vod = v }
        await tune(again, base: base)
    }
}

/// Full-screen live playback in the system player. The PC stops the channel a few minutes after nobody watches.
/// Other feeds (a game's other feeds, or a channel's spares): Apple TV, in the player's menu with its controls;
/// iPhone, tap the picture and pick Feeds. Nothing of the app's own sits over the playing picture until it is asked for.
struct LivePlayerScreen: View {
    let request: LiveRequest
    @EnvironmentObject private var rtx: RTXServer
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = LivePlayerModel()
    @State private var attempt = 0
    @State private var casting = false
    @State private var castStarted = false
    @State private var choosingFeed = false
    /// iPhone: Close, Feeds and Cast, shown by a tap on the picture (with the system's controls) and gone again
    /// after a few seconds; always there while paused.
    @State private var controls = false
    @State private var hideControls: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player = model.player {
                SystemPlayer(player: player, menu: feedActions, onTap: { toggleControls() }).ignoresSafeArea()
                #if os(iOS)
                if model.paused || controls { closeBar(playing: true).transition(.opacity) }
                #endif
            } else {
                VStack(spacing: S(34)) {
                    Text(request.title).font(.system(size: F(60), weight: .bold)).multilineTextAlignment(.center)
                    if let taken = model.taken {
                        Text(taken).foregroundStyle(Color.white.opacity(0.75)).multilineTextAlignment(.center).frame(maxWidth: W(1300))
                        HStack(spacing: S(40)) {
                            Button("Take it back") { Task { await model.takeBack(base: rtx.base) } }
                            Button("Back") { dismiss() }
                        }
                    } else if let error = model.error {
                        Text(error).foregroundStyle(Color.white.opacity(0.65)).multilineTextAlignment(.center).frame(maxWidth: W(1300))
                        HStack(spacing: S(40)) {
                            Button("Try again") { Task { await model.retry(base: rtx.base) } }
                            Button("Back") { dismiss() }
                        }
                    } else {
                        ProgressView()
                        Text(model.notice ?? "Tuning in on the PC...").foregroundStyle(Color.white.opacity(0.7)).multilineTextAlignment(.center)
                    }
                }
                .padding(S(100))
                #if os(iOS)
                closeBar(playing: false)
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
        .sheet(isPresented: $choosingFeed) {
            FeedSheet(feeds: request.switchable, current: model.currentFeed, name: feedName) { id in
                choosingFeed = false
                controls = false
                Task { await model.switchFeed(id, request: request, base: rtx.base) }
            }
            .presentationDetents([.medium, .large])
        }
        #endif
    }

    /// A tap on the picture shows the buttons (or hides them, like the system's controls); they go by themselves.
    private func toggleControls() {
        hideControls?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { controls.toggle() }
        guard controls else { return }
        hideControls = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { controls = false }
        }
    }

    /// A game: "Feed 1 · 1080p60 (best)", "Feed 2 · not measured yet". A channel: "Feed 1 · main", "Feed 2 · spare".
    private func feedName(_ i: Int, _ f: LiveFeed) -> String {
        let game = !request.feeds.isEmpty
        let what = f.quality ?? (game ? "not measured yet" : (i == 0 ? "main" : "spare"))
        return "Feed \(i + 1) \u{00B7} " + what + (game && i == 0 ? " (best)" : "")
    }

    /// Other feeds in the Apple TV player's menu, shown with its controls; nothing when there is only one feed.
    private var feedActions: [UIAction] {
        let feeds = request.switchable
        guard feeds.count > 1 else { return [] }
        return feeds.enumerated().map { i, f in
            UIAction(title: feedName(i, f), image: UIImage(systemName: f.id == model.currentFeed ? "checkmark" : "antenna.radiowaves.left.and.right")) { _ in
                Task { await model.switchFeed(f.id, request: request, base: rtx.base) }
            }
        }
    }

    #if os(iOS)
    /// Since iOS 26 the system player shows its own Close (and AirPlay) at the top left with its controls, and this bar
    /// only shows with them: so over a picture it leaves Close to the system and sits on the same line, at the right.
    /// While tuning in, and before iOS 26, it has its own Close.
    private func closeBar(playing: Bool) -> some View {
        var systemClose = false
        if #available(iOS 26, *) { systemClose = playing }
        return VStack {
            HStack {
                if !systemClose {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .accessibilityLabel("Close")
                }
                Spacer()
                if request.switchable.count > 1 {
                    Button { choosingFeed = true } label: {
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
            .padding(.top, systemClose ? 6 : 54)  // 6: level with the system's Close and AirPlay
            Spacer()
        }
        .tint(.white)
    }
    #endif
}

#if os(iOS)
/// iPhone: Other feeds, as a list. Picking one switches to it (the PC changes the stream; a few seconds).
struct FeedSheet: View {
    let feeds: [LiveFeed]
    let current: String?
    let name: (Int, LiveFeed) -> String
    let pick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(feeds.enumerated()), id: \.element.id) { i, f in
                        Button { if f.id == current { dismiss() } else { pick(f.id) } } label: {
                            HStack {
                                Label(name(i, f), systemImage: "antenna.radiowaves.left.and.right")
                                Spacer()
                                if f.id == current { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                            }
                        }
                        .accessibilityLabel(name(i, f))
                        .accessibilityAddTraits(f.id == current ? .isSelected : [])
                    }
                } footer: {
                    Text("Switching takes a few seconds: the PC changes the stream. If a feed won't start, the next one plays.")
                }
            }
            .navigationTitle("Other feeds")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(Theme.accent)
    }
}
#endif
