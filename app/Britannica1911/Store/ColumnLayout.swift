import Foundation
import CoreGraphics

#if canImport(UIKit)
import UIKit
typealias PlatformFont = UIFont
#elseif canImport(AppKit)
import AppKit
typealias PlatformFont = NSFont
#endif

// MARK: - Fonts

/// The serif faces used by the column reader.
///
/// These are the *same* fonts SwiftUI resolves for
/// `.system(size:weight:design: .serif)`, which is what the reader renders
/// with. Measuring with them therefore predicts what `Text` will actually
/// draw, so the line breaks computed here survive rendering.
enum ReaderFont {
    static func serif(size: CGFloat, bold: Bool = false) -> PlatformFont {
        #if canImport(UIKit)
        let base = UIFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return UIFont(descriptor: descriptor, size: size)
        #else
        let base = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        guard let descriptor = base.fontDescriptor.withDesign(.serif),
              let font = NSFont(descriptor: descriptor, size: size) else { return base }
        return font
        #endif
    }

    /// Distance between consecutive baselines, before `lineSpacing`.
    static func lineHeight(_ font: PlatformFont) -> CGFloat {
        #if canImport(UIKit)
        return font.lineHeight
        #else
        // AppKit has no `lineHeight`; `descender` is negative.
        return font.ascender - font.descender + font.leading
        #endif
    }
}

// MARK: - Glyph advance table

/// A precomputed table of character advance widths for one font.
///
/// Laying out thousands of pages with TextKit would be far too slow to do
/// while scrolling, so the reader wraps text itself with a greedy line breaker
/// driven by this table. Widths are measured once per font size (a few hundred
/// short layout calls, ~10 ms) and then wrapping costs one array lookup per
/// character — fast enough to paginate a whole letter of the encyclopaedia in
/// well under a second on a background queue.
///
/// The table deliberately errs *wide*: real rendering applies kerning and
/// ligatures, which only ever pull glyphs closer together, so a line that fits
/// by this measure always fits on screen.
struct GlyphWidths {
    /// U+0020…U+007E — ASCII, the overwhelming majority of the corpus.
    private let ascii: [CGFloat]
    /// U+00A0…U+017F — Latin-1 Supplement + Latin Extended-A (accented text).
    private let latin: [CGFloat]
    /// Punctuation, dashes, quotes and spaces (U+2000…U+205F).
    private let punctuation: [CGFloat]
    /// Greek, which EB1911 uses freely in etymologies (U+0386…U+03CE).
    private let greek: [CGFloat]
    /// Anything unmeasured (Cyrillic, CJK, symbols): one em, i.e. generous.
    private let fallback: CGFloat

    private static let asciiRange = 32...126
    private static let latinRange = 160...383
    private static let punctuationRange = 0x2000...0x205F
    private static let greekRange = 0x0386...0x03CE

    /// Measure a font's advances. Use `table(size:bold:)` instead — it caches,
    /// and this walks nearly five hundred glyphs.
    private init(font: PlatformFont) {
        ascii = Self.measure(Self.asciiRange, font: font)
        latin = Self.measure(Self.latinRange, font: font)
        punctuation = Self.measure(Self.punctuationRange, font: font)
        greek = Self.measure(Self.greekRange, font: font)
        fallback = font.pointSize
    }

    /// Width of a character, taken from its base scalar. Combining marks add
    /// no advance of their own, so ignoring them is both correct and cheap.
    func advance(_ character: Character) -> CGFloat {
        guard let scalar = character.unicodeScalars.first else { return 0 }
        let value = Int(scalar.value)
        if Self.asciiRange.contains(value) { return ascii[value - Self.asciiRange.lowerBound] }
        if Self.latinRange.contains(value) { return latin[value - Self.latinRange.lowerBound] }
        if Self.punctuationRange.contains(value) { return punctuation[value - Self.punctuationRange.lowerBound] }
        if Self.greekRange.contains(value) { return greek[value - Self.greekRange.lowerBound] }
        return fallback
    }

    private struct Key: Hashable {
        let size: CGFloat
        let bold: Bool
    }

    private static let cacheLock = NSLock()
    private static var cached: [Key: GlyphWidths] = [:]

