import Foundation
import CoreGraphics

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// One article set in the same sideways newspaper columns as the Browse pane.
///
/// Browse can never hold the corpus in memory, so it measures a whole letter
/// entry by entry and keeps nothing but line counts (`ColumnIndex`). A single
/// article is small enough to wrap outright, so this keeps the wrapped lines
/// and slices them straight onto the same line grid `ColumnStyle` defines:
///
/// * a **masthead** — headword, citation, byline — opens the first column and
///   is measured in whole line slots, exactly as a title is in Browse, so the
///   body picks up on the grid beneath it;
/// * the **body** flows on from column to column;
/// * a closing **"See also"** panel takes a column of its own when the entry
///   has cross references, rather than being squeezed into the text.
///
/// Building one wraps the article and renders each column's text, which is a
/// few milliseconds even for a very long entry — see `ArticleReaderModel`,
/// which is what decides when to pay for it.
struct ArticleColumnLayout {
    /// What one column of the article draws.
    struct Column: Identifiable {
        let index: Int
        /// The masthead opens the first column.
        let showsMasthead: Bool
        /// The slice of the article's wrapped lines this column carries.
        let lines: Range<Int>
        /// The closing "See also" panel, which carries no body text.
        let isCrossReferences: Bool
        var id: Int { index }
    }

    /// What this was measured for, so a re-configure can tell at a glance
    /// whether anything actually changed.
    let articleID: Int64
    let crossReferenceCount: Int

    let style: ColumnStyle
    let masthead: ArticleMasthead
    /// The article's body, wrapped to the column measure.
    let lines: [TextLine]
    let columns: [Column]
    /// Each column's body text exactly as it is drawn — and so exactly what
    /// Find searches (see `ArticleFind`).
    let columnTexts: [String]

    init(article: Article, style: ColumnStyle, crossReferenceCount: Int) {
        self.articleID = article.id
        self.crossReferenceCount = crossReferenceCount
        self.style = style
        let masthead = ArticleMasthead(article: article, style: style)
        self.masthead = masthead

        let body = ArticleText.stripHeadword(article.body, title: article.title)
        let lines = style.lines(forBody: body)
        self.lines = lines

        var columns: [Column] = []
        var cursor = 0
        // `repeat` rather than `while`: an entry with no body still has a
        // first column to put its masthead in.
        repeat {
            let isFirst = columns.isEmpty
            let capacity = max(1, style.linesPerColumn - (isFirst ? masthead.slots : 0))
            let end = min(cursor + capacity, lines.count)
            columns.append(Column(index: columns.count,
                                  showsMasthead: isFirst,
                                  lines: cursor..<end,
                                  isCrossReferences: false))
            cursor = end
        } while cursor < lines.count

        if crossReferenceCount > 0 {
            columns.append(Column(index: columns.count,
                                  showsMasthead: false,
                                  lines: cursor..<cursor,
                                  isCrossReferences: true))
        }
        self.columns = columns
        self.columnTexts = columns.map { column in
            column.lines.isEmpty ? "" : TextColumnizer.render(lines[column.lines])
        }
    }

    /// Width of the whole run of columns. Narrower than the pane means the
    /// entry is short enough to be read without scrolling — the reader centres
    /// it rather than leaving it hard against the leading edge.
    var contentWidth: CGFloat { CGFloat(columns.count) * style.columnWidth }

    // MARK: - Text shared by the measurement and the drawing

    /// The provenance line under the headword.
    static func citation(for article: Article) -> String {
        var parts = ["Encyclopædia Britannica, 11th ed."]
        if let volume = article.volume { parts.append("Vol. \(volume)") }
        if let pages = article.pages { parts.append("p. \(pages)") }
        return parts.joined(separator: " · ")
    }

    /// One contributor as the byline sets them: name, then their EB1911
    /// signature initials.
    static func bylineLabel(_ author: ArticleAuthor) -> String {
        guard let initials = author.initials, !initials.isEmpty else { return author.name }
        return "\(author.name) \(initials)"
    }

    /// The byline as a run of separately measurable pieces, in drawing order.
    static func bylinePieces(for article: Article) -> [String] {
        guard !article.authors.isEmpty else { return [] }
        return ["By"] + article.authors.map(bylineLabel)
    }
}

// MARK: - The masthead

/// The head of an article's first column — headword, citation, byline —
/// measured in whole line slots.
///
/// Everything in a column sits on one grid of body lines; a block that took
/// some other height would knock the text below it off that grid. So the
/// masthead is measured here, reserved as a whole number of slots, and drawn
/// into exactly that height (clipped, on the rare over-long headword).
struct ArticleMasthead {
    /// The headword is set larger than a Browse column's title: this is the
    /// entry's own page rather than one of fifty in a stream.
    private static let headwordScale: CGFloat = 1.6
    private static let maxHeadwordLines = 5
    private static let maxCitationLines = 2
    private static let maxBylineRows = 2
    /// Gap between byline pieces; the `FlowLayout` that draws them uses the
    /// same figure, so the rows counted here are the rows drawn.
    static let bylineSpacing: CGFloat = 6

    let headwordFontSize: CGFloat
    /// Size of the citation and byline — the two lines of interface text.
    let metaFontSize: CGFloat
    let spacing: CGFloat
    let headwordLines: Int
    let citationLines: Int
    let bylineRows: Int
    /// Height of the whole block, in slots of body text.
    let slots: Int

