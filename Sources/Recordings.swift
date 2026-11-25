import SwiftUI

/// A game recorded on the PC (GET /tv/sports "recordings", 2026-11-25): set to record, recording now (it plays from
/// the start while it records) or done. Ad breaks are found on the PC and skipped as they come.
struct Recording: Identifiable, Hashable {
    let id: String
    let title: String
    let league: String
    let state: String
    let start: Date
    let madeS: Double
    let resumeS: Double
    let game: String?
    let why: String?
    let teams: [LiveTeam]

    init?(_ j: JSON) {
        guard let id = j["id"].string, let title = j["title"].string, let state = j["state"].string else { return nil }
        self.id = id
        self.title = title
        self.state = state
        league = j["league"].string ?? ""
        start = Date(timeIntervalSince1970: j["start"].double ?? 0)
        madeS = j["made_s"].double ?? 0
        resumeS = j["t"].double ?? 0
        game = j["game"].string
        why = j["why"].string
        let t = j["teams"].array.compactMap(LiveTeam.init)
        teams = t.count == 2 ? t : []
    }

    var recording: Bool { state == "recording" }
    var playable: Bool { (state == "recording" || state == "done") && madeS > 30 }

    /// "Recording now · 1:12 so far", "Thu 1:00 PM · will record", "2:58 · watched to 1:05".
    var line: String {
        func hm(_ s: Double) -> String {
            let m = Int(s / 60)
            return m >= 60 ? String(format: "%d:%02d", m / 60, m % 60) : "\(m) min"
        }
        switch state {
        case "recording": return "Recording now · \(hm(madeS)) so far" + (resumeS > 60 ? " · watched to \(hm(resumeS))" : "")
        case "scheduled":
            let f = DateFormatter()
            f.dateFormat = Calendar.current.isDateInToday(start) ? "'Today' h:mm a" : Calendar.current.isDateInTomorrow(start) ? "'Tomorrow' h:mm a" : "EEE h:mm a"
            return "\(f.string(from: start)) · will record"
        default: return hm(madeS) + (resumeS > 60 ? " · watched to \(hm(resumeS))" : "")
        }
    }
}

/// The Recordings row at the top of Sports: play from the start or where it was left; the long-press menu stops,
/// cancels or deletes one.
struct RecordingsRow: View {
    let recordings: [Recording]
    let play: (LiveRequest) -> Void
    /// "cancel" (stop or don't record) or "delete" (the recording and its files).
    let act: (Recording, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: S(18)) {
            Text("Recordings").font(.system(size: F(34), weight: .bold)).padding(.horizontal, Theme.sidePadding)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: S(40)) {
                    ForEach(recordings) { r in
                        Button {
                            if r.playable { play(LiveRequest(stream: r.id, title: r.title, rec: r.id)) }
                        } label: { RecordingCell(recording: r) }
                        .buttonStyle(QuietButtonStyle())
                        .contextMenu {
                            if r.state == "scheduled" {
                                Button { act(r, "cancel") } label: { Label("Cancel recording", systemImage: "xmark.circle") }
                            }
                            if r.recording {
                                Button { act(r, "cancel") } label: { Label("Stop recording", systemImage: "stop.circle") }
                            }
                            if r.state != "scheduled" {
                                Button(role: .destructive) { act(r, "delete") } label: { Label("Delete recording", systemImage: "trash") }
                            }
                        }
                    }
                }
                .padding(.vertical, S(30))
                .padding(.horizontal, Theme.sidePadding)
            }
            .tvFocusSection()
        }
    }
}

struct RecordingCell: View {
    let recording: Recording
    @Environment(\.isFocused) private var focused

    var body: some View {
        VStack(alignment: .leading, spacing: S(10)) {
            ZStack(alignment: .bottomLeading) {
                if recording.teams.count == 2 {
                    MatchupArt(first: recording.teams[0], second: recording.teams[1],
                               at: recording.title.range(of: #"\sat\s|@"#, options: [.regularExpression, .caseInsensitive]) != nil)
                } else {
                    LinearGradient(colors: LiveTV.colors(recording.league), startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(recording.title).font(.system(size: F(30), weight: .heavy)).lineLimit(2).minimumScaleFactor(0.75)
                        .foregroundStyle(Color.white).padding(S(20))
                }
                if recording.madeS > 0, recording.resumeS > 60 {
                    GeometryReader { g in
                        Rectangle().fill(Theme.accent).frame(width: g.size.width * min(1, recording.resumeS / recording.madeS), height: S(6))
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
            .frame(width: W(480), height: S(270))
            .overlay(alignment: .topTrailing) {
                if recording.state != "done" { RecPill(recording: recording.recording).padding(S(14)) }
            }
            .modifier(LiveCardChrome(focused: focused))
            VStack(alignment: .leading, spacing: S(4)) {
                Text(recording.title).font(.system(size: F(22), weight: .semibold)).lineLimit(1)
                Text(recording.line).font(.system(size: F(21))).foregroundStyle(Theme.dim).lineLimit(1)
            }
            .frame(width: W(480), alignment: .leading)
            .offset(y: focused ? S(12) : 0)
        }
        .animation(.easeOut(duration: 0.18), value: focused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(recording.title), \(recording.line)")
    }
}
