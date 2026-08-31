import SwiftUI

/// The single-article reading surface: the entry set in the same sideways
/// newspaper columns the Browse pane uses — a third of the screen wide on an
/// iPad or a Mac, four-fifths of it on an iPhone (`ColumnMetrics`).
///
/// The difference from Browse is that an article is finite. Where the letter
/// stream is measured in the background and never ends, one entry is wrapped
/// outright (`ArticleColumnLayout`), so the run of columns has a known width —
/// and an entry that comes to one or two columns is **centred** in the pane
/// rather than left hard against its leading edge.
///
/// The first column opens with the masthead (headword, citation, byline); the
/// text flows on from there; cross references close the article in a panel of
/// their own.
struct ArticleColumnsView: View {
    let article: Article
    let crossReferences: [CrossReference]
    @ObservedObject var reader: ArticleReaderModel
    let onSendNote: (String) -> Void

    @EnvironmentObject var settings: SettingsStore

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    #endif

    /// A phone reads four-fifths of the screen at a time; everything wider
    /// keeps the three-column page. Part of the style key, so moving between
    /// the two (rotation, an iPad split view) re-measures the article.
    private var metrics: ColumnMetrics {
        #if os(iOS)
        return hSizeClass == .compact ? .phone : .wide
        #else
        return .wide
        #endif
    }

    var body: some View {
        GeometryReader { geo in
            let key = ColumnStyleKey(width: geo.size.width,
                                     height: geo.size.height,
                                     fontSize: settings.fontSize.pointSize,
                                     metrics: metrics)
            content(paneWidth: geo.size.width)
                // One view per entry (the caller keys it by article id), so
                // appearing is the whole of "a new article to measure";
                // afterwards only the geometry can change under it.
                .onAppear { configure(key) }
                .onChange(of: key) { configure($0) }
        }
    }

    private func configure(_ key: ColumnStyleKey) {
        reader.configure(article: article,
                         styleKey: key,
                         crossReferenceCount: crossReferences.count)
    }

    /// Drawn from the style the article was measured with rather than the live
    /// geometry, so the columns stay internally consistent while a resize
    /// settles.
    ///
    /// Paging to a neighbour swaps the article a moment before the reader has
    /// re-measured it, so the layout is only drawn once it is this entry's:
    /// one blank frame is better than one frame of the last entry's text under
    /// this entry's headword. Nothing is shown before the first measurement
    /// either — it takes a couple of milliseconds, where a spinner would only
    /// flicker.
    @ViewBuilder
    private func content(paneWidth: CGFloat) -> some View {
        if let layout = reader.layout, layout.articleID == article.id {
            stream(layout, paneWidth: paneWidth)
        } else {
            Color.clear
        }
    }

    private func stream(_ layout: ArticleColumnLayout, paneWidth: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(alignment: .top, spacing: 0) {
                    ForEach(layout.columns) { column in
                        cell(column, layout: layout)
                            .id(column.index)
                    }
                }
                // A short entry does not fill the pane, and one or two columns
                // jammed against the leading edge read as a mistake. The run
                // is measured (`contentWidth`) and offset by half of whatever
                // is left over, which centres it; an entry long enough to
                // scroll leaves nothing over and starts flush, as Browse does.
                .padding(.leading, max(0, (paneWidth - layout.contentWidth) / 2))
            }
            // Paging to a neighbour, and stepping through find matches, both
            // arrive here as a column to move to.
            .onChange(of: reader.scrollRequest) { request in
                guard let request else { return }
                if request.animated {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(request.column, anchor: .leading)
                    }
                } else {
                    proxy.scrollTo(request.column, anchor: .leading)
                }
            }
        }
    }

    private func cell(_ column: ArticleColumnLayout.Column, layout: ArticleColumnLayout) -> some View {
        ArticleColumnCell(column: column,
                          layout: layout,
                          article: article,
                          crossReferences: crossReferences,
                          isLast: column.index == layout.columns.count - 1,
                          highlights: reader.highlights(inColumn: column.index),
                          currentHighlight: reader.currentHighlight(inColumn: column.index),
                          onSendNote: onSendNote)
    }
}

// MARK: - One column of an article

/// A single column of an article: the masthead if it opens the entry, its
/// slice of the wrapped text, and a running foot.
///
/// Every block is framed at an exact multiple of the line height, exactly as
/// in the Browse columns, so the grid stays true down the column and the next
/// column resumes precisely where this one stops.
private struct ArticleColumnCell: View {
    let column: ArticleColumnLayout.Column
    let layout: ArticleColumnLayout
    let article: Article
    let crossReferences: [CrossReference]
    /// The rule between columns is dropped after the last one, where it would
    /// read as a margin rather than a gutter.
    let isLast: Bool
    let highlights: [NSRange]
    let currentHighlight: NSRange?
    let onSendNote: (String) -> Void

    @EnvironmentObject var store: LibraryStore

