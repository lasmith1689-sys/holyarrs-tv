import SwiftUI

/// Search: names as you type (GET /search/suggest: Library, TMDB movies, shows and people, charted music),
/// and plain descriptions ("space movie with a robot from 2014") through HolyArrs' plain-words search.
struct SearchView: View {
    @EnvironmentObject private var api: HolyArrs
    @State private var text = ""
    @State private var titles: [Card] = []
    @State private var people: [CastMember] = []
    @State private var music: [Card] = []
    @State private var understood: String?
    @State private var searching = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 50) {
                if let understood { Text("Understood as: \(understood)").font(.title3).foregroundStyle(Theme.accent).padding(.horizontal, Theme.sidePadding) }
                if !titles.isEmpty {
                    PosterGrid(cards: titles).padding(.horizontal, Theme.sidePadding)
                }
                if !people.isEmpty {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("People").font(.system(size: 34, weight: .bold)).padding(.horizontal, Theme.sidePadding)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 40) {
                                ForEach(people, id: \.self) { p in
                                    NavigationLink(value: Route.person(id: p.id ?? "", name: p.name)) { PersonCell(name: p.name, role: nil, image: p.image) }
                                        .buttonStyle(QuietButtonStyle())
                                }
                            }
                            .padding(.vertical, 30).padding(.horizontal, Theme.sidePadding)
                        }
                        .focusSection()
                    }
                }
                CardRow(title: "Music", cards: music)
                if text.count < 2 {
                    Text("Type a name, or describe it: \"80s horror movies\", \"shows with Pedro Pascal\".")
                        .font(.title3).foregroundStyle(Theme.dim).padding(.horizontal, Theme.sidePadding)
                } else if titles.isEmpty && people.isEmpty && music.isEmpty {
                    LoadState(loading: searching, error: error, empty: "Nothing found for \"\(text)\".")
                }
            }
            .padding(.vertical, 40)
        }
        .searchable(text: $text, prompt: "Movies, shows, people, artists")
        .task(id: text) {
            // Waits for a pause in typing, like HolyArrs' own search field.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await search(text.trimmingCharacters(in: .whitespaces))
        }
    }

    private func search(_ q: String) async {
        guard q.count >= 2 else { titles = []; people = []; music = []; understood = nil; return }
        searching = true
        defer { searching = false }
        do {
            if SearchView.describes(q) {
                let j = try await api.get("search", ["q": q])
                if !j["query"]["plain"].bool {
                    understood = SearchView.understood(j["query"])
                    let lib = j["titles"].array.map { Card(title: $0) }
                    let more = j["more"].array.map { Card(provider: $0, row: "more") }
                    if !lib.isEmpty || !more.isEmpty {
                        titles = lib + more
                        people = []
                        music = []
                        error = nil
                        return
                    }
                }
            }
            understood = nil
            let s = try await api.get("search/suggest", ["q": q])
            let items = s["items"].array
            titles = items.filter { ["movie", "show"].contains($0["kind"].string ?? "") }.map { Card(suggest: $0) }
            people = items.filter { $0["kind"].string == "person" }.compactMap { p in
                p["person_id"].string.map { CastMember(id: $0, name: p["name"].string ?? "", role: nil, image: p["art"].string) }
            }
            music = items.filter { ["artist", "album", "song"].contains($0["kind"].string ?? "") }.map { m -> Card in
                var o = m.object
                o["kind"] = .string("artist")
                if m["kind"].string != "artist" { o["mbid"] = m["artist_mbid"]; o["title_id"] = .null }
                return Card(suggest: .object(o))
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The same test HolyArrs' web app uses before trying a plain-words search (lib/discover/search-plain.ts).
    static func describes(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        let words = t.split(separator: " ").count
        if t.count > 300 || words < 2 { return false }
        let lower = t.lowercased()
        func has(_ pattern: String) -> Bool { lower.range(of: pattern, options: .regularExpression) != nil }
        let kind = has(#"\b(movies?|films?|shows?|series|tv|sitcom)\b"#)
        let years = has(#"\b(from|in|after|before|since|around)\s+(18[7-9]\d|19\d\d|20\d\d)\b|\b'?\d0'?s\b|\b(18|19|20)\d0s\b|\b(twenties|thirties|forties|fifties|sixties|seventies|eighties|nineties)\b"#)
        let about = has(#"\b(starring|featuring|about|with)\b"#) && words >= 3
        return kind || years || about
    }

    static func understood(_ q: JSON) -> String {
        let kind = ["movie": "movies", "show": "shows", "music": "music"][q["kind"].string ?? ""] ?? "titles"
        var parts: [String] = []
        if let n = q["name"].string { parts.append("\"\(n)\"") }
        parts.append(([q["genres"].names.joined(separator: " or ")].filter { !$0.isEmpty } + [kind]).joined(separator: " "))
        let from = q["year_from"].int, to = q["year_to"].int
        if let f = from, let t = to { parts.append(f == t ? "\(f)" : "\(f)-\(t)") } else if let f = from { parts.append("\(f) or later") } else if let t = to { parts.append("\(t) or earlier") }
        let ppl = q["people"].names
        if !ppl.isEmpty { parts.append("with " + ppl.joined(separator: ", ")) }
        let words = q["words"].names
        if !words.isEmpty { parts.append("about " + words.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}
