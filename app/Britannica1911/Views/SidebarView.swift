import SwiftUI

/// The leading column: a search field over the whole corpus, or an A–Z browse
/// index when the search box is empty.
struct SidebarView: View {
    @EnvironmentObject var store: LibraryStore
    @Binding var selection: Int64?

    var body: some View {
        // A NavigationStack of its own so drilling into a letter pushes the
        // per-letter list within this column, leaving the detail pane to the
        // shared `selection` binding.
        NavigationStack {
            List(selection: $selection) {
                if let error = store.loadError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                if store.searchText.isEmpty {
                    homeSections
                } else {
                    searchResultsSection
                }
            }
            .navigationTitle("Britannica 1911")
            .searchable(text: $store.searchText, placement: .sidebar, prompt: "Search articles")
            .onSubmit(of: .search) { store.recordSearch(store.searchText) }
            .onChange(of: selection) { newValue in
                // Opening a result during an active search counts as a used query.
                if newValue != nil,
                   !store.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    store.recordSearch(store.searchText)
                }
            }
            .toolbar {
                ToolbarItem {
                    Button(action: openRandom) {
                        Label("Random article", systemImage: "die.face.5")
                    }
                    .help("Open a random article")
                }
            }
        }
    }

    // MARK: - Home (empty search) sections

    @ViewBuilder
    private var homeSections: some View {
        Section {
            Button(action: openRandom) {
                Label("Random article", systemImage: "die.face.5")
            }
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
                    Button { store.searchText = query } label: {
                        Label(query, systemImage: "magnifyingglass").lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                clearableHeader("Recent searches", clear: store.clearRecentSearches)
            }
        }

        Section("Browse A–Z") {
            ForEach(store.letters, id: \.self) { letter in
                NavigationLink {
                    LetterListView(letter: letter, selection: $selection)
                } label: {
                    Label(letter, systemImage: "\(letter.lowercased()).square")
                }
            }
        }
    }

    private var searchResultsSection: some View {
        Section(resultsHeader) {
            ForEach(store.results) { result in
                SearchResultRow(result: result).tag(result.id)
            }
            if store.results.isEmpty {
                Text("No matching articles")
                    .foregroundStyle(.secondary)
            }
        }
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

    // MARK: - Actions

    private func openRandom() {
        if let id = store.pickRandom(excluding: selection) { selection = id }
    }

    private func open(slug: String) {
        if let id = store.article(slug: slug)?.id { selection = id }
    }

    private var resultsHeader: String {
        switch store.results.count {
        case 0: return "Results"
        case 1: return "1 result"
        default: return "\(store.results.count) results"
        }
    }
}

/// Alphabetical listing for a single letter, pushed within the sidebar.
struct LetterListView: View {
    let letter: String
    @Binding var selection: Int64?
    @EnvironmentObject var store: LibraryStore

    var body: some View {
        List(store.articles(startingWith: letter), selection: $selection) { article in
            VStack(alignment: .leading, spacing: 2) {
                Text(article.title)
                if let volume = article.volume {
                    Text("Vol. \(volume)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tag(article.id)
        }
        .navigationTitle(letter)
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
