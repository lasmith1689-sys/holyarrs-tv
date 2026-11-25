import SwiftUI

/// One programme in the guide (GET /tv/guide from the PC: the provider's listings).
struct GuideProgram: Identifiable, Hashable {
    let title: String
    let start: Date
    let end: Date
    let desc: String?
    var id: String { "\(start.timeIntervalSince1970)-\(title)" }

    init?(_ j: JSON) {
        guard let t = j["title"].string, let s = j["start"].double, let e = j["end"].double, e > s else { return nil }
        title = t
        start = Date(timeIntervalSince1970: s)
        end = Date(timeIntervalSince1970: e)
        desc = j["desc"].string
    }

    func onNow(_ now: Date) -> Bool { start <= now && now < end }
    func progress(_ now: Date) -> Double { min(1, max(0, now.timeIntervalSince(start) / end.timeIntervalSince(start))) }
    func minutesLeft(_ now: Date) -> Int { max(0, Int(end.timeIntervalSince(now) / 60)) }
}

struct GuideChannel: Identifiable, Hashable {
    let id: String
    let name: String
    let logo: String?
    let alt: [String]
    let programs: [GuideProgram]

    init?(_ j: JSON) {
        guard let id = j["id"].string else { return nil }
        self.id = id
        name = LiveTV.clean(j["name"].string ?? id)
        logo = j["logo"].string
        alt = j["alt"].array.compactMap(\.string)
        programs = j["programs"].array.compactMap(GuideProgram.init)
    }
}

/// The TV guide (Release 6, Luke 2026-11-25: "like the old TV Guide channel"): channels down the side, time across
/// the top (3 hours on Apple TV, 2 on iPhone, from the last half hour), each programme as wide as it runs, the one
/// on now with how far in it is. The highlighted (Apple TV) or tapped (iPhone) programme shows above the grid with
/// its times and description; select it (Apple TV) or Watch (iPhone) to play the channel. Later / Earlier move the
/// window by an hour. Groups as the Live page (Sports, News, Kids...).
struct GuideView: View {
    let play: (LiveRequest) -> Void
    @EnvironmentObject private var rtx: RTXServer
    @State private var groups: [(name: String, channels: [GuideChannel])] = []
    @AppStorage("guideGroup") private var group = "All"
    @State private var shift = 0  // hours past now
    @State private var picked: (GuideChannel, GuideProgram?)?
    @State private var loading = true
    @State private var error: String?

    private var hours: Double { Device.isTV ? 3 : 2 }
    private var channelWidth: CGFloat { Device.isTV ? 300 : 96 }
    private var rowHeight: CGFloat { Device.isTV ? 104 : 62 }

