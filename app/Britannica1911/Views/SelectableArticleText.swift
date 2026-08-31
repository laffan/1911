import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// A read-only, freely selectable run of article text.
///
/// Backed by the platform's text view rather than SwiftUI's `Text`, for one
/// reason: the reader can select an arbitrary passage — not the whole block —
/// and the edit menu offers **Send to Notebook** alongside the usual
/// Copy / Look Up / Share. SwiftUI's `.textSelection(.enabled)` gives selection
/// but no way to add an action to the menu.
///
/// Used for every run of body text in the app: the single-article view and each
/// block of text in the Browse columns.
///
/// Text is laid out with the same serif face and line spacing the column
/// engine measures with (`ReaderFont`), so a block of pre-wrapped lines draws
/// exactly the lines it was given.
#if os(iOS)
struct SelectableArticleText: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat
    var lineSpacing: CGFloat = 4
    /// Every occurrence of an in-article find, and the one the reader is on.
    var highlights: [NSRange] = []
    var currentHighlight: NSRange? = nil
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
        // Don't let the text view start a drag-and-drop session on a horizontal
        // pan; that would swallow the sideways scroll of the columns it sits
        // in, in Browse and in an article alike. Selection (long-press) still
        // works.
        textView.textDragInteraction?.isEnabled = false
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.onSendToNotebook = onSendToNotebook
        // Only rebuild the attributed text when it actually changes. Otherwise a
        // frequent re-render would reset the user's in-progress selection.
        let applied = AppliedText(text: text, fontSize: fontSize, lineSpacing: lineSpacing,
                                  highlights: highlights, currentHighlight: currentHighlight)
        if context.coordinator.applied != applied {
            textView.attributedText = Self.attributed(text, fontSize: fontSize, lineSpacing: lineSpacing,
                                                      highlights: highlights, currentHighlight: currentHighlight)
            context.coordinator.applied = applied
        }
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

    static func attributed(_ text: String, fontSize: CGFloat, lineSpacing: CGFloat,
                           highlights: [NSRange] = [],
                           currentHighlight: NSRange? = nil) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = .byWordWrapping
        let string = NSMutableAttributedString(string: text, attributes: [
            .font: ReaderFont.serif(size: fontSize),
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraph,
        ])
        string.paintFindMatches(highlights, current: currentHighlight)
        return string
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onSendToNotebook: (String) -> Void
        var applied: AppliedText?

        init(onSendToNotebook: @escaping (String) -> Void) {
            self.onSendToNotebook = onSendToNotebook
        }

        func textView(_ textView: UITextView,
                      editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0, let text = textView.text, !text.isEmpty else {
                return UIMenu(children: suggestedActions)
            }
            let selection = (text as NSString).substring(with: range)
            let send = UIAction(title: "Send to Notebook",
                                image: UIImage(systemName: "text.badge.plus")) { [weak self] _ in
                self?.onSendToNotebook(selection)
            }
            return UIMenu(children: [send] + suggestedActions)
        }
    }
}
#elseif os(macOS)
struct SelectableArticleText: NSViewRepresentable {
    let text: String
    let fontSize: CGFloat
    var lineSpacing: CGFloat = 4
    /// Every occurrence of an in-article find, and the one the reader is on.
    var highlights: [NSRange] = []
    var currentHighlight: NSRange? = nil
    var onSendToNotebook: (String) -> Void

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = context.coordinator
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        context.coordinator.onSendToNotebook = onSendToNotebook
        let applied = AppliedText(text: text, fontSize: fontSize, lineSpacing: lineSpacing,
                                  highlights: highlights, currentHighlight: currentHighlight)
        if context.coordinator.applied != applied {
            textView.textStorage?.setAttributedString(
                Self.attributed(text, fontSize: fontSize, lineSpacing: lineSpacing,
                                highlights: highlights, currentHighlight: currentHighlight))
            context.coordinator.applied = applied
        }
    }

    /// Report the height the text needs at the proposed width, so the view
    /// sizes itself inside a SwiftUI ScrollView. Measured from the attributed
    /// string rather than the view's own layout, which may not have run yet.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let bounds = Self.attributed(text, fontSize: fontSize, lineSpacing: lineSpacing)
            .boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: width, height: ceil(bounds.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSendToNotebook: onSendToNotebook) }

    static func attributed(_ text: String, fontSize: CGFloat, lineSpacing: CGFloat,
                           highlights: [NSRange] = [],
                           currentHighlight: NSRange? = nil) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = .byWordWrapping
        let string = NSMutableAttributedString(string: text, attributes: [
            .font: ReaderFont.serif(size: fontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])
        string.paintFindMatches(highlights, current: currentHighlight)
        return string
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onSendToNotebook: (String) -> Void
        var applied: AppliedText?
        private weak var textView: NSTextView?

        init(onSendToNotebook: @escaping (String) -> Void) {
            self.onSendToNotebook = onSendToNotebook
        }

        /// Put **Send to Notebook** at the top of the right-click menu whenever
        /// something is selected.
        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            textView = view
            guard view.selectedRange().length > 0 else { return menu }
            let item = NSMenuItem(title: "Send to Notebook",
                                  action: #selector(sendSelection),
                                  keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: 0)
            menu.insertItem(NSMenuItem.separator(), at: 1)
            return menu
        }

        @objc private func sendSelection() {
            guard let view = textView else { return }
            let range = view.selectedRange()
            guard range.length > 0 else { return }
            onSendToNotebook((view.string as NSString).substring(with: range))
        }
    }
}
#endif

/// What a text view is currently showing, so a re-render that changes nothing
/// leaves an in-progress selection alone.
struct AppliedText: Equatable {
    let text: String
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    var highlights: [NSRange] = []
    var currentHighlight: NSRange? = nil

    static func == (lhs: AppliedText, rhs: AppliedText) -> Bool {
        guard lhs.text == rhs.text,
              lhs.fontSize == rhs.fontSize,
              lhs.lineSpacing == rhs.lineSpacing,
              lhs.highlights.count == rhs.highlights.count,
              sameRange(lhs.currentHighlight, rhs.currentHighlight) else { return false }
        for (left, right) in zip(lhs.highlights, rhs.highlights) where !NSEqualRanges(left, right) {
            return false
        }
        return true
    }

    private static func sameRange(_ lhs: NSRange?, _ rhs: NSRange?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (left?, right?): return NSEqualRanges(left, right)
        default: return false
        }
    }
}

#if os(iOS)
typealias PlatformColor = UIColor
#elseif os(macOS)
typealias PlatformColor = NSColor
#endif

private extension NSMutableAttributedString {
    /// Paint the in-article find: every match in yellow, the one the reader is
    /// on in orange. Both are drawn with dark text so they stay legible under
    /// either appearance.
    ///
    /// Ranges that fall outside the string are skipped rather than trusted —
    /// a highlight computed against a column that has since been re-measured
    /// must never take the reader down with it.
    func paintFindMatches(_ ranges: [NSRange], current: NSRange?) {
        guard !ranges.isEmpty || current != nil else { return }
        paint(ranges, background: PlatformColor.systemYellow.withAlphaComponent(0.85))
        if let current {
            paint([current], background: PlatformColor.systemOrange.withAlphaComponent(0.95))
        }
    }

    func paint(_ ranges: [NSRange], background: PlatformColor) {
        let bounds = NSRange(location: 0, length: length)
        for range in ranges {
            guard range.length > 0,
                  NSIntersectionRange(range, bounds).length == range.length else { continue }
            addAttribute(.backgroundColor, value: background, range: range)
            addAttribute(.foregroundColor, value: PlatformColor.black, range: range)
        }
    }
}
