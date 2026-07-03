import SwiftUI

/// Two-column layout: a browse/search sidebar and an article detail pane.
/// The same layout adapts to iPhone (stack), iPad and Mac.
struct ContentView: View {
    @EnvironmentObject var store: LibraryStore
    @State private var selection: Int64?

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
        } detail: {
            if let id = selection {
                // `.id(id)` recreates the navigation stack when a new entry is
                // chosen from the sidebar, so cross-reference history resets.
                ArticleNavigator(rootID: id)
                    .id(id)
            } else {
                PlaceholderView()
            }
        }
    }
}

/// A self-contained navigation stack so cross-reference links push new
/// articles on top of the current one within the detail pane.
struct ArticleNavigator: View {
    let rootID: Int64
    @State private var path: [Int64] = []

    var body: some View {
        NavigationStack(path: $path) {
            ArticleView(articleID: rootID)
                .navigationDestination(for: Int64.self) { id in
                    ArticleView(articleID: id)
                }
                .navigationDestination(for: AuthorRef.self) { author in
                    AuthorArticlesView(author: author)
                }
        }
    }
}

struct PlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "book.closed")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Encyclopædia Britannica")
                .font(.title2.weight(.semibold))
            Text("Eleventh Edition · 1911")
                .foregroundStyle(.secondary)
            Text("Search or browse A–Z to open an article.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
