import SwiftUI

/// Saved articles. Add a bookmark by long-pressing an entry's title anywhere in
/// the app; swipe a row here to remove it.
struct BookmarksTab: View {
    @EnvironmentObject var store: LibraryStore
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.bookmarks.isEmpty {
                    ContentPlaceholder(
                        icon: "bookmark",
                        title: "No bookmarks yet",
                        message: "Long-press an entry's title and choose Bookmark to save it here."
                    )
                } else {
                    List {
                        ForEach(store.bookmarks) { bookmark in
                            Button { open(bookmark.slug) } label: {
                                Text(bookmark.title)
                                    .font(.headline)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    store.removeBookmark(slug: bookmark.slug)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Bookmarks")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .articleDestinations()
        }
    }

    private func open(_ slug: String) {
        if let id = store.article(slug: slug)?.id { path.append(id) }
    }
}
