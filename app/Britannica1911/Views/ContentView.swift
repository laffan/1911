import SwiftUI

/// The primary destinations, presented as a bottom tab bar (iOS) or a tab strip
/// (macOS).
enum Tab: Hashable {
    case browse, search, random, bookmarks
}

struct ContentView: View {
    @State private var selectedTab: Tab = .browse

    var body: some View {
        TabView(selection: $selectedTab) {
            BrowseTab()
                .tabItem { Label("Browse", systemImage: "book") }
                .tag(Tab.browse)

            SearchTab()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(Tab.search)

            RandomTab()
                .tabItem { Label("Random", systemImage: "die.face.5") }
                .tag(Tab.random)

            BookmarksTab()
                .tabItem { Label("Bookmarks", systemImage: "bookmark") }
                .tag(Tab.bookmarks)
        }
        // Give the whole app an encyclopedic serif feel.
        .fontDesign(.serif)
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

    /// Adds a long-press context menu to bookmark / un-bookmark an entry.
    func bookmarkable(slug: String, title: String) -> some View {
        modifier(BookmarkContextMenu(slug: slug, title: title))
    }
}

private struct BookmarkContextMenu: ViewModifier {
    @EnvironmentObject var store: LibraryStore
    let slug: String
    let title: String

    func body(content: Content) -> some View {
        content.contextMenu {
            Button {
                store.toggleBookmark(slug: slug, title: title)
            } label: {
                if store.isBookmarked(slug) {
                    Label("Remove Bookmark", systemImage: "bookmark.slash")
                } else {
                    Label("Bookmark", systemImage: "bookmark")
                }
            }
        }
    }
}

/// A title + two-line preview row, shared by the browse and bookmark lists.
struct EntryRow: View {
    let title: String
    var subtitle: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
