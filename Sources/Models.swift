import Foundation

/// One poster or backdrop card, whichever HolyArrs route it came from (Explore rows, Home rows, search,
/// a person's films, asks, the calendar).
struct Card: Identifiable, Hashable {
    enum Kind: String { case movie, show, artist }

    let id: String
    let kind: Kind
    let name: String
    let year: Int?
    let poster: String?
    let backdrop: String?
    let logo: String?
    let overview: String?
    let tmdb: String?
    let titleId: Int?
    let mbid: String?
    /// A short line under the title: "S5 · 3 new episodes", a character, an air day.
    let line: String?
    /// What HolyArrs says about it: "In library", "Asked", "Downloading"...
    let status: String?
    let genres: [String]
    /// A film on the PC that HolyArrs doesn't have (Movies tab): its RTX film id; the card opens PCFilmPage.
    var pcFilm: String? = nil
    /// When HolyArrs added it (Movies and TV Shows: Recently added).
    var added: Date? = nil

    var route: Route {
        if let pcFilm { return .pcFilm(id: pcFilm) }
        return .title(TitleRef(kind: kind, tmdb: tmdb, titleId: titleId, mbid: mbid, name: name))
    }

    static func kind(_ s: String?) -> Kind {
        switch s {
        case "show", "tv", "series": return .show
        case "artist", "music": return .artist
        default: return .movie
        }
    }

    /// Explore, search and metadata items (ProviderItem in HolyArrs' web app).
    init(provider d: JSON, row: String = "") {
        let kind = Card.kind(d["kind"].string)
        let tmdb = d.first("tmdb_id", "tmdb").string ?? d["ids"]["tmdb"].string
        self.kind = kind
        self.tmdb = tmdb
        name = d.first("name", "title").string ?? ""
        year = d["year"].int
        poster = d.first("poster", "image").string
        backdrop = d.first("backdrop", "wide").string
        logo = d.first("card_logo", "logo").string
        overview = d["overview"].string
        let inLibrary = d["in_library"].bool || d["title_id"].int != nil
        titleId = d["title_id"].int
        mbid = d.first("mbid", "artist_mbid").string
        line = d.first("line", "subtitle", "sub").string
        genres = d["genres"].names
        if inLibrary {
            status = "In library"
        } else if let label = d["ask"]["state_label"].string, d["ask"]["state"].string != "turned_down" {
            status = label
        } else if row == "more", tmdb != nil, kind != .artist {
            status = "Get it"  // a search result that isn't here yet: one tap on its page downloads it
        } else {
            status = nil
        }
        id = "\(row)-\(kind.rawValue)-\(tmdb ?? mbid ?? titleId.map(String.init) ?? name)"
    }

    /// Home's cards (arrived, new seasons, following, soon): always Library titles.
    init(home d: JSON) {
        kind = Card.kind(d["kind"].string)
        name = d["name"].string ?? ""
        year = d["year"].int
        poster = d["poster"].string
        backdrop = d["backdrop"].string
        logo = d["logo"].string
        overview = nil
        tmdb = nil
        titleId = d["title_id"].int
        mbid = nil
        line = d["line"].string
        status = "In library"
        genres = []
        id = d["key"].string ?? "home-\(titleId ?? 0)-\(name)"
    }

    /// A Library title (TitleView).
    init(title d: JSON) {
        kind = Card.kind(d["kind"].string)
        name = d["name"].string ?? ""
        year = d["year"].int
        poster = d["artwork"][0].string ?? d["poster"].string
        backdrop = d["backdrop"].string
        logo = d["logo"].string
        overview = d["overview"].string
        tmdb = d["ids"]["tmdb"].string
        titleId = d["id"].int
        mbid = d["artist"]["mbid"].string ?? d["ids"]["mbid"].string
        line = d["year"].int.map(String.init)
        status = "In library"
        genres = d["genres"].names
        id = "t\(titleId ?? 0)"
    }