    /// The advance table for one serif face and size.
    ///
    /// Widths depend only on the font, never on the column geometry, so a
    /// window resize or rotation reuses the table rather than paying for a
    /// thousand text measurements per frame. Call from the main thread: the
    /// measurements go through UIKit/AppKit.
    static func table(size: CGFloat, bold: Bool) -> GlyphWidths {
        let key = Key(size: size, bold: bold)
        cacheLock.lock()
        let hit = cached[key]
        cacheLock.unlock()
        if let hit { return hit }

        // Measured outside the lock: a duplicate on a race costs a little work
        // and produces the same table either way.
        let table = GlyphWidths(font: ReaderFont.serif(size: size, bold: bold))
        cacheLock.lock()
        cached[key] = table
        cacheLock.unlock()
        return table
    }

    private static func measure(_ range: ClosedRange<Int>, font: PlatformFont) -> [CGFloat] {
        var widths: [CGFloat] = []
        widths.reserveCapacity(range.count)
        for value in range {
            guard let scalar = Unicode.Scalar(UInt32(value)) else {
                widths.append(font.pointSize)
                continue
            }
            let string = NSAttributedString(string: String(scalar), attributes: [.font: font])
            widths.append(string.size().width)
        }
        return widths
    }
}

// MARK: - Line breaking

/// One wrapped line of body text. `indented` marks the opening line of a
/// paragraph, which is set with a leading em space rather than a blank line —
/// blank lines waste a lot of room in a narrow column.
struct TextLine {
    let text: Substring
    let indented: Bool
}

enum TextColumnizer {
    /// Em space, used as the paragraph indent. Its width is part of the
    /// measured table, so wrapping and rendering agree on it exactly.
    static let indentCharacter: Character = "\u{2003}"

    /// Greedily break `text` into lines no wider than `width`, calling `emit`
    /// once per line. Streaming through a closure means the index builder can
    /// count an article's lines without allocating any of them.
    static func wrap(_ text: String,
                     width: CGFloat,
                     widths: GlyphWidths,
                     indent: CGFloat,
                     emit: (Substring, Bool) -> Void) {
        guard width > 0 else { return }
        var isFirstParagraph = true
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // The opening paragraph sits directly under the entry title, so it
            // is set flush; the rest are indented.
            wrapParagraph(paragraph,
                          width: width,
                          widths: widths,
                          indent: isFirstParagraph ? 0 : indent,
                          emit: emit)
            isFirstParagraph = false
        }
    }

    /// Number of lines `text` occupies, without building them.
    static func lineCount(_ text: String, width: CGFloat, widths: GlyphWidths, indent: CGFloat) -> Int {
        var count = 0
        wrap(text, width: width, widths: widths, indent: indent) { _, _ in count += 1 }
        return count
    }

    /// All the lines of `text`, for rendering.
    static func lines(_ text: String, width: CGFloat, widths: GlyphWidths, indent: CGFloat) -> [TextLine] {
        var lines: [TextLine] = []
        lines.reserveCapacity(text.utf8.count / 48 + 4)
        wrap(text, width: width, widths: widths, indent: indent) { line, indented in
            lines.append(TextLine(text: line, indented: indented))
        }
        return lines
    }

    private static func wrapParagraph(_ paragraph: Substring,
                                      width: CGFloat,
                                      widths: GlyphWidths,
                                      indent: CGFloat,
                                      emit: (Substring, Bool) -> Void) {
        var lineStart = paragraph.startIndex
        var lastBreak: Substring.Index?
        var lineWidth = indent
        var widthSinceBreak: CGFloat = 0
        var isFirstLine = true
        var i = paragraph.startIndex

        while i < paragraph.endIndex {
            let character = paragraph[i]
            let advance = widths.advance(character)

            if character.isWhitespace {
                // A space may always end a line, and costs nothing when it does.
                lastBreak = i
                lineWidth += advance
                widthSinceBreak = 0
                i = paragraph.index(after: i)
                continue
            }

            if lineWidth + advance > width, i > lineStart {
                if let breakIndex = lastBreak, breakIndex > lineStart {
                    emit(paragraph[lineStart..<breakIndex], isFirstLine && indent > 0)
                    lineStart = paragraph.index(after: breakIndex)
                    lineWidth = widthSinceBreak      // the word carried down
                } else {
                    // A single word longer than the column: break it mid-word
                    // rather than letting it bleed into the gutter.
                    emit(paragraph[lineStart..<i], isFirstLine && indent > 0)
                    lineStart = i
                    lineWidth = 0
                }
                lastBreak = nil
                widthSinceBreak = 0
                isFirstLine = false
            }

            lineWidth += advance
            widthSinceBreak += advance
            i = paragraph.index(after: i)
        }

        if lineStart < paragraph.endIndex {
            emit(paragraph[lineStart...], isFirstLine && indent > 0)
        }
    }

    /// Join a run of wrapped lines back into the string one column renders.
    static func render(_ lines: ArraySlice<TextLine>) -> String {
        var out = ""
        out.reserveCapacity(lines.reduce(0) { $0 + $1.text.utf8.count + 2 })
        var first = true
        for line in lines {
            if !first { out.append("\n") }
            first = false
            if line.indented { out.append(indentCharacter) }
            out += line.text
        }
        return out
    }
}

