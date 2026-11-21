import SwiftUI

enum SportRoute: Hashable {
    case event(SportEvent)
    case league(SportLeague)
    case addLeague
}

/// Sports, from Sportarr: what's ready to watch (played through the RTX server), what's downloading, the next two
/// weeks of your leagues, and the leagues themselves. Scores are never shown.
struct SportsView: View {
    @EnvironmentObject private var sportarr: Sportarr
    @EnvironmentObject private var rtx: RTXServer
    @State private var leagues: [SportLeague] = []
    @State private var events: [SportEvent] = []
    @State private var queue: [JSON] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: S(46)) {
                AdaptiveStack(spacing: S(30)) {
                    Text("Sports").font(.system(size: F(64), weight: .bold))
                    if let v = sportarr.version { Text("Sportarr \(v)").font(.title3).foregroundStyle(Theme.dim) }
                    Spacer()
                }
                .padding(.horizontal, Theme.sidePadding)
                switch sportarr.state {
                case .checking:
                    LoadState(loading: true, error: nil).frame(maxWidth: .infinity)
                case .needsKey:
                    SportarrKeyCard().padding(.horizontal, Theme.sidePadding)
                case let .unreachable(why):
                    LoadState(loading: false, error: why, retry: { Task { await sportarr.connect() } }).frame(maxWidth: .infinity)
                case .ready:
                    content
                }
            }
            .padding(.vertical, S(40))
        }
        .refreshable { await load() }
        .task(id: sportarr.state) {
            guard sportarr.ready else { return }
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        .navigationDestination(for: SportRoute.self) { route in
            switch route {
            case let .event(e): EventPage(event: e)
            case let .league(l): LeaguePage(league: l)
            case .addLeague: AddLeagueView()
            }
        }
    }

    @ViewBuilder private var content: some View {
        let ready = events.filter(\.hasFile).sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        if !ready.isEmpty { EventRow(title: "Ready to watch", events: Array(ready.prefix(20))) }
        if !queue.isEmpty {
            VStack(alignment: .leading, spacing: S(14)) {
                Text("Downloading").font(.system(size: F(34), weight: .bold))
                ForEach(queue.indices, id: \.self) { i in SportQueueRow(q: queue[i]) }
            }
            .padding(.horizontal, Theme.sidePadding)
            .tvFocusSection()
        }
        ForEach(upcomingDays, id: \.day) { group in
            EventRow(title: group.label, events: group.events)
        }
        if upcomingDays.isEmpty && !loading && error == nil {
            Text(leagues.isEmpty ? "Add a league to see its schedule here." :
                    "Nothing on in the next two weeks. NFL and Premier League show games once you pick teams on their league page.")
                .foregroundStyle(Theme.dim).padding(.horizontal, Theme.sidePadding)
        }
        if let error { Text(error).foregroundStyle(Theme.dim).padding(.horizontal, Theme.sidePadding) }
        VStack(alignment: .leading, spacing: S(18)) {
            Text("Your leagues").font(.system(size: F(34), weight: .bold)).padding(.horizontal, Theme.sidePadding)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: S(40)) {
                    ForEach(leagues) { l in
                        NavigationLink(value: SportRoute.league(l)) { LeagueTile(league: l) }.buttonStyle(QuietButtonStyle())
                    }
                    NavigationLink(value: SportRoute.addLeague) { AddLeagueTile() }.buttonStyle(QuietButtonStyle())
                }
                .padding(.vertical, S(30))
                .padding(.horizontal, Theme.sidePadding)
            }
            .tvFocusSection()
        }
    }

    /// The next 14 days, one row per day (on the viewer's own clock when the start time is known).
    private var upcomingDays: [(day: String, label: String, events: [SportEvent])] {
        let now = Date().addingTimeInterval(-3 * 3600)
        let soon = events.filter { e in
            guard let d = e.date else { return false }
            return d >= now && !e.hasFile
        }
        var groups: [String: [SportEvent]] = [:]
        let key = DateFormatter()
        key.dateFormat = "yyyy-MM-dd"
        for e in soon {
            guard let d = e.date else { continue }
            if !e.timeKnown { key.timeZone = TimeZone(identifier: "UTC") } else { key.timeZone = .current }
            groups[key.string(from: d), default: []].append(e)
        }
        return groups.keys.sorted().map { k in
            (day: k, label: SportsView.dayLabel(k), events: (groups[k] ?? []).sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) })
        }
    }

    static func dayLabel(_ day: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: day) else { return day }
        if Calendar.current.isDateInToday(d) { return "Today" }
        if Calendar.current.isDateInTomorrow(d) { return "Tomorrow" }
        let out = DateFormatter()
        out.dateFormat = "EEEE, MMMM d"
        return out.string(from: d)
    }

    private func load() async {
        defer { loading = false }
        let iso = ISO8601DateFormatter()
        let start = iso.string(from: Date().addingTimeInterval(-21 * 86400))
        let end = iso.string(from: Date().addingTimeInterval(14 * 86400))
        do {
            async let l = sportarr.get("leagues")
            async let c = sportarr.get("calendar", ["start": start, "end": end, "unmonitored": "true"])
            async let q = sportarr.get("queue")
            let (lj, cj, qj) = try await (l, c, q)
            leagues = lj.array.compactMap(SportLeague.init).sorted { $0.name < $1.name }
            events = cj.array.compactMap(SportEvent.init)
            queue = qj.array.isEmpty ? qj["records"].array : qj.array
            error = nil
            await rtx.refreshSports()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A row of event cards under a heading.
struct EventRow: View {
    let title: String
    let events: [SportEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: S(18)) {
            Text(title).font(.system(size: F(34), weight: .bold)).padding(.horizontal, Theme.sidePadding)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: S(40)) {
                    ForEach(events) { e in
                        NavigationLink(value: SportRoute.event(e)) { SportCell(event: e) }.buttonStyle(QuietButtonStyle())
                    }
                }
                .padding(.vertical, S(30))
                .padding(.horizontal, Theme.sidePadding)
            }
            .tvFocusSection()
        }
    }
}

