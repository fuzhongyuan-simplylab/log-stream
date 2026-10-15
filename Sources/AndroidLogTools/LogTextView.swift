import AppKit
import SwiftUI

struct LogTextView: NSViewRepresentable {
    var lines: [String]
    var isLive: Bool
    var onLiveChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.lines = []
        let scrollView = LogScrollView()
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
        guard let scrollView = scrollView as? LogScrollView,
              let textView = scrollView.documentView as? NSTextView else { return }
        scrollView.isLive = isLive
        scrollView.onLiveChange = { [onLiveChange] atBottom in
            onLiveChange(atBottom)
        }

        let old = context.coordinator.lines
        let becameLive = isLive && !context.coordinator.wasLive
        context.coordinator.wasLive = isLive
        guard old != lines || becameLive else {
            if isLive {
                scrollView.followLive()
            }
            return
        }

        let savedOrigin = scrollView.contentView.bounds.origin
        if old != lines {
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
        }

        let width = scrollView.contentSize.width
        if width > 1, abs(textView.frame.width - width) > 1 {
            textView.frame.size.width = width
        }

        if isLive {
            scrollView.followLive()
        } else if old != lines, !lines.starts(with: old) {
            scrollView.programmaticScroll = true
            scrollView.contentView.scroll(to: savedOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            scrollView.programmaticScroll = false
        }
    }

    final class Coordinator {
        var lines: [String] = []
        var wasLive = true
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        var attributes: [NSAttributedString.Key: Any] {
            [
                .font: font,
                .foregroundColor: NSColor.labelColor
            ]
        }
    }
}

final class LogScrollView: NSScrollView {
    var isLive = false
    var programmaticScroll = false
    var onLiveChange: ((Bool) -> Void)?
    private var userScrolling = false
    private var followedSize: NSSize = .zero

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        followedSize = .zero
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.followLive()
        }
    }

    override func layout() {
        super.layout()
        let size = contentView.bounds.size
        let changed = abs(size.width - followedSize.width) > 0.5 || abs(size.height - followedSize.height) > 0.5
        guard changed else { return }
        followedSize = size
        followLive()
    }

    override func scrollWheel(with event: NSEvent) {
        userScrolling = true
        super.scrollWheel(with: event)
        reportUserScroll()
        userScrolling = false
    }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        let userEvent = !programmaticScroll && isUserScrollEvent
        if userEvent { userScrolling = true }
        super.reflectScrolledClipView(clipView)
        if userEvent {
            reportUserScroll()
            userScrolling = false
        }
    }

    func followLive() {
        guard isLive, !userScrolling, !programmaticScroll, !isNearBottom else { return }
        pinToBottom()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isLive, !self.userScrolling, !self.programmaticScroll, !self.isNearBottom else { return }
            self.pinToBottom()
        }
    }

    private func pinToBottom() {
        guard let textView = documentView as? NSTextView else { return }
        programmaticScroll = true
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
        }
        let length = (textView.string as NSString).length
        textView.scrollRangeToVisible(NSRange(location: length, length: 0))
        let contentHeight = textView.frame.height
        let visibleHeight = contentView.bounds.height
        if contentHeight > visibleHeight + 1 {
            var origin = contentView.bounds.origin
            origin.y = contentHeight - visibleHeight
            contentView.scroll(to: origin)
            reflectScrolledClipView(contentView)
        }
        programmaticScroll = false
    }

    private func reportUserScroll() {
        guard canScrollContent else { return }
        let atBottom = isNearBottom
        isLive = atBottom
        onLiveChange?(atBottom)
    }

    private var isUserScrollEvent: Bool {
        guard let event = NSApp.currentEvent else { return false }
        switch event.type {
        case .leftMouseDragged, .leftMouseDown, .scrollWheel, .keyDown:
            return true
        default:
            return false
        }
    }

    private var canScrollContent: Bool {
        guard let document = documentView else { return false }
        return document.frame.height > contentView.bounds.height + 1
    }

    private var isNearBottom: Bool {
        guard let document = documentView else { return true }
        let visible = contentView.bounds
        let height = document.frame.height
        if height <= visible.height + 1 { return true }
        return visible.maxY >= height - 8
    }
}
