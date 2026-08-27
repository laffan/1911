import Foundation
import Combine

/// Paginates a letter of the encyclopaedia into columns, off the main thread,
/// and keeps the reader supplied with wrapped text while it scrolls.
///
/// ## Why this exists
///
/// The corpus runs to tens of thousands of pages. Laying all of it out is
/// impossible, but a horizontal reader still needs a *stable* answer to "how
/// wide is the whole letter, and which column am I looking at?" — otherwise
/// content shifts under the reader's finger whenever new text is measured.
///
/// The compromise here:
///
/// * **Measure once, cheaply.** Each entry is wrapped exactly once per letter
///   and geometry, on a background queue, and all that is kept is its line and
///   column count (a few dozen bytes). Column positions never move afterwards,
///   so scrolling never jumps.
/// * **Publish as it goes.** Entries are appended in browse order in small
///   batches, so the reader can start scrolling within a frame or two of
///   choosing a letter. Because entries only ever land *after* what is already
///   indexed, growth never disturbs the reader's position.
/// * **Draw from a cache.** Rendering a column needs that entry's wrapped
///   lines; they are recomputed on demand (a fraction of a millisecond for a
///   typical entry), kept in a small LRU, and prefetched a few entries ahead of
///   the viewport on a second background queue so a flick never waits on one.
///
/// This is deliberately *not* a `@MainActor` class: the build and prefetch
/// queues hand results back with `DispatchQueue.main.async`, which keeps
/// publishing order strictly FIFO — important, since a batch appended out of
/// order would corrupt the column arithmetic.
final class ColumnIndexStore: ObservableObject {
    /// The paginated letter. Grows as the build proceeds.
    @Published private(set) var index = ColumnIndex()
    /// Fonts and per-column geometry the index was built for.
    @Published private(set) var style: ColumnStyle?
    /// Fraction of the letter measured so far, 0…1.
    @Published private(set) var progress: Double = 1

    private var expectedEntries = 0
    private var token = BuildToken()
    private var pendingReconfigure: DispatchWorkItem?
    /// A resize streams size changes frame by frame; wait for it to settle
    /// rather than restarting the measurement pass on each one.
    private let resizeSettleDelay: TimeInterval = 0.25

    private let buildQueue = DispatchQueue(label: "britannica.columns.build", qos: .userInitiated)
    private let prefetchQueue = DispatchQueue(label: "britannica.columns.prefetch", qos: .utility)

    // The bundled database is opened with SQLITE_OPEN_NOMUTEX, so a connection
    // may only ever be touched by one thread. Each of the three readers here
    // therefore gets its own — they are read-only and cost next to nothing.
    private let buildDatabase = try? Database()
    private let prefetchDatabase = try? Database()
    private let renderDatabase = try? Database()

    private let cache = WrappedLineCache(lineBudget: 30_000)
    /// Entries whose lines are already queued for prefetch, so a burst of
    /// scroll events doesn't schedule the same work repeatedly.
    private var prefetching: Set<Int64> = []

    /// Entries are handed to the main thread in batches; small enough that the
    /// first columns appear immediately, large enough that a whole letter costs
    /// only a few dozen published updates.
    private let batchSize = 96
    private let batchInterval: TimeInterval = 0.1
    /// Ceiling on entries queued by one prefetch pass, so a run of very short
    /// entries cannot flood the queue.
    private let maxPrefetchPerPass = 48

    // MARK: - Configuration

    /// Point the index at a letter and a column geometry, rebuilding only when
    /// one of them actually changed.
    ///
    /// Choosing a letter rebuilds at once — it is a direct request. A geometry
    /// change waits for the resize to settle, and until it does the reader
    /// keeps scrolling the columns it already has.
    func configure(letter: String, styleKey: ColumnStyleKey, expectedEntries: Int) {
        guard styleKey.width > 0, styleKey.height > 0 else { return }
        if index.letter == letter, index.styleKey == styleKey, style != nil {
            // Same letter and geometry: the caller may simply have learned how
            // many entries there are, which only the progress bar cares about.
            if expectedEntries > 0 { self.expectedEntries = expectedEntries }
            return
        }

        pendingReconfigure?.cancel()
        pendingReconfigure = nil

        guard style != nil, index.letter == letter else {
            rebuild(letter: letter, styleKey: styleKey, expectedEntries: expectedEntries)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.rebuild(letter: letter, styleKey: styleKey, expectedEntries: expectedEntries)
        }
        pendingReconfigure = work
        DispatchQueue.main.asyncAfter(deadline: .now() + resizeSettleDelay, execute: work)
    }

    private func rebuild(letter: String, styleKey: ColumnStyleKey, expectedEntries: Int) {
        pendingReconfigure = nil
        token.cancel()
        token = BuildToken()
        cache.removeAll()
        prefetching.removeAll()

        let style = ColumnStyle(key: styleKey)
        self.style = style
        self.expectedEntries = max(expectedEntries, 1)
        index = ColumnIndex(letter: letter, styleKey: styleKey, linesPerColumn: style.linesPerColumn)
        // An empty letter has nothing to measure, so it is already "done".
        progress = expectedEntries == 0 ? 1 : 0

        build(letter: letter, style: style, token: token)
    }

    // MARK: - Building

