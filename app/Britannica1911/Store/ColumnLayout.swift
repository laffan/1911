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

/// The inputs that determine every measurement below. When this changes
/// (rotation, window resize, a new article text size) the index is rebuilt.
struct ColumnStyleKey: Equatable {
    let width: CGFloat
    let height: CGFloat
    let fontSize: CGFloat
}

/// Everything needed to paginate and draw one column: fonts, advance tables
/// and the exact number of lines a column holds.
///
/// Building one measures a few hundred glyphs, so it is created only when
/// `key` changes — never inside a view body.
struct ColumnStyle {
    /// Columns visible at once: the redesign shows thirds of the screen.
    static let columnsPerScreen: CGFloat = 3
    /// Trim a sliver of the column height before counting lines, so that any
    /// small disagreement between measured and rendered line heights can never
    /// push the last line out of view.
    private static let heightSafetyFactor: CGFloat = 0.985

    let key: ColumnStyleKey
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
    let headerGap: CGFloat
    let maxTitleLines: Int
    /// Room kept beside a title for the bookmark badge, so a bookmarked entry
    /// never re-wraps its title into an extra line.
    let titleBadgeWidth: CGFloat

    let bodyWidths: GlyphWidths
    let titleWidths: GlyphWidths

    init(width: CGFloat, height: CGFloat, fontSize: CGFloat) {
        key = ColumnStyleKey(width: width, height: height, fontSize: fontSize)

        horizontalInset = 12
        topInset = 10
        bottomInset = 8
        headerGap = 10
        maxTitleLines = 4
        titleBadgeWidth = 20
        lineSpacing = 3
        footerFontSize = 10
        footerHeight = 18

        columnWidth = max(80, width / Self.columnsPerScreen)
        columnHeight = max(80, height)
        textWidth = max(24, columnWidth - horizontalInset * 2)
        textHeight = max(lineSpacing, columnHeight - topInset - bottomInset - footerHeight)

        bodyFontSize = fontSize
        titleFontSize = (fontSize * 1.25).rounded()

        let bodyFont = ReaderFont.serif(size: bodyFontSize)
        let titleFont = ReaderFont.serif(size: titleFontSize, bold: true)
        lineHeight = ReaderFont.lineHeight(bodyFont).rounded(.up) + lineSpacing
        titleLineHeight = ReaderFont.lineHeight(titleFont).rounded(.up)

        bodyWidths = GlyphWidths.table(size: bodyFontSize, bold: false)
        titleWidths = GlyphWidths.table(size: titleFontSize, bold: true)
        paragraphIndent = bodyWidths.advance(TextColumnizer.indentCharacter)

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

    func headerHeight(titleLines: Int) -> CGFloat {
        CGFloat(titleLines) * titleLineHeight + headerGap
    }

    /// Lines of body text that fit in an entry's opening column, under its title.
    func firstColumnLines(titleLines: Int) -> Int {
        let available = textHeight - headerHeight(titleLines: titleLines)
        guard available > 0 else { return 0 }
        return Self.lineCapacity(height: available,
                                 lineHeight: lineHeight,
                                 lineSpacing: lineSpacing,
                                 minimum: 0)
    }

    /// Columns an entry occupies: its opening column plus however many more
    /// the remaining lines need.
    func columnCount(bodyLines: Int, firstColumnLines: Int) -> Int {
        let remaining = max(0, bodyLines - firstColumnLines)
        guard remaining > 0 else { return 1 }
        return 1 + (remaining + linesPerColumn - 1) / linesPerColumn
    }

    /// Which of an entry's wrapped lines belong in one of its columns.
    func lineRange(for entry: EntryLayout, column: Int) -> Range<Int> {
        if column <= 0 {
            return 0..<min(entry.firstColumnLines, entry.bodyLines)
        }
        let start = entry.firstColumnLines + (column - 1) * linesPerColumn
        guard start < entry.bodyLines else { return 0..<0 }
        return start..<min(start + linesPerColumn, entry.bodyLines)
    }

    func lines(forBody body: String) -> [TextLine] {
        TextColumnizer.lines(body, width: textWidth, widths: bodyWidths, indent: paragraphIndent)
    }

    func bodyLineCount(_ body: String) -> Int {
        TextColumnizer.lineCount(body, width: textWidth, widths: bodyWidths, indent: paragraphIndent)
    }
}

// MARK: - The index

/// One entry's place in the column stream. Just 60-odd bytes per article, so a
/// whole letter of the encyclopaedia costs a few hundred kilobytes to index —
/// the body text itself is read, measured and thrown away.
struct EntryLayout: Identifiable, Hashable {
    let id: Int64
    let slug: String
    let title: String
    let volume: String?
    let pages: String?
    let titleLines: Int
    let bodyLines: Int
    let firstColumnLines: Int
    let columnCount: Int
    /// Index of this entry's first column within the letter.
    var columnStart: Int = 0

    var columnEnd: Int { columnStart + columnCount }
}

/// The paginated stream for one letter: entries in browse order, each knowing
/// where its columns begin.
struct ColumnIndex {
    let letter: String
    let styleKey: ColumnStyleKey
    private(set) var entries: [EntryLayout] = []
    private(set) var totalColumns: Int = 0
    var isComplete: Bool = false

    init(letter: String = "", styleKey: ColumnStyleKey = ColumnStyleKey(width: 0, height: 0, fontSize: 0)) {
        self.letter = letter
        self.styleKey = styleKey
    }

    var isEmpty: Bool { entries.isEmpty }

    mutating func append(_ batch: [EntryLayout]) {
        entries.reserveCapacity(entries.count + batch.count)
        for var entry in batch {
            entry.columnStart = totalColumns
            totalColumns += entry.columnCount
            entries.append(entry)
        }
    }

    /// The entry a global column belongs to, by binary search over the running
    /// column totals.
    func entryIndex(forColumn column: Int) -> Int? {
        guard column >= 0, column < totalColumns else { return nil }
        var low = 0
        var high = entries.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let entry = entries[mid]
            if column < entry.columnStart {
                high = mid - 1
            } else if column >= entry.columnEnd {
                low = mid + 1
            } else {
                return mid
            }
        }
        return nil
    }

    func columnStart(ofEntry index: Int) -> Int? {
        guard entries.indices.contains(index) else { return nil }
        return entries[index].columnStart
    }
}
