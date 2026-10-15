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
        let textView = LogNSTextView()
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
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
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

        scrollView.relayoutText()

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

final class LogNSTextView: NSTextView {
    private var fitting = false

    override func setFrameSize(_ newSize: NSSize) {
        var size = newSize
        if !fitting {
            fitting = true
            let fitted = fittedHeight
            fitting = false
            if fitted > size.height {
                size.height = fitted
            }
        }
        super.setFrameSize(size)
    }

    var fittedHeight: CGFloat {
        guard let layoutManager, let textContainer else { return frame.height }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let inset = textContainerInset.height
        guard used.height > 0 || (string as NSString).length > 0 else { return frame.height }
        return ceil(inset + used.maxY + inset) + 4
    }
}

final class LogScrollView: NSScrollView {
    var isLive = false
    var programmaticScroll = false
    var onLiveChange: ((Bool) -> Void)?
    private var userScrolling = false
    private var fittingText = false
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
        guard !fittingText else { return }
        relayoutText()
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
        guard isLive, !userScrolling, !programmaticScroll, !isAtBottom else { return }
        pinToBottom()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isLive, !self.userScrolling, !self.programmaticScroll, !self.isAtBottom else { return }
            self.pinToBottom()
        }
    }

    func relayoutText() {
        guard !fittingText,
              let textView = documentView as? LogNSTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        let width = contentSize.width
        guard width > 1 else { return }
        fittingText = true
        defer { fittingText = false }

        if abs(textView.frame.width - width) > 0.5 {
            textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
        }
        layoutManager.ensureLayout(for: container)
        let height = textView.fittedHeight
        guard height > 1, abs(textView.frame.height - height) > 0.5 else { return }
        textView.setFrameSize(NSSize(width: textView.frame.width, height: height))
    }

    private func pinToBottom() {
        guard let textView = documentView as? LogNSTextView else { return }
        programmaticScroll = true
        relayoutText()
        let contentHeight = textView.frame.height
        let visibleHeight = contentView.bounds.height
        if contentHeight > visibleHeight + 1 {
            var origin = contentView.bounds.origin
            origin.y = max(0, contentHeight - visibleHeight)
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
        case .scrollWheel:
            return true
        case .leftMouseDown, .leftMouseDragged:
            let point = convert(event.locationInWindow, from: nil)
            return hitTest(point) is NSScroller
        case .keyDown:
            let responder = window?.firstResponder
            return responder === self || responder === documentView
        default:
            return false
        }
    }

    private var canScrollContent: Bool {
        guard let document = documentView else { return false }
        return document.frame.height > contentView.bounds.height + 1
    }

    private var isAtBottom: Bool {
        distanceFromBottom <= 1
    }

    private var isNearBottom: Bool {
        distanceFromBottom <= 8
    }

    private var distanceFromBottom: CGFloat {
        guard let document = documentView else { return 0 }
        let visible = contentView.bounds
        let height = document.frame.height
        if height <= visible.height + 1 { return 0 }
        return height - visible.maxY
    }
}
