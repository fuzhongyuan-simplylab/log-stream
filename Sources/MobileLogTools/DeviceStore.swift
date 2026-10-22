import Foundation
import Observation

/// 一份设备日志。`revision` 在清空时增加，`dropped` 累计从开头丢掉的行数，用来让文本视图删前缀而不是重写全文。
struct LogSnapshot: Equatable, Sendable {
    private(set) var revision = 0
    private(set) var dropped = 0
    private(set) var lines: [String] = []

    static let limit = 10_000
    static let slack = 2_000

    var count: Int { lines.count }

    mutating func clear() {
        lines.removeAll(keepingCapacity: false)
        dropped = 0
        revision += 1
    }

    mutating func append(_ accepted: [String]) {
        guard !accepted.isEmpty else { return }
        lines.append(contentsOf: accepted)
        let ceiling = Self.limit + Self.slack
        guard lines.count > ceiling else { return }
        let remove = lines.count - Self.limit
        lines.removeFirst(remove)
        dropped += remove
    }
}

@MainActor
@Observable
final class DeviceStore {
    private(set) var devices: [Device] = []
    var filter: String
    var filterUsesRegex: Bool
    private var filtersByPlatform: [DevicePlatform: String] = [:]
    private var filterUsesRegexByPlatform: [DevicePlatform: Bool] = [:]
    var emulatorSortField: DeviceSortField {
        didSet { UserDefaults.standard.set(emulatorSortField.rawValue, forKey: Self.emulatorSortFieldKey) }
    }
    var emulatorSortAscending: Bool {
        didSet { UserDefaults.standard.set(emulatorSortAscending, forKey: Self.emulatorSortAscendingKey) }
    }
    var physicalSortField: DeviceSortField {
        didSet { UserDefaults.standard.set(physicalSortField.rawValue, forKey: Self.physicalSortFieldKey) }
    }
    var physicalSortAscending: Bool {
        didSet { UserDefaults.standard.set(physicalSortAscending, forKey: Self.physicalSortAscendingKey) }
    }
    var iosEmulatorSortField: DeviceSortField {
        didSet { UserDefaults.standard.set(iosEmulatorSortField.rawValue, forKey: Self.iosEmulatorSortFieldKey) }
    }
    var iosEmulatorSortAscending: Bool {
        didSet { UserDefaults.standard.set(iosEmulatorSortAscending, forKey: Self.iosEmulatorSortAscendingKey) }
    }
    var iosPhysicalSortField: DeviceSortField {
        didSet { UserDefaults.standard.set(iosPhysicalSortField.rawValue, forKey: Self.iosPhysicalSortFieldKey) }
    }
    var iosPhysicalSortAscending: Bool {
        didSet { UserDefaults.standard.set(iosPhysicalSortAscending, forKey: Self.iosPhysicalSortAscendingKey) }
    }
    var platform: DevicePlatform {
        didSet { UserDefaults.standard.set(platform.rawValue, forKey: Self.platformKey) }
    }
    private(set) var isRefreshing = false
    private(set) var adbMissing = false
    private(set) var xcrunMissing = false
    private(set) var errorMessage: String?
    private(set) var exportNotice: String?
    private(set) var adbPath = ""

    private var logs: [String: LogSnapshot] = [:]
    private var streamWarnings: [String: String] = [:]
    private var streams: [String: LogStream] = [:]
    private var iosStreams: [String: IOSDeviceLogStream] = [:]
    private var streamPredicates: [String: String] = [:]
    private var streamDebug: [String: Bool] = [:]
    private var includeDebug: [String: Bool] = [:]
    private var intentionalStop: Set<String> = []
    private var paused: Set<String> = []
    private var liveDisabled: Set<String> = []
    private var startedSerials: Set<String> = []
    private var starting: Set<String> = []
    private var iosGeneration: [String: Int] = [:]
    private var iosRestartTasks: [String: Task<Void, Never>] = [:]
    private let streamQueue = StreamStartQueue()
    private var client: AdbClient?
    private var didStart = false
    private var appliedLogcatExpression: String?
    private var filterRegex: NSRegularExpression?
    private var filterGeneration = 0
    /// logcat 一条记录里的换行会被拆开。续行没有时间戳，先拼回原记录再过滤。
    private var openAndroidEntry: [String: String] = [:]
    private var openAndroidEntryFlush: [String: Task<Void, Never>] = [:]
    private static let androidLogHeader = #/^\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} [VDIWEF]\//#

