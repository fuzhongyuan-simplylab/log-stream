import AppKit
import SwiftUI

enum LogSearch {
    static func ranges(
        in text: String,
        query: String,
        matchCase: Bool,
        wholeWord: Bool,
        usesRegex: Bool
    ) -> [NSRange] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, !text.isEmpty else { return [] }
        if usesRegex {
            guard let regex = expression(query: needle, matchCase: matchCase, wholeWord: wholeWord, usesRegex: true) else {
                return []
            }
            let full = NSRange(text.startIndex..., in: text)
            return regex.matches(in: text, range: full).map(\.range).filter { $0.length > 0 }
        }
        return literalRanges(in: text, needle: needle, matchCase: matchCase, wholeWord: wholeWord)
    }

    static func isInvalid(query: String, matchCase: Bool, wholeWord: Bool, usesRegex: Bool) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard usesRegex, !needle.isEmpty else { return false }
        return expression(query: query, matchCase: matchCase, wholeWord: wholeWord, usesRegex: true) == nil
    }

    /// 纯文本沿用原来的大小写和变音折叠。全词只在模式首尾是单词字符时检查边界，和 VS Code 的 `\b` 一致。
    private static func literalRanges(
        in text: String,
        needle: String,
        matchCase: Bool,
        wholeWord: Bool
    ) -> [NSRange] {
        var options: String.CompareOptions = []
        if !matchCase {
            options.formUnion([.caseInsensitive, .diacriticInsensitive])
        }
        let requireLeading = wholeWord && needle.first.map(isASCIIWordCharacter) == true
        let requireTrailing = wholeWord && needle.last.map(isASCIIWordCharacter) == true
        let nsText = text as NSString
        var ranges: [NSRange] = []
        var start = text.startIndex
        while start < text.endIndex,
              let found = text.range(of: needle, options: options, range: start..<text.endIndex) {
            let range = NSRange(found, in: text)
            let leadingOK = !requireLeading || range.location == 0 || !isASCIIWordUnit(nsText.character(at: range.location - 1))
            let trailingIndex = NSMaxRange(range)
            let trailingOK = !requireTrailing || trailingIndex >= nsText.length || !isASCIIWordUnit(nsText.character(at: trailingIndex))
            if leadingOK && trailingOK {
                ranges.append(range)
            }
            start = found.upperBound
        }
        return ranges
    }

    private static func expression(
        query: String,
        matchCase: Bool,
        wholeWord: Bool,
        usesRegex: Bool
    ) -> NSRegularExpression? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        var pattern = usesRegex ? needle : NSRegularExpression.escapedPattern(for: needle)
        if wholeWord {
            pattern = applyingWholeWord(to: pattern)
        }
        var options: NSRegularExpression.Options = []
        if !matchCase {
            options.insert(.caseInsensitive)
        }
        return try? NSRegularExpression(pattern: pattern, options: options)
    }

    /// VS Code 的全词：模式首尾如果是 `[A-Za-z0-9_]`，就补上 ASCII `\b`。
    private static func applyingWholeWord(to pattern: String) -> String {
        var pattern = pattern
        if let first = pattern.first, isASCIIWordCharacter(first) {
            pattern = "\\b" + pattern
        }
        if let last = pattern.last, isASCIIWordCharacter(last) {
            pattern += "\\b"
        }
        return pattern
    }

    private static func isASCIIWordCharacter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let value = character.unicodeScalars.first?.value,
              value < 128 else {
            return false
        }
        return isASCIIWordUnit(unichar(value))
    }

    private static func isASCIIWordUnit(_ unit: unichar) -> Bool {
        switch unit {
        case 48...57, 65...90, 97...122, 95:
            return true
        default:
            return false
        }
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

@MainActor
final class LogEditorBridge {
    weak var textView: NSTextView?

    func singleLineSelection() -> String? {
        guard let textView else { return nil }
        let range = textView.selectedRange()
        guard range.length > 0 else { return nil }
        let nsString = textView.string as NSString
        guard NSMaxRange(range) <= nsString.length else { return nil }
        let selected = nsString.substring(with: range)
        guard !selected.isEmpty, selected.allSatisfy({ !$0.isNewline }) else { return nil }
        return selected
    }

    func focus() {
        guard let textView, let window = textView.window else { return }
        window.makeFirstResponder(textView)
    }
}

struct LogTextView: NSViewRepresentable {
    var snapshot: LogSnapshot
    var isLive: Bool
    var onLiveChange: (Bool) -> Void
    var searchQuery: String
    var searchMatchCase: Bool
    var searchWholeWord: Bool
    var searchUsesRegex: Bool
    var searchEpoch: Int
    var searchMatchIndex: Int
    var searchScrollToken: Int
    var editorBridge: LogEditorBridge
    var onMatchCount: (Int, Int) -> Void
    var onBecomeFirstResponder: () -> Void
    var onSelectMatch: (Int) -> Void
    var onHighlightMatch: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
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
        editorBridge.textView = textView
        scrollView.onSelectMatch = onSelectMatch
        scrollView.onHighlightMatch = onHighlightMatch
        scrollView.installMatchScroller()

        let coordinator = context.coordinator
        scrollView.onMatchRefresh = { [weak scrollView] in
            guard let scrollView, let textView = scrollView.documentView as? NSTextView else { return }
            publishMatches(textView, scrollView: scrollView, coordinator: coordinator)
        }

        let change = coordinator.change(for: snapshot)
        let becameLive = isLive && !coordinator.wasLive
        let queryChanged = coordinator.query != searchQuery
            || coordinator.matchCase != searchMatchCase
            || coordinator.wholeWord != searchWholeWord
            || coordinator.usesRegex != searchUsesRegex
            || coordinator.epoch != searchEpoch
        let indexChanged = coordinator.matchIndex != searchMatchIndex
        let shouldReveal = coordinator.scrollToken != searchScrollToken
        coordinator.wasLive = isLive
        coordinator.query = searchQuery
        coordinator.matchCase = searchMatchCase
        coordinator.wholeWord = searchWholeWord
        coordinator.usesRegex = searchUsesRegex
        coordinator.epoch = searchEpoch
        coordinator.matchIndex = searchMatchIndex
        guard change != .none || becameLive || queryChanged || indexChanged || shouldReveal else {
            if isLive {
                scrollView.followLive()
            }
            return
        }

        if change.isGrowth {
            apply(change, to: textView, coordinator: coordinator)
            scrollView.relayoutText()
            if isLive, !shouldReveal {
                scrollView.followLive()
            }
            let trimmed = change.droppedLines > 0
            if trimmed || queryChanged || indexChanged || shouldReveal {
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
        if change == .replace {
            replaceText(snapshot.lines, in: textView, coordinator: coordinator)
            scrollView.noteMatchRefreshPerformed()
        }

        scrollView.relayoutText()
        if queryChanged || change == .replace || indexChanged || shouldReveal {
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
        } else if change == .replace, !shouldReveal {
            scrollView.programmaticScroll = true
            scrollView.contentView.scroll(to: savedOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            scrollView.programmaticScroll = false
        }
    }

    private func publishMatches(_ textView: NSTextView, scrollView: LogScrollView, coordinator: Coordinator) {
        let matchCount = applySearchHighlights(textView, scrollView: scrollView)
        guard coordinator.reportedCount != matchCount || coordinator.reportedEpoch != searchEpoch else { return }
        coordinator.reportedCount = matchCount
        coordinator.reportedEpoch = searchEpoch
        let epoch = searchEpoch
        let report = onMatchCount
        DispatchQueue.main.async {
            report(matchCount, epoch)
        }
    }

    final class Coordinator {
        var revision = 0
        var dropped = 0
        var count = 0
        var wasLive = true
        var query = ""
        var matchCase = false
        var wholeWord = false
        var usesRegex = false
        var epoch = 0
        var matchIndex = -1
        var scrollToken = 0
        var reportedCount = 0
        var reportedEpoch = -1
        var onBecomeFirstResponder: (() -> Void)?
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        var attributes: [NSAttributedString.Key: Any] {
            [
                .font: font,
                .foregroundColor: NSColor.labelColor
            ]
        }

        enum Change: Equatable {
            case none
            case append(Int)
            case trim(dropped: Int, appended: Int)
            case replace

            var isGrowth: Bool {
                switch self {
                case .append, .trim:
                    return true
                case .none, .replace:
                    return false
                }
            }

            var droppedLines: Int {
                if case .trim(let dropped, _) = self { return dropped }
                return 0
            }
        }

        func change(for snapshot: LogSnapshot) -> Change {
            if snapshot.revision != revision { return .replace }
            let droppedDelta = snapshot.dropped - dropped
            if droppedDelta < 0 { return .replace }
            let appended = snapshot.count - (count - droppedDelta)
            if appended < 0 { return .replace }
            if droppedDelta == 0 {
                return appended == 0 ? .none : .append(appended)
            }
            return .trim(dropped: droppedDelta, appended: appended)
        }

        func noteApplied(_ snapshot: LogSnapshot) {
            revision = snapshot.revision
            dropped = snapshot.dropped
            count = snapshot.count
        }
    }

    private func apply(_ change: Coordinator.Change, to textView: NSTextView, coordinator: Coordinator) {
        guard let storage = textView.textStorage else {
            coordinator.noteApplied(snapshot)
            return
        }
        storage.beginEditing()
        switch change {
        case .append(let count):
            append(snapshot.lines.suffix(count), to: storage, coordinator: coordinator)
        case .trim(let dropped, let appended):
            deletePrefixLines(dropped, in: storage)
            if appended > 0 {
                append(snapshot.lines.suffix(appended), to: storage, coordinator: coordinator)
            }
        case .none, .replace:
            break
        }
        storage.endEditing()
        coordinator.noteApplied(snapshot)
    }

    private func replaceText(_ lines: [String], in textView: NSTextView, coordinator: Coordinator) {
        textView.string = lines.joined(separator: "\n")
        textView.font = coordinator.font
        textView.textColor = .labelColor
        coordinator.noteApplied(snapshot)
    }

    private func append(_ lines: some Sequence<String>, to storage: NSTextStorage, coordinator: Coordinator) {
        let added = lines.joined(separator: "\n")
        guard !added.isEmpty else { return }
        let prefix = storage.length > 0 ? "\n" : ""
        storage.append(NSAttributedString(string: prefix + added, attributes: coordinator.attributes))
    }

    private func deletePrefixLines(_ lineCount: Int, in storage: NSTextStorage) {
        guard lineCount > 0, storage.length > 0 else { return }
        let text = storage.string as NSString
        var found = 0
        var index = 0
        while found < lineCount, index < text.length {
            let next = text.range(of: "\n", range: NSRange(location: index, length: text.length - index))
            if next.location == NSNotFound {
                storage.deleteCharacters(in: NSRange(location: 0, length: text.length))
                return
            }
            found += 1
            index = next.location + next.length
        }
        if index > 0 {
            storage.deleteCharacters(in: NSRange(location: 0, length: index))
        }
    }

    private func applySearchHighlights(_ textView: NSTextView, scrollView: LogScrollView) -> Int {
        guard let storage = textView.textStorage else { return 0 }
        let full = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.backgroundColor, range: full)
        let ranges = LogSearch.ranges(
            in: textView.string,
            query: searchQuery,
            matchCase: searchMatchCase,
            wholeWord: searchWholeWord,
            usesRegex: searchUsesRegex
        )
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
        let ranges = LogSearch.ranges(
            in: textView.string,
            query: searchQuery,
            matchCase: searchMatchCase,
            wholeWord: searchWholeWord,
            usesRegex: searchUsesRegex
        )
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