// MARK: - Column geometry

/// How a column is proportioned for the pane it is being read in.
///
/// A third of an iPad is a newspaper column; a third of an iPhone is a ribbon
/// ~130pt across, which at reading size leaves four or five words to the line.
/// A compact pane therefore reads **four-fifths of the screen** at a time,
/// with tighter margins and slightly smaller type — the same page, set for a
/// smaller sheet.
enum ColumnMetrics: Equatable {
    /// iPad, Mac, and any regular-width window: three columns to a screen.
    case wide
    /// Compact-width iOS, i.e. the iPhone.
    case phone

    /// Fraction of the reader's width one column occupies.
    var columnFraction: CGFloat {
        switch self {
        case .wide:  return 1.0 / 3.0
        case .phone: return 4.0 / 5.0
        }
    }

    /// Ceiling on a column's width. Four-fifths of an iPhone *in landscape*
    /// would be 600pt+ of prose to a line, so the phone's slice stops growing
    /// there and simply yields more columns per screen instead.
    var maximumColumnWidth: CGFloat {
        switch self {
        case .wide:  return .greatestFiniteMagnitude
        case .phone: return 420
        }
    }

    /// Breathing room around a column's text on every side. The gutter between
    /// two columns therefore reads as twice this. A phone column cannot spare
    /// the tablet's margins and still hold a sensible measure.
    var padding: CGFloat {
        switch self {
        case .wide:  return 50
        case .phone: return 24
        }
    }

    /// Multiplier on the reader's chosen article text size. Phone columns are
    /// set a step smaller so a line still carries a phrase rather than a word
    /// or two; the single knob to turn if the phone type wants resizing.
    var fontScale: CGFloat {
        switch self {
        case .wide:  return 1
        case .phone: return 0.85
        }
    }
}

/// The inputs that determine every measurement below. When this changes
/// (rotation, window resize, a new article text size, moving between a compact
/// and a regular pane) the index is rebuilt.
struct ColumnStyleKey: Equatable {
    let width: CGFloat
    let height: CGFloat
    let fontSize: CGFloat
    var metrics: ColumnMetrics = .wide
}

/// Everything needed to paginate and draw one column: fonts, advance tables
/// and the exact number of lines a column holds.
///
/// Building one measures a few hundred glyphs, so it is created only when
/// `key` changes — never inside a view body.
struct ColumnStyle {
    /// Floors that keep the padding from swallowing a narrow column whole (a
    /// third of an iPhone in portrait is only ~130pt across).
    private static let minimumTextWidth: CGFloat = 96
    private static let minimumTextHeight: CGFloat = 140
    /// Trim a sliver of the column height before counting lines, so that any
    /// small disagreement between measured and rendered line heights can never
    /// push the last line out of view.
    private static let heightSafetyFactor: CGFloat = 0.985

    let key: ColumnStyleKey
    /// The proportions this style was built with (see `ColumnMetrics`).
    let metrics: ColumnMetrics
    let columnWidth: CGFloat
    let columnHeight: CGFloat
    let textWidth: CGFloat
    let textHeight: CGFloat
    let bodyFontSize: CGFloat
    let titleFontSize: CGFloat
    let footerFontSize: CGFloat
    let lineSpacing: CGFloat
    let lineHeight: CGFloat
    let titleLineHeight: CGFloat
    let linesPerColumn: Int
    let paragraphIndent: CGFloat
    let horizontalInset: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat
    let footerHeight: CGFloat
    /// Space set above an entry's title, separating it from the entry that ran
    /// into it. Suppressed when the title happens to land at a column's top.
    let titleSpaceAbove: CGFloat
    /// Space between an entry's title and its opening line.
    let titleSpaceBelow: CGFloat
    let maxTitleLines: Int
    /// Room kept beside a title for the bookmark badge, so a bookmarked entry
    /// never re-wraps its title into an extra line.
    let titleBadgeWidth: CGFloat

    let bodyWidths: GlyphWidths
    let titleWidths: GlyphWidths