    private func build(letter: String, style: ColumnStyle, token: BuildToken) {
        buildQueue.async { [weak self] in
            guard let self, let db = self.buildDatabase else { return }
            var batch: [EntryLayout] = []
            var lastFlush = Date()

            db.forEachEntry(startingWith: letter) { row in
                if token.isCancelled { return false }
                batch.append(Self.layout(for: row, style: style))
                if batch.count >= self.batchSize || Date().timeIntervalSince(lastFlush) >= self.batchInterval {
                    let flushed = batch
                    batch = []
                    lastFlush = Date()
                    DispatchQueue.main.async { self.append(flushed, complete: false, token: token) }
                }
                return true
            }

            let tail = batch
            DispatchQueue.main.async { self.append(tail, complete: !token.isCancelled, token: token) }
        }
    }

    /// Measure one entry. Runs on the build queue; touches nothing shared.
    private static func layout(for row: ArticleTextRow, style: ColumnStyle) -> EntryLayout {
        let body = ArticleText.stripHeadword(row.body, title: row.title)
        let titleLines = style.titleLines(row.title)
        return EntryLayout(
            id: row.id,
            slug: row.slug,
            title: row.title,
            volume: row.volume,
            pages: row.pages,
            titleLines: titleLines,
            titleSlots: style.titleSlots(titleLines: titleLines),
            bodyLines: style.bodyLineCount(body)
        )
    }

    private func append(_ batch: [EntryLayout], complete: Bool, token: BuildToken) {
        guard token === self.token, !token.isCancelled else { return }
        if !batch.isEmpty { index.append(batch) }
        if complete { index.isComplete = true }
        progress = complete ? 1 : min(1, Double(index.entries.count) / Double(expectedEntries))
    }

    // MARK: - Wrapped text for rendering

    /// The wrapped lines of an entry, from the cache when possible. On a miss
    /// the entry is wrapped synchronously — cheap for all but the very longest
    /// entries, and the prefetcher normally gets there first.
    func lines(for entry: EntryLayout) -> [TextLine] {
        if let cached = cache.lines(for: entry.id) { return cached }
        guard let style, let db = renderDatabase,
              let body = db.body(forArticle: entry.id) else { return [] }
        let lines = style.lines(forBody: ArticleText.stripHeadword(body, title: entry.title))
        cache.store(lines, for: entry.id)
        return lines
    }

    /// Warm the cache for what is about to scroll into view.
    ///
    /// Reach is measured in columns rather than entries: a column of short
    /// EB1911 entries can hold a dozen of them, so "the next three entries"
    /// would not even cover the screen.
    func prefetch(fromEntry entryIndex: Int, columnsAhead: Int = 4, entriesBehind: Int = 2) {
        guard let style, style.linesPerColumn > 0, !index.entries.isEmpty else { return }
        let lower = max(0, min(entryIndex - entriesBehind, index.entries.count - 1))
        let reach = index.entries[lower].startSlot + columnsAhead * style.linesPerColumn
        var scheduled = 0

        for i in lower..<index.entries.count {
            let entry = index.entries[i]
            if entry.startSlot > reach || scheduled >= maxPrefetchPerPass { break }
            scheduled += 1
            if cache.contains(entry.id) || prefetching.contains(entry.id) { continue }
            prefetching.insert(entry.id)
            prefetchQueue.async { [weak self] in
                guard let self else { return }
                // Clear the in-flight mark however this turns out, so a failed
                // read can be retried the next time the entry comes near.
                defer { DispatchQueue.main.async { self.prefetching.remove(entry.id) } }
                guard let db = self.prefetchDatabase,
                      let body = db.body(forArticle: entry.id) else { return }
                self.cache.store(style.lines(forBody: ArticleText.stripHeadword(body, title: entry.title)),
                                 for: entry.id)
            }
        }
    }
}

/// A cancellation flag shared between the main thread and a build queue.
final class BuildToken {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }
}

/// A small LRU of wrapped entries, shared by the render path (main thread) and
/// the prefetcher (background), so it takes a lock.
///
/// Each `TextLine` is a slice of the entry's body string, so an entry's text
/// stays alive exactly as long as its lines are cached — and no longer.
final class WrappedLineCache {
    private let lock = NSLock()
    private var storage: [Int64: [TextLine]] = [:]
    private var order: [Int64] = []
    private var cachedLines = 0
    /// Budgeted in wrapped lines rather than entries: one column may hold a
    /// dozen one-line entries or a slice of a single enormous one.
    private let lineBudget: Int

    init(lineBudget: Int) {
        self.lineBudget = max(1, lineBudget)
    }

    func lines(for id: Int64) -> [TextLine]? {
        lock.lock(); defer { lock.unlock() }
        guard let wrapped = storage[id] else { return nil }
        touch(id)
        return wrapped
    }

    func contains(_ id: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return storage[id] != nil
    }

    func store(_ wrapped: [TextLine], for id: Int64) {
        lock.lock(); defer { lock.unlock() }
        if let existing = storage[id] { cachedLines -= existing.count }
        storage[id] = wrapped
        cachedLines += wrapped.count
        touch(id)
        while cachedLines > lineBudget, order.count > 1, let oldest = order.first {
            order.removeFirst()
            cachedLines -= storage.removeValue(forKey: oldest)?.count ?? 0
        }
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
        order.removeAll()
        cachedLines = 0
    }

    /// Move `id` to the most-recently-used end. Caller holds the lock.
    private func touch(_ id: Int64) {
        if let existing = order.firstIndex(of: id) { order.remove(at: existing) }
        order.append(id)
    }
}
