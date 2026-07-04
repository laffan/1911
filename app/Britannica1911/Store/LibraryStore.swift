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

    /// Recently submitted / used search queries (most recent first).
    @Published private(set) var recentSearches: [String] = []
    /// Bookmarked articles (most recently added first).
    @Published private(set) var bookmarks: [RecentArticle] = []

    let letters: [String]

    private let db: Database?
    private var cancellable: AnyCancellable?

    private let defaults = UserDefaults.standard
    private let maxRecents = 15
    private enum Keys {
        static let recentSearches = "recentSearches"
        static let bookmarks = "bookmarks"
    }

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

        recentSearches = defaults.stringArray(forKey: Keys.recentSearches) ?? []
        if let data = defaults.data(forKey: Keys.bookmarks),
           let saved = try? JSONDecoder().decode([RecentArticle].self, from: data) {
            bookmarks = saved
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

    func browseItems(startingWith letter: String) -> [ArticleListItem] {
        db?.browseItems(startingWith: letter) ?? []
    }

    func article(id: Int64) -> Article? { db?.article(id: id) }

    func article(slug: String) -> Article? { db?.article(slug: slug) }

    func crossReferences(for id: Int64) -> [CrossReference] {
        db?.crossReferences(for: id) ?? []
    }

    func articles(byAuthor id: Int64) -> [ArticleSummary] {
        db?.articles(byAuthor: id) ?? []
    }

    /// Resolve a cross-reference to a concrete article id, falling back to a
    /// slug lookup for references that were not resolvable at build time.
    func resolve(_ ref: CrossReference) -> Int64? {
        ref.toID ?? db?.article(slug: ref.toSlug)?.id
    }

    /// Resolve a previous/next neighbour to an article id, if it is in the corpus.
    func resolve(_ neighbor: Neighbor) -> Int64? {
        db?.article(slug: neighbor.slug)?.id
    }

    // MARK: - Random

    /// Pick a random article, returning its id to open.
    func pickRandom(excluding current: Int64?) -> Int64? {
        db?.randomArticle(excluding: current)?.id
    }

    // MARK: - Recent searches

    /// Record a query the user actually searched with (deduped, case-insensitive).
    func recordSearch(_ raw: String) {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return }
        var list = recentSearches.filter { $0.caseInsensitiveCompare(query) != .orderedSame }
        list.insert(query, at: 0)
        recentSearches = Array(list.prefix(maxRecents))
        defaults.set(recentSearches, forKey: Keys.recentSearches)
    }

    func clearRecentSearches() {
        recentSearches = []
        defaults.removeObject(forKey: Keys.recentSearches)
    }

    // MARK: - Bookmarks

    func isBookmarked(_ slug: String) -> Bool {
        bookmarks.contains { $0.slug == slug }
    }

    func toggleBookmark(slug: String, title: String) {
        if isBookmarked(slug) {
            removeBookmark(slug: slug)
        } else {
            bookmarks.insert(RecentArticle(slug: slug, title: title), at: 0)
            saveBookmarks()
        }
    }

    func removeBookmark(slug: String) {
        bookmarks.removeAll { $0.slug == slug }
        saveBookmarks()
    }

    private func saveBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            defaults.set(data, forKey: Keys.bookmarks)
        }
    }
}
