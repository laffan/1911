import SwiftUI

/// A full article: title, byline, a Listen shortcut, a selectable body, and
/// cross-reference links.
///
/// Previous/next are handled as in-place *paging* rather than stack pushes: the
/// displayed article is swapped with a directional slide (next → right-to-left,
/// previous → left-to-right) and a horizontal swipe does the same. The
/// navigation stack is left untouched, so Back returns to the list the reader
/// came from. Cross-reference and author links still push as new screens.
struct ArticleView: View {
    let articleID: Int64
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var listen: ListenStore
    @EnvironmentObject var router: AppRouter

    @State private var currentID: Int64
    @State private var goingForward = true

    // Listen / notebook feedback
    @State private var isGenerating = false
    @State private var showNeedsKey = false
    @State private var errorMessage: String?
    @State private var addedTrack: AudioTrack?
    @State private var showNoteSaved = false

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    #endif

    /// Center the reading column and its title on iPad (regular width).
    private var isRegular: Bool {
        #if os(iOS)
        return hSizeClass == .regular
        #else
        return false
        #endif
    }

    init(articleID: Int64) {
        self.articleID = articleID
        _currentID = State(initialValue: articleID)
    }

    var body: some View {
        let article = store.article(id: currentID)
        return ZStack {
            if let article {
                articleScroll(article)
                    .id(currentID)
                    .transition(pagingTransition)
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
        // Prev/next stays pinned to the bottom; the article scrolls beneath it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let article { neighborBar(article) }
        }
        // Swipe left → next, swipe right → previous (simultaneous with scrolling).
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    let dx = value.translation.width, dy = value.translation.height
                    guard abs(dx) > 80, abs(dx) > abs(dy) * 2 else { return }
                    if dx < 0 { goNext() } else { goPrevious() }
                }
        )
        .overlay(alignment: .top) { noteSavedToast }
        .alert("OpenAI key needed", isPresented: $showNeedsKey) {
            Button("Open Settings") { router.selectedTab = .settings }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Add your OpenAI API key in Settings › Listen to create an audio version.")
        }
        .alert("Couldn’t create audio",
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Ready to Listen",
               isPresented: Binding(get: { addedTrack != nil },
                                    set: { if !$0 { addedTrack = nil } })) {
            Button("Play Now") {
                if let track = addedTrack {
                    router.selectedTab = .listen
                    listen.play(track)
                }
                addedTrack = nil
            }
            Button("Later", role: .cancel) { addedTrack = nil }
        } message: {
            Text("“\(addedTrack?.title ?? "This article")” was added to your Listen playlist.")
        }
    }

    private func articleScroll(_ article: Article) -> some View {
        let refs = store.crossReferences(for: article.id)
        let bodyText = article.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(article)

                listenButton(article)

                if !article.authors.isEmpty {
                    byline(article.authors)
                }

                bodyView(bodyText, article: article)

                if !refs.isEmpty {
                    crossReferenceSection(refs)
                }
            }
            .frame(maxWidth: LayoutMetrics.articleContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: isRegular ? .center : .leading)
            .padding(24)
        }
    }

    // MARK: - Body

    @ViewBuilder
    private func bodyView(_ text: String, article: Article) -> some View {
        #if os(iOS)
        SelectableArticleText(text: text, fontSize: settings.fontSize.pointSize) { selection in
            sendToNotebook(selection, article: article)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #else
        Text(text)
            .font(.system(size: settings.fontSize.pointSize, design: .serif))
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        #endif
    }

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

    // MARK: - Listen

    private func listenButton(_ article: Article) -> some View {
        Button {
            startListen(article)
        } label: {
            HStack(spacing: 6) {
                if isGenerating {
                    ProgressView().controlSize(.small)
                    Text("Preparing audio…")
                } else {
                    Image(systemName: "headphones")
                    Text("Listen")
                }
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .disabled(isGenerating)
        .frame(maxWidth: .infinity, alignment: isRegular ? .center : .leading)
    }

    private func startListen(_ article: Article) {
        guard settings.hasAPIKey else { showNeedsKey = true; return }
        isGenerating = true
        Task { @MainActor in
            do {
                let track = try await listen.generate(article: article,
                                                       apiKey: settings.apiKey,
                                                       voice: settings.voice)
                isGenerating = false
                addedTrack = track
            } catch {
                isGenerating = false
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Paging

    private var pagingTransition: AnyTransition {
        goingForward
            ? .asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading))
            : .asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .trailing))
    }

    private func goNext() {
        guard let next = store.article(id: currentID)?.next,
              let id = store.resolve(next) else { return }
        goingForward = true
        withAnimation(.easeInOut(duration: 0.28)) { currentID = id }
    }

    private func goPrevious() {
        guard let previous = store.article(id: currentID)?.previous,
              let id = store.resolve(previous) else { return }
        goingForward = false
        withAnimation(.easeInOut(duration: 0.28)) { currentID = id }
    }

    // MARK: - Header & byline

    private func header(_ article: Article) -> some View {
        VStack(alignment: isRegular ? .center : .leading, spacing: 6) {
            Text(article.title)
                .font(.system(.largeTitle, design: .serif).weight(.bold))
                .multilineTextAlignment(isRegular ? .center : .leading)
                .frame(maxWidth: .infinity, alignment: isRegular ? .center : .leading)
                .textSelection(.enabled)
                .bookmarkable(slug: article.slug, title: article.title)
            if let citation = citation(article) {
                Text(citation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: isRegular ? .center : .leading)
            }
        }
    }

    private func citation(_ article: Article) -> String? {
        var parts = ["Encyclopædia Britannica, 11th ed."]
        if let volume = article.volume { parts.append("Volume \(volume)") }
        if let pages = article.pages { parts.append("p. \(pages)") }
        return parts.count > 1 ? parts.joined(separator: " · ") : parts.first
    }

    /// Tappable contributor byline. Each author leads to their collected articles.
    private func byline(_ authors: [ArticleAuthor]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("By")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(authors) { author in
                    NavigationLink(value: AuthorRef(id: author.id, name: author.name)) {
                        HStack(spacing: 4) {
                            Text(author.name)
                            if let initials = author.initials {
                                Text(initials)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
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

    // MARK: - Cross references

    private func crossReferenceSection(_ refs: [CrossReference]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("See also")
                .font(.headline)
            FlowLayout(spacing: 8) {
                ForEach(refs) { ref in
                    crossReferenceChip(ref)
                }
            }
        }
    }

    @ViewBuilder
    private func crossReferenceChip(_ ref: CrossReference) -> some View {
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
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(resolved ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
            )
            .foregroundStyle(resolved ? Color.accentColor : Color.secondary)
    }
}
