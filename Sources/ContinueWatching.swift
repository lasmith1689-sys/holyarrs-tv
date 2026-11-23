import SwiftUI

// Continue Watching: the first row on Home. Everything left part-way on any screen (positions are kept on the PC,
// so a film stopped on the iPhone shows on the Apple TV too), newest first. Selecting a card plays straight from
// where it was left; holding it offers the page, starting over, or taking it off the row.

struct ContinueEntry: Identifiable, Hashable {
    let id: String
    let seconds: Double
    let duration: Double
    let at: Date
    let place: String

    var left: String {
        let m = max(0, Int((duration - seconds) / 60))
        return m >= 60 ? "\(m / 60)h \(m % 60)m left" : "\(m)m left"
    }

    var progress: Double { duration > 0 ? min(1, seconds / duration) : 0 }

    var placeLabel: String? {
        switch place {
        case "iphone": "on iPhone"
        case "apple-tv": "on Apple TV"
        case "outside": "outside"
        default: nil
        }
    }
}

/// Art for an RTX film: the HolyArrs Library title with the same name and year (looked up once per film).
@MainActor
final class ContinueArt: ObservableObject {
    static let shared = ContinueArt()
    @Published private(set) var cards: [String: Card] = [:]
    private var asked: Set<String> = []

    func card(for film: RTXFilm, api: HolyArrs) async {
        guard !asked.contains(film.id) else { return }
        asked.insert(film.id)
        guard let s = try? await api.get("search/suggest", ["q": film.title]) else { asked.remove(film.id); return }
        let key = RTXServer.key(film.title)
        let hit = s["items"].array.first { j in
            j["kind"].string == "movie" && RTXServer.key(j["name"].string ?? "") == key
                && (film.year == nil || j["year"].int == nil || abs((j["year"].int ?? 0) - (film.year ?? 0)) <= 1)
        }
        guard let hit else { return }
        var card = Card(suggest: hit)
        // The Library title has the wide backdrop and logo the suggestion lacks.
        if let tid = card.titleId, let t = try? await api.get("titles/\(tid)") { card = Card(title: t) }
        cards[film.id] = card
    }
}

struct ContinueRow: View {
    /// Home's focus: the first card answers to `firstFocus`, so the Apple TV starts there.
    var focus: FocusState<String?>.Binding
    static let firstFocus = "continue-first"
    @EnvironmentObject private var rtx: RTXServer
    @EnvironmentObject private var api: HolyArrs
    @ObservedObject private var art = ContinueArt.shared
    @State private var playing: PlayRequest?

    private var entries: [(ContinueEntry, RTXFilm)] {
        rtx.continueList.compactMap { e in rtx.film(id: e.id).map { (e, $0) } }
    }

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: S(18)) {
                Text("Continue Watching").font(.system(size: F(34), weight: .bold))
                    .padding(.horizontal, Theme.sidePadding)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: S(40)) {
                        let list = entries
                        ForEach(list.indices, id: \.self) { i in
                            let (entry, film) = list[i]
                            let card = art.cards[film.id]
                            Button {
                                playing = PlayRequest(label: card?.name ?? film.title, film: film, seconds: entry.seconds,
                                                      backdrop: card?.backdrop)
                            } label: {
                                ContinueCell(entry: entry, film: film, card: card)
                            }
                            .buttonStyle(QuietButtonStyle())
                            .focused(focus, equals: i == 0 ? ContinueRow.firstFocus : "continue-\(entry.id)")
                            .contextMenu {
                                if let card {
                                    NavigationLink(value: card.route) { Label("Details", systemImage: "info.circle") }
                                }
                                Button {
                                    playing = PlayRequest(label: card?.name ?? film.title, film: film, seconds: 0, backdrop: card?.backdrop)
                                } label: { Label("Start from the beginning", systemImage: "backward.end") }
                                Button(role: .destructive) { rtx.forget(entry.id, duration: entry.duration) } label: {
                                    Label("Remove from Continue Watching", systemImage: "xmark")
                                }
                            }
                            .task { await art.card(for: film, api: api) }
                        }
                    }
                    .padding(.vertical, S(30))
                    .padding(.horizontal, Theme.sidePadding)
                }
                .tvFocusSection()
            }
            .fullScreenCover(item: $playing) { req in
                PlayerScreen(request: req).onDisappear { Task { await rtx.syncPositions() } }
            }
        }
    }
}

