import SwiftUI

/// The RTX 4K app's look: near-black gradient, warm amber accent like a cinema marquee, dim secondary text.
enum Theme {
    static let background = LinearGradient(colors: [Color(white: 0.11), Color(white: 0.04)],
                                           startPoint: .top, endPoint: .bottom)
    static let accent = Color(red: 0.98, green: 0.74, blue: 0.20)
    static let dim = Color.white.opacity(0.55)
    static let sidePadding: CGFloat = 80
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
                VStack(spacing: 10) {
                    Text(title).font(.system(size: 26, weight: .bold)).multilineTextAlignment(.center)
                    if let subtitle { Text(subtitle).font(.system(size: 20)).foregroundStyle(Theme.dim) }
                }
                .padding(20)
            }
            if let url = api.image(raw, width: width) {
                AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: 0.25))) { phase in
                    if let image = phase.image { image.resizable().aspectRatio(contentMode: fit ? .fit : .fill) }
                }
            }
        }
    }
}

/// A poster that lifts and glows when focused, with its title underneath (as in RTX 4K's gallery).
struct PosterCell: View {
    let card: Card
    var width: CGFloat = 250
    @Environment(\.isFocused) private var focused

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Artwork(raw: card.poster, width: 342, title: card.name, subtitle: card.year.map(String.init))
                .frame(width: width, height: width * 1.5)
                .overlay(alignment: .topTrailing) {
                    if let status = card.status { StatusDot(status: status).padding(12) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(focused ? 0.9 : 0.08), lineWidth: focused ? 4 : 1))
                .shadow(color: .black.opacity(focused ? 0.7 : 0.35), radius: focused ? 30 : 10, y: focused ? 20 : 6)
                .scaleEffect(focused ? 1.08 : 1.0)
            VStack(alignment: .leading, spacing: 4) {
                Text(card.name).font(.system(size: 24, weight: .semibold)).lineLimit(1)
                Text(card.line ?? card.stableYear).font(.system(size: 21)).foregroundStyle(Theme.dim).lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
            .foregroundStyle(focused ? Color.white : Color.white.opacity(0.75))
            .offset(y: focused ? 14 : 0)
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
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .bottomLeading) {
                Artwork(raw: card.backdrop ?? card.poster, width: 780, title: card.backdrop == nil && card.poster == nil ? card.name : "")
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                Group {
                    if let logo = card.logo {
                        Artwork(raw: logo, width: 500, plain: true, fit: true).frame(width: 260, height: 90, alignment: .bottomLeading)
                    } else {
                        Text(card.name).font(.system(size: 30, weight: .heavy)).lineLimit(2).shadow(radius: 6)
                    }
                }
                .padding(20)
            }
            .frame(width: 480, height: 270)
            .overlay(alignment: .topTrailing) {
                if let status = card.status { StatusDot(status: status).padding(14) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(focused ? 0.9 : 0.08), lineWidth: focused ? 4 : 1))
            .shadow(color: .black.opacity(focused ? 0.7 : 0.35), radius: focused ? 30 : 10, y: focused ? 20 : 6)
            .scaleEffect(focused ? 1.06 : 1.0)
            Text(card.line ?? card.stableYear)
                .font(.system(size: 21)).foregroundStyle(Theme.dim).lineLimit(1)
                .frame(width: 480, alignment: .leading)
                .offset(y: focused ? 12 : 0)
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
            .font(.system(size: 15, weight: .heavy))
            .tracking(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(status == "In library" ? Theme.accent : Color.black.opacity(0.7)))
            .foregroundStyle(status == "In library" ? Color.black : Theme.accent)
    }
}

struct Badge: View {
    let text: String
    var focused = false

    var body: some View {
        Text(text)
            .font(.system(size: 18, weight: .bold))
            .tracking(1.2)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? Color.black.opacity(0.5) : Color.white.opacity(0.4), lineWidth: 2))
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
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 34, weight: .bold))
                    if let subtitle { Text(subtitle).font(.system(size: 22)).foregroundStyle(Theme.dim) }
                }
                .padding(.horizontal, Theme.sidePadding)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: wide ? 40 : 46) {
                        ForEach(cards) { card in
                            NavigationLink(value: card.route) {
                                if wide { WideCell(card: card) } else { PosterCell(card: card) }
                            }
                            .buttonStyle(QuietButtonStyle())
                        }
                    }
                    .padding(.vertical, 30)  // room for the focused card to lift
                    .padding(.horizontal, Theme.sidePadding)
                }
                .focusSection()
            }
        }
    }
}

/// A grid of posters (search results, a person's films, a genre).
struct PosterGrid: View {
    let cards: [Card]
    private let columns = Array(repeating: GridItem(.fixed(250), spacing: 46, alignment: .top), count: 6)

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 60) {
            ForEach(cards) { card in
                NavigationLink(value: card.route) { PosterCell(card: card) }
                    .buttonStyle(QuietButtonStyle())
            }
        }
        .focusSection()
    }
}

/// Loading, error and empty states in one place.
struct LoadState: View {
    let loading: Bool
    let error: String?
    var empty: String? = nil
    var retry: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 26) {
            if loading {
                ProgressView()
            } else if let error {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 80)).foregroundStyle(Theme.dim)
                Text(error).foregroundStyle(Theme.dim).multilineTextAlignment(.center).frame(maxWidth: 1200)
                if let retry { Button("Try again", action: retry) }
            } else if let empty {
                Text(empty).foregroundStyle(Theme.dim)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 300)
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
            .overlay { Artwork(raw: raw, width: 780).blur(radius: 60).opacity(0.45) }
            .clipped()
            .ignoresSafeArea()
        LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.88)], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}