    private static let filterKey = "logFilter"
    private static let filterRegexKey = "logFilterUsesRegex"

    private static func filterTextKey(_ platform: DevicePlatform) -> String {
        "\(filterKey).\(platform.rawValue)"
    }

    private static func filterUsesRegexKey(_ platform: DevicePlatform) -> String {
        "\(filterRegexKey).\(platform.rawValue)"
    }
    private static let emulatorSortFieldKey = "emulatorSortField"
    private static let emulatorSortAscendingKey = "emulatorSortAscending"
    private static let physicalSortFieldKey = "physicalSortField"
    private static let physicalSortAscendingKey = "physicalSortAscending"
    private static let iosEmulatorSortFieldKey = "iosEmulatorSortField"
    private static let iosEmulatorSortAscendingKey = "iosEmulatorSortAscending"
    private static let iosPhysicalSortFieldKey = "iosPhysicalSortField"
    private static let iosPhysicalSortAscendingKey = "iosPhysicalSortAscending"
    private static let platformKey = "logPlatform"
    private static let includeDebugKey = "iosIncludeDebug"

    init() {
        let defaults = UserDefaults.standard
        let storedFilters = Self.loadFilters(from: defaults)
        filtersByPlatform = storedFilters.texts
        filterUsesRegexByPlatform = storedFilters.flags
        emulatorSortField = DeviceSortField(rawValue: defaults.string(forKey: Self.emulatorSortFieldKey) ?? "") ?? .connection
        emulatorSortAscending = defaults.object(forKey: Self.emulatorSortAscendingKey) as? Bool ?? true
        physicalSortField = DeviceSortField(rawValue: defaults.string(forKey: Self.physicalSortFieldKey) ?? "") ?? .name
        physicalSortAscending = defaults.object(forKey: Self.physicalSortAscendingKey) as? Bool ?? true
        iosEmulatorSortField = DeviceSortField(rawValue: defaults.string(forKey: Self.iosEmulatorSortFieldKey) ?? "") ?? .name
        iosEmulatorSortAscending = defaults.object(forKey: Self.iosEmulatorSortAscendingKey) as? Bool ?? true
        iosPhysicalSortField = DeviceSortField(rawValue: defaults.string(forKey: Self.iosPhysicalSortFieldKey) ?? "") ?? .name
        iosPhysicalSortAscending = defaults.object(forKey: Self.iosPhysicalSortAscendingKey) as? Bool ?? true
        let selectedPlatform = DevicePlatform(rawValue: defaults.string(forKey: Self.platformKey) ?? "") ?? .android
        filter = storedFilters.texts[selectedPlatform] ?? ""
        filterUsesRegex = storedFilters.flags[selectedPlatform] ?? false
        platform = selectedPlatform
        if let stored = defaults.dictionary(forKey: Self.includeDebugKey) as? [String: Bool] {
            includeDebug = stored
        }
        appliedLogcatExpression = LogcatFilter.expression(for: filter, usesRegex: filterUsesRegex)
        filterRegex = Self.compiledFilter(filter, usesRegex: filterUsesRegex)
    }

    func appliedFilter(for platform: DevicePlatform) -> String {
        filtersByPlatform[platform] ?? ""
    }

    func appliedFilterUsesRegex(for platform: DevicePlatform) -> Bool {
        filterUsesRegexByPlatform[platform] ?? false
    }