struct ContinueCell: View {
    let entry: ContinueEntry
    let film: RTXFilm
    let card: Card?
    @Environment(\.isFocused) private var focused

    var body: some View {
        VStack(alignment: .leading, spacing: S(12)) {
            ZStack(alignment: .bottomLeading) {
                Artwork(raw: card?.backdrop ?? card?.poster, width: 780,
                        title: card?.backdrop == nil && card?.poster == nil ? film.title : "")
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: S(12)) {
                    if let logo = card?.logo {
                        Artwork(raw: logo, width: 500, plain: true, fit: true).frame(width: W(240), height: S(80), alignment: .bottomLeading)
                    } else {
                        Text(card?.name ?? film.title).font(.system(size: F(28), weight: .heavy)).lineLimit(2).shadow(radius: S(6))
                    }
                    // How far in: a thin amber bar across the bottom of the picture.
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.25))
                            Capsule().fill(Theme.accent).frame(width: g.size.width * entry.progress)
                        }
                    }
                    .frame(height: S(6))
                }
                .padding(S(20))
                Image(systemName: "play.fill")
                    .font(.system(size: F(26), weight: .bold))
                    .padding(S(14))
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(S(18))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .opacity(focused || !Device.isTV ? 1 : 0)
            }
            .frame(width: W(480), height: S(270))
            .clipShape(RoundedRectangle(cornerRadius: S(14), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: S(14), style: .continuous)
                .stroke(Color.white.opacity(focused ? 0.9 : 0.08), lineWidth: focused ? 4 : 1))
            .shadow(color: .black.opacity(focused ? 0.7 : 0.35), radius: focused ? 30 : 10, y: focused ? 20 : 6)
            .scaleEffect(focused ? 1.06 : 1.0)
            Text([entry.left, entry.placeLabel].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: F(21))).foregroundStyle(Theme.dim).lineLimit(1)
                .frame(width: W(480), alignment: .leading)
                .offset(y: focused ? S(12) : 0)
        }
        .animation(.easeOut(duration: 0.18), value: focused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Resume \(card?.name ?? film.title), \(entry.left)")
    }
}

/// One line under Home's hero when the PC or HolyArrs isn't answering: what still works stays on screen (the last
/// good lists), and Retry asks again now. Nothing shows while both answer.
struct ConnectionLine: View {
    @EnvironmentObject private var rtx: RTXServer
    @EnvironmentObject private var api: HolyArrs

    private var text: String? {
        let pc = rtx.reachable == false, holyarrs = api.unreachable
        if pc && holyarrs { return "PC and HolyArrs not answering" }
        if pc { return "PC not answering" }
        if holyarrs { return "HolyArrs not answering" }
        return nil
    }

    var body: some View {
        if let text {
            HStack(spacing: S(24)) {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(Theme.accent)
                Text(text).font(.system(size: F(26), weight: .semibold))
                Text("What's here is from the last time it answered.").font(.system(size: F(22))).foregroundStyle(Theme.dim)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button {
                    Task {
                        if api.unreachable { await api.restore() }
                        await rtx.refresh()
                    }
                } label: {
                    Label(rtx.checking || api.checking ? "Trying..." : "Retry", systemImage: "arrow.clockwise")
                        .font(.system(size: F(24), weight: .semibold))
                }
                .disabled(rtx.checking || api.checking)
                .accessibilityLabel("Retry")
            }
            .padding(.horizontal, S(28))
            .padding(.vertical, S(16))
            .overlay(RoundedRectangle(cornerRadius: S(16), style: .continuous).stroke(Theme.accent.opacity(0.7), lineWidth: 1.5))
            .padding(.horizontal, Theme.sidePadding)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("connection-line")
        }
    }
}
