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
    /// The qualities HolyArrs lets this person ask for (GET /asks/limit), e.g. 1080p and 4K.
    @State private var qualities: [(id: String, name: String)] = []
    @State private var choosingQuality = false
    @State private var pendingSeasons: (seasons: [Int], futureOnly: Bool) = ([], false)
    @State private var checkedPC = false
    /// Asked for here just now: the download card shows "Looking for the best copy" until the download appears.
    @State private var askedAt: Date?
    /// A Library show's episodes the PC can play (GET /show), in order.
    @State private var pcEpisodes: [RTXEpisode] = []
    /// iPhone: the summary opened past its first three lines.
    @State private var moreOverview = false

    var body: some View {
        ZStack {
            BlurredArt(raw: info?.backdrop ?? info?.poster)
            if let info {
                ScrollView {
                    VStack(alignment: .leading, spacing: S(60)) {
                        if Device.isTV { header(info) } else { phoneHeader(info) }
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
            if let info, info.kind == .show, let id = info.titleId { pcEpisodes = await rtx.show(titleId: id) }
        }
        .fullScreenCover(item: $playing) { req in
            PlayerScreen(request: req).onDisappear { Task { await rtx.syncPositions() } }
        }
        .confirmationDialog("Which quality?", isPresented: $choosingQuality, titleVisibility: .visible) {
            ForEach(qualities, id: \.id) { q in
                Button(q.name) { Task { await ask(seasons: pendingSeasons.seasons, futureOnly: pendingSeasons.futureOnly, quality: q.id) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(qualities.contains { $0.id == "own-ultra" }
                 ? "1080p: a good copy, upscaled to 4K by the PC. 4K: a standard 4K HDR copy. Ultra: the full-quality remux, several times bigger."
                 : "1080p: a good Blu-ray copy, upscaled to 4K by the PC. 4K: the best real 4K HDR copy there is.")
        }
        .sheet(isPresented: $choosingSeasons) {
            if let info { SeasonPicker(info: info) { seasons, futureOnly in startAsk(seasons: seasons, futureOnly: futureOnly) } }
        }
        .sheet(item: Binding(get: { openSeason.map { SeasonID(number: $0) } }, set: { openSeason = $0?.number })) { s in
            if let info { EpisodesSheet(info: info, season: s.number, pc: pcEpisodes) }
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
                facts(info)
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
                // Its download, right here: looking for a copy, progress, and Play once it can play while downloading.
                TitleDownloadCard(name: info.name, year: info.year, titleId: info.titleId, runtimeMinutes: info.runtime,
                                  askedAt: askedAt, finished: { Task { await load(); await rtx.refresh() } })
                if let film = rtxFilm {
                    OutsideNote(film: film)
                } else if checkedPC, info.inLibrary, info.kind == .movie {
                    Text(rtx.diagnosis).font(.system(size: F(20))).foregroundStyle(Theme.dim)
                }
            }
            .padding(.top, S(10))
        }
        .padding(.horizontal, S(110))
        .tvFocusSection()
    }

    /// Year, length, network and badges, on one line.
    private func facts(_ info: TitleInfo) -> some View {
        HStack(spacing: S(24)) {
            if let y = info.year { Text(String(y)) }
            if let r = info.runtime, r > 0 { Text(r >= 60 ? "\(r / 60)h \(r % 60)m" : "\(r)m") }
            if let n = info.network { Text(n) }
            if let r = info.rating { Badge(text: r) }
            if let q = info.quality { Badge(text: q) }
            if let f = rtxFilm { Badge(text: f.label) }
            if let hdr = rtxFilm?.range, hdr != "SDR" { Badge(text: hdr) }
        }
        .font(Device.isTV ? .title3 : .system(size: F(26)))
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .foregroundStyle(Color.white.opacity(0.8))
    }

    /// iPhone (Release 4): Play within reach. A short backdrop band, a small poster beside the title, year and
    /// badges, then Play or Resume, then the summary in three lines with More. The full header pushed Play under
    /// the tab bar on a title with a logo and a long summary.
    private func phoneHeader(_ info: TitleInfo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let band = info.backdrop {
                Artwork(raw: band, width: 780, plain: true)
                    .frame(maxWidth: .infinity).frame(height: 120).clipped()
                    .overlay(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
            }
            HStack(alignment: .top, spacing: 14) {
                Artwork(raw: info.poster, width: 342, title: info.name, subtitle: info.year.map(String.init))
                    .frame(width: 96, height: 144)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 10, y: 6)
                VStack(alignment: .leading, spacing: 8) {
                    if let logo = info.logo {
                        Artwork(raw: logo, width: 500, plain: true, fit: true)
                            .frame(maxWidth: 210, maxHeight: 60, alignment: .leading)
                            .accessibilityLabel(info.name)
                    } else {
                        Text(info.name).font(.system(size: F(48), weight: .bold)).lineLimit(3).minimumScaleFactor(0.7)
                    }
                    facts(info)
                    if let state = info.stateLabel ?? info.askLabel {
                        Label(state, systemImage: info.inLibrary ? "checkmark.circle.fill" : "clock")
                            .font(.system(size: F(24), weight: .semibold)).foregroundStyle(Theme.accent).lineLimit(2)
                    }
                }
            }
            actions(info)
            if let message { Text(message).foregroundStyle(Theme.accent).font(.callout) }
            if let o = info.overview {
                VStack(alignment: .leading, spacing: 4) {
                    Text(o).font(.system(size: F(26))).foregroundStyle(Color.white.opacity(0.75))
                        .lineLimit(moreOverview ? nil : 3)
                    if o.count > 140 {
                        Button(moreOverview ? "Less" : "More") { withAnimation { moreOverview.toggle() } }
                            .font(.system(size: F(24), weight: .semibold))
                    }
                }
            }
            if !info.genres.isEmpty || !info.moods.isEmpty {
                Text((info.genres + info.moods).prefix(5).joined(separator: " · ")).font(.system(size: F(22))).foregroundStyle(Theme.dim)
            }
            TitleDownloadCard(name: info.name, year: info.year, titleId: info.titleId, runtimeMinutes: info.runtime,
                              askedAt: askedAt, finished: { Task { await load(); await rtx.refresh() } })
            if let film = rtxFilm {
                OutsideNote(film: film)
            } else if checkedPC, info.inLibrary, info.kind == .movie {
                Text(rtx.diagnosis).font(.system(size: F(20))).foregroundStyle(Theme.dim)
            }
        }
        .padding(.horizontal, 16)
    }

    private var rtxFilm: RTXFilm? {
        guard let info, info.kind == .movie else { return nil }
        return rtx.match(name: info.name, year: info.year) ?? foundFilm
    }

    /// No match in the list here: ask the PC directly (its own matching), once per page.
    private func checkPC() async {
        guard let info, info.kind == .movie, info.inLibrary, rtxFilm == nil else { return }
        foundFilm = await rtx.find(name: info.name, year: info.year)
        checkedPC = true
    }

    /// The episode a show's page offers first: the one left part-way most recently, else the first the PC has.
    private var nextEpisode: (episode: RTXEpisode, resume: Double?)? {
        let started = pcEpisodes.filter { Resume.position($0.id) != nil }
        if let e = started.max(by: { (Resume.savedAt($0.id) ?? 0) < (Resume.savedAt($1.id) ?? 0) }) {
            return (e, Resume.position(e.id))
        }
        return pcEpisodes.first.map { ($0, nil) }
    }

    @ViewBuilder private func actions(_ info: TitleInfo) -> some View {
        AdaptiveStack(spacing: S(30)) {
            if info.kind == .show, let next = nextEpisode {
                Button {
                    playing = PlayRequest(label: "\(info.name) \u{00B7} \(next.episode.code)", film: next.episode.film,
                                          seconds: next.resume ?? 0, backdrop: info.backdrop)
                } label: {
                    Label(next.resume.map { "Resume \(next.episode.code) from \(Resume.label($0))" } ?? "Play \(next.episode.code)",
                          systemImage: "play.fill")
                        .font(.system(size: F(30), weight: .semibold)).padding(.horizontal, S(30))
                }
                .buttonStyle(.borderedProminent)
                // iPhone: download that episode (each episode's own arrow is in the season list).
                OfflineButton(film: next.episode.film, title: "\(info.name) \(next.episode.code)", subtitle: next.episode.name)
            }
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
                if resume != nil {
                    Button {
                        playing = PlayRequest(label: info.name, film: film, seconds: 0, backdrop: info.backdrop)
                    } label: {
                        Label("Start over", systemImage: "backward.end").font(.system(size: F(28), weight: .semibold))
                    }
                }
                OutsideButton(film: film, label: info.name)
                OfflineButton(film: film, title: info.name, subtitle: info.year.map(String.init))
            }
            if !info.inLibrary, info.myAsk == nil, api.me?.canAsk == true, !info.neverAdd {
                Button {
                    if info.kind == .show && info.seasons.count > 1 { choosingSeasons = true } else { startAsk(seasons: [], futureOnly: false) }
                } label: {
                    Label(info.kind == .show ? "Get this show" : "Get it", systemImage: "arrow.down.circle")
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
            if !i.inLibrary, qualities.isEmpty { await loadQualities(i.kind) }
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

    /// Asks straight away when HolyArrs offers one quality; otherwise asks which (1080p or 4K) first.
    private func startAsk(seasons: [Int], futureOnly: Bool) {
        if qualities.count > 1 {
            pendingSeasons = (seasons, futureOnly)
            choosingQuality = true
        } else {
            Task { await ask(seasons: seasons, futureOnly: futureOnly) }
        }
    }

    private func loadQualities(_ kind: Card.Kind) async {
        guard kind != .artist, let j = try? await api.get("asks/limit") else { return }
        qualities = j["qualities"][kind == .show ? "show" : "movie"].array.compactMap { q in
            guard let id = q["id"].string else { return nil }
            return (id, q["name"].string ?? (id == "4k" ? "4K" : "Standard"))
        }
    }

    private func ask(seasons: [Int], futureOnly: Bool, quality: String? = nil) async {
        guard let info, let tmdb = info.tmdb else { return }
        busy = true
        defer { busy = false }
        var body: [String: Any] = ["id": "tmdb:\(tmdb)", "kind": info.kind.rawValue]
        if !seasons.isEmpty { body["seasons"] = seasons }
        if futureOnly { body["future_only"] = true }
        if let quality { body["quality"] = quality }
        do {
            let a = try await api.post("asks", body)
            let label = a["ask"]["state_label"].string ?? "Asked"
            // The download card below shows what happens next (looking for a copy, then progress): no status line.
            message = a["joined"].bool ? "You joined an earlier ask: \(label)." : a["already"].bool ? "Already asked: \(label)." : nil
            askedAt = Date()
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
    /// The show's episodes the PC can play: those rows play (or resume) on a press.
    var pc: [RTXEpisode] = []
    @EnvironmentObject private var api: HolyArrs
    @EnvironmentObject private var rtx: RTXServer
    @State private var rows: [EpisodeRow] = []
    @State private var error: String?
    @State private var playing: PlayRequest?

    private func playable(_ n: Int) -> RTXEpisode? { pc.first { $0.season == season && $0.episode == n } }

    var body: some View {
        NavigationStack {
            List {
                ForEach(rows) { e in
                    if let ep = playable(e.n) {
                        let resume = Resume.position(ep.id)
                        HStack(spacing: 8) {
                            Button {
                                playing = PlayRequest(label: "\(info.name) \u{00B7} \(ep.code)", film: ep.film, seconds: resume ?? 0, backdrop: info.backdrop)
                            } label: {
                                row(e, trailing: resume.map { "Resume \(Resume.label($0))" } ?? "Play", progress: resume.map { $0 / max(1, ep.film.duration) })
                            }
                            .accessibilityLabel("\(resume == nil ? "Play" : "Resume") \(ep.code): \(e.name)")
                            .phoneBorderless()
                            OfflineIcon(film: ep.film, title: "\(info.name) \(ep.code)", subtitle: e.name)
                        }
                    } else {
                        row(e, trailing: e.state, progress: nil)
                    }
                }
                if rows.isEmpty { Text(error ?? "Loading...").foregroundStyle(.secondary) }
            }
            .navigationTitle("\(info.name): Season \(season)")
        }
        .fullScreenCover(item: $playing) { req in
            PlayerScreen(request: req).onDisappear { Task { await rtx.syncPositions() } }
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

    private func row(_ e: EpisodeRow, trailing: String?, progress: Double?) -> some View {
        HStack(spacing: S(24)) {
            Artwork(raw: e.still, width: 300).frame(width: W(240), height: S(135)).clipShape(RoundedRectangle(cornerRadius: S(8)))
            VStack(alignment: .leading, spacing: S(6)) {
                Text("\(e.n). \(e.name)").font(.headline)
                Text(e.line).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                if let progress {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.2))
                            Capsule().fill(Theme.accent).frame(width: g.size.width * min(1, progress))
                        }
                    }
                    .frame(width: W(240), height: S(5))
                }
            }
            Spacer()
            if let trailing { Text(trailing).font(.callout.bold()).foregroundStyle(Theme.accent) }
        }
    }
}
