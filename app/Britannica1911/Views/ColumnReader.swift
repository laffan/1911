import SwiftUI

/// The Browse reading surface: the whole letter set as a continuous run of
/// newspaper columns, each a third of the screen wide, scrolling sideways.
///
/// Only the handful of columns actually on screen are ever built — the
/// `LazyHStack` realizes visible children, and because every column is exactly
/// `columnWidth` wide the stack can place the other fifty thousand without
/// touching them. Pagination itself lives in `ColumnIndexStore`, which measures
/// the letter on a background queue and appends to the stream in order, so the
/// content under the reader's finger never shifts.
struct ColumnReader: View {
    @ObservedObject var columns: ColumnIndexStore

    let letter: String
    let entryCount: Int
    let fontSize: CGFloat
    /// Entry the reader should scroll to; cleared once it has been honoured.
    @Binding var jumpTarget: Int?
    /// Entry currently at the leading edge, reported back for the A–Z bars.
    @Binding var visibleEntry: Int
    let onOpen: (Int64) -> Void

    /// An entry asked for before the index had reached it. Retried as the
    /// build publishes more entries.
    @State var pendingJump: Int?

    private static let scrollSpace = "columnReaderScroll"

    var body: some View {
        GeometryReader { geo in
            let key = ColumnStyleKey(width: geo.size.width, height: geo.size.height, fontSize: fontSize)
            content()
                .onAppear { columns.configure(letter: letter, styleKey: key, expectedEntries: entryCount) }
                .onChange(of: key) { columns.configure(letter: letter, styleKey: $0, expectedEntries: entryCount) }
                .onChange(of: letter) { columns.configure(letter: $0, styleKey: key, expectedEntries: entryCount) }
        }
    }

    /// Drawn from the style the index was built with rather than the live
    /// geometry, so every column stays internally consistent while a resize
    /// settles and the letter is re-measured.
    @ViewBuilder
    private func content() -> some View {
        if let style = columns.style, !columns.index.isEmpty {
            stream(style: style)
        } else if columns.index.isComplete {
            ContentPlaceholder(
                icon: "text.book.closed",
                title: "Nothing under this letter",
                message: "Run the scraper to load the full encyclopaedia, or pick another letter."
            )
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func stream(style: ColumnStyle) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(alignment: .top, spacing: 0) {
                    ForEach(0..<columns.index.totalColumns, id: \.self) { column in
                        cell(column, style: style)
                            .id(column)
                    }
                }
                .background(
                    GeometryReader { metrics in
                        Color.clear.preference(
                            key: ColumnOffsetKey.self,
                            value: metrics.frame(in: .named(Self.scrollSpace)).minX
                        )
                    }
                )
            }
            .coordinateSpace(name: Self.scrollSpace)
            .onPreferenceChange(ColumnOffsetKey.self) { minX in
                trackScroll(minX: minX, style: style)
            }
            .onChange(of: jumpTarget) { target in
                guard let target else { return }
                pendingJump = target
                jumpTarget = nil
                honourPendingJump(proxy)
            }
            // The build appends entries in order; a jump past the indexed end
            // is honoured as soon as it arrives.
            .onChange(of: columns.index.entries.count) { _ in honourPendingJump(proxy) }
            .onAppear { restorePosition(proxy) }
            .overlay(alignment: .top) { buildProgress }
        }
    }

    @ViewBuilder
    private func cell(_ column: Int, style: ColumnStyle) -> some View {
        if let entryIndex = columns.index.entryIndex(forColumn: column) {
            let entry = columns.index.entries[entryIndex]
            ColumnCell(entry: entry,
                       columnInEntry: column - entry.columnStart,
                       style: style,
                       columns: columns,
                       onOpen: onOpen)
        } else {
            Color.clear.frame(width: style.columnWidth, height: style.columnHeight)
        }
    }

    /// A hairline while the letter is still being measured. Columns already
    /// published are fully readable meanwhile.
    @ViewBuilder
    private var buildProgress: some View {
        if columns.progress < 1 {
            ProgressView(value: columns.progress)
                .progressViewStyle(.linear)
                .frame(height: 2)
        }
    }

    // MARK: - Scroll position

    private func trackScroll(minX: CGFloat, style: ColumnStyle) {
        guard style.columnWidth > 0 else { return }
        let leadingColumn = Int(max(0, -minX) / style.columnWidth)
        guard let entryIndex = columns.index.entryIndex(forColumn: leadingColumn) else { return }
        guard entryIndex != visibleEntry else { return }
        visibleEntry = entryIndex
        columns.prefetch(entriesAround: entryIndex)
    }

    /// Coming back from a search (or any other time the stream is rebuilt),
    /// pick the reader up where they left off rather than at the letter's start.
    private func restorePosition(_ proxy: ScrollViewProxy) {
        if pendingJump == nil, visibleEntry > 0 { pendingJump = visibleEntry }
        honourPendingJump(proxy)
    }

    private func honourPendingJump(_ proxy: ScrollViewProxy) {
        guard let target = pendingJump else { return }
        guard let column = columns.index.columnStart(ofEntry: target) else { return }
        pendingJump = nil
        proxy.scrollTo(column, anchor: .leading)
        visibleEntry = target
        columns.prefetch(entriesAround: target)
    }
}

