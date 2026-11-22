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
            RootView()
                .environmentObject(api)
                .environmentObject(rtx)
                .environmentObject(sportarr)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

/// Signs in first, then the tab bar: Home, Explore, Sports, TV, Search, Requests (with Downloads and Calendar),
/// Settings.
struct RootView: View {
    @EnvironmentObject private var api: HolyArrs
    @EnvironmentObject private var rtx: RTXServer
    @EnvironmentObject private var sportarr: Sportarr
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("tab") private var tab = "home"

    var body: some View {
        ZStack {
            Backdrop()
            if api.checking && api.me == nil {
                ProgressView()
            } else if let me = api.me {
                TabView(selection: $tab) {
                    Tab("Home", systemImage: "house", value: "home") { Stack { HomeView() } }
                    // iPhone shows four tabs and More: Home, Sports, TV and Search up front, Explore in More.
                    if Device.isTV {
                        Tab("Explore", systemImage: "sparkles.tv", value: "explore") { Stack { ExploreView() } }
                    }
                    if sportarr.enabled || rtx.liveTV {
                        Tab("Sports", systemImage: "sportscourt", value: "sports") { Stack { SportsView() } }
                    }
                    if rtx.liveTV {
                        Tab("TV", systemImage: "tv", value: "tv") { Stack { TVView() } }
                    }
                    // On Apple TV, Search and Settings are icon-only so the tabs fit across the top. Downloads and
                    // Calendar live inside Requests.
                    Tab(value: "search", role: .search) { Stack { SearchView() } } label: {
                        if Device.isTV { Image(systemName: "magnifyingglass").accessibilityLabel("Search") } else { Label("Search", systemImage: "magnifyingglass") }
                    }
                    if !Device.isTV {
                        Tab("Explore", systemImage: "sparkles.tv", value: "explore") { Stack { ExploreView() } }
                    }
                    Tab("Requests", systemImage: "tray.full", value: "requests") { Stack { RequestsHub(canManage: me.canManage) } }
                    Tab(value: "settings") { Stack { SettingsView() } } label: {
                        if Device.isTV { Image(systemName: "gearshape").accessibilityLabel("Settings") } else { Label("Settings", systemImage: "gearshape") }
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
        .onAppear {
            // Downloads and Calendar used to be tabs of their own: a saved choice of either opens it inside Requests.
            if tab == "downloads" || tab == "calendar" {
                UserDefaults.standard.set(tab, forKey: "requestsPage")
                tab = "requests"
            }
        }
        .task(id: api.address) { await api.restore() }
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
