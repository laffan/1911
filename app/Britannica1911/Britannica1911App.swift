import SwiftUI

@main
struct Britannica1911App: App {
    @StateObject private var store = LibraryStore()
    @StateObject private var settings = SettingsStore()
    @StateObject private var listen = ListenStore()
    @StateObject private var router = AppRouter()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(listen)
                .environmentObject(router)
        }
        #if os(macOS)
        .defaultSize(width: 1000, height: 720)
        #endif
    }
}