    init(article: Article, style: ColumnStyle) {
        headwordFontSize = max(style.titleFontSize, (style.bodyFontSize * Self.headwordScale).rounded())
        metaFontSize = max(10, (style.bodyFontSize * 0.7).rounded())
        spacing = (style.lineHeight * 0.35).rounded()

        let headwordFont = ReaderFont.serif(size: headwordFontSize, bold: true)
        let headwordLineHeight = ReaderFont.lineHeight(headwordFont).rounded(.up)
        let metaFont = PlatformFont.systemFont(ofSize: metaFontSize)
        let metaLineHeight = ReaderFont.lineHeight(metaFont).rounded(.up)

        // Measured against a width that already reserves room for the bookmark
        // badge, so keeping an entry never re-wraps its headword.
        let headwordWidth = max(24, style.textWidth - style.titleBadgeWidth)
        let counted = TextColumnizer.lineCount(article.title,
                                               width: headwordWidth,
                                               widths: GlyphWidths.table(size: headwordFontSize, bold: true),
                                               indent: 0)
        headwordLines = min(max(1, counted), Self.maxHeadwordLines)

        citationLines = Self.lineCount(ArticleColumnLayout.citation(for: article),
                                       font: metaFont,
                                       width: style.textWidth,
                                       limit: Self.maxCitationLines)
        bylineRows = Self.rowCount(ArticleColumnLayout.bylinePieces(for: article),
                                   font: metaFont,
                                   width: style.textWidth,
                                   spacing: Self.bylineSpacing,
                                   limit: Self.maxBylineRows)

        var height = CGFloat(headwordLines) * headwordLineHeight
        if citationLines > 0 { height += spacing + CGFloat(citationLines) * metaLineHeight }
        if bylineRows > 0 { height += spacing + CGFloat(bylineRows) * metaLineHeight }
        height += style.titleSpaceBelow

        // Never let the masthead take a whole column: the entry has to start
        // somewhere. An enormous headword is clipped rather than allowed to
        // push its own text off the page.
        slots = min(max(1, Int((height / style.lineHeight).rounded(.up))),
                    max(1, style.linesPerColumn - 1))
    }

    /// How many lines a run of interface text wraps to at this measure.
    /// Interface text is set in the system sans face, which the reader's glyph
    /// tables (serif only) cannot measure, so this asks the text engine — a
    /// couple of measurements per article, not per entry.
    private static func lineCount(_ text: String, font: PlatformFont,
                                  width: CGFloat, limit: Int) -> Int {
        guard !text.isEmpty, width > 0, limit > 0 else { return 0 }
        let lineHeight = ReaderFont.lineHeight(font)
        guard lineHeight > 0 else { return 1 }
        let bounds = NSAttributedString(string: text, attributes: [.font: font])
            .boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading],
                          context: nil)
        return min(max(1, Int((bounds.height / lineHeight).rounded())), limit)
    }

    /// How many rows a run of byline pieces needs, mirroring the greedy fill
    /// `FlowLayout` performs when it draws them.
    private static func rowCount(_ pieces: [String], font: PlatformFont,
                                 width: CGFloat, spacing: CGFloat, limit: Int) -> Int {
        guard !pieces.isEmpty, width > 0 else { return 0 }
        var rows = 1
        var x: CGFloat = 0
        for piece in pieces {
            let pieceWidth = NSAttributedString(string: piece, attributes: [.font: font]).size().width
            if x > 0, x + pieceWidth > width {
                rows += 1
                x = 0
            }
            x += pieceWidth + spacing
        }
        return min(rows, limit)
    }
}

// MARK: - Finding a phrase inside an article

/// One occurrence of the reader's query: which column it falls in, and where
/// in that column's text.
struct ArticleFindMatch {
    let column: Int
    /// A range in that column's rendered text, ready to hand to the text view.
    let range: NSRange
}

enum ArticleFind {
    /// Every occurrence of `query` in one column's rendered text.
    ///
    /// A column's text arrives already broken into lines, so a phrase the
    /// reader is looking for may be split by a newline — and a paragraph's
    /// first line opens with an em space. Both stand in for a space, so the
    /// search runs against a copy with those two characters replaced by one.
    /// That copy is the same length as the original (each is a single UTF-16
    /// unit), which is what keeps every range found valid in the text the view
    /// actually draws.
    ///
    /// A phrase broken across a *column* boundary is not found: its halves are
    /// in two different text views, the same limitation selection has.
    static func matches(of query: String, in text: String) -> [NSRange] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, !text.isEmpty else { return [] }

        let haystack = flattened(text) as NSString
        var found: [NSRange] = []
        var start = 0
        while start < haystack.length {
            let range = haystack.range(of: needle,
                                       options: [.caseInsensitive, .diacriticInsensitive],
                                       range: NSRange(location: start, length: haystack.length - start))
            guard range.location != NSNotFound else { break }
            found.append(range)
            start = range.location + max(1, range.length)
        }
        return found
    }

    /// Line breaks and paragraph indents read as ordinary spaces. Each is a
    /// single UTF-16 unit, as a space is, so the copy lines up with the
    /// original character for character.
    private static func flattened(_ text: String) -> String {
        var out = String()
        out.reserveCapacity(text.count)
        for character in text {
            if character == "\n" || character == TextColumnizer.indentCharacter {
                out.append(" ")
            } else {
                out.append(character)
            }
        }
        return out
    }
}
