import SwiftUI

/// Downloads (GET /downloads/view): what is coming in, with progress, speed and time left, refreshed every
/// 5 s; pause, resume and remove one, or pause and resume everything.
struct DownloadsView: View {
    @EnvironmentObject private var api: HolyArrs
    @State private var rows: [JSON] = []
    @State private var loading = true
    @State private var error: String?
    @State private var note: String?
    @State private var removing: JSON?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: S(24)) {
                AdaptiveStack(spacing: S(30)) {
                    Text("Downloads").font(.system(size: F(64), weight: .bold))
                    Text(summary).font(.title3).foregroundStyle(Theme.dim)
                    Spacer()
                    HStack(spacing: S(30)) {
                        Button("Pause all") { Task { await act("downloads/pause-all", "Paused everything.") } }
                        Button("Resume all") { Task { await act("downloads/resume-all", "Resumed everything.") } }
                    }
                }
                .tvFocusSection()
                if let note { Text(note).foregroundStyle(Theme.accent) }
                ForEach(rows.indices, id: \.self) { i in
                    DownloadRowView(d: rows[i], queued: queued(rows[i]),
                                    pause: { Task { await act("downloads/\(rows[i]["id"].int ?? 0)/pause", "Paused.") } },
                                    resume: { Task { await act("downloads/\(rows[i]["id"].int ?? 0)/resume", "Resumed.") } },
                                    remove: { removing = rows[i] })
                }
                if rows.isEmpty { LoadState(loading: loading, error: error, empty: "Nothing downloading.") }
            }
            .padding(.horizontal, Theme.sidePadding)
            .padding(.vertical, S(40))
        }
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        .confirmationDialog("Remove \(removing?["title"].string ?? "this download")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let d = removing { Task { await act("downloads/\(d["id"].int ?? 0)/remove", "Removed.") } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("HolyArrs removes it from the download app. Files already in the Library stay.")
        }
    }

    /// SABnzbd fetches one job at a time, but HolyArrs reports every job in its queue as "downloading" with the total
    /// speed split between them. A job with nothing in yet while another is part way through is waiting its turn.
    private func queued(_ d: JSON) -> Bool {
        d["phase"].string == "downloading" && (d["progress"].double ?? 0) <= 0
            && rows.contains { $0["phase"].string == "downloading" && ($0["progress"].double ?? 0) > 0 }
    }

    private var summary: String {
        let waiting = rows.filter(queued).count
        let speed = rows.filter { $0["phase"].string == "downloading" }.compactMap { $0["speed"].double }.reduce(0, +)
        var bits = ["\(active - waiting) active"]
        if waiting > 0 { bits.append("\(waiting) queued") }
        if speed > 0 { bits.append(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s") }
        return bits.joined(separator: " · ")
    }

    /// The one coming in first, then the queue in the order it will download (soonest done first).
    private func ordered(_ r: [JSON]) -> [JSON] {
        r.enumerated().sorted { a, b in
            func rank(_ d: JSON) -> Int { d["phase"].string == "downloading" ? ((d["progress"].double ?? 0) > 0 ? 0 : 1) : 2 }
            let (ra, rb) = (rank(a.element), rank(b.element))
            if ra != rb { return ra < rb }
            if ra == 1 { return (a.element["eta"].int ?? .max) < (b.element["eta"].int ?? .max) }
            return a.offset < b.offset
        }.map(\.element)
    }

    private var active: Int { rows.filter { ["downloading", "stalled", "waiting", "importing", "waiting_to_import"].contains($0["phase"].string ?? "") }.count }

    private func load() async {
        defer { loading = false }
        do {
            rows = ordered(try await api.get("downloads/view", ["limit": "100"])["downloads"].array)
            error = nil
        } catch {
            if rows.isEmpty { self.error = error.localizedDescription }
        }
    }

    private func act(_ path: String, _ done: String) async {
        do { try await api.post(path); note = done; await load() } catch { note = error.localizedDescription }
    }
}

struct DownloadRowView: View {
    let d: JSON
    var queued = false
    let pause: () -> Void
    let resume: () -> Void
    let remove: () -> Void
    @EnvironmentObject private var rtx: RTXServer
    /// From the PC (GET /grow/status): whether this Usenet download can already play start to finish.
    @State private var grow: JSON = .null
    @State private var watching: LiveRequest?

    private var phase: String { d["phase"].string ?? "" }
    private var release: String? { d["downloader"].string == "SABnzbd" && phase == "downloading" ? d["name"].string : nil }
    private var progress: Double { min(1, max(0, d["progress"].double ?? 0)) }

    var body: some View {
        AdaptiveStack(spacing: S(30)) {
            VStack(alignment: .leading, spacing: S(10)) {
                Text([d["title"].string ?? d["name"].string, d["year"].int.map { "(\($0))" }, episodes].compactMap { $0 }.joined(separator: " "))
                    .font(.system(size: F(30), weight: .semibold)).lineLimit(1)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(phase == "failed" || phase == "stalled" ? Color.red.opacity(0.8) : Theme.accent)
                        .frame(width: max(S(10), W(900) * progress))
                }
                .frame(width: W(900), height: S(10))
                Text(line).font(.callout).foregroundStyle(Theme.dim).lineLimit(1).frame(width: W(1000), alignment: .leading)
                if release != nil, let wait = grow["playable_in_s"].int, wait > 0 {
                    Label("Playable in about \(TitleDownloadCard.minutes(wait))", systemImage: "clock")
                        .font(.callout.weight(.semibold)).foregroundStyle(Theme.accent)
                }
            }
            Spacer()
            HStack(spacing: S(30)) {
                if let release, grow["playable"].bool {
                    Button {
                        watching = LiveRequest(stream: release, title: d["title"].string ?? release, grow: release)
                    } label: { Label("Play now", systemImage: "play.fill") }
                    .accessibilityLabel("Play now while it downloads")
                }
                Badge(text: queued ? "QUEUED" : (d["label"].string ?? phase.replacingOccurrences(of: "_", with: " ")).uppercased())
                if phase == "downloading" || phase == "stalled" || phase == "waiting" {
                    Button(action: pause) { Image(systemName: "pause.fill") }.accessibilityLabel("Pause")
                } else if phase == "paused" {
                    Button(action: resume) { Image(systemName: "play.fill") }.accessibilityLabel("Resume")
                }
                if d["can_act"].bool {
                    Button(role: .destructive, action: remove) { Image(systemName: "trash") }.accessibilityLabel("Remove")
                }
            }
        }
        .padding(.vertical, S(12))
        .tvFocusSection()
        .task(id: "\(release ?? "")|\(Int(progress * 100))") {
            guard let release, let base = rtx.base else { grow = .null; return }
            grow = (try? await RTXAPI(base: base).get("grow/status", [URLQueryItem(name: "name", value: release)])) ?? .null
        }
        .fullScreenCover(item: $watching) { LivePlayerScreen(request: $0) }
    }

    private var episodes: String? {
        let e = d["episodes"].array.compactMap { $0["label"].string }
        return e.isEmpty ? nil : e.prefix(3).joined(separator: ", ")
    }

    private var line: String {
        if queued {
            var parts = ["Waiting its turn"]
            if let eta = d["eta"].int, eta > 0, eta < 7 * 86400 { parts.append("ready in about " + (eta >= 3600 ? "\(eta / 3600)h \(eta / 60 % 60)m" : "\(max(1, eta / 60))m")) }
            if let size = d["size"].double, size > 0 { parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
            return parts.joined(separator: " · ")
        }
        var parts = ["\(Int(progress * 100))%"]
        if let s = d["speed"].double, s > 0 { parts.append(ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file) + "/s") }
        if let eta = d["eta"].int, eta > 0, eta < 7 * 86400 { parts.append(eta >= 3600 ? "\(eta / 3600)h \(eta / 60 % 60)m left" : "\(max(1, eta / 60))m left") }
        if let size = d["size"].double, size > 0 { parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
        if let t = d["text"].string { parts.append(t) }
        if let dl = d["downloader"].string { parts.append(dl) }
        return parts.joined(separator: " · ")
    }
}
