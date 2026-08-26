import SwiftUI

/// The Browse pane.
///
/// Layout, top to bottom: a **search field** with the Random dice, the **A–Z
/// rail** and the **sub-section scrubber** (Aa, Ab, Ac …) as horizontal bars
/// beneath it, and then the reading surface — the whole letter set as columns
/// a third of a screen wide that scroll sideways (`ColumnReader`).
///
/// Typing swaps the columns for ranked full-text results; clearing the field
/// brings the reading columns back exactly where they were.
struct BrowseTab: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var router: AppRouter
    @StateObject private var columns = ColumnIndexStore()

    @State private var path = NavigationPath()
    @State private var selectedLetter = "A"
    @State private var entries: [ArticleSummary] = []
    @State private var groups: [BrowseGroup] = []
    @State private var visibleEntry = 0
    @State private var jumpTarget: Int?
    @FocusState private var searchFocused: Bool

    private var isSearching: Bool {
        !store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                SearchField(text: $store.searchText,
                            focus: $searchFocused,
                            onRandom: openRandom,
                            onSubmit: { store.recordSearch(store.searchText) })
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                Divider()

                if isSearching {
                    searchResults
                } else {
                    LetterBar(letters: store.letters, selected: selectedLetter, onSelect: select(letter:))
                    if !groups.isEmpty {
                        GroupBar(groups: groups, activeKey: activeGroupKey, onSelect: jump(toGroup:))
                    }
                    Divider()
                    ColumnReader(columns: columns,
                                 letter: selectedLetter,
                                 entryCount: entries.count,
                                 fontSize: settings.fontSize.pointSize,
                                 jumpTarget: $jumpTarget,
                                 visibleEntry: $visibleEntry,
                                 onOpen: { path.append($0) })
                }
            }
            .articleDestinations()
            #if os(iOS)
            // No pane header — the tab bar's active state is enough.
            .toolbar(.hidden, for: .navigationBar)
            .scrollDismissesKeyboard(.interactively)
            #endif
        }
        // Clear stale focus when leaving Browse, so returning and tapping the
        // field re-presents the keyboard (and its Hide button).
        .onChange(of: router.selectedTab) { tab in
            if tab != .browse { searchFocused = false }
        }
        .onAppear {
            if entries.isEmpty {
                if !store.letters.contains(selectedLetter) {
                    selectedLetter = store.letters.first ?? "A"
                }
                reload()
            }
        }
    }

    // MARK: - Letter / sub-section navigation

    private func select(letter: String) {
        guard letter != selectedLetter else { return }
        selectedLetter = letter
        reload()
    }

    private func reload() {
        entries = store.entries(startingWith: selectedLetter)
        groups = Self.groups(for: entries, fallback: selectedLetter)
        visibleEntry = 0
        jumpTarget = 0
    }

    private func jump(toGroup group: BrowseGroup) {
        jumpTarget = group.startIndex
    }

    /// The sub-section the reader is currently inside.
    private var activeGroupKey: String? {
        guard !groups.isEmpty else { return nil }
        var active = groups[0].key
        for group in groups where group.startIndex <= visibleEntry {
            active = group.key
        }
        return active
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

    // MARK: - Grouping

    /// Group consecutive (already title-sorted) entries by their first two
    /// letters, e.g. "Aa", "Ab", "Ac", recording where each group starts.
    static func groups(for entries: [ArticleSummary], fallback: String) -> [BrowseGroup] {
        var result: [BrowseGroup] = []
        for (index, entry) in entries.enumerated() {
            let key = groupKey(entry.title, fallback: fallback)
            if let last = result.last, last.key == key {
                result[result.count - 1] = BrowseGroup(key: key,
                                                       startIndex: last.startIndex,
                                                       count: last.count + 1)
            } else {
                result.append(BrowseGroup(key: key, startIndex: index, count: 1))
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

/// A run of consecutive entries sharing their first two letters.
struct BrowseGroup: Identifiable, Hashable {
    let key: String
    /// Index of the group's first entry within the letter's entry list.
    let startIndex: Int
    let count: Int
    var id: String { key }
}

// MARK: - A–Z rail

/// The alphabet, laid across the top of the pane. Tap a letter, or drag along
/// the rail to scrub through it.
///
/// A scrub highlights letters as your finger passes but only *commits* on
/// release: changing letter re-measures a whole section of the encyclopaedia,
/// which is not something to do twenty-six times on the way past.
struct LetterBar: View {
    let letters: [String]
    let selected: String
    let onSelect: (String) -> Void

    @State var preview: String?

    private var highlighted: String { preview ?? selected }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(letters, id: \.self) { letter in
                    Text(letter)
                        .font(.caption)
                        .fontWeight(letter == highlighted ? .bold : .regular)
                        .foregroundStyle(letter == highlighted ? Color.accentColor : .secondary)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in preview = letter(at: value.location.x, width: geo.size.width) }
                    .onEnded { value in
                        let picked = letter(at: value.location.x, width: geo.size.width)
                        preview = nil
                        if let picked, picked != selected { onSelect(picked) }
                    }
            )
        }
        .frame(height: 26)
        .padding(.horizontal, 8)
        .padding(.top, 20)
    }

    private func letter(at x: CGFloat, width: CGFloat) -> String? {
        guard !letters.isEmpty, width > 0 else { return nil }
        let fraction = min(max(x / width, 0), 0.999)
        return letters[min(Int(fraction * CGFloat(letters.count)), letters.count - 1)]
    }
}

// MARK: - Sub-section scrubber

/// The two-letter sub-sections of the current letter (Aa, Ab, Ac …). Tapping
/// one sends the column reader straight to that run of entries.
struct GroupBar: View {
    let groups: [BrowseGroup]
    let activeKey: String?
    let onSelect: (BrowseGroup) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(groups) { group in
                        Button { onSelect(group) } label: {
                            Text(group.key)
                                .font(.caption2)
                                .fontWeight(group.key == activeKey ? .bold : .regular)
                                .foregroundStyle(group.key == activeKey ? Color.white : Color.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule().fill(group.key == activeKey
                                                   ? Color.accentColor
                                                   : Color.secondary.opacity(0.12))
                                )
                        }
                        .buttonStyle(.plain)
                        .id(group.key)
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 30)
            // Keep the section the reader is in visible as they scroll.
            .onChange(of: activeKey) { key in
                guard let key else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(key, anchor: .center) }
            }
        }
    }
}

// MARK: - Search field

/// A rounded search field paired with a Random-article shortcut, sitting at the
/// top of the Browse pane.
struct SearchField: View {
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    var onRandom: () -> Void
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search 1911 Britannica", text: $text)
                    .textFieldStyle(.plain)
                    .focused(focus)
                    .submitLabel(.search)
                    .onSubmit(onSubmit)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    // Attach the Hide-Keyboard control to the field itself so it
                    // re-appears reliably each time the field is focused.
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button {
                                focus.wrappedValue = false
                            } label: {
                                Label("Hide Keyboard", systemImage: "keyboard.chevron.compact.down")
                            }
                        }
                    }
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
