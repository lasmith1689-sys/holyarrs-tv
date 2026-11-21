import SwiftUI

/// Everything a title page shows, gathered from up to three routes: the Library title (GET /titles/{id}),
/// TMDB's page through HolyArrs (GET /metadata/{kind}/{tmdb}) and the ask state (GET /titles/lookup or
/// /shows/lookup).
struct TitleInfo {
    var kind: Card.Kind
    var name: String
    var year: Int?
    var overview: String?
    var poster: String?
    var backdrop: String?
    var logo: String?
    var genres: [String] = []
    var runtime: Int?
    var rating: String?
    var network: String?
    var tmdb: String?
    var titleId: Int?
    var neverAdd = false
    var stateLabel: String?
    var quality: String?
    var myAsk: (id: Int, label: String, state: String)?
    var askLabel: String?
    var cast: [CastMember] = []
    var similar: [Card] = []
    var collection: (name: String, parts: [Card])?
    var seasons: [Season] = []
    var moods: [String] = []

    var inLibrary: Bool { titleId != nil }
}

struct CastMember: Hashable {
    let id: String?
    let name: String
    let role: String?
    let image: String?
}

struct Season: Hashable, Identifiable {
    let number: Int
    let name: String
    let episodes: Int
    var have: Int? = nil
    var missing: Int? = nil
    var year: Int? = nil
    var id: Int { number }
}

struct EpisodeRow: Hashable, Identifiable {
    let n: Int
    let name: String
    let line: String
    var state: String? = nil
    var still: String? = nil
    var id: Int { n }
}

struct TitlePage: View {
    let ref: TitleRef
    @EnvironmentObject private var api: HolyArrs
    @EnvironmentObject private var rtx: RTXServer
    @State private var info: TitleInfo?
    @State private var trailer: Trailer?
    @State private var following: Bool?
    @State private var error: String?
    @State private var busy = false
    @State private var message: String?
    @State private var playing: PlayRequest?
    @State private var choosingSeasons = false
    @State private var openSeason: Int?
    @State private var foundFilm: RTXFilm?
    @State private var checkedPC = false

    var body: some View {
        ZStack {
            BlurredArt(raw: info?.backdrop ?? info?.poster)
            if let info {
                ScrollView {
                    VStack(alignment: .leading, spacing: S(60)) {
                        header(info)
                        if !info.seasons.isEmpty { seasonsRow(info) }
                        if !info.cast.isEmpty { castRow(info) }
                        if let c = info.collection { CardRow(title: c.name, cards: c.parts) }
                        CardRow(title: "More like this", cards: info.similar)
                    }
                    .padding(.vertical, S(70))
                }
            } else {
                LoadState(loading: error == nil, error: error) { Task { await load() } }
            }
        }
        .task { await load() }
        .task(id: info?.name) {
            await rtx.refreshIfStale(maxAge: 30)
            await checkPC()
        }
        .fullScreenCover(item: $playing) { PlayerScreen(request: $0) }
        .sheet(isPresented: $choosingSeasons) {
            if let info { SeasonPicker(info: info) { seasons, futureOnly in Task { await ask(seasons: seasons, futureOnly: futureOnly) } } }
        }
        .sheet(item: Binding(get: { openSeason.map { SeasonID(number: $0) } }, set: { openSeason = $0?.number })) { s in
            if let info { EpisodesSheet(info: info, season: s.number) }
        }
    }

    // MARK: Header