/// A 16:9 event card: Sportarr's picture of the event, its league badge, title and start time.
struct SportCell: View {
    let event: SportEvent
    @Environment(\.isFocused) private var focused

    var body: some View {
        VStack(alignment: .leading, spacing: S(10)) {
            ZStack(alignment: .bottomLeading) {
                Artwork(raw: event.thumb, width: 780, title: event.thumb == nil ? event.title : "")
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: S(6)) {
                    if let logo = event.leagueLogo {
                        Artwork(raw: logo, width: 154, plain: true, fit: true).frame(width: S(60), height: S(60), alignment: .leading)
                    }
                    Text(event.matchup ?? event.title).font(.system(size: F(26), weight: .heavy)).lineLimit(2).shadow(radius: S(6))
                }
                .padding(S(18))
            }
            .frame(width: W(480), height: S(270))
            .overlay(alignment: .topTrailing) {
                if !event.stateLabel.isEmpty { SportState(label: event.stateLabel).padding(S(14)) }
            }
            .clipShape(RoundedRectangle(cornerRadius: S(14), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: S(14), style: .continuous)
                .stroke(Color.white.opacity(focused ? 0.9 : 0.08), lineWidth: focused ? 4 : 1))
            .shadow(color: .black.opacity(focused ? 0.7 : 0.35), radius: focused ? 30 : 10, y: focused ? 20 : 6)
            .scaleEffect(focused ? 1.06 : 1.0)
            Text("\(event.league) · \(event.whenLabel)")
                .font(.system(size: F(21))).foregroundStyle(Theme.dim).lineLimit(1)
                .frame(width: W(480), alignment: .leading)
                .offset(y: focused ? S(12) : 0)
        }
        .animation(.easeOut(duration: 0.18), value: focused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(event.matchup ?? event.title), \(event.whenLabel)")
    }
}

struct SportState: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: F(15), weight: .heavy)).tracking(1)
            .padding(.horizontal, S(10)).padding(.vertical, S(5))
            .background(Capsule().fill(label == "READY" ? Theme.accent : Color.black.opacity(0.7)))
            .foregroundStyle(label == "READY" ? Color.black : Theme.accent)
    }
}

struct LeagueTile: View {
    let league: SportLeague
    @Environment(\.isFocused) private var focused