    private var shown: [GuideChannel] {
        group == "All" ? groups.flatMap(\.channels) : (groups.first { $0.name == group }?.channels ?? [])
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { tick in
            let now = tick.date
            let start = GuideView.windowStart(now).addingTimeInterval(Double(shift) * 3600)
            let end = start.addingTimeInterval(hours * 3600)
            VStack(alignment: .leading, spacing: S(24)) {
                details(now)
                    .padding(.horizontal, Theme.sidePadding)
                groupPicker
                    .padding(.horizontal, Theme.sidePadding)
                    .tvFocusSection()
                GeometryReader { geo in
                    let gridWidth = max(200, geo.size.width - channelWidth - Theme.sidePadding * 2)
                    let perSecond = gridWidth / (hours * 3600)
                    VStack(alignment: .leading, spacing: 0) {
                        ruler(start: start, width: gridWidth)
                        ScrollView(.vertical) {
                            LazyVStack(alignment: .leading, spacing: Device.isTV ? 10 : 4) {
                                ForEach(shown) { c in
                                    row(c, now: now, start: start, end: end, perSecond: perSecond, width: gridWidth)
                                }
                            }
                            .overlay(alignment: .topLeading) {
                                // The "now" line across every row.
                                if now >= start && now < end {
                                    Rectangle().fill(Theme.accent.opacity(0.85)).frame(width: 2)
                                        .offset(x: channelWidth + CGFloat(now.timeIntervalSince(start)) * perSecond)
                                        .allowsHitTesting(false)
                                }
                            }
                            .padding(.bottom, S(60))
                        }
                    }
                    .padding(.horizontal, Theme.sidePadding)
                }
                .frame(minHeight: Device.isTV ? 640 : 420)
                if shown.isEmpty {
                    LoadState(loading: loading, error: error, empty: "No guide yet.", retry: { Task { await load() } })
                }
            }
        }
        .task(id: rtx.address) {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(nanoseconds: 600_000_000_000)  // the PC refreshes listings every 15 minutes
            }
        }
    }

    /// The window starts on the half hour before now.
    static func windowStart(_ now: Date) -> Date {
        let t = now.timeIntervalSince1970
        return Date(timeIntervalSince1970: (t / 1800).rounded(.down) * 1800)
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm"
        return f
    }()
    private static let clockAMPM: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    static func span(_ p: GuideProgram) -> String { "\(clock.string(from: p.start)) - \(clockAMPM.string(from: p.end))" }

    // MARK: Parts

    @ViewBuilder private func details(_ now: Date) -> some View {
        HStack(alignment: .top, spacing: S(30)) {
            VStack(alignment: .leading, spacing: S(8)) {
                if case let (c, p)? = picked {
                    Text(c.name).font(.system(size: F(24), weight: .semibold)).foregroundStyle(Theme.accent)
                    Text(p?.title ?? "No guide for this channel").font(.system(size: F(40), weight: .bold)).lineLimit(1)
                    if let p {
                        Text(GuideView.span(p) + (p.onNow(now) ? " · \(p.minutesLeft(now)) min left" : ""))
                            .font(.system(size: F(24))).foregroundStyle(Theme.dim)
                        if let d = p.desc { Text(d).font(.system(size: F(24))).foregroundStyle(Color.white.opacity(0.75)).lineLimit(2) }
                    }
                } else {
                    Text(Device.isTV ? "Move around the grid to see what's on; select to watch."
                                     : "Tap a programme to see it; Watch plays the channel.")
                        .font(.system(size: F(24))).foregroundStyle(Theme.dim)
                }
            }
            Spacer()
            #if os(iOS)
            if case let (c, _)? = picked {
                Button { play(LiveRequest(stream: c.id, title: c.name, alt: c.alt)) } label: {
                    Label("Watch", systemImage: "play.fill").font(.system(size: F(28), weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
            }
            #endif
        }
        .frame(minHeight: Device.isTV ? 150 : 96, alignment: .top)
    }

    private var groupPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: S(16)) {
                ForEach(["All"] + groups.map(\.name), id: \.self) { g in
                    Button { group = g } label: {
                        Text(g).font(.system(size: F(24), weight: .semibold)).padding(.horizontal, S(8))
                    }
                    .buttonStyle(KindButtonStyle(selected: group == g))
                    .accessibilityAddTraits(group == g ? .isSelected : [])
                }
                Spacer(minLength: S(20))
                Button { shift = max(0, shift - 1) } label: { Label("Earlier", systemImage: "chevron.left") }
                    .disabled(shift == 0)
                Button { shift = min(9, shift + 1) } label: { Label("Later", systemImage: "chevron.right") }
            }
            .font(.system(size: F(24), weight: .semibold))
        }
    }

    private func ruler(start: Date, width: CGFloat) -> some View {
        let slots = Int(hours * 2)
        return HStack(spacing: 0) {
            Text(GuideView.dayLabel(start)).font(.system(size: F(22), weight: .semibold)).foregroundStyle(Theme.dim)
                .frame(width: channelWidth, alignment: .leading)
            ForEach(0..<slots, id: \.self) { i in
                Text(GuideView.clockAMPM.string(from: start.addingTimeInterval(Double(i) * 1800)))
                    .font(.system(size: F(22), weight: .semibold)).foregroundStyle(Theme.dim)
                    .frame(width: width / CGFloat(slots), alignment: .leading)
            }
        }
        .padding(.bottom, S(10))
    }

    static func dayLabel(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? "Today" : (Calendar.current.isDateInTomorrow(d) ? "Tomorrow" : d.formatted(.dateTime.weekday(.abbreviated)))
    }

    private func row(_ c: GuideChannel, now: Date, start: Date, end: Date, perSecond: CGFloat, width: CGFloat) -> some View {
        let inWindow = c.programs.filter { $0.end > start && $0.start < end }
        return HStack(spacing: 0) {
            // Apple TV: logo and name side by side. iPhone: the logo with the name under it (small), so a channel whose
            // logo doesn't load is still named.
            AdaptiveStack(tvAlignment: .center, spacing: S(Device.isTV ? 12 : 2)) {
                if let logo = c.logo, let base = rtx.base, let u = URL(string: logo, relativeTo: base) {
                    AsyncImage(url: u.absoluteURL) { phase in
                        if let image = phase.image { image.resizable().aspectRatio(contentMode: .fit) } else { Color.clear }
                    }
                    .frame(width: Device.isTV ? 90 : 40, height: Device.isTV ? 50 : 24)
                }
                Text(c.name).font(.system(size: Device.isTV ? F(22) : 11, weight: .semibold)).lineLimit(2)
            }
            .frame(width: channelWidth - 8, height: rowHeight, alignment: .leading)
            .padding(.trailing, 8)
            .accessibilityLabel(c.name)
            HStack(spacing: 0) {
                if inWindow.isEmpty {
                    cell(c, nil, now: now, width: width)
                } else {
                    let lead = max(0, inWindow[0].start.timeIntervalSince(start))
                    if lead > 60 { Color.clear.frame(width: CGFloat(lead) * perSecond) }
                    ForEach(inWindow) { p in
                        let s = max(p.start, start), e = min(p.end, end)
                        cell(c, p, now: now, width: max(2, CGFloat(e.timeIntervalSince(s)) * perSecond))
                    }
                }
            }
            .frame(width: width, alignment: .leading)
            .clipped()
        }
    }

    private func cell(_ c: GuideChannel, _ p: GuideProgram?, now: Date, width: CGFloat) -> some View {
        GuideCell(program: p, now: now, width: width, height: rowHeight, onFocus: { picked = (c, p) }) {
            if Device.isTV { play(LiveRequest(stream: c.id, title: c.name, alt: c.alt)) } else { picked = (c, p) }
        }
        .accessibilityLabel("\(c.name): " + (p.map { "\($0.title), \(GuideView.span($0))" } ?? "no guide"))
    }

    private func load() async {
        defer { loading = false }
        guard let base = rtx.base else { error = "The PC's address isn't set. Open Settings."; return }
        do {
            let j = try await RTXAPI(base: base).get("tv/guide", [URLQueryItem(name: "hours", value: "12")])
            groups = j["groups"].array.map { g in (g["name"].string ?? "", g["channels"].array.compactMap(GuideChannel.init)) }
                .filter { !$0.1.isEmpty }
                .map { (name: $0.0, channels: $0.1) }
            if group != "All", !groups.contains(where: { $0.name == group }) { group = "All" }
            error = nil
        } catch {
            if groups.isEmpty { self.error = "Couldn't reach the guide on the PC." }
        }
    }
}