    var visibleDevices: [Device] {
        devices.filter { $0.platform == platform }
    }

    var emulators: [Device] {
        let field = platform == .ios ? iosEmulatorSortField : emulatorSortField
        let ascending = platform == .ios ? iosEmulatorSortAscending : emulatorSortAscending
        return Device.sorted(visibleDevices.filter(\.isEmulator), field: field, ascending: ascending)
    }

    var physicalDevices: [Device] {
        let field = platform == .ios ? iosPhysicalSortField : physicalSortField
        let ascending = platform == .ios ? iosPhysicalSortAscending : physicalSortAscending
        return Device.sorted(visibleDevices.filter { !$0.isEmulator }, field: field, ascending: ascending)
    }

    var hasOnlineDevice: Bool {
        visibleDevices.contains(where: \.isOnline)
    }

    var canStartAll: Bool {
        visibleDevices.contains { device in
            device.isOnline && paused.contains(device.serial)
        }
    }

    var canPauseAll: Bool {
        visibleDevices.contains { $0.isOnline && !paused.contains($0.serial) }
    }

    func isPaused(_ serial: String) -> Bool {
        paused.contains(serial)
    }

    func isLive(_ serial: String) -> Bool {
        !liveDisabled.contains(serial)
    }

    func setLive(_ serial: String, _ live: Bool) {
        var next = liveDisabled
        if live {
            guard next.remove(serial) != nil else { return }
        } else {
            guard next.insert(serial).inserted else { return }
        }
        liveDisabled = next
    }

    func setAllLive(_ live: Bool) {
        let shown = Set(visibleDevices.map(\.serial))
        if live {
            let next = liveDisabled.subtracting(shown)
            guard next != liveDisabled else { return }
            liveDisabled = next
        } else {
            let next = liveDisabled.union(shown)
            guard next != liveDisabled else { return }
            liveDisabled = next
        }
    }

    var allDevicesLive: Bool {
        let shown = visibleDevices
        guard !shown.isEmpty else { return true }
        return shown.allSatisfy { isLive($0.serial) }
    }

    var summaryText: String {
        if platform == .android && adbMissing {
            return "未找到 adb"
        }
        if platform == .ios && xcrunMissing {
            return "未找到 Xcode"
        }
        let filterText: String
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty {
            filterText = "显示全部日志"
        } else {
            filterText = "过滤「\(needle)」"
        }
        let activity = isRefreshing ? "正在刷新…" : filterText
        let simulatorLabel = platform == .ios ? "模拟器" : "虚拟机"
        return "\(emulators.count) 台\(simulatorLabel) · \(physicalDevices.count) 台真机 · \(activity)"
    }

    func start() async {
        guard !didStart else { return }
        didStart = true
        if let resolved = AdbClient.resolve() {
            client = resolved
            adbPath = resolved.path
            adbMissing = false
        } else {
            adbMissing = true
        }
        xcrunMissing = !IOSClient.isAvailable
        await refresh()
    }