    var body: some View {
        VStack(alignment: .leading, spacing: S(10)) {
            ZStack {
                Color(white: 0.16)
                Artwork(raw: league.logo ?? league.poster, width: 342, title: league.logo == nil ? league.name : "", plain: true, fit: true)
                    .padding(S(26))
            }
            .frame(width: S(250), height: S(250))
            .clipShape(RoundedRectangle(cornerRadius: S(14), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: S(14), style: .continuous)
                .stroke(Color.white.opacity(focused ? 0.9 : 0.08), lineWidth: focused ? 4 : 1))
            .scaleEffect(focused ? 1.06 : 1.0)
            Text(league.name).font(.system(size: F(22), weight: .semibold)).lineLimit(1).frame(width: S(250), alignment: .leading)
            Text(league.monitored ? "Downloads automatically" : "Schedule only")
                .font(.system(size: F(18))).foregroundStyle(league.monitored ? Theme.accent : Theme.dim).lineLimit(1)
        }
        .animation(.easeOut(duration: 0.18), value: focused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(league.name)
    }
}

struct AddLeagueTile: View {
    @Environment(\.isFocused) private var focused

    var body: some View {
        VStack(alignment: .leading, spacing: S(10)) {
            ZStack {
                Color(white: 0.12)
                Image(systemName: "plus").font(.system(size: F(70), weight: .light)).foregroundStyle(Theme.accent)
            }
            .frame(width: S(250), height: S(250))
            .clipShape(RoundedRectangle(cornerRadius: S(14), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: S(14), style: .continuous)
                .stroke(Color.white.opacity(focused ? 0.9 : 0.15), style: StrokeStyle(lineWidth: focused ? 4 : 2, dash: focused ? [] : [8, 6])))
            .scaleEffect(focused ? 1.06 : 1.0)
            Text("Add a league").font(.system(size: F(22), weight: .semibold))
        }
        .animation(.easeOut(duration: 0.18), value: focused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Add a league")
    }
}

struct SportQueueRow: View {
    let q: JSON

    private var progress: Double {
        let p = q["progress"].double ?? 0
        return min(1, max(0, p > 1 ? p / 100 : p))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: S(8)) {
            HStack {
                Text(q["event"]["title"].string ?? q["title"].string ?? "Download").font(.system(size: F(26), weight: .semibold)).lineLimit(1)
                Spacer()
                Text("\(Int(progress * 100))%").font(.system(size: F(24), weight: .bold)).foregroundStyle(Theme.accent)
            }
            ProgressView(value: progress).tint(Theme.accent)
            // Sportarr's status is sometimes a number (its enum); only words are shown.
            Text([q["quality"].string, q["status"].string.flatMap { Int($0) == nil ? $0 : nil }].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: F(20))).foregroundStyle(Theme.dim).lineLimit(1)
        }
        .padding(S(22))
        .background(RoundedRectangle(cornerRadius: S(14)).fill(Color.white.opacity(0.06)))
        .tvFocusable()
    }
}

/// Shown when Sportarr has its own login on and so doesn't hand the app its key: paste it once.
struct SportarrKeyCard: View {
    @EnvironmentObject private var sportarr: Sportarr
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: S(20)) {
            Text("Sportarr needs its key").font(.system(size: F(34), weight: .bold))
            Text("Sportarr has a login turned on, so it doesn't share its key with apps on its own. Copy the key from Sportarr's Settings > General and paste it here (on Apple TV, the iPhone keyboard prompt can paste).")
                .foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            SecureField("Sportarr API key", text: $key)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .frame(maxWidth: W(900))
            Button("Use this key") { Task { await sportarr.useKey(key) } }
        }
        .tvFocusSection()
    }
}

// MARK: Event page

struct EventPage: View {
    @State var event: SportEvent
    @EnvironmentObject private var sportarr: Sportarr
    @EnvironmentObject private var rtx: RTXServer
    @State private var note: String?
    @State private var playing: PlayRequest?
    @State private var busy = false

