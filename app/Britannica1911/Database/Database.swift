import Foundation
import SQLite3

/// Read-only access to the bundled `britannica.sqlite` (SQLite + FTS5).
///
/// Uses Apple's system SQLite via `import SQLite3` — no third-party
/// dependencies. The database ships as an app resource and is opened
/// read-only, so it is safe to query concurrently from the main actor.
final class Database {
    enum DBError: Error { case cannotOpen(String), notBundled }

    private let handle: OpaquePointer

    // SQLite wants to know whether a bound string is temporary. TRANSIENT tells
    // it to copy the bytes, which is always correct for Swift `String`s.
    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init() throws {
        guard let url = Bundle.main.url(forResource: "britannica", withExtension: "sqlite") else {
            throw DBError.notBundled
        }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw DBError.cannotOpen(msg)
        }
        handle = db
    }

    deinit { sqlite3_close_v2(handle) }

    // MARK: - Browse

    /// Distinct first letters that have at least one entry, for the A–Z index.
    func letters() -> [String] {
        query("SELECT DISTINCT first_letter FROM articles ORDER BY first_letter") { stmt in
            String(cString: sqlite3_column_text(stmt, 0))
        }
    }

    /// A uniformly-random entry, optionally excluding the one already open.
    func randomArticle(excluding excludedID: Int64?) -> ArticleSummary? {
        let sql = "SELECT id, slug, title, volume FROM articles"
            + (excludedID != nil ? " WHERE id != ?" : "")
            + " ORDER BY RANDOM() LIMIT 1"
        return query(sql, bind: excludedID.map { [.int($0)] } ?? []) { stmt in
            ArticleSummary(
                id: sqlite3_column_int64(stmt, 0),
                slug: String(cString: sqlite3_column_text(stmt, 1)),
                title: String(cString: sqlite3_column_text(stmt, 2)),
                volume: columnTextOrNil(stmt, 3)
            )
        }.first
    }

    func articles(startingWith letter: String) -> [ArticleSummary] {
        query(
            "SELECT id, slug, title, volume FROM articles WHERE first_letter = ? ORDER BY title COLLATE NOCASE",
            bind: [.text(letter)]
        ) { stmt in
            ArticleSummary(
                id: sqlite3_column_int64(stmt, 0),
                slug: String(cString: sqlite3_column_text(stmt, 1)),
                title: String(cString: sqlite3_column_text(stmt, 2)),
                volume: columnTextOrNil(stmt, 3)
            )
        }
    }

    // MARK: - Article lookup

    func article(id: Int64) -> Article? {
        articleRows("WHERE id = ?", bind: [.int(id)]).first
    }

    func article(slug: String) -> Article? {
        articleRows("WHERE slug = ?", bind: [.text(slug)]).first
    }

    func crossReferences(for id: Int64) -> [CrossReference] {
        query(
            "SELECT to_slug, to_title, to_id FROM cross_references WHERE from_id = ? ORDER BY to_title COLLATE NOCASE",
            bind: [.int(id)]
        ) { stmt in
            CrossReference(
                toSlug: String(cString: sqlite3_column_text(stmt, 0)),
                toTitle: String(cString: sqlite3_column_text(stmt, 1)),
                toID: sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 2)
            )
        }
    }

    // MARK: - Authors

    /// Contributors who signed a given article, in signing order.
    func authors(forArticle id: Int64) -> [ArticleAuthor] {
        query(
            """
            SELECT au.id, au.slug, au.name, aa.initials, au.wikisource_url
            FROM article_authors aa
            JOIN authors au ON au.id = aa.author_id
            WHERE aa.article_id = ?
            ORDER BY aa.seq
            """,
            bind: [.int(id)]
        ) { stmt in
            ArticleAuthor(
                id: sqlite3_column_int64(stmt, 0),
                slug: String(cString: sqlite3_column_text(stmt, 1)),
                name: String(cString: sqlite3_column_text(stmt, 2)),
                initials: columnTextOrNil(stmt, 3),
                wikisourceURL: columnTextOrNil(stmt, 4)
            )
        }
    }

    /// Every article signed by a contributor, for the browse-by-author view.
    func articles(byAuthor id: Int64) -> [ArticleSummary] {
        query(
            """
            SELECT a.id, a.slug, a.title, a.volume
            FROM article_authors aa
            JOIN articles a ON a.id = aa.article_id
            WHERE aa.author_id = ?
            ORDER BY a.title COLLATE NOCASE
            """,
            bind: [.int(id)]
        ) { stmt in
            ArticleSummary(
                id: sqlite3_column_int64(stmt, 0),
                slug: String(cString: sqlite3_column_text(stmt, 1)),
                title: String(cString: sqlite3_column_text(stmt, 2)),
                volume: columnTextOrNil(stmt, 3)
            )
        }
    }

    // MARK: - Search

    /// Full-text search ranked by bm25, with a highlighted snippet of the body.
    /// Author names are indexed too, so searching a contributor finds their work.
    func search(_ text: String, limit: Int = 100) -> [SearchResult] {
        guard let match = Self.ftsQuery(from: text) else { return [] }
        let sql = """
            SELECT a.id, a.slug, a.title,
                   snippet(articles_fts, 1, char(2), char(3), ' … ', 12) AS snip
            FROM articles_fts f
            JOIN articles a ON a.id = f.rowid
            WHERE articles_fts MATCH ?
            ORDER BY bm25(articles_fts, 5.0, 1.0, 3.0)
            LIMIT ?
            """
        return query(sql, bind: [.text(match), .int(Int64(limit))]) { stmt in
            SearchResult(
                id: sqlite3_column_int64(stmt, 0),
                slug: String(cString: sqlite3_column_text(stmt, 1)),
                title: String(cString: sqlite3_column_text(stmt, 2)),
                snippet: String(cString: sqlite3_column_text(stmt, 3))
            )
        }
    }

    /// Turn free user input into a safe FTS5 MATCH expression. Each word becomes
    /// a quoted prefix term so partial words match ("magnet" → "magnet"*), and
    /// double quotes are escaped so no input can break out of the string.
    static func ftsQuery(from text: String) -> String? {
        let tokens = text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }
            .joined(separator: " ")
    }

    // MARK: - Low-level helpers

    private func articleRows(_ whereClause: String, bind: [Value]) -> [Article] {
        query(
            """
            SELECT id, slug, title, volume, pages, body, source_url,
                   previous_slug, previous_title, next_slug, next_title
            FROM articles \(whereClause)
            """,
            bind: bind
        ) { stmt in
            let id = sqlite3_column_int64(stmt, 0)
            return Article(
                id: id,
                slug: String(cString: sqlite3_column_text(stmt, 1)),
                title: String(cString: sqlite3_column_text(stmt, 2)),
                volume: columnTextOrNil(stmt, 3),
                pages: columnTextOrNil(stmt, 4),
                body: String(cString: sqlite3_column_text(stmt, 5)),
                authors: authors(forArticle: id),
                previous: neighbor(columnTextOrNil(stmt, 7), columnTextOrNil(stmt, 8)),
                next: neighbor(columnTextOrNil(stmt, 9), columnTextOrNil(stmt, 10)),
                sourceURL: columnTextOrNil(stmt, 6)
            )
        }
    }

    private func neighbor(_ slug: String?, _ title: String?) -> Neighbor? {
        guard let slug, let title else { return nil }
        return Neighbor(slug: slug, title: title)
    }

    enum Value { case text(String), int(Int64) }

    private func query<T>(_ sql: String, bind: [Value] = [], row: (OpaquePointer) -> T) -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            assertionFailure("SQL prepare failed: \(String(cString: sqlite3_errmsg(handle)))")
            return []
        }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in bind.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, Self.SQLITE_TRANSIENT)
            case .int(let n): sqlite3_bind_int64(stmt, idx, n)
            }
        }
        var results: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(row(stmt!))
        }
        return results
    }

    private func columnTextOrNil(_ stmt: OpaquePointer, _ col: Int32) -> String? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL,
              let c = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: c)
    }
}
