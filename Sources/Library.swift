import SwiftUI

/// The Movies and TV Shows tabs (Release 6, Luke 2026-11-25: "TV shows and movies should be our downloaded
/// media"): only what is downloaded. HolyArrs' titles with files (size above zero), and for Movies also the films
/// on the PC that HolyArrs doesn't track (152 of the PC's 342 on 2026-11-25: Alien, Die Hard...), each once.
/// Recently added first, then everything A to Z (or newest first).
struct LibraryKindView: View {
    enum Kind: String { case movie, show }
    let kind: Kind

    @EnvironmentObject private var api: HolyArrs
    @EnvironmentObject private var rtx: RTXServer
    @AppStorage("librarySort") private var sort = "az"
    @State private var cards: [Card] = []
    @State private var loading = true
    @State private var error: String?

    private var title: String { kind == .movie ? "Movies" : "TV Shows" }

    private var recent: [Card] {
        Array(cards.filter { $0.added != nil }.sorted { ($0.added ?? .distantPast) > ($1.added ?? .distantPast) }.prefix(16))
    }

    private var sorted: [Card] {
        sort == "recent"
            ? cards.sorted { ($0.added ?? .distantPast) > ($1.added ?? .distantPast) }
            : cards.sorted { LibraryKindView.key($0.name) < LibraryKindView.key($1.name) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: S(46)) {
                AdaptiveStack(spacing: S(30)) {
                    VStack(alignment: .leading, spacing: S(6)) {
                        Text(title).font(.system(size: F(64), weight: .bold))
                        if !cards.isEmpty {
                            Text("\(cards.count) downloaded").font(.system(size: F(24))).foregroundStyle(Theme.dim)
                        }
                    }
                    Spacer()
                    HStack(spacing: S(18)) {
                        ForEach([("az", "A to Z"), ("recent", "Newest")], id: \.0) { key, label in
                            Button { sort = key } label: {
                                Text(label).font(.system(size: F(26), weight: .semibold)).padding(.horizontal, S(10))
                            }
                            .buttonStyle(KindButtonStyle(selected: sort == key))
                            .accessibilityAddTraits(sort == key ? .isSelected : [])
                        }
                    }
                }
                .padding(.horizontal, Theme.sidePadding)
                .tvFocusSection()
                if !recent.isEmpty, sort == "az" {
                    CardRow(title: "Recently added", subtitle: nil, cards: recent, wide: false)
                }
                if !cards.isEmpty {
                    VStack(alignment: .leading, spacing: S(24)) {
                        Text(sort == "az" ? "All \(title.lowercased())" : "Newest first").font(.system(size: F(36), weight: .bold))
                        PosterGrid(cards: sorted)
                    }
                    .padding(.horizontal, Theme.sidePadding)
                }
                if cards.isEmpty {
                    LoadState(loading: loading, error: error,
                              empty: kind == .movie ? "No movies downloaded yet." : "No TV shows downloaded yet. Ask for one from Search.",
                              retry: { Task { await load() } })
                }
            }
            .padding(.vertical, S(40))
        }
        .refreshable { await load() }
        .task { await load() }
    }

    /// Sort title: case and punctuation ignored, a leading "The", "A" or "An" skipped.
    static func key(_ name: String) -> String {
        var s = name.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
        for a in ["the ", "a ", "an "] where s.hasPrefix(a) { s = String(s.dropFirst(a.count)); break }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let j = try await api.get("titles")
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()
            var out: [Card] = []
            for t in j["titles"].array where t["kind"].string == kind.rawValue && (t["size_bytes"].int ?? 0) > 0 {
                var c = Card(title: t)
                if let s = t["added_at"].string { c.added = iso.date(from: s) ?? plain.date(from: s) }
                out.append(c)
            }
            if kind == .movie {
                // The PC's films HolyArrs doesn't have (matched by title and year, or title alone).
                if rtx.films.isEmpty { await rtx.refresh() }
                let have = Set(out.map { "\(LibraryKindView.key($0.name))|\($0.year ?? 0)" })
                let names = Set(out.map { LibraryKindView.key($0.name) })
                var seen = Set<String>()
                for f in rtx.films where !f.title.isEmpty {
                    let k = LibraryKindView.key(f.title)
                    guard !have.contains("\(k)|\(f.year ?? 0)"), !names.contains(k), seen.insert("\(k)|\(f.year ?? 0)").inserted else { continue }
                    let poster = f.poster.flatMap { p in rtx.base.flatMap { URL(string: p, relativeTo: $0)?.absoluteString } }
                    out.append(Card(pc: f, poster: poster))
                }
            }
            cards = out
            error = nil
        } catch {
            if cards.isEmpty { self.error = error.localizedDescription }
        }
    }
}

