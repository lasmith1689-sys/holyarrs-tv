import SwiftUI

/// The RTX 4K app's look: near-black gradient, warm amber accent like a cinema marquee, dim secondary text.
enum Theme {
    static let background = LinearGradient(colors: [Color(white: 0.11), Color(white: 0.04)],
                                           startPoint: .top, endPoint: .bottom)
    static let accent = Color(red: 0.98, green: 0.74, blue: 0.20)
    static let dim = Color.white.opacity(0.55)
    static let sidePadding: CGFloat = S(80)
}

/// Buttons draw their own focus look (PosterCell, WideCell, ListRow), so the system highlight is turned off.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// A picture from HolyArrs (its TMDB cache or its own artwork), with a typographic stand-in underneath.
struct Artwork: View {
    @EnvironmentObject private var api: HolyArrs
    let raw: String?
    var width = 342
    var title: String = ""
    var subtitle: String? = nil
    /// No stand-in (logos sit on top of other art).
    var plain = false
    var fit = false

    var body: some View {
        ZStack {
            if !plain {
                LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            if !title.isEmpty {
                VStack(spacing: S(10)) {
                    Text(title).font(.system(size: F(26), weight: .bold)).multilineTextAlignment(.center)
                    if let subtitle { Text(subtitle).font(.system(size: F(20))).foregroundStyle(Theme.dim) }
                }
                .padding(S(20))
            }
            if let url = api.image(raw, width: width) {
                AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: 0.25))) { phase in
                    if let image = phase.image { image.resizable().aspectRatio(contentMode: fit ? .fit : .fill) }
                }
            }
        }
    }
}

/// Posters HolyArrs leaves out of some answers (Library titles, Library hits in search suggestions): read once
/// from the title's TMDB page through HolyArrs (GET /metadata/{kind}/{tmdb}) and kept for the session.
@MainActor
final class PosterCache {
    static let shared = PosterCache()
    private var known: [String: String] = [:]
    private var asking: [String: Task<String?, Never>] = [:]

    func poster(_ api: HolyArrs, kind: Card.Kind, tmdb: String) async -> String? {
        let key = "\(kind.rawValue):\(tmdb)"
        if let p = known[key] { return p }
        if let t = asking[key] { return await t.value }
        let t = Task { () -> String? in
            (try? await api.get("metadata/\(kind.rawValue)/\(tmdb)"))?["poster"].string
        }
        asking[key] = t
        let p = await t.value
        asking[key] = nil
        if let p { known[key] = p }
        return p
    }
}

/// A poster that lifts and glows when focused, with its title underneath (as in RTX 4K's gallery).
struct PosterCell: View {
    let card: Card
    var width: CGFloat = S(250)
    @Environment(\.isFocused) private var focused
    @EnvironmentObject private var api: HolyArrs
    @State private var fetched: String?

    var body: some View {
        VStack(alignment: .leading, spacing: S(14)) {
            Artwork(raw: card.poster ?? fetched, width: 342, title: card.name, subtitle: card.year.map(String.init))
                .task(id: card.id) {
                    guard card.poster == nil, card.kind != .artist, let tmdb = card.tmdb else { return }
                    fetched = await PosterCache.shared.poster(api, kind: card.kind, tmdb: tmdb)
                }
                .frame(width: width, height: width * 1.5)
                .overlay(alignment: .topTrailing) {
                    if let status = card.status { StatusDot(status: status).padding(S(12)) }
                }
                .clipShape(RoundedRectangle(cornerRadius: S(14), style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: S(14), style: .continuous)
                    .stroke(Color.white.opacity(focused ? 0.9 : 0.08), lineWidth: focused ? 4 : 1))
                .shadow(color: .black.opacity(focused ? 0.7 : 0.35), radius: focused ? 30 : 10, y: focused ? 20 : 6)
                .scaleEffect(focused ? 1.08 : 1.0)
            VStack(alignment: .leading, spacing: S(4)) {
                Text(card.name).font(.system(size: F(24), weight: .semibold)).lineLimit(1)
                Text(card.line ?? card.stableYear).font(.system(size: F(21))).foregroundStyle(Theme.dim).lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
            .foregroundStyle(focused ? Color.white : Color.white.opacity(0.75))
            .offset(y: focused ? S(14) : 0)
        }
        .animation(.easeOut(duration: 0.18), value: focused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.year.map { "\(card.name), \($0)" } ?? card.name)
    }
}

/// A wide backdrop card with the title's logo or name on it (Explore's movie and show rows).
struct WideCell: View {
    let card: Card
    @Environment(\.isFocused) private var focused