    private var style: ColumnStyle { layout.style }
    private var masthead: ArticleMasthead { layout.masthead }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if column.showsMasthead { mastheadBlock }
            if column.isCrossReferences {
                crossReferencePanel
            } else if !column.lines.isEmpty {
                bodyBlock
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, style.horizontalInset)
        .padding(.top, style.topInset)
        .padding(.bottom, style.bottomInset)
        .frame(width: style.columnWidth, height: style.columnHeight, alignment: .topLeading)
        .overlay(alignment: .trailing) {
            if !isLast {
                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 0.5)
                    .padding(.vertical, style.topInset)
            }
        }
    }

    // MARK: Masthead

    /// Headword, citation and byline, drawn into the whole number of line
    /// slots they were measured for (`ArticleMasthead`).
    private var mastheadBlock: some View {
        VStack(alignment: .leading, spacing: masthead.spacing) {
            headword
            if masthead.citationLines > 0 {
                Text(ArticleColumnLayout.citation(for: article))
                    .font(.system(size: masthead.metaFontSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(masthead.citationLines)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if masthead.bylineRows > 0 { byline }
        }
        .frame(width: style.textWidth,
               height: CGFloat(masthead.slots) * style.lineHeight,
               alignment: .topLeading)
        .clipped()
    }

    /// The headword takes the same keeping gesture as a Browse column's title:
    /// double-click to bookmark, with a red bookmark once it is kept.
    private var headword: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(article.title)
                .font(.system(size: masthead.headwordFontSize, weight: .bold, design: .serif))
                .lineLimit(masthead.headwordLines)
                .fixedSize(horizontal: false, vertical: true)
            if store.isBookmarked(article.slug) {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: masthead.headwordFontSize * 0.5))
                    .foregroundStyle(.red)
                    .accessibilityLabel("Bookmarked")
            }
        }
        .frame(width: style.textWidth, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            store.toggleBookmark(slug: article.slug, title: article.title)
        }
        .bookmarkable(slug: article.slug, title: article.title)
        .accessibilityAddTraits(.isHeader)
    }

    /// Tappable contributor byline. Each name leads to that author's collected
    /// articles. Set as plain text rather than the chips the vertical view
    /// used — a capsule is most of a column's measure on a phone.
    private var byline: some View {
        FlowLayout(spacing: ArticleMasthead.bylineSpacing) {
            Text("By")
                .font(.system(size: masthead.metaFontSize))
                .foregroundStyle(.secondary)
            ForEach(article.authors) { author in
                NavigationLink(value: AuthorRef(id: author.id, name: author.name)) {
                    Text(ArticleColumnLayout.bylineLabel(author))
                        .font(.system(size: masthead.metaFontSize, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: style.textWidth, alignment: .leading)
    }

    // MARK: Body

    /// The text itself, drawn by the platform text view so any passage can be
    /// selected and sent to the Notebook, and so a find can highlight inside
    /// it. It is handed lines already broken to this exact width, so it
    /// re-wraps nothing.
    private var bodyBlock: some View {
        SelectableArticleText(text: layout.columnTexts[column.index],
                              fontSize: style.bodyFontSize,
                              lineSpacing: style.lineSpacing,
                              highlights: highlights,
                              currentHighlight: currentHighlight,
                              onSendToNotebook: onSendNote)
            // Sized from the slots the block was given rather than the lines
            // that came back, so the grid holds whatever the text does.
            .frame(width: style.textWidth,
                   height: CGFloat(column.lines.count) * style.lineHeight,
                   alignment: .topLeading)
            .clipped()
    }

    // MARK: Cross references

    /// "See also" closes the article in a column of its own. It scrolls
    /// vertically on the rare entry with more references than a column holds.
    private var crossReferencePanel: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                Text("See also")
                    .font(.system(size: masthead.metaFontSize + 3, weight: .semibold))
                FlowLayout(spacing: 8) {
                    ForEach(crossReferences) { ref in
                        chip(ref)
                    }
                }
            }
            .frame(width: style.textWidth, alignment: .topLeading)
        }
        .frame(width: style.textWidth, height: style.textHeight, alignment: .topLeading)
    }

    @ViewBuilder
    private func chip(_ ref: CrossReference) -> some View {
        if let targetID = store.resolve(ref) {
            NavigationLink(value: targetID) {
                chipLabel(ref.toTitle, resolved: true)
            }
            .buttonStyle(.plain)
        } else {
            // Referenced entry is not in the corpus (e.g. not yet scraped).
            chipLabel(ref.toTitle, resolved: false)
        }
    }

    private func chipLabel(_ title: String, resolved: Bool) -> some View {
        Text(title)
            .font(.system(size: masthead.metaFontSize))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(resolved ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
            )
            .foregroundStyle(resolved ? Color.accentColor : Color.secondary)
    }

    // MARK: Footer

    /// A running head, and where in the entry this column falls — the reader's
    /// only sense of length once the article scrolls sideways.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: 0.5)
            HStack(spacing: 6) {
                Text(column.isCrossReferences ? "See also" : article.title.uppercased())
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text("\(column.index + 1) / \(layout.columns.count)")
                    .lineLimit(1)
                    .monospacedDigit()
            }
            .font(.system(size: style.footerFontSize))
            .foregroundStyle(.secondary)
        }
        .frame(width: style.textWidth, height: style.footerHeight, alignment: .bottomLeading)
    }
}
