import AppKit
import SwiftUI

enum LogSearch {
    static func ranges(in text: String, query: String, usesRegex: Bool) -> [NSRange] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, !text.isEmpty else { return [] }
        if usesRegex {
            guard let regex = try? NSRegularExpression(pattern: needle) else { return [] }
            let full = NSRange(text.startIndex..., in: text)
            return regex.matches(in: text, range: full).map(\.range).filter { $0.length > 0 }
        }
        var ranges: [NSRange] = []
        var start = text.startIndex
        while start < text.endIndex,
              let found = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex) {
            ranges.append(NSRange(found, in: text))
            start = found.upperBound
        }
        return ranges
    }

    /// 离字符位置最近的一条匹配。点在匹配中间时就是这一条。
    static func nearestIndex(in ranges: [NSRange], to offset: Int) -> Int? {
        guard !ranges.isEmpty else { return nil }
        var low = 0
        var high = ranges.count - 1
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(ranges[mid]) <= offset {
                low = mid + 1
            } else {
                high = mid
            }
        }
        let next = low
        let previous = next - 1
        guard previous >= 0 else { return next }
        return distance(from: offset, to: ranges[previous]) <= distance(from: offset, to: ranges[next]) ? previous : next
    }

    private static func distance(from offset: Int, to range: NSRange) -> Int {
        if NSLocationInRange(offset, range) { return 0 }
        if offset < range.location { return range.location - offset }
        return offset - (NSMaxRange(range) - 1)
    }
}

struct LogTextView: NSViewRepresentable {
    var lines: [String]
    var isLive: Bool
    var onLiveChange: (Bool) -> Void
    var searchQuery: String
    var searchUsesRegex: Bool
    var searchMatchIndex: Int
    var searchScrollToken: Int
    var onMatchCount: (Int) -> Void
    var onBecomeFirstResponder: () -> Void
    var onSelectMatch: (Int) -> Void
    var onHighlightMatch: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.lines = []
        let scrollView = LogScrollView()
        let textView = LogNSTextView()
        let scroller = MatchScroller(frame: .zero)
        scroller.textView = textView
        scrollView.hasVerticalScroller = true
        scrollView.verticalScroller = scroller
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

        textView.onBecameFirstResponder = { [weak coordinator = context.coordinator] in
            coordinator?.onBecomeFirstResponder?()
        }
        scrollView.documentView = textView
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
        if let textView = scrollView.documentView as? LogNSTextView {
            textView.onBecameFirstResponder = { [onBecomeFirstResponder] in
                onBecomeFirstResponder()
            }
        }
        scrollView.onSelectMatch = onSelectMatch
        scrollView.onHighlightMatch = onHighlightMatch
        scrollView.installMatchScroller()

        let coordinator = context.coordinator
        scrollView.onMatchRefresh = { [weak scrollView] in
            guard let scrollView, let textView = scrollView.documentView as? NSTextView else { return }
            publishMatches(textView, scrollView: scrollView, coordinator: coordinator)
        }

        let old = coordinator.lines
        let becameLive = isLive && !coordinator.wasLive
        let queryChanged = coordinator.query != searchQuery || coordinator.usesRegex != searchUsesRegex
        let indexChanged = coordinator.matchIndex != searchMatchIndex
        let shouldReveal = coordinator.scrollToken != searchScrollToken
        let linesAppended = old != lines && !old.isEmpty && lines.starts(with: old)
        let linesReplaced = old != lines && !linesAppended
        coordinator.wasLive = isLive
        coordinator.query = searchQuery
        coordinator.usesRegex = searchUsesRegex
        coordinator.matchIndex = searchMatchIndex
        guard old != lines || becameLive || queryChanged || indexChanged || shouldReveal else {
            if isLive {
                scrollView.followLive()
            }
            return
        }

