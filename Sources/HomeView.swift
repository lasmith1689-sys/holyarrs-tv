import AVKit
import SwiftUI

/// Muted, looping video behind a hero, with no controls (the trailer that plays when a title is focused).
struct BackgroundVideo: UIViewRepresentable {
    let url: URL
    let cookies: [HTTPCookie]

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var looper: AVPlayerLooper?
        var loaded: URL?
    }

    func makeUIView(context: Context) -> PlayerView {
        let v = PlayerView()
        v.playerLayer.videoGravity = .resizeAspectFill
        v.isUserInteractionEnabled = false
        load(v)
        return v
    }

    func updateUIView(_ v: PlayerView, context: Context) {
        if v.loaded != url { load(v) }
    }

    static func dismantleUIView(_ v: PlayerView, coordinator: ()) {
        v.playerLayer.player?.pause()
        v.playerLayer.player = nil
        v.looper = nil
    }

    private func load(_ v: PlayerView) {
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: [AVURLAssetHTTPCookiesKey: cookies]))
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        v.looper = AVPlayerLooper(player: player, templateItem: item)
        v.playerLayer.player = player
        v.loaded = url
        player.play()
    }
}

/// How many full-screen players are open. Anything that plays by itself in the background (the hero's muted
/// trailers) waits while one is: a trailer starting under a live game used to take over what was playing.
@MainActor
final class FullScreenPlayers: ObservableObject {
    static let shared = FullScreenPlayers()
    @Published private(set) var open = 0
    func began() { open += 1 }
    func ended() { open = max(0, open - 1) }
}

extension View {
    /// Marks a full-screen player: background trailers stop while it is up.
    func fullScreenPlayer() -> some View {
        onAppear { FullScreenPlayers.shared.began() }.onDisappear { FullScreenPlayers.shared.ended() }
    }
}

/// The big picture at the top of Home and a genre's page: a rotating set of titles; the focused one's trailer starts
/// muted after a moment, like Netflix and the Apple TV app.
struct Hero: View {
    let items: [Card]
    /// Home's Find button (opens Search): the quickest way to something new to get or watch.
    var find: (() -> Void)? = nil
    /// Its height at TV size (scaled on iPhone). Home's is shorter, so Continue Watching sits right under it.
    var height: CGFloat = 860
    @EnvironmentObject private var api: HolyArrs
    @State private var index = 0
    @State private var trailer: Trailer?
    @State private var playing: PlayRequest?
    @FocusState private var focused: String?
    @ObservedObject private var players = FullScreenPlayers.shared
    @Environment(\.scenePhase) private var scenePhase
    /// On screen: not on another tab, not under a player, app in front. Only then does it rotate or play trailers.
    @State private var shown = false
    private var active: Bool { shown && players.open == 0 && scenePhase == .active }

    private var item: Card? { items.isEmpty ? nil : items[index % items.count] }

