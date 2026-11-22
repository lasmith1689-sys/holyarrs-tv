import SwiftUI

// On Demand: the IPTV plan's films and series, from the PC (rtx-upscale-stream: src/ondemand.py), played through
// the PC like a live channel (src/tvstream.py "vod" sessions), so the app never sees the login. Where each title was
// left is kept on the PC with the films' positions ("od:movie-<id>", "od:episode-<id>"), so every screen resumes it.

/// A film or series from the plan.
struct ODItem: Identifiable, Hashable {
    let id: String
    let kind: String  // "movie" or "series"
    let title: String
    let year: Int?
    let poster: String?
    let rating: Double?
    let ext: String

    init?(_ j: JSON) {
        guard let id = j["id"].string, let title = j["title"].string else { return nil }
        self.id = id
        kind = j["kind"].string ?? "movie"
        self.title = title
        year = j["year"].int
        poster = j["poster"].string
        rating = j["rating"].double
        ext = j["ext"].string ?? "mp4"
    }

    var route: ODRoute { kind == "series" ? .series(self) : .movie(self) }
    var line: String {
        [year.map(String.init), rating.map { String(format: "\u{2605} %.1f", $0) }].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }
}

struct ODRow: Identifiable, Hashable {
    let id: String
    let title: String
    let items: [ODItem]
}

struct ODCategory: Identifiable, Hashable {
    let id: String
    let name: String
    let count: Int
}

enum ODRoute: Hashable {
    case movie(ODItem)
    case series(ODItem)
    case categories(String)
    case category(kind: String, category: ODCategory)
    case search

    @MainActor @ViewBuilder var page: some View {
        switch self {
        case let .movie(item): ODMoviePage(item: item)
        case let .series(item): ODSeriesPage(item: item)
        case let .categories(kind): ODCategoriesView(kind: kind)
        case let .category(kind, category): ODCategoryView(kind: kind, category: category)
        case .search: ODSearchView()
        }
    }
}

enum OnDemand {
    /// Where On Demand titles were left, from the PC (key "movie-<id>" / "episode-<id>" to seconds).
    static func positions(_ base: URL?) async -> [String: Double] {
        guard let base, let j = try? await RTXAPI(base: base).get("positions") else { return [:] }
        var out: [String: Double] = [:]
        for (k, v) in j["positions"].object where k.hasPrefix("od:") {
            if let t = v["t"].double { out[String(k.dropFirst(3))] = t }
        }
        return out
    }

    static func minutes(_ s: Double) -> String {
        let m = max(0, Int(s / 60))
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }
}

/// A poster that lifts when focused, with the title and year underneath.
struct ODPosterCell: View {
    let item: ODItem
    var width: CGFloat = S(250)
    @Environment(\.isFocused) private var focused

    var body: some View {
        VStack(alignment: .leading, spacing: S(14)) {
            Artwork(raw: item.poster, width: 342, title: item.title, subtitle: item.year.map(String.init))
                .frame(width: width, height: width * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: S(14), style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: S(14), style: .continuous)
                    .stroke(Color.white.opacity(focused ? 0.9 : 0.08), lineWidth: focused ? 4 : 1))
                .shadow(color: .black.opacity(focused ? 0.7 : 0.35), radius: focused ? 30 : 10, y: focused ? 20 : 6)
                .scaleEffect(focused ? 1.08 : 1.0)
            VStack(alignment: .leading, spacing: S(4)) {
                Text(item.title).font(.system(size: F(24), weight: .semibold)).lineLimit(1)
                Text(item.line.isEmpty ? " " : item.line).font(.system(size: F(21))).foregroundStyle(Theme.dim).lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
            .foregroundStyle(focused ? Color.white : Color.white.opacity(0.75))
            .offset(y: focused ? S(14) : 0)
        }
        .animation(.easeOut(duration: 0.18), value: focused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.year.map { "\(item.title), \($0)" } ?? item.title)
    }
}

struct ODItemRow: View {
    let title: String
    let items: [ODItem]

    var body: some View {
        VStack(alignment: .leading, spacing: S(18)) {
            Text(title).font(.system(size: F(34), weight: .bold)).padding(.horizontal, Theme.sidePadding)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: S(46)) {
                    ForEach(items) { item in
                        NavigationLink(value: item.route) { ODPosterCell(item: item) }.buttonStyle(QuietButtonStyle())
                    }
                }
                .padding(.vertical, S(30))
                .padding(.horizontal, Theme.sidePadding)
            }
            .tvFocusSection()
        }
    }
}

