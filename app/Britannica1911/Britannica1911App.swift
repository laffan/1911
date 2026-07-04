import SwiftUI

@main
struct Britannica1911App: App {
    @StateObject private var store = LibraryStore()

    init() {
        Self.applySerifChrome()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
        #if os(macOS)
        .defaultSize(width: 1000, height: 720)
        #endif
    }

    /// Give the UIKit navigation and tab bars a serif face too, so the whole
    /// app (not just SwiftUI content) reads like an encyclopedia.
    private static func applySerifChrome() {
        #if os(iOS)
        func serif(_ style: UIFont.TextStyle, weight: UIFont.Weight = .regular) -> UIFont {
            let base = UIFont.preferredFont(forTextStyle: style)
            let systemDesc = UIFont.systemFont(ofSize: base.pointSize, weight: weight).fontDescriptor
            let desc = systemDesc.withDesign(.serif) ?? systemDesc
            return UIFont(descriptor: desc, size: base.pointSize)
        }

        let nav = UINavigationBarAppearance()
        nav.configureWithDefaultBackground()
        nav.titleTextAttributes = [.font: serif(.headline, weight: .semibold)]
        nav.largeTitleTextAttributes = [.font: serif(.largeTitle, weight: .bold)]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav

        let tab = UITabBarAppearance()
        tab.configureWithDefaultBackground()
        for item in [tab.stackedLayoutAppearance, tab.inlineLayoutAppearance, tab.compactInlineLayoutAppearance] {
            item.normal.titleTextAttributes = [.font: serif(.caption2)]
            item.selected.titleTextAttributes = [.font: serif(.caption2, weight: .semibold)]
        }
        UITabBar.appearance().standardAppearance = tab
        if #available(iOS 15.0, *) {
            UITabBar.appearance().scrollEdgeAppearance = tab
        }
        #endif
    }
}
