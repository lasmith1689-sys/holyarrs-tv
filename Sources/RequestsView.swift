import SwiftUI

/// Requests: asks waiting for an OK (for people who approve), your own asks, everyone's, and the movies
/// HolyArrs got stuck on (Needs a decision, for people who manage the Library).
struct RequestsView: View {
    enum Part: String, CaseIterable, Identifiable {
        case waiting = "Waiting", mine = "Mine", all = "All", stuck = "Needs a decision"
        var id: String { rawValue }
    }

    @EnvironmentObject private var api: HolyArrs
    @State private var part: Part = .mine
    @State private var asks: [AskItem] = []
    @State private var decisions: [JSON] = []
    @State private var counts: [String: Int] = [:]
    @State private var loading = true
    @State private var error: String?
    @State private var note: String?
    @State private var turningDown: AskItem?

    private var parts: [Part] {
        var p: [Part] = []
        if api.me?.canApprove == true { p.append(.waiting) }
        p += [.mine, .all]
        if api.me?.canManage == true { p.append(.stuck) }
        return p
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(spacing: 40) {
                    Picker("Show", selection: $part) {
                        ForEach(parts) { p in Text(label(p)).tag(p) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 1200)
                    Spacer()
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Refresh")
                }
                .focusSection()
                if let note { Text(note).foregroundStyle(Theme.accent) }
                if part == .stuck {
                    ForEach(decisions.indices, id: \.self) { i in DecisionRow(d: decisions[i]) { action in Task { await decide(decisions[i], action) } } }
                    if decisions.isEmpty { LoadState(loading: loading, error: error, empty: "Nothing is stuck.") }
                } else {
                    ForEach(asks) { a in
                        AskRow(ask: a, canApprove: api.me?.canApprove == true,
                               approve: { Task { await approve(a) } },
                               turnDown: { turningDown = a },
                               takeBack: { Task { await takeBack(a) } })
                    }
                    if asks.isEmpty { LoadState(loading: loading, error: error, empty: part == .waiting ? "Nothing is waiting for an OK." : "No asks yet.") }
                }
            }
            .padding(.horizontal, Theme.sidePadding)
            .padding(.vertical, 40)
        }
        .task(id: part) { await load() }
        .onAppear { if api.me?.canApprove == true, counts.isEmpty { part = .waiting } }
        .confirmationDialog("Turn down \(turningDown?.name ?? "")?", isPresented: Binding(get: { turningDown != nil }, set: { if !$0 { turningDown = nil } }), titleVisibility: .visible) {
            Button("Turn down", role: .destructive) { if let a = turningDown { Task { await turnDown(a) } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The people who asked are told it was turned down.")
        }
    }

    private func label(_ p: Part) -> String {
        switch p {
        case .waiting: return counts["pending"].map { "Waiting (\($0))" } ?? "Waiting"
        case .stuck: return decisions.isEmpty ? "Needs a decision" : "Needs a decision (\(decisions.count))"
        default: return p.rawValue
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            switch part {
            case .stuck:
                decisions = try await api.get("needs-decision")["items"].array
            case .waiting, .mine, .all:
                var q: [String: String] = ["limit": "200"]
                if part == .waiting { q["state"] = "asked" }
                if part == .mine { q["mine"] = "1" }
                let j = try await api.get("asks", q)
                asks = j["asks"].array.map(AskItem.init)
                for (k, v) in j["counts"].object { counts[k] = v.int }
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func approve(_ a: AskItem) async {
        do { try await api.post("asks/\(a.id)/approve"); note = "Approved \(a.name). HolyArrs starts looking for it now." ; await load() } catch { note = error.localizedDescription }
    }

    private func turnDown(_ a: AskItem) async {
        do { try await api.post("asks/\(a.id)/turn-down"); note = "Turned down \(a.name)."; await load() } catch { note = error.localizedDescription }
    }

    private func takeBack(_ a: AskItem) async {
        do { try await api.delete("asks/\(a.id)"); note = "Took back \(a.name)."; await load() } catch { note = error.localizedDescription }
    }

    private func decide(_ d: JSON, _ action: String) async {
        guard let slot = d["slot_id"].int else { return }
        do {
            try await api.post("needs-decision/\(slot)/decide", ["action": action])
            note = action == "search" ? "Searching again for \(d["title"].string ?? "it")." : action == "stop" ? "Stopped looking." : "Turned down."
            await load()
        } catch { note = error.localizedDescription }
    }
}

struct AskRow: View {
    let ask: AskItem
    let canApprove: Bool
    let approve: () -> Void
    let turnDown: () -> Void
    let takeBack: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 34) {
            NavigationLink(value: ask.card.route) {
                Artwork(raw: ask.poster, width: 185, title: ask.name).frame(width: 120, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.card)
            .accessibilityLabel("Open \(ask.name)")
            VStack(alignment: .leading, spacing: 8) {
                Text(ask.year.map { "\(ask.name) (\($0))" } ?? ask.name).font(.system(size: 32, weight: .semibold)).lineLimit(1)
                if let what = ask.what { Text(what).foregroundStyle(Theme.dim) }
                Text([ask.by.isEmpty ? nil : "Asked by \(ask.by)\(ask.people > 1 ? " and \(ask.people - 1) more" : "")",
                      ask.askedAt.map(Dates.relative)].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(Theme.dim)
                if let n = ask.note { Text(n).font(.callout).foregroundStyle(Theme.dim).lineLimit(2) }
            }
            Spacer()
            Badge(text: ask.stateLabel.uppercased())
            if ask.waiting && canApprove {
                Button("Approve", action: approve).buttonStyle(.borderedProminent)
                Button("Turn down", role: .destructive, action: turnDown)
            } else if ask.waiting && ask.mine {
                Button("Take back", role: .destructive, action: takeBack)
            }
        }
        .padding(.vertical, 14)
        .focusSection()
    }
}

/// One movie HolyArrs got stuck on, with the reason in plain words and what to do about it.
struct DecisionRow: View {
    let d: JSON
    let act: (String) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 34) {
            VStack(alignment: .leading, spacing: 8) {
                Text([d["title"].string, d["year"].int.map { "(\($0))" }, d["episode"]["label"].string].compactMap { $0 }.joined(separator: " "))
                    .font(.system(size: 32, weight: .semibold)).lineLimit(1)
                Text(d.first("reason", "why").string ?? "").foregroundStyle(Theme.dim).lineLimit(3)
                if let r = d["release_name"].string { Text(r).font(.callout.monospaced()).foregroundStyle(Theme.dim).lineLimit(1) }
            }
            Spacer()
            Button("Search again") { act("search") }.buttonStyle(.borderedProminent)
            Button("Stop looking") { act("stop") }
            Button("Turn down", role: .destructive) { act("turn_down") }
        }
        .padding(.vertical, 14)
        .focusSection()
    }
}