struct ODGrid: View {
    let items: [ODItem]
    private let columns = Device.isTV
        ? Array(repeating: GridItem(.fixed(250), spacing: 46, alignment: .top), count: 6)
        : [GridItem(.adaptive(minimum: S(250)), spacing: S(46), alignment: .top)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: S(60)) {
            ForEach(items) { item in
                NavigationLink(value: item.route) { ODPosterCell(item: item) }.buttonStyle(QuietButtonStyle())
            }
        }
        .tvFocusSection()
    }
}

/// The On Demand half of the TV tab: rows (new releases, top films, new series, IMDb Top 250 and more), then the
/// plan's own categories.
struct OnDemandRows: View {
    @EnvironmentObject private var rtx: RTXServer
    @State private var rows: [ODRow] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: S(46)) {
            ForEach(rows) { r in ODItemRow(title: r.title, items: r.items) }
            if rows.isEmpty {
                LoadState(loading: loading, error: error, empty: "Nothing On Demand yet.", retry: { Task { await load() } })
            } else {
                AdaptiveStack(spacing: S(30)) {
                    NavigationLink(value: ODRoute.categories("movie")) { Label("Film categories", systemImage: "film") }
                    NavigationLink(value: ODRoute.categories("series")) { Label("Series categories", systemImage: "tv") }
                }
                .font(.system(size: F(28), weight: .semibold))
                .padding(.horizontal, Theme.sidePadding)
                .tvFocusSection()
            }
        }
        .task(id: rtx.address) { await load() }
    }

    private func load() async {
        defer { loading = false }
        guard let base = rtx.base else { error = "The PC's address isn't set. Open Settings."; return }
        do {
            let j = try await RTXAPI(base: base).get("tv/ondemand")
            rows = j["rows"].array.compactMap { r in
                let items = r["items"].array.compactMap(ODItem.init)
                guard let id = r["id"].string, !items.isEmpty else { return nil }
                return ODRow(id: id, title: r["title"].string ?? id, items: items)
            }
            error = nil
        } catch {
            self.error = "Couldn't reach On Demand on the PC."
        }
    }
}

/// A film: its picture, details and Play (or Resume and Start over).
struct ODMoviePage: View {
    let item: ODItem
    @EnvironmentObject private var rtx: RTXServer
    @State private var info: JSON = .null
    @State private var resume: Double?
    @State private var watching: LiveRequest?

    private var duration: Double? { info["duration_s"].double }

    var body: some View {
        ZStack {
            BlurredArt(raw: info["backdrop"].string ?? item.poster)
            ScrollView {
                AdaptiveStack(tvAlignment: .top, spacing: S(60)) {
                    Artwork(raw: item.poster, width: 500, title: item.title)
                        .frame(width: S(400), height: S(600))
                        .clipShape(RoundedRectangle(cornerRadius: S(18), style: .continuous))
                    VStack(alignment: .leading, spacing: S(24)) {
                        Text(item.title).font(.system(size: F(64), weight: .bold)).lineLimit(2).minimumScaleFactor(0.6)
                        Text(meta).font(.system(size: F(26))).foregroundStyle(Theme.dim)
                        if let plot = info["plot"].string {
                            Text(plot).font(.system(size: F(26))).lineLimit(6).frame(maxWidth: W(1100), alignment: .leading)
                        }
                        if let cast = info["cast"].string {
                            Text(cast).font(.system(size: F(22))).foregroundStyle(Theme.dim).lineLimit(2).frame(maxWidth: W(1100), alignment: .leading)
                        }
                        HStack(spacing: S(30)) {
                            if let resume {
                                Button { play(resume) } label: {
                                    Label("Resume \u{00B7} \(OnDemand.minutes(resume)) in", systemImage: "play.fill")
                                }
                                Button { play(0) } label: { Label("Start over", systemImage: "backward.end.fill") }
                            } else {
                                Button { play(0) } label: { Label("Play", systemImage: "play.fill") }
                            }
                        }
                        .tvFocusSection()
                        Text("Plays through your PC. Your plan plays one stream at a time, so this stops live TV on any other screen.")
                            .font(.system(size: F(20))).foregroundStyle(Theme.dim).frame(maxWidth: W(1100), alignment: .leading)
                    }
                }
                .padding(Theme.sidePadding)
            }
        }
        .task {
            guard let base = rtx.base else { return }
            async let pos = OnDemand.positions(base)
            info = (try? await RTXAPI(base: base).get("tv/ondemand/movie", [URLQueryItem(name: "id", value: item.id)])) ?? .null
            let p = await pos
            resume = p["movie-\(item.id)"]
        }
        .fullScreenCover(item: $watching, onDismiss: {
            Task { resume = await OnDemand.positions(rtx.base)["movie-\(item.id)"] }
        }) { LivePlayerScreen(request: $0) }
    }

