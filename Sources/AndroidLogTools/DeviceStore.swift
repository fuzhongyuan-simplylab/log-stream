import Foundation
import Observation

@MainActor
@Observable
final class DeviceStore {
    private(set) var devices: [Device] = []
    var filter: String
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
    private(set) var isRefreshing = false
    private(set) var adbMissing = false
    private(set) var errorMessage: String?
    private(set) var exportNotice: String?
    private(set) var adbPath = ""

    private var lines: [String: [String]] = [:]
    private var raw: [String: [String]] = [:]
    private var streamWarnings: [String: String] = [:]
    private var streams: [String: LogStream] = [:]
    private var intentionalStop: Set<String> = []
    private var paused: Set<String> = []
    private var liveDisabled: Set<String> = []
    private var startedSerials: Set<String> = []
    private var starting: Set<String> = []
    private var client: AdbClient?
    private var didStart = false

    private static let filterKey = "logFilter"
    private static let emulatorSortFieldKey = "emulatorSortField"
    private static let emulatorSortAscendingKey = "emulatorSortAscending"
    private static let physicalSortFieldKey = "physicalSortField"
    private static let physicalSortAscendingKey = "physicalSortAscending"
    private static let rawLimit = 20_000
    private static let rawSlack = 2_000
    private static let shownLimit = 2_000
    private static let shownSlack = 400

    init() {
        let defaults = UserDefaults.standard
        filter = defaults.string(forKey: Self.filterKey) ?? ""
        emulatorSortField = DeviceSortField(rawValue: defaults.string(forKey: Self.emulatorSortFieldKey) ?? "") ?? .connection
        emulatorSortAscending = defaults.object(forKey: Self.emulatorSortAscendingKey) as? Bool ?? true
        physicalSortField = DeviceSortField(rawValue: defaults.string(forKey: Self.physicalSortFieldKey) ?? "") ?? .name
        physicalSortAscending = defaults.object(forKey: Self.physicalSortAscendingKey) as? Bool ?? true
    }

    var emulators: [Device] {
        Device.sorted(devices.filter(\.isEmulator), field: emulatorSortField, ascending: emulatorSortAscending)
    }

    var physicalDevices: [Device] {
        Device.sorted(devices.filter { !$0.isEmulator }, field: physicalSortField, ascending: physicalSortAscending)
    }

    var hasOnlineDevice: Bool {
        devices.contains(where: \.isOnline)
    }

    var canStartAll: Bool {
        devices.contains { $0.isOnline && paused.contains($0.serial) }
    }

    var canPauseAll: Bool {
        devices.contains { $0.isOnline && !paused.contains($0.serial) }
    }

    func isPaused(_ serial: String) -> Bool {
        paused.contains(serial)
    }

    func isLive(_ serial: String) -> Bool {
        !liveDisabled.contains(serial)
    }

    var allDevicesLive: Bool {
        devices.allSatisfy { isLive($0.serial) }
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
        if live {
            guard !liveDisabled.isEmpty else { return }
            liveDisabled = []
        } else {
            let all = Set(devices.map(\.serial))
            guard liveDisabled != all else { return }
            liveDisabled = all
        }
    }

    var summaryText: String {
        if adbMissing {
            return "未找到 adb"
        }
        let filterText: String
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty {
            filterText = "显示全部日志"
        } else {
            filterText = "过滤「\(needle)」"
        }
        let activity = isRefreshing ? "正在刷新…" : filterText
        return "\(emulators.count) 台虚拟机 · \(physicalDevices.count) 台真机 · \(activity)"
    }

    func start() async {
        guard !didStart else { return }
        didStart = true
        if let resolved = AdbClient.resolve() {
            client = resolved
            adbPath = resolved.path
            adbMissing = false
            await refresh()
        } else {
            adbMissing = true
        }
    }