    @ViewBuilder private func heroButtons(_ item: Card, compact: Bool) -> some View {
        HStack(spacing: S(compact ? 24 : 30)) {
            NavigationLink(value: item.route) {
                Label("More info", systemImage: "info.circle").font(.system(size: F(28), weight: .semibold))
                    .lineLimit(1).fixedSize().padding(.horizontal, S(20))
            }
            .buttonStyle(.borderedProminent)
            .focused($focused, equals: "info")
            if let trailer {
                Button {
                    playing = PlayRequest(label: item.name, trailer: trailer.withSound, backdrop: item.backdrop)
                } label: {
                    Label("Trailer", systemImage: "play.rectangle").font(.system(size: F(28), weight: .semibold))
                        .labelStyle(HeroLabel(compact: compact))
                }
                .focused($focused, equals: "trailer")
                .accessibilityLabel("Trailer")
            }
            if items.count > 1 {
                Button {
                    index = (index + 1) % items.count
                } label: {
                    Label("Next", systemImage: "chevron.right").font(.system(size: F(28), weight: .semibold))
                        .labelStyle(HeroLabel(compact: compact))
                }
                .focused($focused, equals: "next")
                .accessibilityLabel("Next title")
            }
            if let find {
                Button(action: find) {
                    Label(Device.isTV ? "Find a movie or show" : "Find", systemImage: "magnifyingglass").font(.system(size: F(28), weight: .semibold))
                        .labelStyle(HeroLabel(compact: compact))
                }
                .focused($focused, equals: "find")
                .accessibilityLabel("Find")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    var body: some View {
        if let item {
            ZStack(alignment: .bottomLeading) {
                Color.black
                    .overlay {
                        ZStack {
                            Artwork(raw: item.backdrop ?? item.poster, width: 1280)
                            if let trailer, active { BackgroundVideo(url: trailer.muted, cookies: api.cookies).transition(.opacity) }
                        }
                    }
                    .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.35), .black.opacity(0.92)], startPoint: .top, endPoint: .bottom)
                LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .leading, endPoint: .center)
                VStack(alignment: .leading, spacing: S(22)) {
                    if let logo = item.logo {
                        Artwork(raw: logo, width: 500, plain: true, fit: true).frame(width: W(620), height: S(200), alignment: .bottomLeading)
                    } else {
                        Text(item.name).font(.system(size: F(80), weight: .heavy)).lineLimit(2).minimumScaleFactor(0.6)
                    }
                    HStack(spacing: S(20)) {
                        if let y = item.year { Text(String(y)) }
                        Text(item.kind == .show ? "Show" : item.kind == .artist ? (item.line ?? "Music") : "Movie")
                        ForEach(item.genres.prefix(3), id: \.self) { Text($0) }
                        if let s = item.status { StatusDot(status: s) }
                    }
                    .font(.title3).foregroundStyle(Color.white.opacity(0.8))
                    .lineLimit(1).minimumScaleFactor(0.6)
                    if let o = item.overview {
                        Text(o).font(.system(size: F(26))).foregroundStyle(Color.white.opacity(0.75))
                            .lineLimit(height < 860 && !Device.isTV ? 2 : 3).frame(maxWidth: W(1100), alignment: .leading)
                    }
                    // The buttons keep one line each: when the full labels don't fit across (an iPhone, larger Text
                    // Size: "More info" was squeezed into a circle, 2026-11-25), Trailer, Next and Find show their
                    // icons only and More info stays a readable pill.
                    ViewThatFits(in: .horizontal) {
                        heroButtons(item, compact: false)
                        heroButtons(item, compact: true)
                    }
                    .tvFocusSection()
                }
                .padding(.horizontal, Theme.sidePadding + S(30))
                .padding(.bottom, S(60))
            }
            .frame(height: S(height))
            .ignoresSafeArea(edges: .horizontal)  // edge to edge, like the Apple TV app's heroes
            .onAppear { shown = true }
            .onDisappear { shown = false }
            .task(id: "\(item.id)|\(active)") {
                trailer = nil
                // Give the picture a moment first; a title skipped past quickly never loads its trailer.
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                guard !Task.isCancelled, active, let tmdb = item.tmdb else { return }
                let t = await Trailer.find(api, kind: item.kind, tmdb: tmdb)
                if !Task.isCancelled { withAnimation(.easeIn(duration: 0.8)) { trailer = t } }
            }
            .task(id: "\(index)|\(active)") {
                // Moves on every 20 s unless the person is on the hero's buttons, and only while it is on screen.
                guard active else { return }
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                if !Task.isCancelled, active, focused == nil, items.count > 1 { index = (index + 1) % items.count }
            }
            .fullScreenCover(item: $playing) { PlayerScreen(request: $0) }
        }
    }
}

/// Home: what is new for this person (GET /home) under a hero of what's trending (GET /explore/head), then Browse
/// (what was the Explore tab: All, Movies, Shows or Music, with the genres). On iPhone, Settings opens from the gear.
/// Home's way into everything (Release 6): one button per tab, under Continue Watching.
/// A hero button's label: icon and title on one line, or the icon alone when the row is short of room.
struct HeroLabel: LabelStyle {
    var compact: Bool
    func makeBody(configuration: Configuration) -> some View {
        if compact {
            configuration.icon.padding(.horizontal, S(8))
        } else {
            HStack(spacing: S(10)) { configuration.icon; configuration.title }.lineLimit(1).fixedSize()
        }
    }
}

struct HomeShortcuts: View {
    let liveTV: Bool
    let open: (String) -> Void
    let downloads: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: S(24)) {
                if liveTV {
                    shortcut("Live & On Demand", "dot.radiowaves.left.and.right") { UserDefaults.standard.set("live", forKey: "tvPage"); open("tv") }
                    shortcut("Guide", "list.bullet.rectangle") { UserDefaults.standard.set("guide", forKey: "tvPage"); open("tv") }
                }
                shortcut("TV Shows", "tv") { open("shows") }
                shortcut("Movies", "film") { open("movies") }
                shortcut("Sports", "sportscourt") { open("sports") }
                shortcut("Downloads", "arrow.down.circle") { downloads() }
            }
            .padding(.horizontal, Theme.sidePadding)
            .padding(.vertical, S(20))
        }
        .tvFocusSection()
    }

    private func shortcut(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.system(size: F(26), weight: .semibold)).padding(.horizontal, S(14)).padding(.vertical, S(8))
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("shortcut-\(title)")
    }
}

