import SwiftUI

@main
struct Britannica1911App: App {
    @StateObject private var store = LibraryStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
        #if os(macOS)
        .defaultSize(width: 1000, height: 720)
        #endif
    }
}