    var body: some View {
        ZStack {
            BlurredArt(raw: event.thumb)
            ScrollView {
                AdaptiveStack(tvAlignment: .top, spacing: S(60)) {
                    Artwork(raw: event.thumb, width: 780, title: event.title)
                        .frame(width: W(760), height: S(428))
                        .clipShape(RoundedRectangle(cornerRadius: S(16), style: .continuous))
                    VStack(alignment: .leading, spacing: S(20)) {
                        HStack(spacing: S(16)) {
                            if let logo = event.leagueLogo {
                                Artwork(raw: logo, width: 154, plain: true, fit: true).frame(width: S(54), height: S(54))
                            }
                            Text(event.league.uppercased()).font(.system(size: F(22), weight: .heavy)).tracking(1.5).foregroundStyle(Theme.accent)
                        }
                        Text(event.title).font(.system(size: F(54), weight: .bold)).fixedSize(horizontal: false, vertical: true)
                        if let m = event.matchup { Text(m).font(.system(size: F(30), weight: .semibold)) }
                        Text(event.whenLabel).font(.system(size: F(26))).foregroundStyle(Theme.dim)
                        if let venue = event.venue { Text(venue).font(.system(size: F(24))).foregroundStyle(Theme.dim) }
                        if !event.stateLabel.isEmpty { SportState(label: event.stateLabel) }
                        actions
                        if let note { Text(note).foregroundStyle(Theme.accent).fixedSize(horizontal: false, vertical: true) }
                    }
                    .frame(maxWidth: W(1000), alignment: .leading)
                }
                .padding(.horizontal, Theme.sidePadding)
                .padding(.vertical, S(60))
            }
        }
        .task { await reload() }
        .fullScreenCover(item: $playing) { PlayerScreen(request: $0) }
    }

    @ViewBuilder private var actions: some View {
        AdaptiveStack(spacing: S(24)) {
            if let film = rtx.sport(for: event) {
                Button {
                    playing = PlayRequest(label: event.matchup ?? event.title, film: film, seconds: Resume.position(film.id) ?? 0, backdrop: event.thumb)
                } label: {
                    Label(Resume.position(film.id) != nil ? "Resume in 4K" : "Play in 4K", systemImage: "play.fill")
                }
            } else if event.hasFile {
                Button { Task { await rtx.refreshSports(); note = rtx.sport(for: event) == nil ? "Downloaded. The PC checks for new sports every 2 minutes; it will play here shortly." : nil } } label: {
                    Label("Check the PC", systemImage: "arrow.clockwise")
                }
            }
            if !event.hasFile {
                Button { Task { await getIt() } } label: { Label("Get it now", systemImage: "arrow.down.circle") }.disabled(busy)
            }
            Button { Task { await toggleMonitor() } } label: {
                Label(event.monitored ? "Don't get automatically" : "Get automatically", systemImage: event.monitored ? "bell.slash" : "bell")
            }
            .disabled(busy)
        }
        .tvFocusSection()
    }

    private func reload() async {
        if let j = try? await sportarr.get("events/\(event.id)"), let e = SportEvent(j) { event = e }
        await rtx.refreshSports()
    }

    private func getIt() async {
        busy = true
        defer { busy = false }
        do {
            try await sportarr.post("event/\(event.id)/automatic-search")
            note = "Searching. If a good copy turns up it starts downloading and shows under Downloading."
        } catch { note = error.localizedDescription }
    }

    private func toggleMonitor() async {
        busy = true
        defer { busy = false }
        do {
            try await sportarr.put("events/\(event.id)", ["monitored": !event.monitored])
            await reload()
            note = event.monitored ? "Sportarr will get this one when it's out." : "Sportarr won't get this one by itself."
        } catch { note = error.localizedDescription }
    }
}

// MARK: League page

