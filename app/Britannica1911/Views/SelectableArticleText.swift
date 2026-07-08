#if os(iOS)
import SwiftUI
import UIKit

/// A read-only, freely selectable article body backed by `UITextView`, so the
/// reader can select an arbitrary passage (not the whole entry) and gets a
/// custom **Send to Notebook** action alongside the standard Copy / Look Up /
/// Share edit-menu items.
struct SelectableArticleText: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat
    var onSendToNotebook: (String) -> Void

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = false
        textView.dataDetectorTypes = []
        textView.delegate = context.coordinator
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.onSendToNotebook = onSendToNotebook
        textView.attributedText = Self.attributed(text, fontSize: fontSize)
    }

    /// iOS 16+: report the height the text needs at the proposed width so the
    /// view sizes itself inside a SwiftUI ScrollView (no internal scrolling).
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        guard width > 0 else { return nil }
        let fit = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fit.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSendToNotebook: onSendToNotebook) }

    static func attributed(_ text: String, fontSize: CGFloat) -> NSAttributedString {
        let base = UIFont.systemFont(ofSize: fontSize)
        let descriptor = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
        let font = UIFont(descriptor: descriptor, size: fontSize)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4

        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraph,
        ])
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onSendToNotebook: (String) -> Void

        init(onSendToNotebook: @escaping (String) -> Void) {
            self.onSendToNotebook = onSendToNotebook
        }

        func textView(_ textView: UITextView,
                      editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0, let full = textView.text as NSString? else {
                return UIMenu(children: suggestedActions)
            }
            let selection = full.substring(with: range)
            let send = UIAction(title: "Send to Notebook",
                                image: UIImage(systemName: "text.badge.plus")) { [weak self] _ in
                self?.onSendToNotebook(selection)
            }
            return UIMenu(children: [send] + suggestedActions)
        }
    }
}
#endif
