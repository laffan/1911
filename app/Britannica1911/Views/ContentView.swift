import SwiftUI
import Combine

/// The primary destinations, presented as a bottom tab bar (iOS) or a tab strip
/// (macOS).
enum Tab: Hashable {
    case browse, notebook, listen, settings
}

/// Shared layout metrics so the browse index and article body line up in width.
/// (Named to avoid colliding with SwiftUI's `Layout` protocol.)
enum LayoutMetrics {
    /// Reading-column width used for articles and (on iPad) the browse list.
    static let articleContentWidth: CGFloat = 720
}

/// App-wide navigation coordinator. Lets deep views switch tabs (e.g. a recent
/// search in the Notebook jumps to Browse; a new recording jumps to Listen).
@MainActor
final class AppRouter: ObservableObject {
    @Published var selectedTab: Tab = .browse
}

struct ContentView: View {
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        TabView(selection: $router.selectedTab) {
            BrowseTab()
                .tabItem { Label("Browse", systemImage: "book") }
                .tag(Tab.browse)

            NotebookTab()
                .tabItem { Label("Notebook", systemImage: "note.text") }
                .tag(Tab.notebook)

            ListenTab()
                .tabItem { Label("Listen", systemImage: "headphones") }
                .tag(Tab.listen)

            SettingsTab()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        // Give the whole app an encyclopedic serif feel.
        .fontDesign(.serif)
        // Honor the user's appearance preference (nil = follow the system).
        .preferredColorScheme(settings.appearance.colorScheme)
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

/// A single search hit: title plus a highlighted body snippet.
struct SearchResultRow: View {
    let result: SearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(result.title)
                .font(.headline)
            Text(Self.highlighted(result.snippet))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// Convert an FTS5 snippet — where matched terms are wrapped in the control
    /// characters STX (\u{2}) and ETX (\u{3}) — into an AttributedString that
    /// bolds the matches.
    static func highlighted(_ snippet: String) -> AttributedString {
        var out = AttributedString()
        var buffer = ""
        var bold = false

        func flush() {
            guard !buffer.isEmpty else { return }
            var piece = AttributedString(buffer)
            if bold {
                piece.font = .caption.bold()
                piece.foregroundColor = .primary
            }
            out += piece
            buffer = ""
        }

        for ch in snippet {
            switch ch {
            case "\u{2}": flush(); bold = true
            case "\u{3}": flush(); bold = false
            default: buffer.append(ch)
            }
        }
        flush()
        return out
    }
}

/// A centered icon + message used for empty states.
struct ContentPlaceholder: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