/// Leading edge of the column stream within the scroll view, i.e. the negated
/// scroll offset.
private struct ColumnOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - One column

/// A single column: an entry's title where the entry begins, then as much of
/// its text as the column holds, over a running footer.
///
/// Every measurement comes from `ColumnStyle`, and the header and text blocks
/// are given explicit heights, so what is drawn can never disagree with what
/// was paginated — the next column always resumes exactly where this one stops.
struct ColumnCell: View {
    let entry: EntryLayout
    let columnInEntry: Int
    let style: ColumnStyle
    /// Held as a plain reference, not observed: the cell only asks it for
    /// wrapped text, and re-rendering on every index update would be waste.
    let columns: ColumnIndexStore
    let onOpen: (Int64) -> Void

    @EnvironmentObject var store: LibraryStore

    private var isOpening: Bool { columnInEntry == 0 }

    private var headerHeight: CGFloat {
        isOpening ? style.headerHeight(titleLines: entry.titleLines) : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isOpening { header }
            bodyText
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, style.horizontalInset)
        .padding(.top, style.topInset)
        .padding(.bottom, style.bottomInset)
        .frame(width: style.columnWidth, height: style.columnHeight, alignment: .topLeading)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 0.5)
                .padding(.vertical, 8)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(entry.title)
                .font(.system(size: style.titleFontSize, weight: .bold, design: .serif))
                .lineLimit(style.maxTitleLines)
                .fixedSize(horizontal: false, vertical: true)
            if store.isBookmarked(entry.slug) {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: style.titleFontSize * 0.6))
                    .foregroundStyle(.red)
                    .accessibilityLabel("Bookmarked")
            }
        }
        .frame(width: style.textWidth, height: headerHeight, alignment: .topLeading)
        .clipped()
        .contentShape(Rectangle())
        // Double-click / double-tap keeps the entry; tapping once opens it in
        // the full reading view.
        .onTapGesture(count: 2) {
            store.toggleBookmark(slug: entry.slug, title: entry.title)
        }
        .onTapGesture { onOpen(entry.id) }
        .bookmarkable(slug: entry.slug, title: entry.title)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Body

    private var bodyText: some View {
        let lines = columns.lines(for: entry)
        let range = style.lineRange(for: entry, column: columnInEntry)
        let upper = min(range.upperBound, lines.count)
        let lower = min(range.lowerBound, upper)
        return Text(TextColumnizer.render(lines[lower..<upper]))
            .font(.system(size: style.bodyFontSize, design: .serif))
            .lineSpacing(style.lineSpacing)
            .frame(width: style.textWidth,
                   height: max(0, style.textHeight - headerHeight),
                   alignment: .topLeading)
            .clipped()
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: 0.5)
            Text(footerText)
                .font(.system(size: style.footerFontSize))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(width: style.textWidth, height: style.footerHeight, alignment: .bottomLeading)
    }

    /// The opening column carries the citation; continuations carry a running
    /// head, so it stays obvious what is being read during a fast scroll.
    private var footerText: String {
        if isOpening {
            var parts: [String] = []
            if let volume = entry.volume { parts.append("Vol. \(volume)") }
            if let pages = entry.pages { parts.append("p. \(pages)") }
            return parts.isEmpty ? "1911 Britannica" : parts.joined(separator: " · ")
        }
        return "\(entry.title.uppercased()) · \(columnInEntry + 1)"
    }
}
