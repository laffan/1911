import Foundation
import Combine

/// State behind the single-article reader: the entry set in columns, and the
/// in-article **Find** session (⌘F).
///
/// Like `ColumnIndexStore` this is deliberately *not* a `@MainActor` class —
/// it schedules its own work on the main queue and is only ever touched from
/// there, by the views that own it.
final class ArticleReaderModel: ObservableObject {
    /// The article, paginated. `nil` until the reader has been given a
    /// geometry to measure against.
    @Published private(set) var layout: ArticleColumnLayout?

    /// Whether the find bar is up.
    @Published private(set) var isFinding = false
    /// What the reader is looking for.
    @Published var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            refreshMatches(keepingPosition: false)
        }
    }
    /// Every occurrence of `query`, in reading order.
    @Published private(set) var matches: [ArticleFindMatch] = []
    /// Which of them is selected, as an index into `matches`.
    @Published private(set) var currentMatch = 0
    /// Column the reader should be scrolled to; cleared once it is honoured.
    @Published var scrollTarget: Int?

    /// The same matches, keyed by column, so drawing one column costs a
    /// dictionary lookup rather than a walk of every match in the article.
    private var matchesByColumn: [Int: [NSRange]] = [:]

    private var pendingReconfigure: DispatchWorkItem?
    /// A window resize streams size changes frame by frame; wait for it to
    /// settle rather than re-wrapping the article on each one.
    private let resizeSettleDelay: TimeInterval = 0.25

    // MARK: - Pagination

    /// Point the reader at an article and a column geometry, re-measuring only
    /// when one of them actually changed.
    ///
    /// A new article is a direct request and is measured at once. A geometry
    /// change waits for the resize to settle, and until it does the columns
    /// already on screen stay readable.
    func configure(article: Article, styleKey: ColumnStyleKey, crossReferenceCount: Int) {
        guard styleKey.width > 0, styleKey.height > 0 else { return }
        if let layout, layout.articleID == article.id, layout.style.key == styleKey,
           layout.crossReferenceCount == crossReferenceCount {
            return
        }

        pendingReconfigure?.cancel()
        pendingReconfigure = nil

        guard let current = layout, current.articleID == article.id else {
            rebuild(article: article, styleKey: styleKey, crossReferenceCount: crossReferenceCount)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.rebuild(article: article, styleKey: styleKey, crossReferenceCount: crossReferenceCount)
        }
        pendingReconfigure = work
        DispatchQueue.main.asyncAfter(deadline: .now() + resizeSettleDelay, execute: work)
    }

    private func rebuild(article: Article, styleKey: ColumnStyleKey, crossReferenceCount: Int) {
        pendingReconfigure = nil
        let isNewArticle = layout?.articleID != article.id
        layout = ArticleColumnLayout(article: article,
                                     style: ColumnStyle(key: styleKey),
                                     crossReferenceCount: crossReferenceCount)
        if isNewArticle {
            // Paging to a neighbour is a fresh read: back to the masthead, and
            // the previous entry's find session does not follow it there.
            endFind()
            scrollTarget = 0
        } else {
            // Re-measured at a new size: the matches are in different places
            // now, but the reader is still looking at the same one.
            refreshMatches(keepingPosition: true)
        }
    }

    // MARK: - Find

    /// ⌘F — put the find bar up (or bring it back to the front).
    func beginFind() {
        isFinding = true
        refreshMatches(keepingPosition: false)
    }

    func endFind() {
        isFinding = false
        query = ""
        matches = []
        matchesByColumn = [:]
        currentMatch = 0
    }

    func nextMatch() { step(1) }
    func previousMatch() { step(-1) }

    /// "3 of 12" — or nothing at all while there is no query to report on.
    var matchSummary: String? {
        guard isFinding, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return matches.isEmpty ? "No matches" : "\(currentMatch + 1) of \(matches.count)"
    }

    /// Every match to highlight in one column.
    func highlights(inColumn column: Int) -> [NSRange] {
        matchesByColumn[column] ?? []
    }

    /// The selected match, when it happens to fall in this column.
    func currentHighlight(inColumn column: Int) -> NSRange? {
        guard matches.indices.contains(currentMatch) else { return nil }
        let match = matches[currentMatch]
        return match.column == column ? match.range : nil
    }

    /// Re-run the query over the whole article. Searching every column costs
    /// one pass over the entry's text, which is cheap enough to do on each
    /// keystroke — and it is what lets the bar report "n of m" honestly.
    private func refreshMatches(keepingPosition: Bool) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isFinding, !needle.isEmpty, let layout else {
            matchesByColumn = [:]
            matches = []
            currentMatch = 0
            return
        }

        var found: [ArticleFindMatch] = []
        var byColumn: [Int: [NSRange]] = [:]
        for (column, text) in layout.columnTexts.enumerated() where !text.isEmpty {
            let ranges = ArticleFind.matches(of: needle, in: text)
            guard !ranges.isEmpty else { continue }
            byColumn[column] = ranges
            found.append(contentsOf: ranges.map { ArticleFindMatch(column: column, range: $0) })
        }

        matchesByColumn = byColumn
        matches = found
        currentMatch = found.isEmpty ? 0 : min(keepingPosition ? currentMatch : 0, found.count - 1)
        scrollToCurrent()
    }

    private func step(_ delta: Int) {
        guard !matches.isEmpty else { return }
        currentMatch = (currentMatch + delta + matches.count) % matches.count
        scrollToCurrent()
    }

    private func scrollToCurrent() {
        guard matches.indices.contains(currentMatch) else { return }
        scrollTarget = matches[currentMatch].column
    }
}
