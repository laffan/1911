import SwiftUI

/// The Notebook pane collects everything the reader has kept: saved articles,
/// passages sent from articles, and recent search / random history.
struct NotebookTab: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var router: AppRouter
    @State private var path = NavigationPath()
    @State private var section: Section = .bookmarks

    enum Section: String, CaseIterable, Identifiable {
        case bookmarks, notes, searches, random
        var id: String { rawValue }
        var label: String {
            switch self {
            case .bookmarks: return "Bookmarks"
            case .notes:     return "Notes"
            case .searches:  return "Searches"
            case .random:    return "Random"
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                Picker("Section", selection: $section) {
                    ForEach(Section.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding()
                Divider()

                Group {
                    switch section {
                    case .bookmarks: bookmarksList
                    case .notes:     notesList
                    case .searches:  recentSearchesList
                    case .random:    recentRandomList
                    }
                }
            }
            .articleDestinations()
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
        }
    }

    private func open(slug: String) {
        if let id = store.article(slug: slug)?.id { path.append(id) }
    }

    // MARK: - Bookmarks

    @ViewBuilder
    private var bookmarksList: some View {
        if store.bookmarks.isEmpty {
            ContentPlaceholder(
                icon: "bookmark",
                title: "No bookmarks yet",
                message: "Long-press an entry's title and choose Bookmark to save it here."
            )
        } else {
            List {
                ForEach(store.bookmarks) { bookmark in
                    Button { open(slug: bookmark.slug) } label: {
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

    // MARK: - Notes

    @ViewBuilder
    private var notesList: some View {
        if store.notes.isEmpty {
            ContentPlaceholder(
                icon: "note.text",
                title: "No notes yet",
                message: "Select text in an article and choose “Send to Notebook” to save a passage here."
            )
        } else {
            List {
                ForEach(store.notes) { note in
                    Button { open(slug: note.articleSlug) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(note.text)
                                .font(.callout)
                                .lineLimit(4)
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up.forward.square")
                                    .font(.caption2)
                                Text(note.articleTitle)
                                    .font(.caption)
                            }
                            .foregroundStyle(Color.accentColor)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            store.removeNote(note)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Recent searches

    @ViewBuilder
    private var recentSearchesList: some View {
        if store.recentSearches.isEmpty {
            ContentPlaceholder(
                icon: "clock.arrow.circlepath",
                title: "No recent searches",
                message: "Searches you run in Browse show up here."
            )
        } else {
            List {
                SwiftUI.Section {
                    ForEach(store.recentSearches, id: \.self) { query in
                        Button {
                            store.searchText = query
                            router.selectedTab = .browse
                        } label: {
                            Label(query, systemImage: "clock.arrow.circlepath")
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    listHeader("Recent searches") { store.clearRecentSearches() }
                }
            }
        }
    }

    // MARK: - Recent random

    @ViewBuilder
    private var recentRandomList: some View {
        if store.recentRandoms.isEmpty {
            ContentPlaceholder(
                icon: "die.face.5",
                title: "No random entries yet",
                message: "Tap the dice in Browse to open a random article; your history lands here."
            )
        } else {
            List {
                SwiftUI.Section {
                    ForEach(store.recentRandoms) { entry in
                        Button { open(slug: entry.slug) } label: {
                            Label(entry.title, systemImage: "die.face.5")
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    listHeader("Recent random") { store.clearRecentRandoms() }
                }
            }
        }
    }

    // MARK: - Helpers

    private func listHeader(_ title: String, clear: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button("Clear", action: clear)
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .textCase(nil)
    }
}
