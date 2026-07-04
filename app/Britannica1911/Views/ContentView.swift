import SwiftUI

/// The three primary destinations, presented as a bottom tab bar (iOS) or a
/// tab strip (macOS).
enum Tab: Hashable {
    case search, random, recent
}

struct ContentView: View {
    @State private var selectedTab: Tab = .search

    var body: some View {
        TabView(selection: $selectedTab) {
            SearchTab()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(Tab.search)

            RandomTab()
                .tabItem { Label("Random", systemImage: "die.face.5") }
                .tag(Tab.random)

            RecentTab(selectedTab: $selectedTab)
                .tabItem { Label("Recent", systemImage: "clock") }
                .tag(Tab.recent)
        }
    }
}

extension View {
    /// Registers article and author navigation for an enclosing NavigationStack,
    /// so any `NavigationLink(value:)` or `path.append(...)` of an article id or
    /// `AuthorRef` resolves to the right screen. Applied once per tab.
    func articleDestinations() -> some View {
        self
            .navigationDestination(for: Int64.self) { id in
                ArticleView(articleID: id)
            }
            .navigationDestination(for: AuthorRef.self) { author in
                AuthorArticlesView(author: author)
            }
    }
}
