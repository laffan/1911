import SwiftUI

/// History across launches: random articles you've landed on, and search
/// queries you've run. Tapping a recent search jumps to the Search tab.
struct RecentTab: View {
    @EnvironmentObject var store: LibraryStore
    @Binding var selectedTab: Tab
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if store.recentRandom.isEmpty && store.recentSearches.isEmpty {
                    emptyState
                }

                if !store.recentRandom.isEmpty {
                    Section {
                        ForEach(store.recentRandom) { item in
                            Button { open(slug: item.slug) } label: {
                                Label(item.title, systemImage: "shuffle").lineLimit(1)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        clearableHeader("Recent random", clear: store.clearRecentRandom)
                    }
                }

                if !store.recentSearches.isEmpty {
                    Section {
                        ForEach(store.recentSearches, id: \.self) { query in
                            Button {
                                store.searchText = query
                                selectedTab = .search
                            } label: {
                                Label(query, systemImage: "magnifyingglass").lineLimit(1)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        clearableHeader("Recent searches", clear: store.clearRecentSearches)
                    }
                }
            }
            .navigationTitle("Recent")
            .articleDestinations()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No history yet")
                .font(.headline)
            Text("Random articles you open and searches you run will appear here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .listRowSeparator(.hidden)
    }

    private func clearableHeader(_ title: String, clear: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button("Clear", action: clear)
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .textCase(nil)
    }

    private func open(slug: String) {
        if let id = store.article(slug: slug)?.id { path.append(id) }
    }
}