    func selectPlatform(_ newPlatform: DevicePlatform, adopting text: String? = nil, usesRegex: Bool = false) async {
        guard newPlatform != platform else { return }
        stopStreams(on: platform)
        platform = newPlatform
        if syncActiveFilter() {
            filterGeneration += 1
        }
        if let text {
            _ = await applyFilter(text, usesRegex: usesRegex)
        }
        for device in visibleDevices where device.isOnline && !paused.contains(device.serial) {
            startedSerials.insert(device.serial)
        }
        await refresh()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        errorMessage = nil
        exportNotice = nil
        adbMissing = client == nil
        xcrunMissing = !IOSClient.isAvailable
        defer { isRefreshing = false }

        async let androidDevices = loadAndroidDevices()
        async let iosDevices = loadIOSDevices()
        let android = await androidDevices
        let ios = await iosDevices
        let found = android.devices + ios.devices
        if let failure = platform == .android ? android.error : ios.error {
            errorMessage = failure
        }
        let foundIDs = Set(found.map(\.serial))
        for serial in Array(streams.keys) + Array(iosStreams.keys) where !foundIDs.contains(serial) {
            stopStream(serial: serial, intentional: true)
        }
        for serial in Array(logs.keys) where !foundIDs.contains(serial) {
            logs[serial] = nil
            streamWarnings[serial] = nil
        }
        startedSerials = startedSerials.intersection(foundIDs)
        liveDisabled = liveDisabled.intersection(foundIDs)
        devices = found
        stopStreams(on: platform == .android ? .ios : .android)
        for device in found where device.platform == platform {
            if device.isOnline && !paused.contains(device.serial) {
                let fromNow = startedSerials.contains(device.serial)
                startedSerials.insert(device.serial)
                // 旧连接可能已经不再出日志，进程却还在。刷新时停掉再开一条。
                await startStream(for: device, fromNow: fromNow, force: true)
            } else if !device.isOnline {
                stopStream(serial: device.serial, intentional: true)
            }
        }
    }

