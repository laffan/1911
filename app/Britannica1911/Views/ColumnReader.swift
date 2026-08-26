import SwiftUI

/// The Browse reading surface: the whole letter set as one continuous run of
/// newspaper columns, each a third of the screen wide, scrolling sideways.
/// Text flows from column to column and entry to entry without a break — a new
/// entry's title falls wherever the previous entry stopped.
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

    private func cell(_ column: Int, style: ColumnStyle) -> some View {
        ColumnCell(segments: columns.index.segments(forColumn: column),
                   style: style,
                   columns: columns,
                   onOpen: onOpen)
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
        guard style.columnWidth > 0, style.linesPerColumn > 0 else { return }
        let leadingColumn = Int(max(0, -minX) / style.columnWidth)
        let slot = leadingColumn * style.linesPerColumn
        guard let entryIndex = columns.index.entryIndex(atSlot: slot) else { return }
        guard entryIndex != visibleEntry else { return }
        visibleEntry = entryIndex
        columns.prefetch(fromEntry: entryIndex)
    }

    /// Coming back from a search (or any other time the stream is rebuilt),
    /// pick the reader up where they left off rather than at the letter's start.
    private func restorePosition(_ proxy: ScrollViewProxy) {
        if pendingJump == nil, visibleEntry > 0 { pendingJump = visibleEntry }
        honourPendingJump(proxy)
    }

    private func honourPendingJump(_ proxy: ScrollViewProxy) {
        guard let target = pendingJump else { return }
        guard let column = columns.index.column(ofEntry: target) else { return }
        pendingJump = nil
        proxy.scrollTo(column, anchor: .leading)
        visibleEntry = target
        columns.prefetch(fromEntry: target)
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

/// A single column of the stream: whatever falls inside its slice of the line
/// grid — the tail of the previous entry, whole short entries, a title, the
/// opening of the next.
///
/// Every block is framed at an exact multiple of the line height, so the grid
/// stays true down the column and the next column resumes precisely where this
/// one stops.
struct ColumnCell: View {
    let segments: [ColumnSegment]
    let style: ColumnStyle
    /// Held as a plain reference, not observed: the cell only asks it for
    /// wrapped text, and re-rendering on every index update would be waste.
    let columns: ColumnIndexStore
    let onOpen: (Int64) -> Void

    @EnvironmentObject var store: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(segments.indices, id: \.self) { index in
                segment(segments[index])
            }
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
                .padding(.vertical, style.topInset)
        }
    }

    @ViewBuilder
    private func segment(_ segment: ColumnSegment) -> some View {
        switch segment {
        case .gap(let slots):
            Color.clear
                .frame(width: style.textWidth, height: CGFloat(slots) * style.lineHeight)
        case .title(let entry, let atColumnTop):
            titleBlock(entry, atColumnTop: atColumnTop)
        case .body(let entry, let lines):
            bodyBlock(entry, lines: lines)
        }
    }

    // MARK: Title

    /// The entry's headword. When the title has been carried down to the top of
    /// a column there is no preceding text to separate it from, so the space
    /// above it is dropped — the block keeps its height either way, which is
    /// what holds the line grid together.
    private func titleBlock(_ entry: EntryLayout, atColumnTop: Bool) -> some View {
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
        .padding(.top, atColumnTop ? 0 : style.titleSpaceAbove)
        .frame(width: style.textWidth,
               height: CGFloat(entry.titleSlots) * style.lineHeight,
               alignment: .topLeading)
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

    private func bodyBlock(_ entry: EntryLayout, lines range: Range<Int>) -> some View {
        let wrapped = columns.lines(for: entry)
        let upper = min(range.upperBound, wrapped.count)
        let lower = min(range.lowerBound, upper)
        return Text(TextColumnizer.render(wrapped[lower..<upper]))
            .font(.system(size: style.bodyFontSize, design: .serif))
            .lineSpacing(style.lineSpacing)
            // Sized from the slots the block was given, not from the lines that
            // came back, so a short read can never shift what follows it.
            .frame(width: style.textWidth,
                   height: CGFloat(range.count) * style.lineHeight,
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

    /// A column that opens an entry carries its citation; one that carries text
    /// over from an earlier column gets a running head instead, so it stays
    /// obvious what is being read during a fast scroll.
    private var footerText: String {
        for segment in segments {
            switch segment {
            case .gap:
                continue
            case .title(let entry, _):
                var parts: [String] = []
                if let volume = entry.volume { parts.append("Vol. \(volume)") }
                if let pages = entry.pages { parts.append("p. \(pages)") }
                return parts.isEmpty ? "1911 Britannica" : parts.joined(separator: " · ")
            case .body(let entry, _):
                return entry.title.uppercased()
            }
        }
        return ""
    }
}
