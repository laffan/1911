import Foundation

/// A lightweight row used in browse lists and search results.
struct ArticleSummary: Identifiable, Hashable {
    let id: Int64
    let slug: String
    let title: String
    let volume: String?
}

/// A full encyclopedia entry.
struct Article: Identifiable, Hashable {
    let id: Int64
    let slug: String
    let title: String
    let volume: String?
    let body: String
    let sourceURL: String?
}

/// A "See also" link from one entry to another. `toID` is present when the
/// target exists in the corpus; dangling references remain browsable by title.
struct CrossReference: Identifiable, Hashable {
    let toSlug: String
    let toTitle: String
    let toID: Int64?
    var id: String { toSlug }
    var isResolved: Bool { toID != nil }
}

/// A search hit carrying an FTS5 snippet with the matched terms delimited.
struct SearchResult: Identifiable, Hashable {
    let id: Int64
    let slug: String
    let title: String
    let snippet: String
}