    private func header(_ info: TitleInfo) -> some View {
        AdaptiveStack(tvAlignment: .top, spacing: S(80)) {
            Artwork(raw: info.poster, width: 500, title: info.name, subtitle: info.year.map(String.init))
                .frame(width: W(420), height: S(630))
                .clipShape(RoundedRectangle(cornerRadius: S(18), style: .continuous))
                .shadow(color: .black.opacity(0.6), radius: S(40), y: 20)

            VStack(alignment: .leading, spacing: S(26)) {
                if let logo = info.logo {
                    Artwork(raw: logo, width: 500, plain: true, fit: true).frame(width: W(640), height: S(180), alignment: .leading)
                        .accessibilityLabel(info.name)
                } else {
                    Text(info.name).font(.system(size: F(72), weight: .bold)).lineLimit(2).minimumScaleFactor(0.6)
                }
                HStack(spacing: S(24)) {
                    if let y = info.year { Text(String(y)) }
                    if let r = info.runtime, r > 0 { Text(r >= 60 ? "\(r / 60)h \(r % 60)m" : "\(r)m") }
                    if let n = info.network { Text(n) }
                    if let r = info.rating { Badge(text: r) }
                    if let q = info.quality { Badge(text: q) }
                    if let f = rtxFilm { Badge(text: f.label) }
                    if let hdr = rtxFilm?.range, hdr != "SDR" { Badge(text: hdr) }
                }
                .font(.title3)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(Color.white.opacity(0.8))
                if !info.genres.isEmpty || !info.moods.isEmpty {
                    Text((info.genres + info.moods).prefix(5).joined(separator: " · ")).font(.system(size: F(24))).foregroundStyle(Theme.dim)
                }
                if let state = info.stateLabel ?? info.askLabel {
                    Label(state, systemImage: info.inLibrary ? "checkmark.circle.fill" : "clock")
                        .font(.system(size: F(26), weight: .semibold)).foregroundStyle(Theme.accent)
                }
                if let o = info.overview {
                    Text(o).font(.system(size: F(26))).foregroundStyle(Color.white.opacity(0.75)).lineLimit(6).frame(maxWidth: W(1150), alignment: .leading)
                }
                actions(info).padding(.top, S(20))
                if let message { Text(message).foregroundStyle(Theme.accent).font(.callout) }
                if let film = rtxFilm {
                    OutsideNote(film: film)
                } else if checkedPC, let info, info.inLibrary, info.kind == .movie {
                    Text(rtx.diagnosis).font(.system(size: F(20))).foregroundStyle(Theme.dim)
                }
            }
            .padding(.top, S(10))
        }
        .padding(.horizontal, S(110))
        .tvFocusSection()
    }

    private var rtxFilm: RTXFilm? {
        guard let info, info.kind == .movie else { return nil }
        return rtx.match(name: info.name, year: info.year) ?? (rtx.enabled ? foundFilm : nil)
    }

    /// No match in the list here: ask the PC directly (its own matching), once per page.
    private func checkPC() async {
        guard let info, info.kind == .movie, info.inLibrary, rtxFilm == nil else { return }
        foundFilm = await rtx.find(name: info.name, year: info.year)
        checkedPC = true
    }

