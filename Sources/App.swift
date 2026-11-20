import SwiftUI

@main
struct HolyArrsTVApp: App {
    @StateObject private var api = HolyArrs()
    @StateObject private var rtx = RTXServer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(api)
                .environmentObject(rtx)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

/// Signs in first, then the tab bar: Home, Explore, Search, Requests, Downloads, Calendar, Settings.
struct RootView: View {
    @EnvironmentObject private var api: HolyArrs
    @EnvironmentObject private var rtx: RTXServer
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
                    Tab("Search", systemImage: "magnifyingglass", value: "search") { Stack { SearchView() } }
                    Tab("Requests", systemImage: "tray.full", value: "requests") { Stack { RequestsView() } }
                    if me.canManage {
                        Tab("Downloads", systemImage: "arrow.down.circle", value: "downloads") { Stack { DownloadsView() } }
                    }
                    Tab("Calendar", systemImage: "calendar", value: "calendar") { Stack { CalendarView() } }
                    Tab("Settings", systemImage: "gearshape", value: "settings") { Stack { SettingsView() } }
                }
            } else {
                SignInView()
            }
        }
        .task(id: api.address) { await api.restore() }
        .task(id: rtx.address) { await rtx.refresh() }
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