    init(key: ColumnStyleKey) {
        self.key = key
        let metrics = key.metrics
        self.metrics = metrics

        maxTitleLines = 4
        titleBadgeWidth = 20
        lineSpacing = 3
        footerFontSize = 10
        footerHeight = 18

        columnWidth = max(80, min(key.width * metrics.columnFraction, metrics.maximumColumnWidth))
        columnHeight = max(80, key.height)

        horizontalInset = min(metrics.padding,
                              max(0, (columnWidth - Self.minimumTextWidth) / 2))
        let verticalInset = min(metrics.padding,
                                max(0, (columnHeight - footerHeight - Self.minimumTextHeight) / 2))
        topInset = verticalInset
        bottomInset = verticalInset

        textWidth = max(24, columnWidth - horizontalInset * 2)
        textHeight = max(lineSpacing, columnHeight - topInset - bottomInset - footerHeight)

        // The reader's chosen size, set for this page: full size on a tablet,
        // a step down on a phone.
        bodyFontSize = max(11, (key.fontSize * metrics.fontScale).rounded())
        titleFontSize = (bodyFontSize * 1.25).rounded()

        let bodyFont = ReaderFont.serif(size: bodyFontSize)
        let titleFont = ReaderFont.serif(size: titleFontSize, bold: true)
        lineHeight = ReaderFont.lineHeight(bodyFont).rounded(.up) + lineSpacing
        titleLineHeight = ReaderFont.lineHeight(titleFont).rounded(.up)

        bodyWidths = GlyphWidths.table(size: bodyFontSize, bold: false)
        titleWidths = GlyphWidths.table(size: titleFontSize, bold: true)
        paragraphIndent = bodyWidths.advance(TextColumnizer.indentCharacter)
        titleSpaceAbove = (lineHeight * 0.6).rounded()
        titleSpaceBelow = (lineHeight * 0.3).rounded()

        linesPerColumn = Self.lineCapacity(height: textHeight,
                                           lineHeight: lineHeight,
                                           lineSpacing: lineSpacing,
                                           minimum: 1)
    }

    private static func lineCapacity(height: CGFloat, lineHeight: CGFloat,
                                     lineSpacing: CGFloat, minimum: Int) -> Int {
        guard lineHeight > 0 else { return minimum }
        // N lines occupy N*lineHeight - lineSpacing (no spacing after the last).
        let usable = height * heightSafetyFactor + lineSpacing
        return max(minimum, Int((usable / lineHeight).rounded(.down)))
    }

    // MARK: Per-entry measurements

    /// How many lines an entry's title needs, measured against a width that
    /// already reserves room for the bookmark badge.
    func titleLines(_ title: String) -> Int {
        let width = max(24, textWidth - titleBadgeWidth)
        let count = TextColumnizer.lineCount(title, width: width, widths: titleWidths, indent: 0)
        return min(max(1, count), maxTitleLines)
    }

    /// How many line slots an entry's title block takes up.
    ///
    /// Titles are measured in whole lines of body text so that everything —
    /// headings included — sits on one grid, which is what lets an entry pick
    /// up exactly where the last one stopped.
    func titleSlots(titleLines: Int) -> Int {
        let height = titleSpaceAbove + CGFloat(titleLines) * titleLineHeight + titleSpaceBelow
        let slots = max(1, Int((height / lineHeight).rounded(.up)))
        // Never let a heading outgrow a column: on a short column with a long
        // headword it would otherwise spill past the bottom, and no amount of
        // carrying it down would help. Capped, it is clipped instead, and the
        // rule that a title always fits in what follows it stays true.
        return min(slots, max(1, linesPerColumn - 1))
    }

    func lines(forBody body: String) -> [TextLine] {
        TextColumnizer.lines(body, width: textWidth, widths: bodyWidths, indent: paragraphIndent)
    }

    func bodyLineCount(_ body: String) -> Int {
        TextColumnizer.lineCount(body, width: textWidth, widths: bodyWidths, indent: paragraphIndent)
    }
}

// MARK: - The index

/// One entry's place in the column stream. Just a handful of integers per
/// article, so a whole letter of the encyclopaedia costs a few hundred
/// kilobytes to index — the body text itself is read, measured and discarded.
///
/// Everything is expressed in *slots*: one slot is one line of body text, and
/// the letter is a single unbroken run of them, sliced into columns. An entry's
/// title takes a whole number of slots, and its body follows immediately, so
/// entries start wherever the previous one stopped rather than at a column top.
struct EntryLayout: Identifiable, Hashable {
    let id: Int64
    let slug: String
    let title: String
    let volume: String?
    let pages: String?
    let titleLines: Int
    let titleSlots: Int
    let bodyLines: Int
    /// First slot of this entry's title, assigned when it joins the index.
    var startSlot: Int = 0

