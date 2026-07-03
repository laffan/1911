import SwiftUI

/// All articles signed by a single contributor, reached by tapping an author's
/// name in a byline. Tapping an entry pushes it onto the same navigation stack.
struct AuthorArticlesView: View {
    let author: AuthorRef
    @EnvironmentObject var store: LibraryStore

    var body: some View {
        let articles = store.articles(byAuthor: author.id)

        List {
            Section {
                ForEach(articles) { article in
                    NavigationLink(value: article.id) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(article.title)
                            if let volume = article.volume {
                                Text("Vol. \(volume)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("^[\(articles.count) article](inflect: true) in this edition")
            }
        }
        .navigationTitle(author.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
