import SwiftUI

/// Full-text search over the corpus, with an A–Z browse grid when the search
/// field is empty.
struct SearchTab: View {
    @EnvironmentObject var store: LibraryStore
    @State private var path = NavigationPath()

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: 4)

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.searchText.isEmpty {
                    browseGrid
                } else {
                    resultsList
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

    // A–Z as a grid of tappable letter icons (the icon is the letter).
    private var browseGrid: some View {
        ScrollView {
            if let error = store.loadError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding()
            }
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(store.letters, id: \.self) { letter in
                    NavigationLink(value: BrowseLetter(letter: letter)) {
                        letterIcon(letter)
                            .font(.system(size: 46))
                            .frame(maxWidth: .infinity, minHeight: 64)
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func letterIcon(_ letter: String) -> some View {
        let lower = letter.lowercased()
        if lower.count == 1, let c = lower.first, c.isLetter || c.isNumber {
            Image(systemName: "\(lower).square")
        } else {
            Image(systemName: "number.square")
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

/// A browse-index letter, used as a navigation value.
struct BrowseLetter: Hashable {
    let letter: String
}

/// Alphabetical listing for a single letter, showing a short preview of each
/// entry (headword removed) instead of a volume number.
struct LetterListView: View {
    let letter: String
    @EnvironmentObject var store: LibraryStore

    var body: some View {
        List(store.browseItems(startingWith: letter)) { item in
            NavigationLink(value: item.id) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.headline)
                    Text(item.preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.vertical, 2)
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