extension Card {
    /// A film on the PC that HolyArrs doesn't track (Movies tab).
    init(pc f: RTXFilm, poster: String?) {
        id = "pc-\(f.id)"
        kind = .movie
        name = f.title
        year = f.year
        self.poster = poster
        backdrop = nil
        logo = nil
        overview = nil
        tmdb = nil
        titleId = nil
        mbid = nil
        line = f.year.map(String.init)
        status = "On the PC"
        genres = []
        pcFilm = f.id
    }
}

/// A film on the PC that HolyArrs doesn't track: its poster, Play in 4K or Resume, Start over, and the iPhone
/// download. (HolyArrs' films open the full TitlePage.)
struct PCFilmPage: View {
    let id: String
    @EnvironmentObject private var rtx: RTXServer
    @State private var playing: PlayRequest?

    var body: some View {
        ScrollView {
            if let film = rtx.film(id: id) {
                AdaptiveStack(tvAlignment: .top, spacing: S(60)) {
                    Artwork(raw: film.poster.flatMap { p in rtx.base.flatMap { URL(string: p, relativeTo: $0)?.absoluteString } },
                            width: 500, title: film.title, subtitle: film.year.map(String.init))
                        .frame(width: W(420), height: S(630))
                        .clipShape(RoundedRectangle(cornerRadius: S(18), style: .continuous))
                    VStack(alignment: .leading, spacing: S(26)) {
                        Text(film.title).font(.system(size: F(64), weight: .bold)).lineLimit(3)
                        HStack(spacing: S(24)) {
                            if let y = film.year { Text(String(y)) }
                            if film.duration > 0 { Text(Resume.label(film.duration)) }
                            Badge(text: film.label)
                            if let hdr = film.range, hdr != "SDR" { Badge(text: hdr) }
                        }
                        .font(Device.isTV ? .title3 : .system(size: F(26)))
                        .foregroundStyle(Color.white.opacity(0.8))
                        Text("On the PC (not in HolyArrs)").font(.system(size: F(24))).foregroundStyle(Theme.dim)
                        let resume = rtx.startPoint(film)
                        AdaptiveStack(spacing: S(24)) {
                            Button {
                                playing = PlayRequest(label: film.title, film: film, seconds: resume ?? 0)
                            } label: {
                                Label(resume.map { "Resume in 4K from \(Resume.label($0))" } ?? "Play in 4K", systemImage: "play.fill")
                                    .font(.system(size: F(30), weight: .semibold)).padding(.horizontal, S(30))
                            }
                            .buttonStyle(.borderedProminent)
                            if resume != nil {
                                Button { playing = PlayRequest(label: film.title, film: film, seconds: 0) } label: {
                                    Label("Start over", systemImage: "backward.end").font(.system(size: F(28), weight: .semibold))
                                }
                            }
                            OfflineButton(film: film, title: film.title, subtitle: film.year.map(String.init))
                        }
                    }
                }
                .padding(.horizontal, Theme.sidePadding)
                .padding(.vertical, S(60))
            } else {
                LoadState(loading: rtx.checking, error: rtx.error, empty: "This film isn't on the PC any more.", retry: { Task { await rtx.refresh() } })
            }
        }
        .fullScreenCover(item: $playing) { req in
            PlayerScreen(request: req).onDisappear { Task { await rtx.syncPositions() } }
        }
    }
}
