import Foundation
import Combine

/// App-wide state: owns the database and drives search.
///
/// Queries are cheap (read-only SQLite over a bundled file), so they run
/// synchronously on the main actor. Search input is debounced to avoid
/// re-querying on every keystroke.
@MainActor
final class LibraryStore: ObservableObject {
    @Published var searchText: String = ""
    @Published private(set) var results: [SearchResult] = []
    @Published private(set) var loadError: String?

    let letters: [String]

    private let db: Database?
    private var cancellable: AnyCancellable?

    init() {
        do {
            let database = try Database()
            self.db = database
            self.letters = database.letters()
        } catch {
            self.db = nil
            self.letters = []
            self.loadError = "Could not open the encyclopedia database: \(error)"
        }

        cancellable = $searchText
            .removeDuplicates()
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] text in self?.runSearch(text) }
    }

    private func runSearch(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let db, trimmed.count >= 2 else {
            results = []
            return
        }
        results = db.search(trimmed)
    }

    // MARK: - Lookups used by the views

    func articles(startingWith letter: String) -> [ArticleSummary] {
        db?.articles(startingWith: letter) ?? []
    }

    func article(id: Int64) -> Article? { db?.article(id: id) }

    func article(slug: String) -> Article? { db?.article(slug: slug) }

    func crossReferences(for id: Int64) -> [CrossReference] {
        db?.crossReferences(for: id) ?? []
    }

    /// Resolve a cross-reference to a concrete article id, falling back to a
    /// slug lookup for references that were not resolvable at build time.
    func resolve(_ ref: CrossReference) -> Int64? {
        ref.toID ?? db?.article(slug: ref.toSlug)?.id
    }
}