    private var meta: String {
        [item.year.map(String.init), duration.map { OnDemand.minutes($0) }, info["genre"].string,
         item.rating.map { String(format: "\u{2605} %.1f", $0) }].compactMap { $0 }.joined(separator: "  \u{00B7}  ")
    }

    private func play(_ t: Double) {
        watching = LiveRequest(stream: item.id, title: item.title,
                               vod: VODRef(kind: "movie", id: item.id, ext: info["ext"].string ?? item.ext, start: t, duration: duration))
    }
}

/// A series: seasons picked at the top, its episodes underneath, each resuming where it was left.
struct ODSeriesPage: View {
    let item: ODItem
    @EnvironmentObject private var rtx: RTXServer
    @State private var info: JSON = .null
    @State private var season = 0
    @State private var resume: [String: Double] = [:]
    @State private var loading = true
    @State private var watching: LiveRequest?

    private var seasons: [JSON] { info["seasons"].array }

    var body: some View {
        ZStack {
            BlurredArt(raw: info["backdrop"].string ?? item.poster)
            ScrollView {
                VStack(alignment: .leading, spacing: S(36)) {
                    AdaptiveStack(tvAlignment: .top, spacing: S(50)) {
                        Artwork(raw: item.poster, width: 342, title: item.title)
                            .frame(width: S(260), height: S(390))
                            .clipShape(RoundedRectangle(cornerRadius: S(16), style: .continuous))
                        VStack(alignment: .leading, spacing: S(18)) {
                            Text(item.title).font(.system(size: F(60), weight: .bold)).lineLimit(2).minimumScaleFactor(0.6)
                            Text(item.line).font(.system(size: F(24))).foregroundStyle(Theme.dim)
                            if let plot = info["plot"].string {
                                Text(plot).font(.system(size: F(24))).lineLimit(5).frame(maxWidth: W(1100), alignment: .leading)
                            }
                        }
                    }
                    if seasons.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: S(20)) {
                                ForEach(seasons.indices, id: \.self) { i in
                                    Button("Season \(seasons[i]["season"].int ?? i + 1)") { season = i }
                                        .tint(i == season ? Theme.accent : nil)
                                }
                            }
                            .padding(.vertical, S(10))
                        }
                        .tvFocusSection()
                    }
                    if seasons.indices.contains(season) {
                        LazyVStack(alignment: .leading, spacing: S(14)) {
                            ForEach(seasons[season]["episodes"].array.indices, id: \.self) { i in
                                episode(seasons[season]["episodes"][i], season: seasons[season]["season"].int ?? season + 1)
                            }
                        }
                        .tvFocusSection()
                    } else {
                        LoadState(loading: loading, error: nil, empty: "No episodes listed for this series.")
                    }
                }
                .padding(Theme.sidePadding)
            }
        }
        .task {
            guard let base = rtx.base else { return }
            async let pos = OnDemand.positions(base)
            info = (try? await RTXAPI(base: base).get("tv/ondemand/series", [URLQueryItem(name: "id", value: item.id)])) ?? .null
            resume = await pos
            loading = false
        }
        .fullScreenCover(item: $watching, onDismiss: { Task { resume = await OnDemand.positions(rtx.base) } }) {
            LivePlayerScreen(request: $0)
        }
    }

    private func episode(_ e: JSON, season s: Int) -> some View {
        let id = e["id"].string ?? ""
        let n = e["episode"].int ?? 0
        let at = resume["episode-\(id)"]
        let title = e["title"].string ?? "Episode \(n)"
        return Button {
            watching = LiveRequest(stream: id, title: "\(item.title) \u{00B7} S\(s) E\(n)",
                                   vod: VODRef(kind: "episode", id: id, ext: e["ext"].string ?? "mp4", start: at ?? 0,
                                               duration: e["duration_s"].double))
        } label: {
            ODEpisodeRow(number: n, title: title, plot: e["plot"].string, still: e["still"].string,
                         detail: [e["duration_s"].double.map { OnDemand.minutes($0) }, at.map { "Resume at \(OnDemand.minutes($0))" }]
                            .compactMap { $0 }.joined(separator: " \u{00B7} "))
        }
        .buttonStyle(QuietButtonStyle())
    }
}

struct ODEpisodeRow: View {
    let number: Int
    let title: String
    let plot: String?
    let still: String?
    let detail: String
    @Environment(\.isFocused) private var focused

