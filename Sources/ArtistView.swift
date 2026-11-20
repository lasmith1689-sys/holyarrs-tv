import SwiftUI

/// An artist (GET /music/artists/{mbid}), in the Library or not: picture, summary, albums with their Library
/// state, top songs and similar artists. Ask for the whole artist or for chosen albums.
struct ArtistView: View {
    let ref: TitleRef
    @EnvironmentObject private var api: HolyArrs
    @State private var page: JSON = .null
    @State private var picked: Set<String> = []
    @State private var error: String?
    @State private var loading = true
    @State private var message: String?
    @State private var busy = false

    private var albums: [JSON] { page["albums"].array }
    private var inLibrary: Bool { page["title_id"].int != nil }

    var body: some View {
        ZStack {
            BlurredArt(raw: page["image"].string)
            ScrollView {
                VStack(alignment: .leading, spacing: S(50)) {
                    AdaptiveStack(tvAlignment: .top, spacing: S(70)) {
                        Artwork(raw: page["image"].string, width: 500, title: ref.name)
                            .frame(width: W(420), height: S(420))
                            .clipShape(RoundedRectangle(cornerRadius: S(18), style: .continuous))
                            .shadow(color: .black.opacity(0.6), radius: S(40), y: 20)
                        VStack(alignment: .leading, spacing: S(22)) {
                            Text(page["name"].string ?? ref.name).font(.system(size: F(72), weight: .bold)).lineLimit(2).minimumScaleFactor(0.6)
                            Text(([page["type"].string, page["country"].string] + page["genres"].names.prefix(3).map(Optional.some)).compactMap { $0 }.joined(separator: " · "))
                                .font(.title3).foregroundStyle(Theme.dim)
                            if inLibrary {
                                Label("In library: \(page["have"].int ?? 0) of \(page["total"].int ?? 0)", systemImage: "checkmark.circle.fill")
                                    .font(.system(size: F(26), weight: .semibold)).foregroundStyle(Theme.accent)
                            }
                            if let bio = page["bio"]["extract"].string {
                                Text(bio).font(.system(size: F(24))).foregroundStyle(Color.white.opacity(0.75)).lineLimit(5).frame(maxWidth: W(1150), alignment: .leading)
                            }
                            HStack(spacing: S(30)) {
                                if api.me?.canAsk == true {
                                    Button {
                                        Task { await ask(Array(picked)) }
                                    } label: {
                                        Label(picked.isEmpty ? (inLibrary ? "Ask for the rest" : "Ask for this artist") : "Ask for \(picked.count) album\(picked.count == 1 ? "" : "s")",
                                              systemImage: "plus")
                                            .font(.system(size: F(30), weight: .semibold)).padding(.horizontal, S(30))
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(busy)
                                }
                            }
                            .padding(.top, S(10))
                            if let message { Text(message).foregroundStyle(Theme.accent) }
                        }
                    }
                    .padding(.horizontal, S(110))
                    .tvFocusSection()

                    ForEach(shelves, id: \.self) { shelf in
                        let items = albums.filter { ($0["shelf"].string ?? "albums") == shelf }
                        VStack(alignment: .leading, spacing: S(18)) {
                            Text(shelf.capitalized).font(.system(size: F(34), weight: .bold)).padding(.horizontal, Theme.sidePadding)
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: S(40)) {
                                    ForEach(items.indices, id: \.self) { i in
                                        let a = items[i]
                                        let id = a["mbid"].string ?? ""
                                        Button {
                                            if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
                                        } label: {
                                            AlbumCell(album: a, picked: picked.contains(id))
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
                    let similar = page["similar"].array.map { s in
                        Card(music: .object(["kind": .string("artist"), "mbid": s["mbid"], "name": s["name"], "image": s["image"]]), row: "similar")
                    }
                    CardRow(title: "Similar artists", cards: similar)
                    if albums.isEmpty { LoadState(loading: loading, error: error, empty: "No albums found.") }
                }
                .padding(.vertical, S(70))
            }
        }
        .task { await load() }
    }

    private var shelves: [String] {
        var seen: [String] = []
        for a in albums { let s = a["shelf"].string ?? "albums"; if !seen.contains(s) { seen.append(s) } }
        return seen
    }

    private func mbid() async -> String? {
        if let m = ref.mbid { return m }
        guard let id = ref.titleId, let t = try? await api.get("titles/\(id)") else { return nil }
        return t["artist"]["mbid"].string ?? t["ids"]["mbid"].string
    }

    private func load() async {
        defer { loading = false }
        guard let m = await mbid() else { error = "This artist has no MusicBrainz id."; return }
        do { page = try await api.get("music/artists/\(m)"); error = nil } catch { self.error = error.localizedDescription }
    }

    private func ask(_ albums: [String]) async {
        guard let m = page["mbid"].string ?? ref.mbid else { return }
        busy = true
        defer { busy = false }
        var body: [String: Any] = ["id": "mbid:\(m)", "kind": "artist"]
        if !albums.isEmpty { body["albums"] = albums }
        do {
            let a = try await api.post("asks", body)
            message = "Asked: \(a["ask"]["state_label"].string ?? "waiting")."
            picked = []
            await load()
        } catch {
            message = error.localizedDescription
        }
    }
}

struct AlbumCell: View {
    let album: JSON
    let picked: Bool
    @Environment(\.isFocused) private var focused

    var body: some View {
        VStack(alignment: .leading, spacing: S(10)) {
            Artwork(raw: album["image"].string, width: 342, title: album["name"].string ?? "")
                .frame(width: W(250), height: S(250))
                .overlay(alignment: .topTrailing) {
                    if picked {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: F(40))).foregroundStyle(Theme.accent).padding(S(10))
                    } else if let s = album["state"].string {
                        StatusDot(status: s == "in_library" || s == "have" ? "In library" : s.replacingOccurrences(of: "_", with: " ").capitalized).padding(S(10))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: S(12), style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: S(12), style: .continuous).stroke(picked ? Theme.accent : Color.white.opacity(focused ? 0.9 : 0.08), lineWidth: focused || picked ? 4 : 1))
                .scaleEffect(focused ? 1.08 : 1)
            Text(album["name"].string ?? "").font(.system(size: F(22), weight: .semibold)).lineLimit(1)
            Text(album["release_date"].string.map { String($0.prefix(4)) } ?? " ").font(.system(size: F(19))).foregroundStyle(Theme.dim)
        }
        .frame(width: W(250), alignment: .leading)
        .foregroundStyle(focused ? Color.white : Color.white.opacity(0.75))
        .animation(.easeOut(duration: 0.18), value: focused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((album["name"].string ?? "") + (picked ? ", picked" : ""))
    }
}