/// One programme block: its title (and time when there's room), shaded by how far in it is when it's on now.
struct GuideCell: View {
    let program: GuideProgram?
    let now: Date
    let width: CGFloat
    let height: CGFloat
    let onFocus: () -> Void
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Device.isTV ? 10 : 6, style: .continuous)
                    .fill(Color.white.opacity(focused ? 0.28 : (program?.onNow(now) == true ? 0.12 : 0.06)))
                if let p = program, p.onNow(now) {
                    GeometryReader { g in
                        Rectangle().fill(Theme.accent.opacity(0.22)).frame(width: g.size.width * p.progress(now))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Device.isTV ? 10 : 6, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(program?.title ?? "No guide").font(.system(size: F(22), weight: .semibold)).lineLimit(1)
                    if let p = program, width > (Device.isTV ? 170 : 90) {
                        Text(GuideView.span(p)).font(.system(size: F(18))).foregroundStyle(Theme.dim).lineLimit(1)
                    }
                }
                .padding(.horizontal, Device.isTV ? 14 : 6)
            }
            .frame(width: max(1, width - (Device.isTV ? 6 : 3)), height: height)
            .padding(.trailing, Device.isTV ? 6 : 3)
        }
        .buttonStyle(.plain)
        .focused($focused)
        .onChange(of: focused) { _, f in if f { onFocus() } }
    }
}