struct LeaguePage: View {
    @State var league: SportLeague
    @EnvironmentObject private var sportarr: Sportarr
    @Environment(\.dismiss) private var dismiss
    @State private var events: [SportEvent] = []
    @State private var loading = true
    @State private var note: String?
    @State private var removing = false
    @State private var pickingTeams = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: S(40)) {
                AdaptiveStack(tvAlignment: .center, spacing: S(40)) {
                    Artwork(raw: league.logo ?? league.poster, width: 342, title: league.name, plain: true, fit: true)
                        .frame(width: S(180), height: S(180))
                    VStack(alignment: .leading, spacing: S(10)) {
                        Text(league.name).font(.system(size: F(60), weight: .bold))
                        Text("\(league.sport) · \(league.monitored ? "downloads automatically" : "schedule only")")
                            .font(.system(size: F(26))).foregroundStyle(Theme.dim)
                    }
                    Spacer()
                }
                .padding(.horizontal, Theme.sidePadding)
                AdaptiveStack(spacing: S(24)) {
                    if league.teamBased {
                        Button { pickingTeams = true } label: { Label("Teams", systemImage: "person.3") }
                    } else {
                        Button { Task { await setMonitored(!league.monitored) } } label: {
                            Label(league.monitored ? "Schedule only" : "Get upcoming automatically", systemImage: league.monitored ? "bell.slash" : "bell")
                        }
                    }
                    Button(role: .destructive) { removing = true } label: { Label("Remove league", systemImage: "trash") }
                }
                .padding(.horizontal, Theme.sidePadding)
                .tvFocusSection()
                if let note { Text(note).foregroundStyle(Theme.accent).padding(.horizontal, Theme.sidePadding) }
                let now = Date().addingTimeInterval(-3 * 3600)
                let upcoming = events.filter { ($0.date ?? .distantPast) >= now }.sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
                let recent = events.filter { ($0.date ?? .distantFuture) < now }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
                if !upcoming.isEmpty { EventRow(title: "Coming up", events: Array(upcoming.prefix(16))) }
                if !recent.isEmpty { EventRow(title: "Recent", events: Array(recent.prefix(16))) }
                if events.isEmpty {
                    LoadState(loading: loading, error: nil,
                              empty: league.teamBased ? "Pick teams to see their games." : "No events yet. Sportarr is still reading the schedule.")
                }
            }
            .padding(.vertical, S(50))
        }
        .task { await load() }
        .sheet(isPresented: $pickingTeams, onDismiss: { Task { await load() } }) { TeamPicker(league: league) }
        .confirmationDialog("Remove \(league.name)?", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await remove() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sportarr stops following it. Games already downloaded stay on the PC.")
        }
    }

    private func load() async {
        defer { loading = false }
        if let j = try? await sportarr.get("leagues/\(league.id)"), let l = SportLeague(j) { league = l }
        if let j = try? await sportarr.get("leagues/\(league.id)/events") {
            let all = j.array.compactMap(SportEvent.init)
            let from = Date().addingTimeInterval(-60 * 86400), to = Date().addingTimeInterval(120 * 86400)
            events = all.filter { e in guard let d = e.date else { return false }; return d >= from && d <= to }
        }
    }

    private func setMonitored(_ on: Bool) async {
        do {
            try await sportarr.put("leagues/\(league.id)", on ? ["monitored": true, "monitorType": "Future"] : ["monitored": false])
            await load()
            note = on ? "Sportarr will download each upcoming event once it's out." : "Sportarr keeps the schedule; tap Get it now on an event you want."
        } catch { note = error.localizedDescription }
    }

    private func remove() async {
        do {
            try await sportarr.delete("leagues/\(league.id)", ["deleteFiles": "false"])
            dismiss()
        } catch { note = error.localizedDescription }
    }
}

