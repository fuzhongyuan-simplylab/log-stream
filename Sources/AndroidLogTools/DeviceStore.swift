import Foundation
import Observation

@MainActor
@Observable
final class DeviceStore {
    private(set) var devices: [Device] = []
    var filter: String
    private(set) var isRefreshing = false
    private(set) var adbMissing = false
    private(set) var errorMessage: String?
    private(set) var adbPath = ""

    private var lines: [String: [String]] = [:]
    private var raw: [String: [String]] = [:]
    private var streamWarnings: [String: String] = [:]
    private var streams: [String: LogStream] = [:]
    private var intentionalStop: Set<String> = []
    private var client: AdbClient?
    private var didStart = false

    private static let filterKey = "logFilter"
    private static let rawLimit = 20_000
    private static let rawSlack = 2_000
    private static let shownLimit = 2_000
    private static let shownSlack = 400

    init() {
        filter = UserDefaults.standard.string(forKey: Self.filterKey) ?? ""
    }

    var emulators: [Device] {
        devices.filter(\.isEmulator)
    }

    var physicalDevices: [Device] {
        devices.filter { !$0.isEmulator }
    }

    var hasOnlineDevice: Bool {
        devices.contains(where: \.isOnline)
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
            devices = found
            for device in found {
                if device.isOnline {
                    startStream(for: device)
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

    func stopAllStreams() {
        for serial in Array(streams.keys) {
            stopStream(serial: serial, intentional: true)
        }
    }

    func logLines(for serial: String) -> [String] {
        lines[serial] ?? []
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

    private func append(serial: String, newLines: [String]) {
        guard !newLines.isEmpty else { return }
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

    private func startStream(for device: Device) {
        guard let client, device.isOnline, streams[device.serial] == nil else { return }
        let serial = device.serial
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
            try stream.start(adbPath: client.path, serial: serial)
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
