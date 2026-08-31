import SwiftUI

/// A full article: the entry set in the same sideways newspaper columns as the
/// Browse pane (`ArticleColumnsView`), with an in-article **Find** over the
/// top and previous/next pinned to the bottom.
///
/// Previous/next are handled as in-place *paging* rather than stack pushes:
/// the displayed article is swapped beneath the same screen and the reader is
/// returned to its first column, so Back still returns to the list they came
/// from. Cross-reference and author links push as new screens, as before.
///
/// The directional slide (and the swipe that went with it) are gone: the
/// reading surface itself now scrolls sideways, and a horizontal swipe belongs
/// to the columns.
struct ArticleView: View {
    let articleID: Int64
    @EnvironmentObject var store: LibraryStore

    /// Owns both the article's pagination and the find session, so the bar up
    /// here and the columns below it are always looking at the same state.
    @StateObject private var reader = ArticleReaderModel()

    @State private var currentID: Int64
    @State private var showNoteSaved = false
    @FocusState private var findFocused: Bool

    init(articleID: Int64) {
        self.articleID = articleID
        _currentID = State(initialValue: articleID)
    }

    var body: some View {
        let article = store.article(id: currentID)
        return Group {
            if let article {
                ArticleColumnsView(article: article,
                                   crossReferences: store.crossReferences(for: article.id),
                                   reader: reader,
                                   onSendNote: { sendToNotebook($0, article: article) })
            } else {
                Text("Article not found")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(article?.title ?? "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { findToolbarItem }
        .background { findKeyShortcut }
        // The find bar sits above the columns rather than over them: a column
        // is a full page of text, with nothing to spare under a floating bar.
        .safeAreaInset(edge: .top, spacing: 0) { findBar }
        // Prev/next stays pinned to the bottom; the columns run beneath it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let article { neighborBar(article) }
        }
        .overlay(alignment: .top) { noteSavedToast }
    }

    // MARK: - Notebook

    private func sendToNotebook(_ selection: String, article: Article) {
        store.addNote(text: selection, articleSlug: article.slug, articleTitle: article.title)
        withAnimation { showNoteSaved = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation { showNoteSaved = false }
        }
    }

    @ViewBuilder
    private var noteSavedToast: some View {
        if showNoteSaved {
            Label("Saved to Notebook", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Capsule().fill(.ultraThinMaterial))
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Find in article (⌘F)

    @ToolbarContentBuilder
    private var findToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(action: beginFind) {
                Label("Find in Article", systemImage: "magnifyingglass")
            }
            .help("Find in Article (⌘F)")
        }
    }

    /// ⌘F itself. The shortcut hangs off a button of its own rather than the
    /// toolbar's, so it is registered whether or not the platform is currently
    /// showing that toolbar.
    private var findKeyShortcut: some View {
        Button("Find in Article", action: beginFind)
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    /// The find bar: what to look for, how many matches there are, and the way
    /// between them. Stepping to a match scrolls its column into view and
    /// paints it (see `ArticleFind`).
    @ViewBuilder
    private var findBar: some View {
        if reader.isFinding {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Find in article", text: $reader.query)
                        .textFieldStyle(.plain)
                        .focused($findFocused)
                        .submitLabel(.search)
                        .onSubmit { reader.nextMatch() }
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    if let summary = reader.matchSummary {
                        Text(summary)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    findStep(systemImage: "chevron.up", label: "Previous match (⇧⌘G)",
                             action: reader.previousMatch)
                        .keyboardShortcut("g", modifiers: [.command, .shift])
                    findStep(systemImage: "chevron.down", label: "Next match (⌘G)",
                             action: reader.nextMatch)
                        .keyboardShortcut("g", modifiers: .command)
                    Button("Done", action: endFind)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                Divider()
            }
            .background(.bar)
        }
    }

    private func findStep(systemImage: String, label: String,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(.plain)
        .foregroundStyle(reader.matches.isEmpty ? Color.secondary : Color.accentColor)
        .disabled(reader.matches.isEmpty)
        .help(label)
        .accessibilityLabel(label)
    }

    private func beginFind() {
        reader.beginFind()
        // The field only exists once the bar is in the hierarchy.
        DispatchQueue.main.async { findFocused = true }
    }

    private func endFind() {
        findFocused = false
        reader.endFind()
    }

    // MARK: - Paging

    private func goNext() {
        guard let next = store.article(id: currentID)?.next,
              let id = store.resolve(next) else { return }
        currentID = id
    }

    private func goPrevious() {
        guard let previous = store.article(id: currentID)?.previous,
              let id = store.resolve(previous) else { return }
        currentID = id
    }

    // MARK: - Bottom prev/next bar

    @ViewBuilder
    private func neighborBar(_ article: Article) -> some View {
        if article.previous != nil || article.next != nil {
            VStack(spacing: 0) {
                Divider()
                HStack(alignment: .center) {
                    neighborButton(article.previous, systemImage: "chevron.left",
                                   trailing: false, action: goPrevious)
                    Spacer(minLength: 12)
                    neighborButton(article.next, systemImage: "chevron.right",
                                   trailing: true, action: goNext)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .background(.bar)
        }
    }

    @ViewBuilder
    private func neighborButton(_ neighbor: Neighbor?, systemImage: String,
                                trailing: Bool, action: @escaping () -> Void) -> some View {
        if let neighbor {
            let resolved = store.resolve(neighbor) != nil
            Button(action: action) {
                VStack(alignment: trailing ? .trailing : .leading, spacing: 2) {
                    Text(trailing ? "Next" : "Previous")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        if !trailing { Image(systemName: systemImage) }
                        Text(neighbor.title)
                            .lineLimit(1)
                            .multilineTextAlignment(trailing ? .trailing : .leading)
                        if trailing { Image(systemName: systemImage) }
                    }
                    .font(.callout)
                }
                .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
            }
            .buttonStyle(.plain)
            .disabled(!resolved)
            .foregroundStyle(resolved ? Color.accentColor : Color.secondary)
        }
    }
}
