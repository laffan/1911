import SwiftUI

/// Full-text search over the corpus, with an A–Z browse index when the search
/// field is empty.
struct SearchTab: View {
    @EnvironmentObject var store: LibraryStore
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let error = store.loadError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                if store.searchText.isEmpty {
                    Section("Browse A–Z") {
                        ForEach(store.letters, id: \.self) { letter in
                            NavigationLink(value: BrowseLetter(letter: letter)) {
                                Label(letter, systemImage: "\(letter.lowercased()).square")
                            }
                        }
                    }
                } else {
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
                            }
                        }
                    }
                }
            }
            .searchable(text: $store.searchText, prompt: "Search 1911 Britannica")
            .onSubmit(of: .search) { store.recordSearch(store.searchText) }
            .navigationDestination(for: BrowseLetter.self) { browse in
                LetterListView(letter: browse.letter)
            }
            .articleDestinations()
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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

/// A browse-index letter, used as a navigation value.
struct BrowseLetter: Hashable {
    let letter: String
}

/// Alphabetical listing for a single letter.
struct LetterListView: View {
    let letter: String
    @EnvironmentObject var store: LibraryStore

    var body: some View {
        List(store.articles(startingWith: letter)) { article in
            NavigationLink(value: article.id) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(article.title)
                    if let volume = article.volume {
                        Text("Vol. \(volume)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
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