/// Team leagues (NFL, Premier League): Sportarr follows the teams picked here, and gets their games.
struct TeamPicker: View {
    let league: SportLeague
    @EnvironmentObject private var sportarr: Sportarr
    @Environment(\.dismiss) private var dismiss
    @State private var teams: [JSON] = []
    @State private var picked: Set<String> = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if teams.isEmpty { LoadState(loading: loading, error: error, empty: "No teams listed for this league.") }
                ForEach(teams.indices, id: \.self) { i in
                    let t = teams[i]
                    let id = t["idTeam"].string ?? ""
                    Button {
                        if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
                    } label: {
                        HStack(spacing: S(20)) {
                            Artwork(raw: t["strTeamBadge"].string, width: 154, plain: true, fit: true).frame(width: S(50), height: S(50))
                            Text(t["strTeam"].string ?? id)
                            Spacer()
                            if picked.contains(id) { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                        }
                    }
                }
            }
            .navigationTitle("\(league.name) teams")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } } }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .task { await load() }
    }

    private func load() async {
        defer { loading = false }
        do {
            let l = try await sportarr.get("leagues/\(league.id)")
            picked = Set(l["monitoredTeams"].array.compactMap { t in
                guard t["monitored"].isNull || t["monitored"].bool else { return nil }
                return t["team"]["externalId"].string ?? t["team"]["idTeam"].string ?? t["externalId"].string ?? t["teamExternalId"].string
            })
            teams = try await sportarr.get("leagues/\(league.id)/teams").array
                .sorted { ($0["strTeam"].string ?? "") < ($1["strTeam"].string ?? "") }
        } catch { self.error = error.localizedDescription }
    }

    private func save() async {
        do {
            try await sportarr.put("leagues/\(league.id)/teams", ["monitoredTeamIds": Array(picked)])
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: Add a league

struct AddLeagueView: View {
    @EnvironmentObject private var sportarr: Sportarr
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [JSON] = []
    @State private var searching = false
    @State private var note: String?
    @State private var adding: JSON?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: S(30)) {
                Text("Add a league").font(.system(size: F(64), weight: .bold))
                AdaptiveStack(spacing: S(24)) {
                    TextField("League or sport, e.g. NBA, MotoGP, UFC", text: $query)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .onSubmit { Task { await search() } }
                        .frame(maxWidth: W(1000))
                    Button("Search") { Task { await search() } }.disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .tvFocusSection()
                if let note { Text(note).foregroundStyle(Theme.accent) }
                if searching { ProgressView() }
                ForEach(results.indices, id: \.self) { i in
                    let r = results[i]
                    Button { adding = r } label: {
                        HStack(spacing: S(26)) {
                            Artwork(raw: r.first("strBadge", "strLogo").string, width: 154, plain: true, fit: true).frame(width: S(80), height: S(80))
                            VStack(alignment: .leading, spacing: S(4)) {
                                Text(r["strLeague"].string ?? "League").font(.system(size: F(28), weight: .semibold))
                                Text([r["strSport"].string, r["strCountry"].string].compactMap { $0 }.joined(separator: " · "))
                                    .font(.system(size: F(22))).foregroundStyle(Theme.dim)
                            }
                            Spacer()
                            Image(systemName: "plus.circle").font(.system(size: F(34))).foregroundStyle(Theme.accent)
                        }
                        .padding(S(18))
                    }
                    .cardButtonStyle()
                }
            }
            .padding(.horizontal, Theme.sidePadding)
            .padding(.vertical, S(40))
        }
        .confirmationDialog("Add \(adding?["strLeague"].string ?? "")?", isPresented: Binding(get: { adding != nil }, set: { if !$0 { adding = nil } }), titleVisibility: .visible) {
            if let r = adding {
                if (r["strSportFormat"].string ?? "").lowercased().contains("team") {
                    Button("Add, then pick teams") { Task { await add(r, monitored: false) } }
                } else {
                    Button("Add and get upcoming automatically") { Task { await add(r, monitored: true) } }
                    Button("Add, schedule only") { Task { await add(r, monitored: false) } }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        searching = true
        defer { searching = false }
        do {
            results = try await sportarr.get("leagues/search/\(q)").array
            note = results.isEmpty ? "Nothing found for \"\(q)\"." : nil
        } catch { note = error.localizedDescription }
    }

    private func add(_ r: JSON, monitored: Bool) async {
        var body: [String: Any] = [
            "externalId": r["idLeague"].string ?? "", "name": r["strLeague"].string ?? "", "sport": r["strSport"].string ?? "",
            "monitored": monitored, "monitorType": monitored ? "Future" : "None", "enableDvr": false,
            "keepAllEvents": true, "searchForMissingEvents": false,
        ]
        if let v = r["strSportFormat"].string { body["sportFormat"] = v }
        if let v = r["strLogo"].string { body["logoUrl"] = v }
        if let v = r["strBanner"].string { body["bannerUrl"] = v }
        if let v = r["strPoster"].string { body["posterUrl"] = v }
        do {
            try await sportarr.post("leagues", body)
            note = "\(r["strLeague"].string ?? "League") added. Its schedule appears in a minute."
            results = []
        } catch { note = error.localizedDescription }
    }
}