    func refresh() async {
        guard let client else {
            adbMissing = true
            return
        }
        guard !isRefreshing else { return }
        isRefreshing = true
        errorMessage = nil
        exportNotice = nil
        defer { isRefreshing = false }

        do {
            let found = try await client.listDevices()
            let foundIDs = Set(found.map(\.serial))
            for serial in Array(streams.keys) where !foundIDs.contains(serial) {
                stopStream(serial: serial, intentional: true)
            }
            for serial in Array(lines.keys) where !foundIDs.contains(serial) {
                lines[serial] = nil
                raw[serial] = nil
                streamWarnings[serial] = nil
            }
            startedSerials = startedSerials.intersection(foundIDs)
            liveDisabled = liveDisabled.intersection(foundIDs)
            devices = found
            for device in found {
                if device.isOnline && !paused.contains(device.serial) {
                    let fromNow = startedSerials.contains(device.serial)
                    startedSerials.insert(device.serial)
                    await startStream(for: device, fromNow: fromNow)
                } else {
                    stopStream(serial: device.serial, intentional: true)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func filterDidChange() {
        UserDefaults.standard.set(filter, forKey: Self.filterKey)
        refilter()
    }

    func clearLogs(serial: String) async {
        guard let client else { return }
        let name = devices.first(where: { $0.serial == serial })?.name ?? serial
        streams[serial]?.discardPending()
        raw[serial] = []
        lines[serial] = []
        do {
            try await client.clearLogcat(serial: serial)
            raw[serial] = []
            lines[serial] = []
            errorMessage = nil
        } catch {
            errorMessage = "清空 \(name) 失败：\(error.localizedDescription)"
        }
    }

    func clearAllLogs() async {
        guard let client else { return }
        let targets = devices.filter(\.isOnline)
        guard !targets.isEmpty else { return }
        errorMessage = nil
        for device in targets {
            streams[device.serial]?.discardPending()
            raw[device.serial] = []
            lines[device.serial] = []
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
            raw[device.serial] = []
            lines[device.serial] = []
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
        for device in devices where device.isOnline && paused.contains(device.serial) {
            await startRecording(serial: device.serial)
        }
    }

    func pauseAll() {
        for device in devices where device.isOnline && !paused.contains(device.serial) {
            pauseRecording(serial: device.serial)
        }
    }

    func stopAllStreams() {
        for serial in Array(streams.keys) {
            stopStream(serial: serial, intentional: true)
        }
    }

    func logLines(for serial: String) -> [String] {
        lines[serial] ?? []
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
        return "Android日志-\(formatter.string(from: Date())).txt"
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
        lines[serial]?.count ?? 0
    }

    func warning(for serial: String) -> String? {
        streamWarnings[serial]
    }

    private func refilter() {
        let current = filter
        for serial in raw.keys {
            let matched = (raw[serial] ?? []).filter { Self.matches($0, filter: current) }
            lines[serial] = Array(matched.suffix(Self.shownLimit))
        }
    }

    private func startRecording(serial: String) async {
        guard let device = devices.first(where: { $0.serial == serial }), device.isOnline else { return }
        paused.remove(serial)
        startedSerials.insert(serial)
        await startStream(for: device, fromNow: true)
    }

    private func pauseRecording(serial: String) {
        paused.insert(serial)
        streams[serial]?.discardPending()
        stopStream(serial: serial, intentional: true)
    }

    private func append(serial: String, newLines: [String]) {
        guard !paused.contains(serial), !newLines.isEmpty else { return }
        var buffer = raw[serial] ?? []
        buffer.append(contentsOf: newLines)
        if buffer.count > Self.rawLimit + Self.rawSlack {
            buffer.removeFirst(buffer.count - Self.rawLimit)
        }
        raw[serial] = buffer

        var shown = lines[serial] ?? []
        var changed = false
        for line in newLines where Self.matches(line, filter: filter) {
            shown.append(line)
            changed = true
        }
        if shown.count > Self.shownLimit + Self.shownSlack {
            shown.removeFirst(shown.count - Self.shownLimit)
            changed = true
        }
        if changed {
            lines[serial] = shown
        }
    }

    private func startStream(for device: Device, fromNow: Bool) async {
        guard let client, device.isOnline else { return }
        let serial = device.serial
        guard streams[serial] == nil, !starting.contains(serial), !paused.contains(serial) else { return }
        starting.insert(serial)
        defer { starting.remove(serial) }

        let since: String? = if fromNow {
            await client.deviceTimestamp(serial: serial) ?? "1"
        } else {
            nil
        }
        guard streams[serial] == nil, !paused.contains(serial) else { return }

        streamWarnings[serial] = nil
        let stream = LogStream(
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
        do {
            try stream.start(adbPath: client.path, serial: serial, since: since)
            guard !paused.contains(serial) else {
                stream.stop()
                return
            }
            streams[serial] = stream
        } catch {
            errorMessage = "无法读取 \(device.name) 的日志：\(error.localizedDescription)"
        }
    }

    private func stopStream(serial: String, intentional: Bool) {
        if intentional {
            intentionalStop.insert(serial)
        }
        streams[serial]?.stop()
        streams[serial] = nil
    }

    private func streamEnded(serial: String) {
        streams[serial] = nil
        if intentionalStop.remove(serial) != nil {
            return
        }
        streamWarnings[serial] = "日志连接已断开，请点刷新设备"
    }

    private static func matches(_ line: String, filter: String) -> Bool {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty { return true }
        return line.localizedCaseInsensitiveContains(needle)
    }
}
