import SwiftUI

/// One row of Explore as the server built it.
struct ExploreRow: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let cards: [Card]
    let wide: Bool

    init(_ r: JSON, music: Bool = false) {
        id = r["id"].string ?? UUID().uuidString
        title = r["title"].string ?? ""
        subtitle = r.first("subtitle", "reason").string
        cards = r["items"].array.map { music ? Card(music: $0, row: r["id"].string ?? "") : Card(provider: $0, row: r["id"].string ?? "") }
        // HolyArrs draws movie and show rows as wide backdrop cards; music rows stay square-ish posters.
        wide = !music && (r["wide"].bool || cards.allSatisfy { $0.backdrop != nil })
    }
}

/// Explore: All, Movies, Shows or Music, each the page HolyArrs builds for this person (head rows, then more
/// rows by pages), with its genre tiles.
struct ExploreView: View {
    enum Kind: String, CaseIterable, Identifiable {
        case all = "All", movies = "Movies", shows = "Shows", music = "Music"
        var id: String { rawValue }
        var param: String { self == .all ? "all" : rawValue.lowercased() }
    }

    @EnvironmentObject private var api: HolyArrs
    @AppStorage("exploreKind") private var kind: Kind = .all
    @State private var hero: [Card] = []
    @State private var rows: [ExploreRow] = []
    @State private var genres: [JSON] = []
    @State private var page = 0
    @State private var more = false
    @State private var cursor: String?
    @State private var loading = true
    @State private var error: String?
    @State private var building = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: S(50)) {
                Picker("Show", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: W(900))
                .padding(.horizontal, Theme.sidePadding)
                .padding(.top, S(20))
                .tvFocusSection()

                Hero(items: hero)
                if building { Text("HolyArrs is still putting your page together. More rows appear in a moment.").foregroundStyle(Theme.dim).padding(.horizontal, Theme.sidePadding) }
                ForEach(rows.prefix(2)) { CardRow(title: $0.title, subtitle: $0.subtitle, cards: $0.cards, wide: $0.wide) }
                if !genres.isEmpty { GenreTiles(type: kind.param, genres: genres) }
                ForEach(rows.dropFirst(2)) { CardRow(title: $0.title, subtitle: $0.subtitle, cards: $0.cards, wide: $0.wide) }
                if more || cursor != nil {
                    Button("More rows") { Task { await loadMore() } }
                        .padding(.horizontal, Theme.sidePadding)
                        .onAppear { Task { await loadMore() } }
                }
                if rows.isEmpty { LoadState(loading: loading, error: error, empty: "Nothing to show yet.") { Task { await load() } } }
            }
            .padding(.bottom, S(80))
        }
        .refreshable { await load() }
        .task(id: kind) { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        rows = []
        hero = []
        genres = []
        page = 0
        more = false
        cursor = nil
        do {
            if kind == .music {
                let j = try await api.get("explore/music")
                hero = ([j["hero"]] + j["hero_alts"].array).filter { !$0.isNull }.map { Card(music: $0, row: "hero") }
                rows = j["rows"].array.map { ExploreRow($0, music: true) }.filter { !$0.cards.isEmpty }
                cursor = j["next"].string
                building = j["partial"].bool
            } else {
                async let headJ = api.get("explore/head", ["type": kind.param, "tz": TimeZone.current.identifier])
                async let genreJ = api.get("explore/genre-row", ["type": kind.param])
                let h = try await headJ
                hero = h["hero"].array.map { Card(provider: $0, row: "hero") }
                rows = h["head"].array.map { ExploreRow($0) }.filter { !$0.cards.isEmpty }
                building = h["building"].bool
                more = (h["tail_rows"].int ?? 0) > 0 || (h["tail_cap"].int ?? 0) > 0
                genres = (try? await genreJ)?["genres"].array ?? []
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadMore() async {
        do {
            if kind == .music {
                guard let c = cursor else { return }
                cursor = nil
                let j = try await api.get("explore/music", ["cursor": c])
                rows += j["rows"].array.map { ExploreRow($0, music: true) }.filter { !$0.cards.isEmpty }
                cursor = j["next"].string
            } else {
                guard more else { return }
                more = false
                let j = try await api.get("explore/tail", ["type": kind.param, "page": String(page), "tz": TimeZone.current.identifier])
                let seen = Set(rows.map(\.id))
                rows += j["rows"].array.map { ExploreRow($0) }.filter { !$0.cards.isEmpty && !seen.contains($0.id) }
                page += 1
                more = j["more"].bool
            }
        } catch {
            // A failed page leaves what is shown; the next scroll tries again.
            more = kind != .music
        }
    }
}

/// "Browse by genre": wide tiles that open the genre's own page.
struct GenreTiles: View {
    let type: String
    let genres: [JSON]

    var body: some View {
        VStack(alignment: .leading, spacing: S(18)) {
            Text("Browse by genre").font(.system(size: F(34), weight: .bold)).padding(.horizontal, Theme.sidePadding)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: S(40)) {
                    ForEach(genres.indices, id: \.self) { i in
                        let g = genres[i]
                        let gType = g["both"].bool ? "all" : (g["kind"].string == "show" ? "shows" : (type == "all" ? "movies" : type))
                        NavigationLink(value: Route.genre(type: gType, id: g["id"].int ?? 0, name: g["name"].string ?? "")) {
                            GenreTile(name: g["name"].string ?? "", backdrop: g["backdrop"].string)
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

struct GenreTile: View {
    let name: String
    let backdrop: String?
    @Environment(\.isFocused) private var focused

    var body: some View {
        ZStack {
            Artwork(raw: backdrop, width: 780)
            Color.black.opacity(focused ? 0.25 : 0.5)
            Text(name).font(.system(size: F(34), weight: .heavy)).shadow(radius: S(8))
        }
        .frame(width: W(400), height: S(200))
        .clipShape(RoundedRectangle(cornerRadius: S(14), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: S(14), style: .continuous).stroke(Color.white.opacity(focused ? 0.9 : 0.08), lineWidth: focused ? 4 : 1))
        .scaleEffect(focused ? 1.06 : 1)
        .animation(.easeOut(duration: 0.18), value: focused)
        .accessibilityLabel(name)
    }
}

/// A genre's page: its hero, then Trending, Best new, Because you have and mood rows.
struct GenreView: View {
    let type: String
    let genre: Int
    let name: String
    @EnvironmentObject private var api: HolyArrs
    @State private var hero: [Card] = []
    @State private var rows: [ExploreRow] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: S(50)) {
                Hero(items: hero)
                ForEach(rows) { CardRow(title: $0.title, subtitle: $0.subtitle, cards: $0.cards, wide: $0.wide) }
                if rows.isEmpty { LoadState(loading: loading, error: error, empty: "Nothing in \(name) yet.") }
            }
            .padding(.bottom, S(80))
        }
        .ignoresSafeArea(edges: .top)
        .task {
            defer { loading = false }
            do {
                let j = try await api.get("explore/genre", ["type": type, "genre": String(genre)])
                hero = j["hero"].array.map { Card(provider: $0, row: "ghero") }
                rows = j["rows"].array.map { ExploreRow($0) }.filter { !$0.cards.isEmpty }
            } catch { self.error = error.localizedDescription }
        }
    }
}
