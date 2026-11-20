import SwiftUI

/// A person (GET /people/{id}): picture, life, and their films with each one's Library and ask state.
/// Cast members without a TMDB id are found by name first (GET /people/search).
struct PersonView: View {
    let id: String
    let name: String
    @EnvironmentObject private var api: HolyArrs
    @State private var person: JSON = .null
    @State private var library: [Card] = []
    @State private var known: [Card] = []
    @State private var soon: [Card] = []
    @State private var all: [Card] = []
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        ZStack {
            BlurredArt(raw: person["profile"].string)
            ScrollView {
                VStack(alignment: .leading, spacing: S(50)) {
                    AdaptiveStack(tvAlignment: .top, spacing: S(70)) {
                        Artwork(raw: person["profile"].string, width: 342, title: String(name.prefix(1)))
                            .frame(width: W(300), height: S(450))
                            .clipShape(RoundedRectangle(cornerRadius: S(18), style: .continuous))
                        VStack(alignment: .leading, spacing: S(20)) {
                            Text(person["name"].string ?? name).font(.system(size: F(66), weight: .bold))
                            Text([person["department"].string, person["birthday"].string.map { "Born \($0)" }, person["birthplace"].string]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.title3).foregroundStyle(Theme.dim)
                            if let bio = person["biography"].string {
                                Text(bio).font(.system(size: F(24))).foregroundStyle(Color.white.opacity(0.75)).lineLimit(8).frame(maxWidth: W(1200), alignment: .leading)
                            }
                        }
                    }
                    .padding(.horizontal, S(110))
                    .tvFocusable()  // so Up from the rows can reach the top and the long bio can be read

                    CardRow(title: "In your library", cards: library)
                    CardRow(title: "Known for", cards: known)
                    CardRow(title: "Coming soon", cards: soon)
                    if !all.isEmpty {
                        Text("Every film").font(.system(size: F(34), weight: .bold)).padding(.horizontal, Theme.sidePadding)
                        PosterGrid(cards: all).padding(.horizontal, Theme.sidePadding)
                    }
                    if all.isEmpty && known.isEmpty { LoadState(loading: loading, error: error, empty: "No films found.") }
                }
                .padding(.vertical, S(70))
            }
        }
        .task { await load() }
    }

    private func load() async {
        defer { loading = false }
        do {
            var pid = id
            if pid.isEmpty {
                let s = try await api.get("people/search", ["q": name])
                guard let first = s["people"].array.first?["id"].string else { error = "No one called \(name) was found."; return }
                pid = first
            }
            let j = try await api.get("people/\(pid)", ["page_size": "100"])
            person = j["person"]
            func cards(_ k: String) -> [Card] {
                j[k].array.map { m in
                    var o = m.object
                    if o["kind"] == nil { o["kind"] = .string("movie") }
                    if !(o["characters"]?.array.isEmpty ?? true) { o["line"] = o["characters"]?[0] }
                    return Card(provider: .object(o), row: k)
                }
            }
            library = cards("library")
            known = cards("known_for")
            soon = cards("coming_soon")
            all = cards("movies")
        } catch {
            self.error = error.localizedDescription
        }
    }
}