    var body: some View {
        VStack(alignment: .leading, spacing: S(12)) {
            ZStack(alignment: .bottomLeading) {
                Artwork(raw: card.backdrop ?? card.poster, width: 780, title: card.backdrop == nil && card.poster == nil ? card.name : "")
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                Group {
                    if let logo = card.logo {
                        Artwork(raw: logo, width: 500, plain: true, fit: true).frame(width: W(260), height: S(90), alignment: .bottomLeading)
                    } else {
                        Text(card.name).font(.system(size: F(30), weight: .heavy)).lineLimit(2).shadow(radius: S(6))
                    }
                }
                .padding(S(20))
            }
            .frame(width: W(480), height: S(270))
            .overlay(alignment: .topTrailing) {
                if let status = card.status { StatusDot(status: status).padding(S(14)) }
            }
            .clipShape(RoundedRectangle(cornerRadius: S(14), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: S(14), style: .continuous)
                .stroke(Color.white.opacity(focused ? 0.9 : 0.08), lineWidth: focused ? 4 : 1))
            .shadow(color: .black.opacity(focused ? 0.7 : 0.35), radius: focused ? 30 : 10, y: focused ? 20 : 6)
            .scaleEffect(focused ? 1.06 : 1.0)
            Text(card.line ?? card.stableYear)
                .font(.system(size: F(21))).foregroundStyle(Theme.dim).lineLimit(1)
                .frame(width: W(480), alignment: .leading)
                .offset(y: focused ? S(12) : 0)
        }
        .animation(.easeOut(duration: 0.18), value: focused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.year.map { "\(card.name), \($0)" } ?? card.name)
    }
}

/// A small amber marker on a card: in the Library, asked for, downloading.
struct StatusDot: View {
    let status: String

    var body: some View {
        Text(status.uppercased())
            .font(.system(size: F(15), weight: .heavy))
            .tracking(1)
            .padding(.horizontal, S(10))
            .padding(.vertical, S(5))
            .background(Capsule().fill(status == "In library" ? Theme.accent : Color.black.opacity(0.7)))
            .foregroundStyle(status == "In library" ? Color.black : Theme.accent)
    }
}

struct Badge: View {
    let text: String
    var focused = false

    var body: some View {
        Text(text)
            .font(.system(size: F(18), weight: .bold))
            .tracking(1.2)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, S(12))
            .padding(.vertical, S(5))
            .overlay(RoundedRectangle(cornerRadius: S(6)).stroke(focused ? Color.black.opacity(0.5) : Color.white.opacity(0.4), lineWidth: S(2)))
            .foregroundStyle(focused ? Color.black.opacity(0.7) : Color.white.opacity(0.8))
    }
}

/// One titled, horizontally scrolling row of cards that open their title page.
struct CardRow: View {
    let title: String
    var subtitle: String? = nil
    let cards: [Card]
    var wide = false

    var body: some View {
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: S(18)) {
                VStack(alignment: .leading, spacing: S(4)) {
                    Text(title).font(.system(size: F(34), weight: .bold))
                    if let subtitle { Text(subtitle).font(.system(size: F(22))).foregroundStyle(Theme.dim) }
                }
                .padding(.horizontal, Theme.sidePadding)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: wide ? S(40) : S(46)) {
                        ForEach(cards) { card in
                            NavigationLink(value: card.route) {
                                if wide { WideCell(card: card) } else { PosterCell(card: card) }
                            }
                            .buttonStyle(QuietButtonStyle())
                        }
                    }
                    .padding(.vertical, S(30))  // room for the focused card to lift
                    .padding(.horizontal, Theme.sidePadding)
                }
                .tvFocusSection()
            }
        }
    }
}

/// A grid of posters (search results, a person's films, a genre).
struct PosterGrid: View {
    let cards: [Card]
    private let columns = Device.isTV
        ? Array(repeating: GridItem(.fixed(250), spacing: 46, alignment: .top), count: 6)
        : [GridItem(.adaptive(minimum: S(250)), spacing: S(46), alignment: .top)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: S(60)) {
            ForEach(cards) { card in
                NavigationLink(value: card.route) { PosterCell(card: card) }
                    .buttonStyle(QuietButtonStyle())
            }
        }
        .tvFocusSection()
    }
}

/// Loading, error and empty states in one place.
struct LoadState: View {
    let loading: Bool
    let error: String?
    var empty: String? = nil
    var retry: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: S(26)) {
            if loading {
                ProgressView()
            } else if let error {
                Image(systemName: "wifi.exclamationmark").font(.system(size: F(80))).foregroundStyle(Theme.dim)
                Text(error).foregroundStyle(Theme.dim).multilineTextAlignment(.center).frame(maxWidth: W(1200))
                if let retry { Button("Try again", action: retry) }
            } else if let empty {
                Text(empty).foregroundStyle(Theme.dim)
            }
        }
        .frame(maxWidth: .infinity, minHeight: S(300))
    }
}

/// The page background used under every screen.
struct Backdrop: View {
    var body: some View { Theme.background.ignoresSafeArea() }
}

/// Blurred art behind a title or person page (kept in an overlay so its aspect-fill size never stretches the layout).
struct BlurredArt: View {
    let raw: String?

    var body: some View {
        Color.black
            .overlay { Artwork(raw: raw, width: 780).blur(radius: S(60)).opacity(0.45) }
            .clipped()
            .ignoresSafeArea()
        LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.88)], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}
