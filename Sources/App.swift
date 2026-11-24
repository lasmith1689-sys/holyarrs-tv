import AVFoundation
import SwiftUI

#if os(iOS)
/// Hands iOS's "your background downloads finished" wake-up to the offline store (offline copies keep downloading
/// with the phone locked or the app closed).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        MainActor.assumeIsolated { OfflineStore.shared.backgroundDone = completionHandler }
    }
}
#endif

@main
struct HolyArrsTVApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    init() {
        #if os(iOS)
        // Playback, not ambient: sound with the ring switch off, AirPlay to an Apple TV, and a cast that keeps going
        // when the phone locks (UIBackgroundModes audio).
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        #endif
    }

    @StateObject private var api = HolyArrs()
    @StateObject private var rtx = RTXServer()
    @StateObject private var sportarr = Sportarr()

    var body: some Scene {
        WindowGroup {
            TextSizeRoot()
                .environmentObject(api)
                .environmentObject(rtx)
                .environmentObject(sportarr)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

/// Redraws everything when the iPhone's Text Size changes, so F() sizes follow it (Release 4).
struct TextSizeRoot: View {
    @Environment(\.dynamicTypeSize) private var size
    var body: some View {
        #if os(iOS)
        RootView().id(size)
        #else
        RootView()
        #endif
    }
}

/// Signs in first, then the tab bar. iPhone: Home, Sports, TV, Downloads, Search (five, so no More); Settings opens
/// from the gear on Home. Apple TV: Home, Sports, TV, Downloads, then Search and Settings as icons. Explore's rows
/// are on Home (Browse); Requests and Calendar are inside Downloads.
struct RootView: View {
    @EnvironmentObject private var api: HolyArrs
    @EnvironmentObject private var rtx: RTXServer
    @EnvironmentObject private var sportarr: Sportarr
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("tab") private var tab = "home"
    @AppStorage("downloadsPage") private var downloadsPage = "downloads"
    /// iPhone: Settings open on Home's stack (it was a tab).
    @AppStorage("homeSettings") private var homeSettings = false
    /// A Top Shelf card (afterglow://play or afterglow://od): straight into the player (Release 4).
    @State private var linkedFilm: PlayRequest?
    @State private var linkedOD: LiveRequest?

    /// afterglow://play?id=<film or episode>&t=&d=&title=[&label=], afterglow://od?kind=&id=&ext=&t=&d=&title=
    static func request(_ url: URL) -> (film: PlayRequest?, od: LiveRequest?) {
        guard url.scheme == "afterglow", let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return (nil, nil) }
        var q: [String: String] = [:]
        for i in c.queryItems ?? [] { q[i.name] = i.value }
        let t = Double(q["t"] ?? "") ?? 0, d = Double(q["d"] ?? "") ?? 0
        let title = q["title"] ?? ""
        switch url.host {
        case "play":
            guard let id = q["id"], !id.isEmpty else { return (nil, nil) }
            let film = RTXFilm(JSON.object(["id": .string(id), "title": .string(title), "duration_s": .number(d)]))
            return (PlayRequest(label: q["label"] ?? title, film: film, seconds: t), nil)
        case "od":
            guard let kind = q["kind"], let id = q["id"], ["movie", "episode"].contains(kind) else { return (nil, nil) }
            return (nil, LiveRequest(stream: id, title: title, vod: VODRef(kind: kind, id: id, ext: q["ext"] ?? "mp4", start: t,
                                                                         duration: d > 0 ? d : nil)))
        default:
            return (nil, nil)
        }
    }

    /// iPhone away from home (HolyArrs and the PC both silent) with films downloaded: their list, not the tabs.
    private var awayWithDownloads: Bool {
        !Device.isTV && api.unreachable && rtx.reachable != true && !OfflineStore.shared.items.isEmpty
    }

    /// Where a saved tab from an older layout lives now. Read through this (not only rewritten once at launch) so a
    /// value that can't be rewritten, such as one passed at launch, still opens the right tab.
    static func current(_ saved: String) -> String {
        switch saved {
        case "explore": return "home"
        case "requests", "calendar": return "downloads"
        case "settings" where !Device.isTV: return "home"
        default: return saved
        }
    }

    var body: some View {
        ZStack {
            Backdrop()
            if api.checking && api.me == nil {
                ProgressView()
            } else if let me = api.me, !awayWithDownloads {
                TabView(selection: Binding(get: { RootView.current(tab) }, set: { tab = $0 })) {
                    Tab("Home", systemImage: "house", value: "home") { Stack { HomeView() } }
                    if sportarr.enabled || rtx.liveTV {
                        Tab("Sports", systemImage: "sportscourt", value: "sports") { Stack { SportsView() } }
                    }
                    if rtx.liveTV {
                        Tab("TV", systemImage: "tv", value: "tv") { Stack { TVView() } }
                    }
                    // Downloads opens on the downloads list; Requests and Calendar are picked at its top.
                    Tab("Downloads", systemImage: "arrow.down.circle", value: "downloads") { Stack { RequestsHub(canManage: me.canManage) } }
                    // On Apple TV, Search and Settings are icon-only at the right so the tabs fit across the top.
                    Tab(value: "search", role: .search) { Stack { SearchView() } } label: {
                        if Device.isTV { Image(systemName: "magnifyingglass").accessibilityLabel("Search") } else { Label("Search", systemImage: "magnifyingglass") }
                    }
                    if Device.isTV {
                        Tab(value: "settings") { Stack { SettingsView() } } label: {
                            Image(systemName: "gearshape").accessibilityLabel("Settings")
                        }
                    }
                }
            } else if api.unreachable, !Device.isTV, !OfflineStore.shared.items.isEmpty {
                #if os(iOS)
                NavigationStack { OfflineView(offlineBanner: true) { Task { await api.restore() } } }
                #endif
            } else {
                SignInView()
            }
        }
        .onOpenURL { url in
            let r = RootView.request(url)
            tab = "home"
            if let f = r.film { linkedFilm = f } else if let o = r.od { linkedOD = o }
        }
        .fullScreenCover(item: $linkedFilm) { req in
            PlayerScreen(request: req).onDisappear { Task { await rtx.syncPositions() } }
        }
        .fullScreenCover(item: $linkedOD) { req in
            LivePlayerScreen(request: req).onDisappear { Task { await rtx.syncPositions() } }
        }
        .onAppear {
            // Saved places from older layouts. Explore is on Home now. Requests was a tab (showing the page kept in
            // "requestsPage"), and before that Calendar and Downloads were tabs: each opens its page inside Downloads.
            // A saved "downloads" needs nothing: it is the Downloads tab, which opens on the downloads list.
            // On iPhone Settings was a tab: it opens on Home's stack.
            switch tab {
            case "requests":
                downloadsPage = UserDefaults.standard.string(forKey: "requestsPage") ?? "requests"
            case "calendar":
                downloadsPage = "calendar"
            case "settings" where !Device.isTV:
                homeSettings = true
            default:
                break
            }
            tab = RootView.current(tab)
        }
        .task(id: api.address) {
            await Away.shared.check(home: rtx.homeBase)  // home or away first, so sign-in goes to the right address
            await api.restore()
            // HolyArrs not answering (the PC restarting): ask again every minute until it does.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if api.unreachable { await api.restore() }
            }
        }
        .task(id: rtx.address) {
            // The PC's film list changes as downloads land: read it again every few minutes while the app is open.
            await rtx.refresh()
            #if os(iOS)
            await OfflineStore.shared.resumeWanted(rtx: rtx.error == nil ? rtx.base : nil)  // downloads asked for earlier carry on
            #endif
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 180_000_000_000)
                await rtx.refreshIfStale()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    let wasAway = Away.shared.active
                    await Away.shared.check(home: rtx.homeBase)  // left home or came back while the app slept
                    if api.unreachable || wasAway != Away.shared.active { await api.restore() }
                    await rtx.refreshIfStale(maxAge: 30)
                    #if os(iOS)
                    await OfflineStore.shared.resumeWanted(rtx: rtx.error == nil ? rtx.base : nil)
                    #endif
                }
            }
        }
        .task(id: "\(sportarr.address)|\(sportarr.enabled)") { await sportarr.connect() }
    }
}

/// Each tab keeps its own navigation, with every kind of page it can open.
struct Stack<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        NavigationStack {
            ZStack {
                Backdrop()
                content
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case let .title(ref):
                    if ref.kind == .artist { ArtistView(ref: ref) } else { TitlePage(ref: ref) }
                case let .person(id, name):
                    PersonView(id: id, name: name)
                case let .genre(type, id, name):
                    GenreView(type: type, genre: id, name: name)
                }
            }
            .navigationDestination(for: ODRoute.self) { route in route.page }  // On Demand pages, from TV or Search
        }
    }
}
