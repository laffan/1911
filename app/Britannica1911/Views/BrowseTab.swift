import SwiftUI

/// The unified Browse pane: a search field with a Random shortcut at the top,
/// then either full-text results (while searching) or the A–Z reading index
/// (when the field is clear).
struct BrowseTab: View {
    @EnvironmentObject var store: LibraryStore
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    #endif
    @State private var path = NavigationPath()
    @State private var selectedLetter = "A"
    @State private var groups: [BrowseGroup] = []
    @State private var activeGroup: String?

    private let coordSpace = "browseScroll"

    private var isSearching: Bool {
        !store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// On iPad (regular width) constrain the browse list to a reading column;
    /// on iPhone / macOS it fills the available width.
    private var isRegularWidth: Bool {
        #if os(iOS)
        return hSizeClass == .regular
        #else
        return false
        #endif
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                SearchField(text: $store.searchText,
                            onRandom: openRandom,
                            onSubmit: { store.recordSearch(store.searchText) })
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                Divider()

                if isSearching {
                    searchResults
                } else {
                    browseIndex
                }
            }
            .navigationTitle("Browse")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .articleDestinations()
        }
        .onAppear {
            if groups.isEmpty {
                if !store.letters.contains(selectedLetter) {
                    selectedLetter = store.letters.first ?? "A"
                }
                reload()
            }
        }
    }

    // MARK: - Random

    private func openRandom() {
        guard let id = store.pickRandom(excluding: nil) else { return }
        if let article = store.article(id: id) {
            store.recordRandom(slug: article.slug, title: article.title)
        }
        path.append(id)
    }

    // MARK: - Search results

    @ViewBuilder
    private var searchResults: some View {
        if let error = store.loadError {
            List { Text(error).font(.footnote).foregroundStyle(.red) }
        } else {
            List {
                Section(resultsHeader) {
                    if store.results.isEmpty {
                        Text("No matching articles")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.results) { result in
                            Button {
                                store.recordSearch(store.searchText)
                                path.append(result.id)
                            } label: {
                                SearchResultRow(result: result)
                            }
                            .buttonStyle(.plain)
                            .bookmarkable(slug: result.slug, title: result.title)
                        }
                    }
                }
            }
        }
    }

    private var resultsHeader: String {
        switch store.results.count {
        case 0: return "Results"
        case 1: return "1 result"
        default: return "\(store.results.count) results"
        }
    }

    // MARK: - Browse index (A–Z)

    private var browseIndex: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                entryList
                subSectionBar(proxy)
                alphabetRail
            }
            // On iPad, keep the reading column the same width as an article and
            // centered, rather than stretched across the whole window.
            .frame(maxWidth: isRegularWidth ? LayoutMetrics.articleContentWidth + 72 : .infinity)
            .frame(maxWidth: .infinity, alignment: .center)
            .onChange(of: selectedLetter) { _ in
                reload()
                scrollToTop(proxy)
            }
        }
    }

    private var entryList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groups) { group in
                    groupAnchor(group.key)
                    ForEach(group.items) { item in
                        NavigationLink(value: item.id) {
                            EntryRow(title: item.title, subtitle: item.preview)
                                .padding(.vertical, 10)   // more air, no separators
                        }
                        .buttonStyle(.plain)
                        .bookmarkable(slug: item.slug, title: item.title)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 4)
        }
        .coordinateSpace(name: coordSpace)
        .onPreferenceChange(GroupOffsetKey.self) { updateActiveGroup($0) }
    }

    private func groupAnchor(_ key: String) -> some View {
        Color.clear
            .frame(height: 0)
            .id(key)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: GroupOffsetKey.self,
                        value: [key: geo.frame(in: .named(coordSpace)).minY]
                    )
                }
            )
    }

    // MARK: - Sub-section scrubber (Aa, Ab, …)

    private func subSectionBar(_ proxy: ScrollViewProxy) -> some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                ForEach(groups) { group in
                    Text(group.key)
                        .font(.caption2)
                        .fontWeight(group.key == activeGroup ? .bold : .regular)
                        .foregroundStyle(group.key == activeGroup ? Color.accentColor : .secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in jump(to: value.location.y, in: geo.size.height, proxy: proxy) }
            )
        }
        .frame(width: 40)
        .padding(.vertical, 8)
    }

    private func jump(to y: CGFloat, in height: CGFloat, proxy: ScrollViewProxy) {
        guard !groups.isEmpty, height > 0 else { return }
        let fraction = min(max(y / height, 0), 0.999)
        let index = min(Int(fraction * CGFloat(groups.count)), groups.count - 1)
        let key = groups[index].key
        if key != activeGroup {
            activeGroup = key
            proxy.scrollTo(key, anchor: .top)
        }
    }

    // MARK: - A–Z rail

    private var alphabetRail: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                ForEach(store.letters, id: \.self) { letter in
                    Text(letter)
                        .font(.caption)
                        .fontWeight(letter == selectedLetter ? .bold : .regular)
                        .foregroundStyle(letter == selectedLetter ? Color.accentColor : .secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in selectLetter(at: value.location.y, in: geo.size.height) }
            )
        }
        .frame(width: 24)
        .padding(.trailing, 4)
        .padding(.vertical, 8)
    }

    private func selectLetter(at y: CGFloat, in height: CGFloat) {
        let letters = store.letters
        guard !letters.isEmpty, height > 0 else { return }
        let fraction = min(max(y / height, 0), 0.999)
        let index = min(Int(fraction * CGFloat(letters.count)), letters.count - 1)
        let letter = letters[index]
        if letter != selectedLetter { selectedLetter = letter }
    }

    // MARK: - Data

    private func reload() {
        groups = Self.group(store.browseItems(startingWith: selectedLetter), fallback: selectedLetter)
        activeGroup = groups.first?.key
    }

    private func scrollToTop(_ proxy: ScrollViewProxy) {
        guard let first = groups.first?.key else { return }
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(first, anchor: .top) }
        }
    }

    private func updateActiveGroup(_ offsets: [String: CGFloat]) {
        // The active sub-section is the last one whose anchor has scrolled to
        // (or above) the top; before any has, it's the first.
        let passed = offsets.filter { $0.value <= 8 }
        let key = passed.max(by: { $0.value < $1.value })?.key
            ?? offsets.min(by: { $0.value < $1.value })?.key
        if let key, key != activeGroup { activeGroup = key }
    }

    /// Group consecutive (already title-sorted) entries by their first two
    /// letters, e.g. "Aa", "Ab", "Ac".
    static func group(_ items: [ArticleListItem], fallback: String) -> [BrowseGroup] {
        var result: [BrowseGroup] = []
        for item in items {
            let key = groupKey(item.title, fallback: fallback)
            if let last = result.last, last.key == key {
                result[result.count - 1] = BrowseGroup(key: key, items: last.items + [item])
            } else {
                result.append(BrowseGroup(key: key, items: [item]))
            }
        }
        return result
    }

    static func groupKey(_ title: String, fallback: String) -> String {
        let letters = title.filter { $0.isLetter }
        guard let first = letters.first else { return fallback.uppercased() }
        if let second = letters.dropFirst().first {
            return String(first).uppercased() + String(second).lowercased()
        }
        return String(first).uppercased()
    }
}

/// A rounded search field paired with a Random-article shortcut, sitting at the
/// top of the Browse pane.
struct SearchField: View {
    @Binding var text: String
    var onRandom: () -> Void
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search 1911 Britannica", text: $text)
                    .textFieldStyle(.plain)
                    .submitLabel(.search)
                    .onSubmit(onSubmit)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.12)))

            Button(action: onRandom) {
                Image(systemName: "die.face.5")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .help("Open a random article")
        }
    }
}

struct BrowseGroup: Identifiable, Hashable {
    let key: String
    let items: [ArticleListItem]
    var id: String { key }
}

/// Reports each sub-section anchor's vertical offset within the scroll view.
private struct GroupOffsetKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}
