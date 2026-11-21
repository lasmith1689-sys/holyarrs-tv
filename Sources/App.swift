import AVFoundation
import SwiftUI

@main
struct HolyArrsTVApp: App {
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

/// Signs in first, then the tab bar: Home, Explore, Sports, Search, Requests, Downloads, Calendar, Settings.
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
                    Tab("Explore", systemImage: "sparkles.tv", value: "explore") { Stack { ExploreView() } }
                    if sportarr.enabled {
                        Tab("Sports", systemImage: "sportscourt", value: "sports") { Stack { SportsView() } }
                    }
                    // On Apple TV, Search and Settings are icon-only so all eight tabs fit across the top.
                    Tab(value: "search", role: .search) { Stack { SearchView() } }
                    Tab("Requests", systemImage: "tray.full", value: "requests") { Stack { RequestsView() } }
                    if me.canManage {
                        Tab("Downloads", systemImage: "arrow.down.circle", value: "downloads") { Stack { DownloadsView() } }
                    }
                    Tab("Calendar", systemImage: "calendar", value: "calendar") { Stack { CalendarView() } }
                    Tab(value: "settings") { Stack { SettingsView() } } label: {
                        if Device.isTV { Image(systemName: "gearshape").accessibilityLabel("Settings") } else { Label("Settings", systemImage: "gearshape") }
                    }
                }
            } else {
                SignInView()
            }
        }
        .task(id: api.address) { await api.restore() }
        .task(id: rtx.address) {
            // The PC's film list changes as downloads land: read it again every few minutes while the app is open.
            await rtx.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 180_000_000_000)
                await rtx.refreshIfStale()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await rtx.refreshIfStale(maxAge: 30) } }
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
        }
    }
}
