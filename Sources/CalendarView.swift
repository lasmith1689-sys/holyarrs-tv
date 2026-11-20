import SwiftUI

/// The next 30 days (GET /calendar): episodes of Library shows, cinema, digital and disc dates of Library
/// movies, and album days of Library artists, grouped by day.
struct CalendarView: View {
    @EnvironmentObject private var api: HolyArrs
    @State private var days: [(day: String, items: [JSON])] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                Text("Coming up").font(.system(size: 64, weight: .bold)).padding(.horizontal, Theme.sidePadding)
                ForEach(days.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 16) {
                        Text(Self.heading(days[i].day)).font(.system(size: 30, weight: .heavy)).foregroundStyle(Theme.accent)
                            .padding(.horizontal, Theme.sidePadding)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 46) {
                                ForEach(days[i].items.indices, id: \.self) { j in
                                    let e = days[i].items[j]
                                    let card = Self.card(e)
                                    NavigationLink(value: card.route) { PosterCell(card: card) }.buttonStyle(QuietButtonStyle())
                                }
                            }
                            .padding(.vertical, 30)
                            .padding(.horizontal, Theme.sidePadding)
                        }
                        .focusSection()
                    }
                }
                if days.isEmpty { LoadState(loading: loading, error: error, empty: "Nothing in the next 30 days.") }
            }
            .padding(.vertical, 40)
        }
        .task { await load() }
    }

    private func load() async {
        defer { loading = false }
        do {
            let j = try await api.get("calendar")
            var groups: [String: [JSON]] = [:]
            for e in j["dates"].array {
                // A timed episode is shown on the viewer's own day; others on their air day.
                let key: String
                if e["timed"].bool, let d = Dates.parse(e["date"].string) {
                    let f = DateFormatter()
                    f.dateFormat = "yyyy-MM-dd"
                    key = f.string(from: d)
                } else {
                    key = String((e.first("air_day", "date").string ?? "").prefix(10))
                }
                groups[key, default: []].append(e)
            }
            days = groups.keys.sorted().map { (day: $0, items: groups[$0] ?? []) }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    static func card(_ e: JSON) -> Card {
        let kind = e["kind"].string ?? ""
        var line: String?
        switch kind {
        case "episode":
            line = "S\(e["season"].int ?? 0) E\(e["episode"].int ?? 0)" + (e["episode_name"].string.map { " · \($0)" } ?? "")
        case "album":
            line = e["album"].string
        default:
            line = ["cinema": "In cinemas", "digital": "Digital release", "physical": "On disc"][kind] ?? e["state"].string
        }
        let titleKind = kind == "episode" ? "show" : kind == "album" ? "artist" : "movie"
        return Card(provider: .object([
            "kind": .string(titleKind), "name": e["name"], "year": e["year"], "poster": e["poster"],
            "backdrop": e["backdrop"], "title_id": e["title_id"], "in_library": .bool(e["title_id"].int != nil),
            "line": line.map(JSON.string) ?? .null,
        ]), row: "cal-\(e["date"].string ?? "")-\(e["item_id"].int ?? 0)")
    }

    static func heading(_ day: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: day) else { return day }
        if Calendar.current.isDateInToday(d) { return "Today" }
        if Calendar.current.isDateInTomorrow(d) { return "Tomorrow" }
        let out = DateFormatter()
        out.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        return out.string(from: d)
    }
}