    @discardableResult
    func applyFilter(_ text: String, usesRegex: Bool) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LogcatFilter.isValid(trimmed, usesRegex: usesRegex) else { return false }
        let expression = LogcatFilter.expression(for: trimmed, usesRegex: usesRegex)
        let unchanged = trimmed == filter.trimmingCharacters(in: .whitespacesAndNewlines)
            && (trimmed.isEmpty || usesRegex == filterUsesRegex)
        guard !unchanged else { return false }
        filter = trimmed
        filterUsesRegex = usesRegex
        filtersByPlatform[platform] = trimmed
        filterUsesRegexByPlatform[platform] = usesRegex
        UserDefaults.standard.set(trimmed, forKey: Self.filterTextKey(platform))
        UserDefaults.standard.set(usesRegex, forKey: Self.filterUsesRegexKey(platform))
        appliedLogcatExpression = expression
        filterRegex = Self.compiledFilter(filter, usesRegex: usesRegex)
        filterGeneration += 1
        for device in visibleDevices {
            clearStoredLog(device.serial)
        }
        for device in visibleDevices where device.isOnline && !paused.contains(device.serial) {
            streams[device.serial]?.discardPending()
            iosStreams[device.serial]?.discardPending()
            stopStream(serial: device.serial, intentional: true)
            await startStream(for: device, fromNow: false, force: true)
        }
        return true
    }

    func clearLogs(serial: String) async {
        guard let device = devices.first(where: { $0.serial == serial }) else { return }
        streams[serial]?.discardPending()
        iosStreams[serial]?.discardPending()
        clearStoredLog(serial)
        guard device.platform == .android else {
            errorMessage = nil
            return
        }
        guard let client else { return }
        do {
            try await client.clearLogcat(serial: serial)
            clearStoredLog(serial)
            errorMessage = nil
        } catch {
            errorMessage = "清空 \(device.name) 失败：\(error.localizedDescription)"
        }
    }

    func clearAllLogs() async {
        let targets = visibleDevices.filter(\.isOnline)
        guard !targets.isEmpty else { return }
        errorMessage = nil
        if platform == .ios {
            for device in targets {
                iosStreams[device.serial]?.discardPending()
                streams[device.serial]?.discardPending()
                clearStoredLog(device.serial)
            }
            return
        }
        guard let client else { return }
        for device in targets {
            streams[device.serial]?.discardPending()
            clearStoredLog(device.serial)
        }

        var failures: [String] = []
        await withTaskGroup(of: String?.self) { group in
            for device in targets {
                group.addTask {
                    do {
                        try await client.clearLogcat(serial: device.serial)
                        return nil
                    } catch {
                        return "\(device.name)：\(error.localizedDescription)"
                    }
                }
            }
            for await failure in group {
                if let failure {
                    failures.append(failure)
                }
            }
        }

        for device in targets {
            clearStoredLog(device.serial)
        }
        if !failures.isEmpty {
            errorMessage = failures.joined(separator: " ")
        }
    }

    func toggleRecording(serial: String) async {
        if paused.contains(serial) {
            await startRecording(serial: serial)
        } else {
            pauseRecording(serial: serial)
        }
    }

    func startAll() async {
        for device in visibleDevices where device.isOnline && paused.contains(device.serial) {
            await startRecording(serial: device.serial)
        }
    }

    func pauseAll() {
        for device in visibleDevices where device.isOnline && !paused.contains(device.serial) {
            pauseRecording(serial: device.serial)
        }
    }

    func stopAllStreams() {
        for serial in Set(streams.keys).union(iosStreams.keys) {
            stopStream(serial: serial, intentional: true)
        }
    }

    func includesDebug(_ serial: String) -> Bool {
        includeDebug[serial] ?? false
    }

    func setIncludesDebug(serial: String, enabled: Bool) async {
        includeDebug[serial] = enabled
        UserDefaults.standard.set(includeDebug, forKey: Self.includeDebugKey)
        clearStoredLog(serial)
        guard let device = devices.first(where: { $0.serial == serial }),
              device.platform == platform,
              device.isOnline,
              !paused.contains(serial) else {
            return
        }
        scheduleIOSRestart(for: device)
    }

    func logSnapshot(for serial: String) -> LogSnapshot {
        logs[serial] ?? LogSnapshot()
    }

    func logLines(for serial: String) -> [String] {
        logSnapshot(for: serial).lines
    }

    func exportText(for devices: [Device]) -> String {
        devices.map { exportSection($0) }.joined(separator: "\n\n========\n\n")
    }

    func exportFileName(for device: Device) -> String {
        "\(Self.safeFileName(device.name))-\(Self.safeFileName(device.serial)).txt"
    }

    func combinedExportFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "Logstream-\(formatter.string(from: Date())).txt"
    }

    func noteExport(_ message: String) {
        exportNotice = message
        errorMessage = nil
    }

    func reportExportFailure(_ message: String) {
        errorMessage = message
        exportNotice = nil
    }

    private func exportSection(_ device: Device) -> String {
        let exportedLines = logLines(for: device.serial)
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let status: String
        if !device.isOnline {
            status = device.stateLabel
        } else if isPaused(device.serial) {
            status = "已暂停"
        } else {
            status = "记录中"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let body = exportedLines.isEmpty ? "（暂无日志）" : exportedLines.joined(separator: "\n")
        return """
        设备: \(device.name)
        类型: \(device.kindLabel)
        序列号: \(device.serial)
        系统: \(device.versionLabel)
        状态: \(status)
        过滤: \(needle.isEmpty ? "（无）" : needle)
        导出时间: \(formatter.string(from: Date()))
        日志行数: \(exportedLines.count)

        \(body)
        """
    }

    private static func safeFileName(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r")
        let cleaned = String(value.unicodeScalars.map { forbidden.contains($0) ? "_" : Character($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "device" : cleaned
    }

    func lineCount(for serial: String) -> Int {
        logs[serial]?.count ?? 0
    }

    private func clearStoredLog(_ serial: String) {
        discardOpenAndroidEntry(serial)
        var snapshot = logs[serial] ?? LogSnapshot()
        snapshot.clear()
        logs[serial] = snapshot
    }

    func warning(for serial: String) -> String? {
        streamWarnings[serial]
    }

    private func startRecording(serial: String) async {
        guard let device = devices.first(where: { $0.serial == serial }), device.isOnline else { return }
        paused.remove(serial)
        streamWarnings[serial] = nil
        startedSerials.insert(serial)
        await startStream(for: device, fromNow: true)
    }

    private func pauseRecording(serial: String) {
        paused.insert(serial)
        flushOpenAndroidEntry(serial)
        streams[serial]?.discardPending()
        iosStreams[serial]?.discardPending()
        stopStream(serial: serial, intentional: true)
    }

    private func append(serial: String, newLines: [String]) {
        guard !paused.contains(serial) else { return }
        if devices.first(where: { $0.serial == serial })?.platform == .android {
            appendAndroid(serial: serial, newLines: newLines)
            return
        }
        let accepted = newLines.filter { matches($0) }
        guard !accepted.isEmpty else { return }
        var snapshot = logs[serial] ?? LogSnapshot()
        snapshot.append(accepted)
        logs[serial] = snapshot
    }

    /// `logcat -v time` 的新记录以 `MM-DD HH:MM:SS.mmm L/` 开头。没有这个前缀的行是上一条的续行。
    private static func isAndroidLogHeader(_ line: String) -> Bool {
        line.starts(with: androidLogHeader)
    }

    private func appendAndroid(serial: String, newLines: [String]) {
        var ready: [String] = []
        var current = openAndroidEntry[serial]
        for line in newLines {
            if Self.isAndroidLogHeader(line) {
                if let current {
                    ready.append(current)
                }
                current = line
            } else if let existing = current {
                current = existing + "\n" + line
            } else {
                current = line
            }
        }
        openAndroidEntry[serial] = current
        commitAndroid(serial: serial, entries: ready)
        scheduleAndroidEntryFlush(serial)
    }

    private func commitAndroid(serial: String, entries: [String]) {
        let accepted = entries.filter { matches($0) }
        guard !accepted.isEmpty else { return }
        var snapshot = logs[serial] ?? LogSnapshot()
        snapshot.append(accepted)
        logs[serial] = snapshot
    }

    private func scheduleAndroidEntryFlush(_ serial: String) {
        openAndroidEntryFlush[serial]?.cancel()
        openAndroidEntryFlush[serial] = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            flushOpenAndroidEntry(serial)
        }
    }

    private func flushOpenAndroidEntry(_ serial: String) {
        openAndroidEntryFlush[serial]?.cancel()
        openAndroidEntryFlush[serial] = nil
        guard let entry = openAndroidEntry.removeValue(forKey: serial) else { return }
        commitAndroid(serial: serial, entries: [entry])
    }

    private func discardOpenAndroidEntry(_ serial: String) {
        openAndroidEntryFlush[serial]?.cancel()
        openAndroidEntryFlush[serial] = nil
        openAndroidEntry[serial] = nil
    }

    private func startStream(for device: Device, fromNow: Bool, force: Bool = false) async {
        if device.platform == .ios {
            await startIOSStream(for: device, force: force)
            return
        }
        guard let client, device.isOnline else { return }
        let serial = device.serial
        guard !paused.contains(serial) else { return }
        if !force {
            guard streams[serial] == nil, !starting.contains(serial) else { return }
        }
        let token = filterGeneration
        starting.insert(serial)
        defer { starting.remove(serial) }

        let since: String? = if fromNow {
            await client.deviceTimestamp(serial: serial) ?? "1"
        } else {
            nil
        }
        guard token == filterGeneration, !paused.contains(serial) else { return }
        if force || streams[serial] != nil {
            streams[serial]?.discardPending()
            stopStream(serial: serial, intentional: true)
        }
        guard streams[serial] == nil else { return }

        streamWarnings[serial] = nil
        let pattern = LogcatFilter.expression(for: filter, usesRegex: filterUsesRegex)
        let tail = since ?? (pattern == nil ? "300" : "20000")
        var arguments = ["-s", serial, "logcat", "-v", "time", "-T", tail]
        if let pattern {
            arguments.append(contentsOf: ["-e", pattern])
        }
        let stream = makeLogStream(serial: serial)
        do {
            try stream.start(executable: client.path, arguments: arguments)
            guard token == filterGeneration, !paused.contains(serial) else {
                stream.stop()
                return
            }
            streams[serial] = stream
        } catch {
            errorMessage = "无法读取 \(device.name) 的日志：\(error.localizedDescription)"
        }
    }

    private func startIOSStream(for device: Device, force: Bool) async {
        guard device.isOnline else { return }
        let serial = device.serial
        guard !paused.contains(serial) else { return }
        let predicate = IOSLogFilter.format(matching: filter, usesRegex: filterUsesRegex)
        let predicateKey = predicate ?? ""
        let debug = includeDebug[serial] ?? false
        let running = streams[serial] != nil || iosStreams[serial] != nil
        if !force, running, streamPredicates[serial] == predicateKey, streamDebug[serial] == debug, !starting.contains(serial) {
            return
        }
        let token = filterGeneration
        if running {
            stopStream(serial: serial, intentional: true)
        }
        guard !starting.contains(serial) else { return }
        starting.insert(serial)
        defer { starting.remove(serial) }
        guard token == filterGeneration, !paused.contains(serial) else { return }
        streamWarnings[serial] = nil
        if device.isEmulator {
            let stream = makeLogStream(serial: serial)
            do {
                try stream.start(
                    executable: IOSClient.xcrunPath,
                    arguments: IOSClient.simulatorArguments(udid: serial, predicate: predicate, includeDebug: debug)
                )
                guard token == filterGeneration, !paused.contains(serial) else {
                    stream.stop()
                    return
                }
                streams[serial] = stream
                streamPredicates[serial] = predicateKey
                streamDebug[serial] = debug
            } catch {
                streamWarnings[serial] = "无法读取 \(device.name) 的日志：\(error.localizedDescription)"
            }
        } else {
            let cutoff = Date()
            iosGeneration[serial, default: 0] += 1
            let generation = iosGeneration[serial] ?? 0
            let stream = IOSDeviceLogStream(
                onLines: { [weak self] lines in
                    Task { @MainActor in
                        guard self?.iosGeneration[serial] == generation else { return }
                        self?.append(serial: serial, newLines: lines)
                    }
                },
                onEnd: { [weak self] in
                    Task { @MainActor in
                        guard self?.iosGeneration[serial] == generation else { return }
                        self?.streamEnded(serial: serial)
                    }
                }
            )
            await streamQueue.enqueue(serial: serial) { [stream] in
                let previous = await MainActor.run { () -> IOSDeviceLogStream? in
                    guard self.iosGeneration[serial] == generation else { return nil }
                    return self.iosStreams.removeValue(forKey: serial)
                }
                previous?.stop()
                let proceed = await MainActor.run {
                    self.iosGeneration[serial] == generation && !self.paused.contains(serial) && self.filterGeneration == token
                }
                guard proceed else { return }
                do {
                    try stream.start(udid: serial, predicate: predicate, includeDebug: debug, cutoff: cutoff)
                } catch {
                    await MainActor.run {
                        guard self.iosGeneration[serial] == generation else { return }
                        self.streamWarnings[serial] = error.localizedDescription
                    }
                    return
                }
                let accepted = await MainActor.run { () -> Bool in
                    guard self.iosGeneration[serial] == generation,
                          !self.paused.contains(serial),
                          self.filterGeneration == token else {
                        return false
                    }
                    self.iosStreams[serial] = stream
                    self.streamPredicates[serial] = predicateKey
                    self.streamDebug[serial] = debug
                    self.streamWarnings[serial] = nil
                    return true
                }
                if !accepted {
                    stream.stop()
                }
            }
        }
    }

    private func scheduleIOSRestart(for device: Device) {
        let serial = device.serial
        iosRestartTasks[serial]?.cancel()
        iosRestartTasks[serial] = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await startIOSStream(for: device, force: true)
        }
    }

    private func makeLogStream(serial: String) -> LogStream {
        LogStream(
            onLines: { [weak self] lines in
                Task { @MainActor in
                    self?.append(serial: serial, newLines: lines)
                }
            },
            onEnd: { [weak self] in
                Task { @MainActor in
                    self?.streamEnded(serial: serial)
                }
            }
        )
    }

    private func stopStream(serial: String, intentional: Bool) {
        if intentional {
            intentionalStop.insert(serial)
        }
        iosGeneration[serial, default: 0] += 1
        iosRestartTasks[serial]?.cancel()
        iosRestartTasks[serial] = nil
        streams[serial]?.stop()
        streams[serial] = nil
        let physical = iosStreams.removeValue(forKey: serial)
        streamPredicates[serial] = nil
        streamDebug[serial] = nil
        guard let physical else { return }
        Task { @MainActor in
            await streamQueue.enqueue(serial: serial) {
                physical.stop()
            }
        }
    }

    private func streamEnded(serial: String) {
        if intentionalStop.remove(serial) != nil {
            return
        }
        streams[serial] = nil
        iosStreams[serial] = nil
        streamPredicates[serial] = nil
        streamDebug[serial] = nil
        streamWarnings[serial] = "日志连接已断开，请点刷新设备"
    }

    private func loadAndroidDevices() async -> (devices: [Device], error: String?) {
        guard let client else { return ([], nil) }
        do {
            return (try await client.listDevices(), nil)
        } catch {
            return (devices.filter { $0.platform == .android }, error.localizedDescription)
        }
    }

    private func loadIOSDevices() async -> (devices: [Device], error: String?) {
        guard IOSClient.isAvailable else { return ([], nil) }
        do {
            return (try await IOSClient.listDevices(), nil)
        } catch {
            return (devices.filter { $0.platform == .ios }, error.localizedDescription)
        }
    }

    private static func loadFilters(from defaults: UserDefaults) -> (texts: [DevicePlatform: String], flags: [DevicePlatform: Bool]) {
        let legacyText = defaults.string(forKey: filterKey) ?? ""
        let legacyRegex = defaults.bool(forKey: filterRegexKey)
        var texts: [DevicePlatform: String] = [:]
        var flags: [DevicePlatform: Bool] = [:]
        for item in DevicePlatform.allCases {
            let textKey = filterTextKey(item)
            let regexKey = filterUsesRegexKey(item)
            if defaults.object(forKey: textKey) == nil {
                defaults.set(legacyText, forKey: textKey)
                defaults.set(legacyRegex, forKey: regexKey)
            }
            texts[item] = defaults.string(forKey: textKey) ?? ""
            flags[item] = defaults.bool(forKey: regexKey)
        }
        return (texts, flags)
    }

    @discardableResult
    private func syncActiveFilter() -> Bool {
        let text = filtersByPlatform[platform] ?? ""
        let usesRegex = filterUsesRegexByPlatform[platform] ?? false
        let changed = text != filter || usesRegex != filterUsesRegex
        filter = text
        filterUsesRegex = usesRegex
        appliedLogcatExpression = LogcatFilter.expression(for: text, usesRegex: usesRegex)
        filterRegex = Self.compiledFilter(text, usesRegex: usesRegex)
        return changed
    }

    private func stopStreams(on platform: DevicePlatform) {
        for device in devices where device.platform == platform {
            stopStream(serial: device.serial, intentional: true)
        }
    }

    private func matches(_ line: String) -> Bool {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty { return true }
        if filterUsesRegex {
            guard let filterRegex else { return false }
            let range = NSRange(line.startIndex..., in: line)
            return filterRegex.firstMatch(in: line, range: range) != nil
        }
        return line.localizedCaseInsensitiveContains(needle)
    }

    private static func compiledFilter(_ filter: String, usesRegex: Bool) -> NSRegularExpression? {
        guard usesRegex else { return nil }
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: needle)
    }
}

private actor StreamStartQueue {
    private var tails: [String: Task<Void, Never>] = [:]

    func enqueue(serial: String, operation: @escaping @Sendable () async -> Void) {
        let previous = tails[serial]
        tails[serial] = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
    }
}
