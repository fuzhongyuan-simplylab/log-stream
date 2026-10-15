import AppKit
import SwiftUI

struct LogTextView: NSViewRepresentable {
    var lines: [String]

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.lines = []
        let scrollView = NSScrollView()
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .labelColor
        textView.font = context.coordinator.font
        textView.allowsUndo = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.enabledTextCheckingTypes = 0
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.textContainer?.lineFragmentPadding = 2
        textView.textContainer?.lineBreakMode = .byCharWrapping
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.borderType = .noBorder
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let old = context.coordinator.lines
        if old == lines { return }

        let atBottom = Self.isAtBottom(scrollView)
        if !old.isEmpty, lines.starts(with: old) {
            let added = lines.dropFirst(old.count).joined(separator: "\n")
            if !added.isEmpty {
                textView.textStorage?.append(
                    NSAttributedString(string: "\n" + added, attributes: context.coordinator.attributes)
                )
            }
        } else {
            textView.string = lines.joined(separator: "\n")
            textView.font = context.coordinator.font
            textView.textColor = .labelColor
        }
        context.coordinator.lines = lines

        let width = scrollView.contentSize.width
        if width > 1, abs(textView.frame.width - width) > 1 {
            textView.frame.size.width = width
        }

        if atBottom || old.isEmpty, let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
            textView.scrollRangeToVisible(NSRange(location: (textView.string as NSString).length, length: 0))
        }
    }

    private static func isAtBottom(_ scrollView: NSScrollView) -> Bool {
        guard let document = scrollView.documentView else { return true }
        let visible = scrollView.contentView.bounds
        let height = document.frame.height
        if height <= visible.height + 1 { return true }
        return visible.maxY >= height - 24
    }

    final class Coordinator {
        var lines: [String] = []
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        var attributes: [NSAttributedString.Key: Any] {
            [
                .font: font,
                .foregroundColor: NSColor.labelColor
            ]
        }
    }
}
