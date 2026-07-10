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
    @State private var showNoteSaved = false
    @State private var activeAlert: ArticleAlert?

    /// A queued audio request awaiting the reader's cost confirmation.
    struct PendingGeneration {
        let article: Article
        let characters: Int
        let cost: Double
    }

    /// The single alert this screen can show at a time. (SwiftUI supports only
    /// one `.alert` per view reliably, so they're modeled as one enum.)
    enum ArticleAlert {
        case needsKey
        case error(String)
        case added(AudioTrack)
        case confirmCost(PendingGeneration)
    }

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
        .alert(alertTitle,
               isPresented: Binding(get: { activeAlert != nil },
                                    set: { if !$0 { activeAlert = nil } }),
               presenting: activeAlert) { alert in
            alertActions(alert)
        } message: { alert in
            alertMessage(alert)
        }
    }

    // MARK: - Alerts

    private var alertTitle: String {
        guard let activeAlert else { return "" }
        switch activeAlert {
        case .needsKey:     return "OpenAI key needed"
        case .error:        return "Couldn’t create audio"
        case .added:        return "Ready to Listen"
        case .confirmCost:  return "Generate audio?"
        }
    }

    @ViewBuilder
    private func alertActions(_ alert: ArticleAlert) -> some View {
        switch alert {
        case .needsKey:
            Button("Open Settings") { router.selectedTab = .settings }
            Button("Cancel", role: .cancel) {}
        case .error:
            Button("OK", role: .cancel) {}
        case .added(let track):
            Button("Play Now") {
                router.selectedTab = .listen
                listen.play(track)
            }
            Button("Later", role: .cancel) {}
        case .confirmCost(let pending):
            Button("Generate") { startListen(pending.article) }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func alertMessage(_ alert: ArticleAlert) -> some View {
        switch alert {
        case .needsKey:
            Text("Add your OpenAI API key in Settings › Listen to create an audio version.")
        case .error(let message):
            Text(message)
        case .added(let track):
            Text("“\(track.title)” was added to your Listen playlist.")
        case .confirmCost(let pending):
            Text("≈\(pending.characters) characters · estimated \(OpenAITTS.currencyString(pending.cost)) on OpenAI tts-1, billed to your OpenAI account.")
        }
    }

    private func articleScroll(_ article: Article) -> some View {
        let refs = store.crossReferences(for: article.id)
        let bodyText = article.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(article)

                listenSection(article)

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

    /// While this article is synthesizing, a progress view; once a recording
    /// exists, a mini-player; otherwise the "Listen" button (after cost confirm).
    @ViewBuilder
    private func listenSection(_ article: Article) -> some View {
        if let progress = listen.generation, progress.articleSlug == article.slug {
            ArticleListenProgress(progress: progress)
                .frame(maxWidth: .infinity, alignment: isRegular ? .center : .leading)
        } else if let track = listen.track(forArticle: article.slug) {
            ArticleListenPlayer(track: track)
                .frame(maxWidth: .infinity, alignment: isRegular ? .center : .leading)
        } else {
            listenButton(article)
        }
    }

    private func listenButton(_ article: Article) -> some View {
        Button {
            requestListen(article)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "headphones")
                Text("Listen")
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .disabled(listen.generation != nil)
        .frame(maxWidth: .infinity, alignment: isRegular ? .center : .leading)
    }

    /// Check for a key, then show the estimated cost before sending the request.
    private func requestListen(_ article: Article) {
        guard settings.hasAPIKey else { activeAlert = .needsKey; return }
        let characters = ListenStore.readableText(from: article).count
        activeAlert = .confirmCost(PendingGeneration(
            article: article,
            characters: characters,
            cost: OpenAITTS.estimatedCost(forCharacters: characters)
        ))
    }

    private func startListen(_ article: Article) {
        Task { @MainActor in
            do {
                let track = try await listen.generate(article: article,
                                                       apiKey: settings.apiKey,
                                                       voice: settings.voice)
                activeAlert = .added(track)
            } catch {
                activeAlert = .error(error.localizedDescription)
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

/// A compact inline player shown at the top of an article once a recording
/// exists for it: play/pause plus a progress bar that fills while it plays.
private struct ArticleListenPlayer: View {
    let track: AudioTrack
    @EnvironmentObject var listen: ListenStore

    private var isCurrent: Bool { listen.currentTrackID == track.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    if isCurrent { listen.togglePlayPause() } else { listen.play(track) }
                } label: {
                    Image(systemName: (isCurrent && listen.isPlaying) ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 34))
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Audio version")
                        .font(.subheadline.weight(.medium))
                    Text(statusText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.secondary)
                }
                Spacer()
            }
            ProgressView(value: fraction)
                .tint(Color.accentColor)
        }
        .foregroundStyle(Color.accentColor)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.12)))
    }

    private var fraction: Double {
        guard isCurrent, listen.duration > 0 else { return 0 }
        return min(listen.currentTime / listen.duration, 1)
    }

    private var statusText: String {
        if isCurrent {
            return "\(TimeFormat.string(from: listen.currentTime)) / \(TimeFormat.string(from: listen.duration))"
        }
        if let duration = track.duration {
            return "\(track.voice) · \(TimeFormat.string(from: duration))"
        }
        return track.voice
    }
}

/// Inline progress shown at the top of an article while its audio synthesizes.
private struct ArticleListenProgress: View {
    let progress: ListenStore.GenerationProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(statusText)
                    .font(.subheadline.weight(.medium))
                Spacer()
                if progress.total > 1 {
                    Text("\(Int(progress.fraction * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.secondary)
                }
            }
            ProgressView(value: progress.fraction)
                .tint(Color.accentColor)
        }
        .foregroundStyle(Color.accentColor)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.12)))
    }

    private var statusText: String {
        progress.total > 1
            ? "Generating audio… clip \(min(progress.completed + 1, progress.total)) of \(progress.total)"
            : "Generating audio…"
    }
}
