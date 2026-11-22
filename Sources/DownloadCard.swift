import SwiftUI

// A title's download, shown on its own page the moment it is asked for: looking for a copy, then downloading with
// progress, speed and time left (HolyArrs' GET /downloads/view), and from the PC whether it can already play while it
// downloads (GET /grow/status: the rest arrives before the film would reach it), with Play once it can.

struct TitleDownloadCard: View {
    let name: String
    let year: Int?
    let titleId: Int?
    let runtimeMinutes: Int?
    /// When it was asked for here (shows "Looking for a copy" until HolyArrs' download appears).
    let askedAt: Date?
    /// Called once a download this card showed has finished (the page reloads: Play in 4K appears).
    var finished: () -> Void = {}
    @EnvironmentObject private var api: HolyArrs
    @EnvironmentObject private var rtx: RTXServer
    @State private var rows: [JSON] = []
    @State private var grow: [String: JSON] = [:]
    @State private var shown = false
    @State private var watching: LiveRequest?

    private var looking: Bool { rows.isEmpty && (askedAt.map { Date().timeIntervalSince($0) < 15 * 60 } ?? false) }

    var body: some View {
        // A container that is always there (an empty Group has nothing to run .task on, so it never polled).
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(width: 0, height: 0)
            if !rows.isEmpty || looking {
                VStack(alignment: .leading, spacing: S(18)) {
                    if rows.isEmpty {
                        HStack(spacing: S(16)) {
                            ProgressView()
                            Text("Looking for the best copy...").font(.system(size: F(28), weight: .semibold))
                        }
                        Text("It starts downloading by itself; this fills in as soon as it does.")
                            .font(.system(size: F(22))).foregroundStyle(Theme.dim)
                    }
                    ForEach(rows.indices, id: \.self) { i in row(rows[i]) }
                }
                .padding(S(28))
                .frame(maxWidth: W(1150), alignment: .leading)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: S(20), style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: S(20), style: .continuous).stroke(Theme.accent.opacity(0.35), lineWidth: 1))
            }
        }
        .task(id: "\(titleId ?? -1)|\(name)|\(askedAt?.timeIntervalSince1970 ?? 0)") {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        .fullScreenCover(item: $watching) { LivePlayerScreen(request: $0) }
    }

    private func row(_ d: JSON) -> some View {
        let release = d["name"].string ?? ""
        let g = grow[release] ?? .null
        let progress = d["progress"].double ?? 0
        return VStack(alignment: .leading, spacing: S(12)) {
            HStack(spacing: S(14)) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accent)
                Text(d["label"].string ?? "Downloading").font(.system(size: F(28), weight: .semibold))
                if let v = d["version"].string, v != "Main" { Badge(text: v) }
                Spacer(minLength: 0)
                Text("\(Int(progress * 100))%").font(.system(size: F(26), weight: .bold)).monospacedDigit()
            }
            ProgressView(value: min(1, max(0, progress))).tint(Theme.accent)
            Text(detail(d)).font(.system(size: F(22))).foregroundStyle(Theme.dim)
            if g["playable"].bool {
                Button {
                    watching = LiveRequest(stream: release, title: name, grow: release)
                } label: {
                    Label("Play now while it downloads", systemImage: "play.fill").font(.system(size: F(28), weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                Text("It finishes downloading before the film could catch up, so it plays start to finish.")
                    .font(.system(size: F(20))).foregroundStyle(Theme.dim)
            } else if let wait = g["playable_in_s"].int, wait > 0 {
                Label("Playable in about \(Self.minutes(wait))", systemImage: "clock").font(.system(size: F(24), weight: .semibold))
                    .foregroundStyle(Theme.accent)
            } else if let why = g["reason"].string, !g.isNull {
                Text(why).font(.system(size: F(20))).foregroundStyle(Theme.dim)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// "3.2 of 7.6 GB · 18 MB/s · 4 min left".
    private func detail(_ d: JSON) -> String {
        var bits: [String] = []
        if let size = d["size"].double, size > 0 {
            let got = size * (d["progress"].double ?? 0)
            bits.append(String(format: "%.1f of %.1f GB", got / 1e9, size / 1e9))
        }
        if let sp = d["speed"].double, sp > 0 { bits.append(String(format: "%.0f MB/s", sp / 1e6)) }
        if let eta = d["eta"].int, eta > 0 { bits.append("\(Self.minutes(eta)) left") }
        return bits.isEmpty ? (d["text"].string ?? " ") : bits.joined(separator: " \u{00B7} ")
    }

    static func minutes(_ s: Int) -> String {
        if s < 90 { return "1 min" }
        let m = (s + 30) / 60
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m) min"
    }

    private func matches(_ d: JSON) -> Bool {
        if let id = titleId, d["title_id"].int == id { return true }
        let n = (d["title"].string ?? "").lowercased()
        return !n.isEmpty && n == name.lowercased() && (year == nil || d["year"].int == nil || d["year"].int == year)
    }

    private func load() async {
        guard let j = try? await api.get("downloads/view", ["limit": "100"]) else { return }
        let mine = j["downloads"].array.filter { matches($0) && !["done", "removed", "failed"].contains($0["phase"].string ?? "") }
        if shown, mine.isEmpty, !rows.isEmpty { finished() }  // it was coming in and now it's done
        rows = mine
        shown = shown || !mine.isEmpty
        guard let base = rtx.base else { return }
        for d in mine where (d["phase"].string ?? "") == "downloading" {
            guard let release = d["name"].string else { continue }
            var q = [URLQueryItem(name: "name", value: release)]
            if let r = runtimeMinutes, r > 0 { q.append(URLQueryItem(name: "runtime", value: String(r * 60))) }
            if let g = try? await RTXAPI(base: base).get("grow/status", q) { grow[release] = g }
        }
    }
}