    var body: some View {
        HStack(alignment: .top, spacing: S(28)) {
            Artwork(raw: still, width: 300, title: still == nil ? "\(number)" : "")
                .frame(width: S(300), height: S(169))
                .clipShape(RoundedRectangle(cornerRadius: S(12), style: .continuous))
            VStack(alignment: .leading, spacing: S(8)) {
                Text("\(number). \(title)").font(.system(size: F(28), weight: .semibold)).lineLimit(2)
                if !detail.isEmpty { Text(detail).font(.system(size: F(22))).foregroundStyle(Theme.dim) }
                if let plot { Text(plot).font(.system(size: F(22))).foregroundStyle(Theme.dim).lineLimit(2) }
            }
            Spacer(minLength: 0)
        }
        .padding(S(18))
        .background(Color.white.opacity(focused ? 0.18 : 0.06), in: RoundedRectangle(cornerRadius: S(16), style: .continuous))
        .scaleEffect(focused ? 1.02 : 1)
        .animation(.easeOut(duration: 0.15), value: focused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Episode \(number), \(title)")
    }
}

/// The plan's own film or series categories.
struct ODCategoriesView: View {
    let kind: String
    @EnvironmentObject private var rtx: RTXServer
    @State private var categories: [ODCategory] = []
    @State private var loading = true

    var body: some View {
        ZStack {
            Backdrop()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: S(14)) {
                    Text(kind == "series" ? "Series categories" : "Film categories")
                        .font(.system(size: F(48), weight: .bold)).padding(.bottom, S(16))
                    ForEach(categories) { c in
                        NavigationLink(value: ODRoute.category(kind: kind, category: c)) {
                            LiveListRow(title: c.name, detail: "\(c.count)", chevron: true)
                        }
                        .buttonStyle(QuietButtonStyle())
                    }
                    if categories.isEmpty { LoadState(loading: loading, error: nil, empty: "No categories.") }
                }
                .padding(.horizontal, Theme.sidePadding)
                .padding(.vertical, S(40))
            }
        }
        .task {
            defer { loading = false }
            guard let base = rtx.base,
                  let j = try? await RTXAPI(base: base).get("tv/ondemand/categories", [URLQueryItem(name: "kind", value: kind)]) else { return }
            categories = j["categories"].array.compactMap { c in
                guard let id = c["id"].string, let name = c["name"].string else { return nil }
                return ODCategory(id: id, name: LiveTV.clean(name).capitalized, count: c["count"].int ?? 0)
            }
        }
    }
}

struct ODCategoryView: View {
    let kind: String
    let category: ODCategory
    @EnvironmentObject private var rtx: RTXServer
    @State private var items: [ODItem] = []
    @State private var loading = true

    var body: some View {
        ZStack {
            Backdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: S(30)) {
                    Text(category.name).font(.system(size: F(48), weight: .bold))
                    ODGrid(items: items)
                    if items.isEmpty { LoadState(loading: loading, error: nil, empty: "Nothing here right now.") }
                }
                .padding(.horizontal, Theme.sidePadding)
                .padding(.vertical, S(40))
            }
        }
        .task {
            defer { loading = false }
            guard let base = rtx.base,
                  let j = try? await RTXAPI(base: base).get("tv/ondemand/category", [URLQueryItem(name: "kind", value: kind),
                                                                                     URLQueryItem(name: "cat", value: category.id),
                                                                                     URLQueryItem(name: "limit", value: "300")]) else { return }
            items = j["items"].array.compactMap(ODItem.init)
        }
    }
}

/// Every film and series in the plan, by name.
struct ODSearchView: View {
    @EnvironmentObject private var rtx: RTXServer
    @State private var query = ""
    @State private var items: [ODItem] = []
    @State private var loading = false

    var body: some View {
        ZStack {
            Backdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: S(30)) {
                    Text(query.isEmpty ? "Search On Demand" : "On Demand matching \u{201C}\(query)\u{201D}")
                        .font(.system(size: F(48), weight: .bold))
                    ODGrid(items: items)
                    if items.isEmpty, !query.isEmpty { LoadState(loading: loading, error: nil, empty: "Nothing by that name.") }
                }
                .padding(.horizontal, Theme.sidePadding)
                .padding(.vertical, S(40))
            }
        }
        #if os(iOS)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Films and series")
        #else
        .searchable(text: $query, prompt: "Films and series")
        #endif
        .task(id: query) {
            guard !query.isEmpty else { items = []; return }
            try? await Task.sleep(nanoseconds: 400_000_000)  // wait for typing to pause
            guard !Task.isCancelled, let base = rtx.base else { return }
            loading = true
            defer { loading = false }
            if let j = try? await RTXAPI(base: base).get("tv/ondemand/search", [URLQueryItem(name: "q", value: query)]) {
                items = j["items"].array.compactMap(ODItem.init)
            }
        }
    }
}
