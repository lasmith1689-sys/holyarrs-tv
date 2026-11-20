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

/// The big picture at the top of Home and Explore: a rotating set of titles; the focused one's trailer starts
/// muted after a moment, like Netflix and the Apple TV app.
struct Hero: View {
    let items: [Card]
    @EnvironmentObject private var api: HolyArrs
    @State private var index = 0
    @State private var trailer: Trailer?
    @State private var playing: PlayRequest?
    @FocusState private var focused: String?

    private var item: Card? { items.isEmpty ? nil : items[index % items.count] }

    var body: some View {
        if let item {
            ZStack(alignment: .bottomLeading) {
                Color.black
                    .overlay {
                        ZStack {
                            Artwork(raw: item.backdrop ?? item.poster, width: 1280)
                            if let trailer { BackgroundVideo(url: trailer.muted, cookies: api.cookies).transition(.opacity) }
                        }
                    }
                    .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.35), .black.opacity(0.92)], startPoint: .top, endPoint: .bottom)
                LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .leading, endPoint: .center)
                VStack(alignment: .leading, spacing: 22) {
                    if let logo = item.logo {
                        Artwork(raw: logo, width: 500, plain: true, fit: true).frame(width: 620, height: 200, alignment: .bottomLeading)
                    } else {
                        Text(item.name).font(.system(size: 80, weight: .heavy)).lineLimit(2).minimumScaleFactor(0.6)
                    }
                    HStack(spacing: 20) {
                        if let y = item.year { Text(String(y)) }
                        Text(item.kind == .show ? "Show" : "Movie")
                        ForEach(item.genres.prefix(3), id: \.self) { Text($0) }
                        if let s = item.status { StatusDot(status: s) }
                    }
                    .font(.title3).foregroundStyle(Color.white.opacity(0.8))
                    if let o = item.overview {
                        Text(o).font(.system(size: 26)).foregroundStyle(Color.white.opacity(0.75)).lineLimit(3).frame(maxWidth: 1100, alignment: .leading)
                    }
                    HStack(spacing: 30) {
                        NavigationLink(value: item.route) {
                            Label("More info", systemImage: "info.circle").font(.system(size: 28, weight: .semibold)).padding(.horizontal, 20)
                        }
                        .buttonStyle(.borderedProminent)
                        .focused($focused, equals: "info")
                        if let trailer {
                            Button {
                                playing = PlayRequest(label: item.name, trailer: trailer.withSound, backdrop: item.backdrop)
                            } label: {
                                Label("Trailer", systemImage: "play.rectangle").font(.system(size: 28, weight: .semibold))
                            }
                            .focused($focused, equals: "trailer")
                        }
                        if items.count > 1 {
                            Button {
                                index = (index + 1) % items.count
                            } label: {
                                Label("Next", systemImage: "chevron.right").font(.system(size: 28, weight: .semibold))
                            }
                            .focused($focused, equals: "next")
                            .accessibilityLabel("Next title")
                        }
                    }
                    .focusSection()
                }
                .padding(.horizontal, Theme.sidePadding + 30)
                .padding(.bottom, 60)
            }
            .frame(height: 860)
            .task(id: item.id) {
                trailer = nil
                // Give the picture a moment first; a title skipped past quickly never loads its trailer.
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                guard !Task.isCancelled, let tmdb = item.tmdb else { return }
                let t = await Trailer.find(api, kind: item.kind, tmdb: tmdb)
                if !Task.isCancelled { withAnimation(.easeIn(duration: 0.8)) { trailer = t } }
            }
            .task(id: index) {
                // Moves on every 20 s unless the person is on the hero's buttons.
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                if !Task.isCancelled, focused == nil, items.count > 1 { index = (index + 1) % items.count }
            }
            .fullScreenCover(item: $playing) { PlayerScreen(request: $0) }
        }
    }
}

/// Home: what is new for this person (GET /home) under a hero of what's trending (GET /explore/head).
struct HomeView: View {
    @EnvironmentObject private var api: HolyArrs
    @State private var hero: [Card] = []
    @State private var rows: [(String, String?, [Card], Bool)] = []
    @State private var approvals = 0
    @State private var stuck = 0
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 50) {
                Hero(items: hero)
                if approvals > 0 || stuck > 0 {
                    HStack(spacing: 30) {
                        if approvals > 0 { Label("\(approvals) waiting for your OK", systemImage: "hand.raised") }
                        if stuck > 0 { Label("\(stuck) need a decision", systemImage: "exclamationmark.triangle") }
                        Text("See Requests").foregroundStyle(Theme.dim)
                    }
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, Theme.sidePadding)
                }
                ForEach(rows.indices, id: \.self) { i in
                    CardRow(title: rows[i].0, subtitle: rows[i].1, cards: rows[i].2, wide: rows[i].3)
                }
                if rows.isEmpty { LoadState(loading: loading, error: error, empty: "Nothing new yet. Ask for something in Explore or Search.") { Task { await load() } } }
            }
            .padding(.bottom, 80)
        }
        .ignoresSafeArea(edges: .top)
        .task { await load() }
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
                case "following": out.append(("Shows you follow", nil, cards("following"), false))
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
            hero = head["hero"].array.map { Card(provider: $0, row: "hero") }
            // Home ends with a few of Explore's rows, so it is never empty on a new install.
            let extra = head["head"].array.prefix(4).map { r in
                (r["title"].string ?? "", r["subtitle"].string, r["items"].array.map { Card(provider: $0, row: r["id"].string ?? "") }, true)
            }
            rows += extra
        }
        if api.me?.canApprove == true, let a = try? await api.get("asks", ["state": "asked", "limit": "1"]) {
            approvals = a["counts"]["pending"].int ?? a["total"].int ?? 0
        }
        if api.me?.canManage == true, let d = try? await api.get("needs-decision") {
            stuck = d["count"].int ?? 0
        }
    }
}