    /// First slot of the entry's body, i.e. just past its title block.
    var bodyStartSlot: Int { startSlot + titleSlots }
    var endSlot: Int { startSlot + titleSlots + bodyLines }
}

/// What one column has to draw, top to bottom. A column may hold the tail of
/// one entry, then several whole short entries, then the opening of another.
enum ColumnSegment {
    /// Blank slots, left when a title was moved down to avoid splitting it.
    case gap(slots: Int)
    case title(EntryLayout, atColumnTop: Bool)
    case body(EntryLayout, lines: Range<Int>)
}

/// The paginated stream for one letter: entries in browse order, each knowing
/// which slot it starts on.
struct ColumnIndex {
    let letter: String
    let styleKey: ColumnStyleKey
    let linesPerColumn: Int
    private(set) var entries: [EntryLayout] = []
    private(set) var totalSlots: Int = 0
    var isComplete: Bool = false

    init(letter: String = "",
         styleKey: ColumnStyleKey = ColumnStyleKey(width: 0, height: 0, fontSize: 0),
         linesPerColumn: Int = 0) {
        self.letter = letter
        self.styleKey = styleKey
        self.linesPerColumn = linesPerColumn
    }

    var isEmpty: Bool { entries.isEmpty }

    var totalColumns: Int {
        guard linesPerColumn > 0 else { return 0 }
        return (totalSlots + linesPerColumn - 1) / linesPerColumn
    }

    /// Place a freshly measured batch at the end of the stream.
    ///
    /// The one thing that interrupts the flow: a title is never split across a
    /// column break, so an entry whose heading (plus its first line) would not
    /// fit in what's left of a column starts the next one instead, leaving the
    /// remaining slots blank. Positions, once assigned, never move.
    mutating func append(_ batch: [EntryLayout]) {
        guard linesPerColumn > 0 else { return }
        entries.reserveCapacity(entries.count + batch.count)
        for var entry in batch {
            let offset = totalSlots % linesPerColumn
            let remaining = linesPerColumn - offset
            let needed = entry.titleSlots + min(1, entry.bodyLines)
            if offset != 0, needed > remaining { totalSlots += remaining }
            entry.startSlot = totalSlots
            totalSlots = entry.endSlot
            entries.append(entry)
        }
    }

    /// The entry occupying `slot` — the one being read there.
    func entryIndex(atSlot slot: Int) -> Int? {
        guard !entries.isEmpty else { return nil }
        var low = 0
        var high = entries.count - 1
        var best: Int?
        while low <= high {
            let mid = (low + high) / 2
            if entries[mid].startSlot <= slot {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return best
    }

    /// The column an entry's title begins in.
    func column(ofEntry index: Int) -> Int? {
        guard linesPerColumn > 0, entries.indices.contains(index) else { return nil }
        return entries[index].startSlot / linesPerColumn
    }

    /// Everything that falls inside one column, in drawing order.
    func segments(forColumn column: Int) -> [ColumnSegment] {
        guard linesPerColumn > 0 else { return [] }
        let lower = column * linesPerColumn
        let upper = lower + linesPerColumn
        guard var i = firstEntry(endingAfter: lower) else { return [] }

        var segments: [ColumnSegment] = []
        var cursor = lower

        while i < entries.count, entries[i].startSlot < upper {
            let entry = entries[i]

            if entry.startSlot >= lower {
                if entry.startSlot > cursor {
                    segments.append(.gap(slots: entry.startSlot - cursor))
                }
                segments.append(.title(entry, atColumnTop: entry.startSlot == lower))
                cursor = min(entry.bodyStartSlot, upper)
            } else if entry.bodyStartSlot > lower {
                // A title taller than a whole column, spilling into this one.
                cursor = min(entry.bodyStartSlot, upper)
                segments.append(.gap(slots: cursor - lower))
            }

            let bodyStart = max(entry.bodyStartSlot, lower)
            let bodyEnd = min(entry.endSlot, upper)
            if bodyEnd > bodyStart {
                if bodyStart > cursor { segments.append(.gap(slots: bodyStart - cursor)) }
                segments.append(.body(entry,
                                      lines: (bodyStart - entry.bodyStartSlot)..<(bodyEnd - entry.bodyStartSlot)))
                cursor = bodyEnd
            }
            i += 1
        }
        return segments
    }

    /// Index of the first entry with anything left to draw at or after `slot`.
    private func firstEntry(endingAfter slot: Int) -> Int? {
        var low = 0
        var high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].endSlot > slot { high = mid } else { low = mid + 1 }
        }
        return low < entries.count ? low : nil
    }
}
