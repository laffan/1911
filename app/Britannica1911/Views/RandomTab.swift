import SwiftUI

/// Opens a random article, with a control to shuffle to another. Cross-reference
/// and author links push onto this tab's own navigation stack.
struct RandomTab: View {
    @EnvironmentObject var store: LibraryStore
    @State private var path = NavigationPath()
    @State private var randomID: Int64?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let id = randomID {
                    // New identity per shuffle so ArticleView re-seeds its paging state.
                    ArticleView(articleID: id).id(id)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "die.face.5")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                        Text("Tap for a random article")
                            .foregroundStyle(.secondary)
                        Button("Surprise me", action: shuffle)
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: shuffle) {
                        Label("Another", systemImage: "die.face.5")
                    }
                    .help("Show another random article")
                }
            }
            .articleDestinations()
        }
        .onAppear { if randomID == nil { shuffle() } }
    }

    private func shuffle() {
        path = NavigationPath()          // return to the new random article's root
        randomID = store.pickRandom(excluding: randomID)
    }
}
