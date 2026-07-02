import SwiftUI

/// A full article: title, volume, body paragraphs, and cross-reference links.
struct ArticleView: View {
    let articleID: Int64
    @EnvironmentObject var store: LibraryStore

    var body: some View {
        Group {
            if let article = store.article(id: articleID) {
                loaded(article)
            } else {
                Text("Article not found")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func loaded(_ article: Article) -> some View {
        let refs = store.crossReferences(for: article.id)

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(article)

                ForEach(Array(paragraphs(article.body).enumerated()), id: \.offset) { _, para in
                    Text(para)
                        .font(.system(.body, design: .serif))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }

                if !refs.isEmpty {
                    crossReferenceSection(refs)
                }

                if let source = article.sourceURL, let url = URL(string: source) {
                    Divider().padding(.top, 4)
                    Link(destination: url) {
                        Label("View on Wikisource", systemImage: "safari")
                            .font(.footnote)
                    }
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .navigationTitle(article.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func header(_ article: Article) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(article.title)
                .font(.system(.largeTitle, design: .serif).weight(.bold))
            if let volume = article.volume {
                Text("Encyclopædia Britannica, 11th ed. · Volume \(volume)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

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

    private func paragraphs(_ body: String) -> [String] {
        body
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