struct HomeView: View {
    @EnvironmentObject private var api: HolyArrs
    @AppStorage("tab") private var tab = "home"
    @AppStorage("homeSettings") private var settingsOpen = false
    @EnvironmentObject private var rtx: RTXServer
    /// Release 6: Search (iPhone) and Downloads open from Home (the tabs are the media).
    @State private var searchOpen = false
    @State private var downloadsOpen = false
    /// A saved tab from the old layout (search, downloads): opened from Home once.
    @AppStorage("homeOpen") private var homeOpen = ""
    @State private var hero: [Card] = []
    @State private var rows: [(String, String?, [Card], Bool)] = []
    @State private var approvals = 0
    @State private var stuck = 0
    @State private var loading = true
    @State private var error: String?
    @ObservedObject private var offline = OfflineStore.shared
    /// Apple TV: coming down from the tab bar lands on the first Continue Watching card (the hero when the row is empty).
    @FocusState private var homeFocus: String?
    /// The Apple TV starts on Continue Watching once per launch (not every time Home's tab is passed over).
    private static var startedOnRow = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: S(50)) {
                Hero(items: hero, find: { if Device.isTV { tab = "search" } else { searchOpen = true } }, height: Device.isTV ? 600 : 700)
                // No hero (HolyArrs not answering, or still loading): keep the rest clear of the tab bar.
                if hero.isEmpty { Color.clear.frame(height: Device.isTV ? 150 : S(260)) }
                ConnectionLine()
                ContinueRow(focus: $homeFocus)
                HomeShortcuts(liveTV: rtx.liveTV, open: { tab = $0 }, downloads: { downloadsOpen = true })
                SubscriptionWarning()
                if approvals > 0 || stuck > 0 {
                    AdaptiveStack(spacing: S(30)) {
                        if approvals > 0 { Label("\(approvals) waiting for your OK", systemImage: "hand.raised") }
                        if stuck > 0 { Label("\(stuck) need a decision", systemImage: "exclamationmark.triangle") }
                        Text("See Requests in Downloads").foregroundStyle(Theme.dim)
                    }
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, Theme.sidePadding)
                }
                #if os(iOS)
                if !offline.items.isEmpty {
                    NavigationLink { OfflineView() } label: {
                        Label("Downloaded on this iPhone: \(offline.items.count)", systemImage: "arrow.down.circle.fill")
                    }
                    .font(.title3)
                    .padding(.horizontal, Theme.sidePadding)
                }
                #endif
                ForEach(rows.indices, id: \.self) { i in
                    CardRow(title: rows[i].0, subtitle: rows[i].1, cards: rows[i].2, wide: rows[i].3)
                }
                if rows.isEmpty { LoadState(loading: loading, error: error, empty: "Nothing new in the Library yet. Browse below, or use Search.") { Task { await load() } } }
                BrowseSection()
            }
            .padding(.bottom, S(80))
        }
        #if os(tvOS)
        .defaultFocus($homeFocus, ContinueRow.firstFocus, priority: .userInitiated)
        .task {
            // At launch, focus moves from the tab bar to the first Continue Watching card (if there is one).
            guard !HomeView.startedOnRow else { return }
            HomeView.startedOnRow = true
            try? await Task.sleep(nanoseconds: 600_000_000)
            homeFocus = ContinueRow.firstFocus
        }
        #endif
        .ignoresSafeArea(edges: .top)
        .refreshable { await load() }
        .task { await load() }
        #if os(iOS)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { searchOpen = true } label: { Image(systemName: "magnifyingglass") }
                    .accessibilityLabel("Search")
                Button { downloadsOpen = true } label: { Image(systemName: "arrow.down.circle") }
                    .accessibilityLabel("Downloads")
                Button { settingsOpen = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
            }
        }
        .navigationDestination(isPresented: $settingsOpen) { SettingsView() }
        .navigationDestination(isPresented: $searchOpen) { SearchView() }
        #endif
        // Downloads (with Requests and Calendar) opens from Home on both: the shortcut, the iPhone top bar, or a
        // saved tab from the old layout. Apple TV's tab bar holds at most seven tabs, so Downloads isn't one.
        .onAppear {
            if homeOpen == "search", !Device.isTV { searchOpen = true } else if homeOpen == "downloads" { downloadsOpen = true }
            homeOpen = ""
        }
        .navigationDestination(isPresented: $downloadsOpen) { RequestsHub(canManage: api.me?.canManage ?? false) }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        async let homeJ = api.get("home")
        async let headJ = api.get("explore/head", ["type": "all", "tz": TimeZone.current.identifier])
        do {
            let h = try await homeJ
            var out: [(String, String?, [Card], Bool)] = []
            func cards(_ key: String) -> [Card] { h[key].array.map { Card(home: $0) } }
            for row in h["rows"].array.compactMap(\.string) {
                switch row {
                case "arrived": out.append(("Just arrived", "New in the Library this fortnight", cards("arrived"), true))
                case "new_season": out.append(("New seasons", nil, cards("new_seasons"), true))
                case "following": out.append(("Following", nil, cards("following"), true))
                case "soon": out.append(("Coming soon", nil, cards("soon"), true))
                default: break
                }
            }
            rows = out
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        if let head = try? await headJ {
            hero = head["hero"].array.map { Card(provider: $0, row: "hero") }  // Browse, below, shows the rows
        }
        if api.me?.canApprove == true, let a = try? await api.get("asks", ["state": "asked", "limit": "1"]) {
            approvals = a["counts"]["pending"].int ?? a["total"].int ?? 0
        }
        if api.me?.canManage == true, let d = try? await api.get("needs-decision") {
            stuck = d["count"].int ?? 0
        }
    }
}
