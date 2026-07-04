import SwiftUI

/// Full-text search over the corpus. When the field is empty it shows recent
/// searches; browsing lives in its own tab.
struct SearchTab: View {
    @EnvironmentObject var store: LibraryStore
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.searchText.isEmpty {
                    recentList
                } else {
                    resultsList
                }
            }
            .searchable(text: $store.searchText, prompt: "Search 1911 Britannica")
            .onSubmit(of: .search) { store.recordSearch(store.searchText) }
            .navigationTitle("Search")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .articleDestinations()
        }
    }

    @ViewBuilder
    private var recentList: some View {
        if let error = store.loadError {
            List { Text(error).font(.footnote).foregroundStyle(.red) }
        } else if store.recentSearches.isEmpty {
            ContentPlaceholder(icon: "magnifyingglass",
                               title: "Search the encyclopedia",
                               message: "Find articles by title, text, or contributor.")
        } else {
            List {
                Section {
                    ForEach(store.recentSearches, id: \.self) { query in
                        Button { store.searchText = query } label: {
                            Label(query, systemImage: "clock.arrow.circlepath")
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    HStack {
                        Text("Recent searches")
                        Spacer()
                        Button("Clear") { store.clearRecentSearches() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                    .textCase(nil)
                }
            }
        }
    }

    private var resultsList: some View {
        List {
            Section(resultsHeader) {
                if store.results.isEmpty {
                    Text("No matching articles")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.results) { result in
                        Button {
                            store.recordSearch(store.searchText)
                            path.append(result.id)
                        } label: {
                            SearchResultRow(result: result)
                        }
                        .buttonStyle(.plain)
                        .bookmarkable(slug: result.slug, title: result.title)
                    }
                }
            }
        }
    }

    private var resultsHeader: String {
        switch store.results.count {
        case 0: return "Results"
        case 1: return "1 result"
        default: return "\(store.results.count) results"
        }
    }
}

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
