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

                if !article.authors.isEmpty {
                    byline(article.authors)
                }

                ForEach(Array(paragraphs(article.body).enumerated()), id: \.offset) { _, para in
                    Text(para)
                        .font(.system(.body, design: .serif))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }

                if !refs.isEmpty {
                    crossReferenceSection(refs)
                }

                neighborNavigation(article)

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
            if let citation = citation(article) {
                Text(citation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    @ViewBuilder
    private func neighborNavigation(_ article: Article) -> some View {
        if article.previous != nil || article.next != nil {
            Divider().padding(.top, 4)
            HStack(alignment: .top) {
                neighborLink(article.previous, systemImage: "chevron.left", trailing: false)
                Spacer(minLength: 12)
                neighborLink(article.next, systemImage: "chevron.right", trailing: true)
            }
        }
    }

    @ViewBuilder
    private func neighborLink(_ neighbor: Neighbor?, systemImage: String, trailing: Bool) -> some View {
        if let neighbor {
            let alignment: HorizontalAlignment = trailing ? .trailing : .leading
            let content = VStack(alignment: alignment, spacing: 2) {
                Text(trailing ? "Next" : "Previous")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    if !trailing { Image(systemName: systemImage) }
                    Text(neighbor.title)
                        .multilineTextAlignment(trailing ? .trailing : .leading)
                    if trailing { Image(systemName: systemImage) }
                }
                .font(.callout)
            }
            // Navigable when the neighbour has been scraped in; plain text otherwise.
            if let id = store.resolve(neighbor) {
                NavigationLink(value: id) { content }.buttonStyle(.plain)
            } else {
                content.foregroundStyle(.secondary)
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
