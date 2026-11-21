import SwiftUI

// Rooms: the basement (this Apple TV, or an iPhone AirPlaying to it) and outside (the Hisense, which the PC casts
// to; there is no Apple TV out there). Positions live on the PC, so a film started in one room carries on in the
// other. Picture settings on the projector and the Hisense are set once by hand (see SetupGuideView): neither
// lets an app change them.

/// One measured playback statistic.
struct StatRow: Identifiable {
    let id = UUID()
    let name: String
    let value: String

    init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }

    static func mbps(_ bps: Double) -> String { String(format: "%.1f Mbps", bps / 1_000_000) }
}

/// Playback stats, as the player reports them (blank until it has numbers).
struct StatsPanel: View {
    @ObservedObject var model: PlaybackModel

    var body: some View {
        HStack(alignment: .top, spacing: S(60)) {
            if model.stats.isEmpty {
                Text("Measuring...").foregroundStyle(Theme.dim)
            }
            ForEach(model.stats) { r in
                VStack(alignment: .leading, spacing: S(6)) {
                    Text(r.name.uppercased()).font(.system(size: F(18), weight: .heavy)).tracking(1).foregroundStyle(Theme.dim)
                    Text(r.value).font(.system(size: F(28), weight: .semibold)).lineLimit(2)
                }
            }
        }
        .padding(S(30))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if os(iOS)
/// iPhone player extras along the top: close, stats, and Continue outside (the system player draws the rest).
struct PhonePlayerBar: View {
    @ObservedObject var model: PlaybackModel
    @Binding var showStats: Bool
    let close: () -> Void
    let outside: (() -> Void)?

    var body: some View {
        VStack {
            // Only while paused: nothing sits over a playing movie.
            if model.paused {
            HStack(spacing: 14) {
                Button(action: close) { Image(systemName: "xmark") }.accessibilityLabel("Close")
                Button { showStats.toggle() } label: { Image(systemName: "chart.bar.xaxis") }.accessibilityLabel("Stats")
                if let outside {
                    Button(action: outside) { Label("Continue outside", systemImage: "sun.max").labelStyle(.titleAndIcon) }
                }
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 54)
            .transition(.opacity)
            }
            Spacer()
            if showStats {
                ScrollView(.horizontal, showsIndicators: false) { StatsPanel(model: model) }
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 12).padding(.bottom, 110)
            }
        }
        .tint(.white)
        .animation(.easeInOut(duration: 0.2), value: model.paused)
    }
}
#endif

/// "Play outside" (or "Stop outside" while the outdoor TV plays this film), next to a page's own Play button.
struct OutsideButton: View {
    let film: RTXFilm
    let label: String
    @EnvironmentObject private var rtx: RTXServer
    @AppStorage("outsideOn") private var outsideOn = false

    var body: some View {
        if outsideOn { buttons }
    }

    private var buttons: some View {
        Group {
            if rtx.outside?.film == film.id, rtx.outside?.active == true {
                Button { Task { await rtx.stopOutside() } } label: {
                    Label("Stop outside", systemImage: "stop.fill").font(.system(size: F(28), weight: .semibold))
                }
            } else {
                Button { Task { await rtx.playOutside(film, label: label, seconds: Resume.position(film.id) ?? 0) } } label: {
                    Label(rtx.castingFilm == film.id ? "Starting outside..." : "Play outside", systemImage: "sun.max")
                        .font(.system(size: F(28), weight: .semibold))
                }
                .disabled(rtx.castingFilm != nil)
            }
        }
        .task {
            while !Task.isCancelled {
                await rtx.refreshOutside()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }
}

/// What the outdoor TV reported for this film, and the last send result.
struct OutsideNote: View {
    let film: RTXFilm
    @EnvironmentObject private var rtx: RTXServer
    @AppStorage("outsideOn") private var outsideOn = false

    var body: some View {
        if outsideOn { note }
    }

    private var note: some View {
        VStack(alignment: .leading, spacing: S(6)) {
            if let o = rtx.outside, o.film == film.id, o.active {
                Text("Outside on \(o.device ?? "the TV"): \(o.state)" + (o.position.map { " at \(Resume.label($0))" } ?? "")
                     + (o.stalls > 0 ? ", \(o.stalls) stall\(o.stalls == 1 ? "" : "s")" : ""))
                    .foregroundStyle(Theme.accent)
            } else if let note = rtx.outsideNote {
                Text(note).foregroundStyle(Theme.dim)
            }
        }
        .font(.system(size: F(22)))
    }
}

extension RTXServer {
    /// Where to start this film here: the outdoor TV's position while it plays it (Continue here), else the
    /// position kept on the PC.
    func startPoint(_ film: RTXFilm) -> Double? {
        if let o = outside, o.film == film.id, o.active, let p = o.position { return p }
        return Resume.position(film.id)
    }

    func continuingHere(_ film: RTXFilm) -> Bool {
        if let o = outside, o.film == film.id, o.active { return true }
        return false
    }
}

/// Settings > Rooms: the outdoor TV and the one-time picture setup.
struct RoomsSection: View {
    @EnvironmentObject private var rtx: RTXServer
    @State private var found: String?
    @State private var looking = false
    @State private var guide = false
    @AppStorage("outsideOn") private var outsideOn = false

    var body: some View {
        Section {
            Toggle("Play outside buttons", isOn: $outsideOn)
            LabeledContent("Outside TV", value: outsideLabel)
            Button(looking ? "Looking..." : "Find the outside TV") { Task { await find() } }.disabled(looking)
            if let found { Text(found).font(.footnote).foregroundStyle(.secondary) }
            if rtx.outside?.active == true {
                Button("Stop outside", role: .destructive) { Task { await rtx.stopOutside() } }
            }
            // A sheet, not a push: on iPhone Settings sits under More, and a push there doubles the back button.
            Button("Picture setup guide") { guide = true }
        } header: {
            Text("Rooms")
        } footer: {
            Text("Off by default. On: Play outside on movie pages and Continue outside in the player cast from the PC to the Hisense (Chromecast built-in; not yet tested on the TV). Positions are kept on the PC either way.")
        }
        .task { await rtx.refreshOutside() }
        .sheet(isPresented: $guide) {
            NavigationStack {
                SetupGuideView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { guide = false } } }
            }
        }
    }

