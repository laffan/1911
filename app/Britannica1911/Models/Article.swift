import Foundation

/// A lightweight row used in browse lists and search results.
struct ArticleSummary: Identifiable, Hashable {
    let id: Int64
    let slug: String
    let title: String
    let volume: String?
}

/// A contributor who signed an article, with their original EB1911 initials.
struct ArticleAuthor: Identifiable, Hashable {
    let id: Int64
    let slug: String
    let name: String
    let initials: String?
    let wikisourceURL: String?
}

/// A neighbouring entry in the encyclopedia's reading order (prev / next).
struct Neighbor: Hashable {
    let slug: String
    let title: String
}

/// A full encyclopedia entry.
struct Article: Identifiable, Hashable {
    let id: Int64
    let slug: String
    let title: String
    let volume: String?
    let pages: String?
    let body: String
    let authors: [ArticleAuthor]
    let previous: Neighbor?
    let next: Neighbor?
    let sourceURL: String?
}

/// A reference used to navigate to a contributor's collected articles.
struct AuthorRef: Hashable {
    let id: Int64
    let name: String
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