        if linesAppended {
            let added = lines.dropFirst(old.count).joined(separator: "\n")
            if !added.isEmpty {
                textView.textStorage?.append(
                    NSAttributedString(string: "\n" + added, attributes: coordinator.attributes)
                )
            }
            coordinator.lines = lines
            scrollView.relayoutText()
            if isLive, !shouldReveal {
                scrollView.followLive()
            }
            if queryChanged || indexChanged || shouldReveal {
                scrollView.noteMatchRefreshPerformed()
                publishMatches(textView, scrollView: scrollView, coordinator: coordinator)
                if shouldReveal {
                    coordinator.scrollToken = searchScrollToken
                    revealCurrentMatch(textView, scrollView: scrollView)
                }
            } else if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                scrollView.scheduleAppendedMatchRefresh()
            }
            return
        }

        let savedOrigin = scrollView.contentView.bounds.origin
        if linesReplaced {
            textView.string = lines.joined(separator: "\n")
            textView.font = coordinator.font
            textView.textColor = .labelColor
            coordinator.lines = lines
            scrollView.noteMatchRefreshPerformed()
        }

        scrollView.relayoutText()
        if queryChanged || linesReplaced || indexChanged || shouldReveal {
            if queryChanged {
                scrollView.noteMatchRefreshPerformed()
            }
            publishMatches(textView, scrollView: scrollView, coordinator: coordinator)
        }
        if shouldReveal {
            coordinator.scrollToken = searchScrollToken
            revealCurrentMatch(textView, scrollView: scrollView)
        }

        if isLive, !shouldReveal {
            scrollView.followLive()
        } else if linesReplaced, !shouldReveal {
            scrollView.programmaticScroll = true
            scrollView.contentView.scroll(to: savedOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            scrollView.programmaticScroll = false
        }
    }

    private func publishMatches(_ textView: NSTextView, scrollView: LogScrollView, coordinator: Coordinator) {
        let matchCount = applySearchHighlights(textView, scrollView: scrollView)
        guard coordinator.reportedCount != matchCount else { return }
        coordinator.reportedCount = matchCount
        let report = onMatchCount
        DispatchQueue.main.async {
            report(matchCount)
        }
    }

    final class Coordinator {
        var lines: [String] = []
        var wasLive = true
        var query = ""
        var usesRegex = false
        var matchIndex = -1
        var scrollToken = 0
        var reportedCount = 0
        var onBecomeFirstResponder: (() -> Void)?
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        var attributes: [NSAttributedString.Key: Any] {
            [
                .font: font,
                .foregroundColor: NSColor.labelColor
            ]
        }
    }

    private func applySearchHighlights(_ textView: NSTextView, scrollView: LogScrollView) -> Int {
        guard let storage = textView.textStorage else { return 0 }
        let full = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.backgroundColor, range: full)
        let ranges = LogSearch.ranges(in: textView.string, query: searchQuery, usesRegex: searchUsesRegex)
        guard !ranges.isEmpty else {
            scrollView.updateMatchMarks(ranges: [], currentIndex: -1)
            return 0
        }
        let normal = NSColor.systemYellow.withAlphaComponent(0.45)
        let current = NSColor.systemOrange.withAlphaComponent(0.8)
        for (index, range) in ranges.enumerated() where range.location != NSNotFound && NSMaxRange(range) <= storage.length {
            storage.addAttribute(.backgroundColor, value: index == searchMatchIndex ? current : normal, range: range)
        }
        scrollView.relayoutText()
        scrollView.updateMatchMarks(ranges: ranges, currentIndex: searchMatchIndex)
        return ranges.count
    }

    private func revealCurrentMatch(_ textView: NSTextView, scrollView: LogScrollView) {
        let ranges = LogSearch.ranges(in: textView.string, query: searchQuery, usesRegex: searchUsesRegex)
        guard ranges.indices.contains(searchMatchIndex) else { return }
        scrollView.programmaticScroll = true
        textView.scrollRangeToVisible(ranges[searchMatchIndex])
        DispatchQueue.main.async { [weak scrollView] in
            scrollView?.programmaticScroll = false
        }
        if !scrollView.isAtBottom {
            scrollView.isLive = false
            onLiveChange(false)
        }
    }
}