    /// Search's live suggestions (GET /search/suggest).
    init(suggest d: JSON) {
        kind = Card.kind(d["kind"].string)
        name = d["name"].string ?? ""
        year = nil
        poster = d["art"].string
        backdrop = nil
        logo = nil
        overview = nil
        tmdb = d["tmdb"].string
        titleId = d["title_id"].int
        mbid = d.first("mbid", "artist_mbid").string
        line = d["sub"].string
        switch d["state"].string {
        case "have": status = "In library"
        case "asked": status = "Asked"
        case "following": status = "Following"
        // Not here yet: one tap on its page gets it.
        default: status = tmdb != nil && titleId == nil && kind != .artist ? "Get it" : nil
        }
        genres = []
        id = "s-\(kind.rawValue)-\(tmdb ?? mbid ?? titleId.map(String.init) ?? name)"
    }

    /// Explore > Music cards (albums, artists, songs): every one opens its artist.
    init(music d: JSON, row: String = "") {
        let k = d["kind"].string ?? "artist"
        kind = .artist
        name = d["name"].string ?? ""
        year = d["date"].string.flatMap { Int($0.prefix(4)) }
        poster = d.first("image", "artist_image").string
        backdrop = nil
        logo = nil
        overview = nil
        tmdb = nil
        titleId = k == "artist" ? d["title_id"].int : nil
        mbid = k == "artist" ? d["mbid"].string : (d["artist_mbid"].string ?? d["mbid"].string)
        line = k == "artist" ? (d["kicker"].string ?? d["genres"].names.first) : d["artist"].string
        status = d["state"].string.map { $0 == "have" || $0 == "in_library" ? "In library" : $0.capitalized }
        genres = d["genres"].names
        id = "\(row)-m-\(k)-\(d["mbid"].string ?? name)"
    }

    var stableYear: String { year.map(String.init) ?? " " }
}

/// Which title page to open: a Library title (by id), or anything else by TMDB id (movies, shows) or
/// MusicBrainz id (artists).
struct TitleRef: Hashable {
    let kind: Card.Kind
    let tmdb: String?
    let titleId: Int?
    let mbid: String?
    let name: String
}

enum Route: Hashable {
    case title(TitleRef)
    case pcFilm(id: String)
    case person(id: String, name: String)
    case genre(type: String, id: Int, name: String)
}

/// One ask (GET /asks): what was asked for, by whom, and where it stands.
struct AskItem: Identifiable, Hashable {
    let id: Int
    let kind: Card.Kind
    let name: String
    let year: Int?
    let poster: String?
    let state: String
    let stateLabel: String
    let what: String?
    let by: String
    let people: Int
    let mine: Bool
    let tmdb: String?
    let titleId: Int?
    let note: String?
    let askedAt: Date?

    init(_ d: JSON) {
        id = d["id"].int ?? 0
        kind = Card.kind(d["kind"].string)
        name = d["name"].string ?? ""
        year = d["year"].int
        poster = d["poster"].string
        state = d["state"].string ?? ""
        stateLabel = d["state_label"].string ?? d["state"].string ?? ""
        what = d.first("season_words", "album_words").string
        by = d["asked_by"]["name"].string ?? ""
        people = max(1, d["people"].array.count)
        mine = d["mine"].bool
        tmdb = d["tmdb_id"].string
        titleId = d["title_id"].int
        note = d["note"].string
        askedAt = Dates.parse(d["asked_at"].string)
    }

    var waiting: Bool { state == "asked" }
    var card: Card {
        Card(provider: .object(["kind": .string(kind.rawValue), "name": .string(name), "year": year.map { .number(Double($0)) } ?? .null,
                                "poster": poster.map(JSON.string) ?? .null, "tmdb_id": tmdb.map(JSON.string) ?? .null,
                                "title_id": titleId.map { .number(Double($0)) } ?? .null]), row: "ask\(id)")
    }
}

enum Dates {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()
    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        return iso.date(from: s) ?? isoPlain.date(from: s) ?? day.date(from: String(s.prefix(10)))
    }

    static func dayString(_ d: Date) -> String { day.string(from: d) }

    static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }
}