    private var outsideLabel: String {
        guard let o = rtx.outside else { return "not checked" }
        if o.active { return "\(o.state) \(o.title ?? "")" }
        if o.state == "failed" { return "not reachable" }
        return o.device ?? "idle"
    }

    private func find() async {
        looking = true
        defer { looking = false }
        guard let base = rtx.base, let j = try? await RTXAPI(base: base).get("cast/devices") else {
            found = "Couldn't ask the PC."
            return
        }
        let names = j["devices"].array.compactMap { d in d["name"].string.map { "\($0) (\(d["model"].string ?? "TV"))" } }
        found = names.isEmpty ? "No TV answered. Turn the Hisense on, or turn on its Network standby." : "Found: " + names.joined(separator: ", ")
    }
}

/// One-time settings on each screen. The app can't change these on the Apple TV, the projector or the Hisense.
struct SetupGuideView: View {
    var body: some View {
        List {
            Section("Basement: Apple TV") {
                guide("Format: 1080p SDR",
                      "Settings > Video and Audio > Format. The projector is native 1080p: this lets the Apple TV shrink the PC's 4K picture with its own good scaler instead of the projector's.")
                guide("Match Frame Rate: on",
                      "Settings > Video and Audio > Match Content. Films play at 24 frames a second, without judder.")
                guide("Match Dynamic Range: try off first",
                      "Off: the Apple TV turns HDR into a clean SDR picture, which usually looks better on a budget projector than its own HDR mode. Try on if HDR looks right on yours.")
            }
            Section("Basement: projector") {
                guide("Picture mode: Movie or Cinema", "The most accurate preset on most projectors.")
                guide("Motion smoothing: off", "Keeps films looking like films.")
                guide("Sharpness: low; keystone: off", "Digital keystone and sharpening soften or ring the picture. Move the projector instead.")
            }
            Section("Outside: Hisense 75M7SG") {
                guide("Network standby: on",
                      "Settings > System > Power & Energy. Lets Play outside wake the TV. Without it, turn the TV on first.")
                guide("Movies: Filmmaker Mode", "Turns off motion smoothing and extra processing.")
                guide("Sports in daylight: Sports or Standard, brightness up",
                      "Keep motion smoothing low; games are already 50 or 60 frames a second.")
                guide("Evening: Filmmaker Mode or Theater Night", "Less glare, more natural color.")
                guide("Picture modes stick to the source", "The mode you pick while something is casting is the one used for casting next time.")
            }
            Section("Stats while playing") {
                guide("Apple TV", "Swipe down during playback and pick Stats.")
                guide("iPhone", "Tap the chart button at the top.")
                guide("Outside", "Settings > Rooms shows what the TV reports, including stalls.")
            }
        }
        .navigationTitle("Picture setup")
    }

    private func guide(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: S(6)) {
            Text(title).font(.system(size: F(26), weight: .semibold))
            Text(detail).font(.system(size: F(21))).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, S(6))
        .tvFocusable()
    }
}