    @ViewBuilder private func actions(_ info: TitleInfo) -> some View {
        AdaptiveStack(spacing: S(30)) {
            if let film = rtxFilm {
                let resume = rtx.startPoint(film)
                Button {
                    playing = PlayRequest(label: info.name, film: film, seconds: resume ?? 0, backdrop: info.backdrop)
                } label: {
                    Label(rtx.continuingHere(film) ? "Continue here" + (resume.map { " from \(Resume.label($0))" } ?? "")
                          : resume.map { "Resume in 4K from \(Resume.label($0))" } ?? "Play in 4K", systemImage: "play.fill")
                        .font(.system(size: F(30), weight: .semibold)).padding(.horizontal, S(30))
                }
                .buttonStyle(.borderedProminent)
                OutsideButton(film: film, label: info.name)
            }
            if !info.inLibrary, info.myAsk == nil, api.me?.canAsk == true, !info.neverAdd {
                Button {
                    if info.kind == .show && info.seasons.count > 1 { choosingSeasons = true } else { Task { await ask(seasons: [], futureOnly: false) } }
                } label: {
                    Label(info.kind == .show ? "Ask for this show" : "Ask for this movie", systemImage: "plus")
                        .font(.system(size: F(30), weight: .semibold)).padding(.horizontal, S(30))
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
            }
            if let ask = info.myAsk, ask.state == "asked" {
                Button(role: .destructive) { Task { await cancel(ask.id) } } label: {
                    Label("Take back my ask", systemImage: "xmark").font(.system(size: F(28), weight: .semibold))
                }
                .disabled(busy)
            }
            if info.inLibrary, info.kind == .show, api.me?.canAsk == true, info.seasons.contains(where: { ($0.missing ?? 0) > 0 }) {
                Button { choosingSeasons = true } label: {
                    Label("Ask for more seasons", systemImage: "plus.square.on.square").font(.system(size: F(28), weight: .semibold))
                }
            }
            if let trailer {
                Button {
                    playing = PlayRequest(label: info.name, trailer: trailer.withSound, backdrop: info.backdrop)
                } label: {
                    Label("Trailer", systemImage: "play.rectangle").font(.system(size: F(28), weight: .semibold))
                }
            }
            if let following, info.titleId != nil, info.kind != .movie {
                Button { Task { await toggleFollow() } } label: {
                    Label(following ? "Following" : "Follow", systemImage: following ? "bell.fill" : "bell")
                        .font(.system(size: F(28), weight: .semibold))
                }
            }
        }
    }

    // MARK: Rows

    private func castRow(_ info: TitleInfo) -> some View {
        VStack(alignment: .leading, spacing: S(18)) {
            Text("Cast and crew").font(.system(size: F(34), weight: .bold)).padding(.horizontal, Theme.sidePadding)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: S(40)) {
                    ForEach(info.cast.indices, id: \.self) { i in
                        let p = info.cast[i]
                        NavigationLink(value: Route.person(id: p.id ?? "", name: p.name)) {
                            PersonCell(name: p.name, role: p.role, image: p.image)
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

    private func seasonsRow(_ info: TitleInfo) -> some View {
        VStack(alignment: .leading, spacing: S(18)) {
            Text("Seasons").font(.system(size: F(34), weight: .bold)).padding(.horizontal, Theme.sidePadding)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: S(30)) {
                    ForEach(info.seasons) { s in
                        Button { openSeason = s.number } label: {
                            VStack(alignment: .leading, spacing: S(8)) {
                                Text(s.name).font(.system(size: F(28), weight: .bold))
                                Text(seasonLine(s)).font(.system(size: F(22))).foregroundStyle(Theme.dim)
                            }
                            .frame(width: W(300), alignment: .leading)
                            .padding(S(24))
                        }
                    }
                }
                .padding(.vertical, S(30))
                .padding(.horizontal, Theme.sidePadding)
            }
            .tvFocusSection()
        }
    }

    private func seasonLine(_ s: Season) -> String {
        var parts = ["\(s.episodes) episodes"]
        if let have = s.have { parts.append(have >= s.episodes && s.episodes > 0 ? "all in library" : "\(have) in library") }
        if let y = s.year { parts.append(String(y)) }
        return parts.joined(separator: " · ")
    }

    // MARK: Loading

    private func load() async {
        do {
            var i = TitleInfo(kind: ref.kind, name: ref.name, tmdb: ref.tmdb, titleId: ref.titleId)
            if let id = ref.titleId {
                let t = try await api.get("titles/\(id)")
                fillFromTitle(&i, t)
            }
            if let tmdb = i.tmdb {
                let kind = i.kind
                async let metaJ = api.get("metadata/\(kind.rawValue)/\(tmdb)")
                async let lookJ = api.get(kind == .show ? "shows/lookup" : "titles/lookup", ["term": "tmdb:\(tmdb)"])
                if let m = try? await metaJ { fillFromMetadata(&i, m) }
                if let l = try? await lookJ { fillFromLookup(&i, l) }
            }
            if let id = i.titleId, i.kind == .show, let s = try? await api.get("titles/\(id)/seasons") {
                let library = s["seasons"].array.filter { ($0["number"].int ?? 0) > 0 }.map { j -> Season in
                    let n = j["number"].int ?? 0
                    return Season(number: n, name: j["name"].string ?? "Season \(n)", episodes: j["episodes"].int ?? j["aired"].int ?? 0,
                                  have: j["in_library"].int, missing: j["missing"].int)
                }
                if !library.isEmpty { i.seasons = library }
            }
            info = i
            error = nil
            if let id = i.titleId, i.kind != .movie, let f = try? await api.get("titles/\(id)/follow") { following = f["following"].bool }
            if let tmdb = i.tmdb { trailer = await Trailer.find(api, kind: i.kind, tmdb: tmdb) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func fillFromTitle(_ i: inout TitleInfo, _ t: JSON) {
        i.kind = Card.kind(t["kind"].string)
        i.name = t["name"].string ?? i.name
        i.year = t["year"].int
        i.overview = t["overview"].string
        i.poster = t["artwork"][0].string
        i.backdrop = t["backdrop"].string
        i.logo = t["logo"].string
        i.genres = t["genres"].names
        i.runtime = t["runtime_minutes"].int
        i.rating = t["rating"].string
        i.tmdb = t["ids"]["tmdb"].string ?? i.tmdb
        i.titleId = t["id"].int ?? i.titleId
        let slots = t["slots"].array
        i.stateLabel = slots.first?["state_label"].string ?? "In library"
        let best = slots.compactMap { $0["file"]["Quality"]["resolution"].int }.max() ?? 0
        i.quality = best >= 2000 ? "4K" : best >= 1000 ? "1080p" : best >= 700 ? "720p" : nil
    }

    private func fillFromMetadata(_ i: inout TitleInfo, _ m: JSON) {
        i.name = i.name.isEmpty ? (m.first("name", "title").string ?? "") : i.name
        i.year = i.year ?? m["year"].int
        i.overview = i.overview ?? m["overview"].string
        i.poster = i.poster ?? m["poster"].string
        i.backdrop = i.backdrop ?? m["backdrop"].string
        i.logo = i.logo ?? m["logo"].string
        if i.genres.isEmpty { i.genres = m["genres"].names }
        i.runtime = i.runtime ?? m.first("runtime_minutes", "runtime").int
        i.rating = i.rating ?? m["rating"].string
        i.network = m["network"].string
        i.moods = m["moods"].names
        i.titleId = i.titleId ?? m["title_id"].int
        i.neverAdd = i.neverAdd || m["never_add"].bool
        let a = m["ask"]
        if i.askLabel == nil, let id = a["id"].int, a["state"].string != "turned_down" {
            i.askLabel = a["state_label"].string
            if a["mine"].bool, i.myAsk == nil { i.myAsk = (id, a["state_label"].string ?? "", a["state"].string ?? "") }
        }
        i.cast = m.first("cast", "people").array.prefix(20).compactMap { p in
            guard let name = p["name"].string else { return nil }
            return CastMember(id: p["id"].string, name: name, role: p["character"].string ?? p["role"].string?.capitalized,
                              image: p.first("profile", "image").string)
        }
        i.similar = m["similar"].array.map { s in
            var c = s
            if c["kind"].isNull, case var .object(o) = c { o["kind"] = .string(i.kind.rawValue); c = .object(o) }
            return Card(provider: c, row: "similar")
        }
        if let col = m["collection"]["name"].string {
            let parts = m["collection"]["parts"].array.map { Card(provider: $0, row: "collection") }
            if parts.count > 1 { i.collection = (col, parts) }
        }
        if i.seasons.isEmpty {
            i.seasons = m["seasons"].array.filter { ($0["number"].int ?? 0) > 0 }.map { j -> Season in
                let n = j["number"].int ?? 0
                return Season(number: n, name: j["name"].string ?? "Season \(n)", episodes: j["episode_count"].int ?? 0, year: j["year"].int)
            }
        }
    }

    private func fillFromLookup(_ i: inout TitleInfo, _ l: JSON) {
        let list = l[i.kind == .show ? "shows" : "movies"].array
        guard let hit = list.first(where: { $0["ids"]["tmdb"].string == i.tmdb }) ?? list.first else { return }
        i.titleId = i.titleId ?? hit["title_id"].int
        i.neverAdd = hit["never_add"].bool
        let a = hit["ask"]
        if let id = a["id"].int, a["state"].string != "turned_down" {
            i.askLabel = a["state_label"].string
            if a["mine"].bool { i.myAsk = (id, a["state_label"].string ?? "", a["state"].string ?? "") }
        }
    }

    // MARK: Actions

    private func ask(seasons: [Int], futureOnly: Bool) async {
        guard let info, let tmdb = info.tmdb else { return }
        busy = true
        defer { busy = false }
        var body: [String: Any] = ["id": "tmdb:\(tmdb)", "kind": info.kind.rawValue]
        if !seasons.isEmpty { body["seasons"] = seasons }
        if futureOnly { body["future_only"] = true }
        do {
            let a = try await api.post("asks", body)
            let label = a["ask"]["state_label"].string ?? "Asked"
            message = a["joined"].bool ? "You joined an earlier ask: \(label)." : a["already"].bool ? "Already asked: \(label)." : "Asked: \(label)."
            await load()
        } catch {
            message = error.localizedDescription
        }
    }

    private func cancel(_ id: Int) async {
        busy = true
        defer { busy = false }
        do { try await api.delete("asks/\(id)"); message = "Ask taken back."; info?.myAsk = nil; info?.askLabel = nil } catch { message = error.localizedDescription }
    }

    private func toggleFollow() async {
        guard let id = info?.titleId, let f = following else { return }
        do {
            let j = f ? try await api.delete("titles/\(id)/follow") : try await api.put("titles/\(id)/follow")
            following = j["following"].bool
        } catch { message = error.localizedDescription }
    }
}

private struct SeasonID: Identifiable { let number: Int; var id: Int { number } }

struct PersonCell: View {
    let name: String
    let role: String?
    let image: String?
    @Environment(\.isFocused) private var focused

    var body: some View {
        VStack(spacing: S(12)) {
            Artwork(raw: image, width: 185, title: String(name.prefix(1)))
                .frame(width: W(180), height: S(180))
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white.opacity(focused ? 0.9 : 0.1), lineWidth: focused ? 4 : 1))
                .scaleEffect(focused ? 1.1 : 1)
            Text(name).font(.system(size: F(22), weight: .semibold)).lineLimit(1)
            if let role { Text(role).font(.system(size: F(19))).foregroundStyle(Theme.dim).lineLimit(1) }
        }
        .frame(width: W(200))
        .foregroundStyle(focused ? Color.white : Color.white.opacity(0.75))
        .animation(.easeOut(duration: 0.18), value: focused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(role.map { "\(name), \($0)" } ?? name)
    }
}

/// Which seasons to ask for: the whole show, chosen seasons, or only what airs from now on.
struct SeasonPicker: View {
    let info: TitleInfo
    let done: ([Int], Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<Int> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Every season") { done([], false); dismiss() }
                    Button("Only new seasons and episodes from now on") { done([], true); dismiss() }
                }
                Section("Or pick seasons") {
                    ForEach(info.seasons) { s in
                        Button {
                            if picked.contains(s.number) { picked.remove(s.number) } else { picked.insert(s.number) }
                        } label: {
                            HStack {
                                Text(s.name)
                                Spacer()
                                if let have = s.have, have >= s.episodes, s.episodes > 0 { Text("In library").foregroundStyle(.secondary) }
                                Image(systemName: picked.contains(s.number) ? "checkmark.circle.fill" : "circle")
                            }
                        }
                    }
                    Button("Ask for \(picked.count) season\(picked.count == 1 ? "" : "s")") { done(picked.sorted(), false); dismiss() }
                        .disabled(picked.isEmpty)
                }
            }
            .navigationTitle(info.name)
        }
    }
}

/// One season's episodes: from the Library (with each copy's state) or from TMDB.
struct EpisodesSheet: View {
    let info: TitleInfo
    let season: Int
    @EnvironmentObject private var api: HolyArrs
    @State private var rows: [EpisodeRow] = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(rows) { e in
                    HStack(spacing: S(24)) {
                        Artwork(raw: e.still, width: 300).frame(width: W(240), height: S(135)).clipShape(RoundedRectangle(cornerRadius: S(8)))
                        VStack(alignment: .leading, spacing: S(6)) {
                            Text("\(e.n). \(e.name)").font(.headline)
                            Text(e.line).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        if let s = e.state { Text(s).font(.callout.bold()).foregroundStyle(Theme.accent) }
                    }
                }
                if rows.isEmpty { Text(error ?? "Loading...").foregroundStyle(.secondary) }
            }
            .navigationTitle("\(info.name): Season \(season)")
        }
        .task {
            if let id = info.titleId, let j = try? await api.get("titles/\(id)/episodes", ["season": String(season)]) {
                rows = j["episodes"].array.map { e -> EpisodeRow in
                    let n = e["episode"].int ?? 0
                    let line = [e["air_day"].string, e["runtime"].int.map { "\($0)m" }].compactMap { $0 }.joined(separator: " · ")
                    return EpisodeRow(n: n, name: e["name"].string ?? "Episode \(n)", line: line, state: e["slots"][0]["state_label"].string)
                }
            } else if let tmdb = info.tmdb {
                do {
                    let j = try await api.get("metadata/show/\(tmdb)/seasons/\(season)")
                    rows = j["episodes"].array.map { e -> EpisodeRow in
                        EpisodeRow(n: e.first("number", "episode").int ?? 0, name: e["name"].string ?? "",
                                   line: e["overview"].string ?? e["air_day"].string ?? "", still: e["still"].string)
                    }
                } catch { self.error = error.localizedDescription }
            }
        }
    }
}
