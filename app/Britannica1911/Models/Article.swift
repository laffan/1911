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

/// One entry as the column indexer reads it: the metadata the reader shows
/// plus the body text it paginates.
struct ArticleTextRow {
    let id: Int64
    let slug: String
    let title: String
    let volume: String?
    let pages: String?
    let body: String
}

/// Text tidying shared by every reading surface.
enum ArticleText {
    /// Drop the leading headword (the title, printed in caps at the start of the
    /// body) so an entry set under its own display title does not repeat it.
    /// Falls back to the raw text if the opening does not match the title.
    ///
    /// Both the column indexer and the column renderer run their text through
    /// this, so the line counts they compute always agree.
    static func stripHeadword(_ body: String, title: String) -> String {
        let titleKey = title.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !titleKey.isEmpty else {
            return body.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var accumulated = ""
        var matchedEnd: String.Index?
        var i = body.startIndex
        var scanned = 0
        while i < body.endIndex, scanned < 80 {
            let ch = body[i]
            if ch.isLetter || ch.isNumber {
                accumulated.append(contentsOf: ch.lowercased())
            }
            i = body.index(after: i)
            scanned += 1
            if accumulated == titleKey { matchedEnd = i; break }
            if accumulated.count > titleKey.count { break }
        }

        guard let end = matchedEnd else {
            return body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var rest = String(body[end...])
        let trim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:.-–—"))
        while let scalar = rest.unicodeScalars.first, trim.contains(scalar) {
            rest.removeFirst()
        }
        return rest
    }
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

/// A remembered article in the "recent random" history. Keyed by `slug` so it
/// survives database rebuilds (where row ids may change).
struct RecentArticle: Codable, Identifiable, Hashable {
    let slug: String
    let title: String
    var id: String { slug }
}

/// A passage the reader saved from an article via "Send to Notebook". Keeps a
/// link back to the source article (by slug, which survives rebuilds).
struct Note: Codable, Identifiable, Hashable {
    let id: UUID
    let text: String
    let articleSlug: String
    let articleTitle: String
    let createdAt: Date

    init(id: UUID = UUID(), text: String, articleSlug: String, articleTitle: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.articleSlug = articleSlug
        self.articleTitle = articleTitle
        self.createdAt = createdAt
    }
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