final class LogNSTextView: NSTextView {
    var onBecameFirstResponder: (() -> Void)?
    private var fitting = false

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        (enclosingScrollView as? LogScrollView)?.highlightNearestClick(event, in: self)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        (enclosingScrollView as? LogScrollView)?.highlightNearestClick(event, in: self)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onBecameFirstResponder?()
        }
        return accepted
    }

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
    var onSelectMatch: ((Int) -> Void)?
    var onHighlightMatch: ((Int) -> Void)?
    var onMatchRefresh: (() -> Void)?
    private var searchRanges: [NSRange] = []
    private var highlightedIndex = -1
    private var userScrolling = false
    private var lastMatchRefresh: CFAbsoluteTime = 0
    private var matchRefreshWork: DispatchWorkItem?
    private var scrollHighlightWork: DispatchWorkItem?
    private let logMatchRefreshInterval: CFAbsoluteTime = 10
    private let scrollHighlightDelay: TimeInterval = 0.3
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
        (verticalScroller as? MatchScroller)?.recomputeFractionsIfNeeded()
    }

    func installMatchScroller() {
        let existing = verticalScroller as? MatchScroller
        let scroller = existing ?? MatchScroller(frame: verticalScroller?.frame ?? .zero)
        scroller.textView = documentView as? LogNSTextView
        scroller.onSelectMatch = onSelectMatch
        if existing == nil {
            verticalScroller = scroller
        }
    }

    func updateMatchMarks(ranges: [NSRange], currentIndex: Int) {
        searchRanges = ranges
        highlightedIndex = currentIndex
        let showMarks = !ranges.isEmpty
        if showMarks, scrollerStyle != .legacy {
            scrollerStyle = .legacy
            autohidesScrollers = false
        } else if !showMarks, scrollerStyle != .overlay {
            scrollerStyle = .overlay
            autohidesScrollers = true
        }
        installMatchScroller()
        (verticalScroller as? MatchScroller)?.updateMarks(ranges: ranges, currentIndex: currentIndex)
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
            scheduleScrollHighlight()
            userScrolling = false
        }
    }

    func noteMatchRefreshPerformed() {
        lastMatchRefresh = CFAbsoluteTimeGetCurrent()
        matchRefreshWork?.cancel()
        matchRefreshWork = nil
    }

    func scheduleAppendedMatchRefresh() {
        guard matchRefreshWork == nil else { return }
        let elapsed = CFAbsoluteTimeGetCurrent() - lastMatchRefresh
        let delay = elapsed >= logMatchRefreshInterval ? 0 : logMatchRefreshInterval - elapsed
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.matchRefreshWork = nil
            self.noteMatchRefreshPerformed()
            self.onMatchRefresh?()
            self.highlightNearestVisibleMatch()
        }
        matchRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func cancelScrollHighlight() {
        scrollHighlightWork?.cancel()
        scrollHighlightWork = nil
    }

    func highlightNearestClick(_ event: NSEvent, in textView: NSTextView) {
        cancelScrollHighlight()
        let point = textView.convert(event.locationInWindow, from: nil)
        let index = textView.characterIndexForInsertion(at: point)
        guard index != NSNotFound else { return }
        highlightNearest(to: index)
    }

    private func scheduleScrollHighlight() {
        scrollHighlightWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.scrollHighlightWork = nil
            self?.highlightNearestVisibleMatch()
        }
        scrollHighlightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + scrollHighlightDelay, execute: work)
    }

    private func highlightNearestVisibleMatch() {
        guard let textView = documentView as? NSTextView else { return }
        let bounds = contentView.bounds
        let point = contentView.convert(NSPoint(x: bounds.midX, y: bounds.midY), to: textView)
        let index = textView.characterIndexForInsertion(at: point)
        guard index != NSNotFound else { return }
        highlightNearest(to: index)
    }

    private func highlightNearest(to offset: Int) {
        guard let index = LogSearch.nearestIndex(in: searchRanges, to: offset), index != highlightedIndex else { return }
        highlightedIndex = index
        onHighlightMatch?(index)
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

    var isAtBottom: Bool {
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

final class MatchScroller: NSScroller {
    weak var textView: LogNSTextView?
    var onSelectMatch: ((Int) -> Void)?
    private var ranges: [NSRange] = []
    private var fractions: [CGFloat] = []
    private var currentIndex = -1
    private var fractionSize: NSSize = .zero

    func updateMarks(ranges: [NSRange], currentIndex: Int) {
        self.ranges = ranges
        self.currentIndex = currentIndex
        fractionSize = .zero
        recomputeFractionsIfNeeded()
        needsDisplay = true
    }

    func recomputeFractionsIfNeeded() {
        guard let textView else {
            fractions = []
            return
        }
        let size = textView.frame.size
        guard size != fractionSize else { return }
        fractionSize = size
        guard size.height > 1,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else {
            fractions = []
            needsDisplay = true
            return
        }
        layoutManager.ensureLayout(for: container)
        let inset = textView.textContainerInset.height
        fractions = ranges.map { range in
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            return min(1, max(0, (rect.midY + inset) / size.height))
        }
        needsDisplay = true
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight: Bool) {
        super.drawKnobSlot(in: slotRect, highlight: highlight)
        guard slotRect.height > 1, !fractions.isEmpty else { return }
        let others = fractions.enumerated().filter { $0.offset != currentIndex }
        for (_, fraction) in others {
            fillMark(fraction: fraction, in: slotRect, current: false)
        }
        if fractions.indices.contains(currentIndex) {
            fillMark(fraction: fractions[currentIndex], in: slotRect, current: true)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if rect(for: .knob).contains(point) {
            super.mouseDown(with: event)
            return
        }
        if let index = matchIndex(at: point) {
            (superview as? LogScrollView)?.cancelScrollHighlight()
            onSelectMatch?(index)
            return
        }
        super.mouseDown(with: event)
    }

    private func fillMark(fraction: CGFloat, in slotRect: NSRect, current: Bool) {
        let height: CGFloat = current ? 3 : 2
        let y = markY(fraction: fraction, slotRect: slotRect) - height / 2
        let rect = NSRect(x: slotRect.minX + 1, y: y, width: max(1, slotRect.width - 2), height: height)
        let color = current ? NSColor.systemOrange : NSColor.systemYellow.withAlphaComponent(0.95)
        color.setFill()
        rect.fill()
    }

    private func matchIndex(at point: NSPoint) -> Int? {
        let slot = rect(for: .knobSlot)
        guard slot.height > 1, slot.contains(point) else { return nil }
        var best: (index: Int, distance: CGFloat)?
        for (index, fraction) in fractions.enumerated() {
            let distance = abs(markY(fraction: fraction, slotRect: slot) - point.y)
            if distance <= 6, best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        return best?.index
    }

    private func markY(fraction: CGFloat, slotRect: NSRect) -> CGFloat {
        if isFlipped {
            return slotRect.minY + fraction * slotRect.height
        }
        return slotRect.maxY - fraction * slotRect.height
    }
}
