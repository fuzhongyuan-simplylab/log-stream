import Darwin
import Foundation
import os

struct Device: Identifiable, Hashable, Sendable {
    var id: String { serial }
    var serial: String
    var state: String
    var name: String
    var androidVersion: String
    var apiLevel: String
    var isEmulator: Bool

    var isOnline: Bool { state == "device" }

    var kindLabel: String { isEmulator ? "虚拟机" : "真机" }

    var symbolName: String { isEmulator ? "desktopcomputer" : "iphone" }

    var versionLabel: String {
        "Android \(androidVersion) · API \(apiLevel)"
    }

    var stateLabel: String {
        switch state {
        case "device":
            return "在线"
        case "unauthorized":
            return "未授权"
        case "offline":
            return "离线"
        case "no", "no permissions":
            return "无权限"
        default:
            return state
        }
    }

    var emulatorPort: Int? {
        guard serial.hasPrefix("emulator-"),
              let value = serial.split(separator: "-").last,
              let port = Int(value) else {
            return nil
        }
        return port
    }

    static func sorted(_ devices: [Device], field: DeviceSortField, ascending: Bool) -> [Device] {
        devices.sorted { lhs, rhs in
            lhs.comesBefore(rhs, field: field, ascending: ascending)
        }
    }

    fileprivate func comesBefore(_ other: Device, field: DeviceSortField, ascending: Bool) -> Bool {
        let missingSelf = field.isMissing(self)
        let missingOther = field.isMissing(other)
        if missingSelf != missingOther {
            return !missingSelf
        }
        let comparison = field.compare(self, other)
        if comparison == .orderedSame {
            return serial < other.serial
        }
        return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
    }
}

enum DeviceSortField: String, CaseIterable, Identifiable, Sendable {
    case name
    case api
    case androidVersion
    case connection

    var id: String { rawValue }

    func title(isEmulator: Bool) -> String {
        switch self {
        case .name:
            return "名称"
        case .api:
            return "API"
        case .androidVersion:
            return "Android 版本"
        case .connection:
            return isEmulator ? "端口" : "序列号"
        }
    }

    fileprivate func isMissing(_ device: Device) -> Bool {
        switch self {
        case .name:
            return device.name.isEmpty
        case .api:
            return Int(device.apiLevel) == nil
        case .androidVersion:
            return Self.versionNumbers(device.androidVersion) == nil
        case .connection:
            return false
        }
    }

    fileprivate func compare(_ lhs: Device, _ rhs: Device) -> ComparisonResult {
        switch self {
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name)
        case .api:
            let left = Int(lhs.apiLevel) ?? 0
            let right = Int(rhs.apiLevel) ?? 0
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
            return .orderedSame
        case .androidVersion:
            let left = Self.versionNumbers(lhs.androidVersion) ?? []
            let right = Self.versionNumbers(rhs.androidVersion) ?? []
            return Self.compareVersions(left, right)
        case .connection:
            if let left = lhs.emulatorPort, let right = rhs.emulatorPort {
                if left < right { return .orderedAscending }
                if left > right { return .orderedDescending }
                return .orderedSame
            }
            return lhs.serial.localizedStandardCompare(rhs.serial)
        }
    }

    private static func versionNumbers(_ version: String) -> [Int]? {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "未知" {
            return nil
        }
        let parts = trimmed.split(separator: ".").map { Int($0) }
        if parts.isEmpty || parts.contains(where: { $0 == nil }) {
            return nil
        }
        return parts.compactMap { $0 }
    }

    private static func compareVersions(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
        }
        return .orderedSame
    }
}

struct ShellOutput: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
}

enum AdbError: LocalizedError {
    case timedOut(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .timedOut(let command):
            return "命令超时：\(command)"
        case .commandFailed(let message):
            return message
        }
    }
}

final class AdbClient: Sendable {
    let path: String

    init(path: String) {
        self.path = path
    }

    static func resolve() -> AdbClient? {
        var candidates: [String] = []
        let env = ProcessInfo.processInfo.environment
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let root = env[key], !root.isEmpty {
                candidates.append((root as NSString).appendingPathComponent("platform-tools/adb"))
            }
        }
        let home = NSHomeDirectory()
        candidates.append(contentsOf: [
            "\(home)/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb"
        ])
        if let found = which("adb") {
            candidates.append(found)
        }
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return AdbClient(path: candidate)
        }
        return nil
    }

    func listDevices() async throws -> [Device] {
        let result = try await run(["devices", "-l"], timeout: 10)
        guard result.status == 0 else {
            throw AdbError.commandFailed(Self.failureMessage(result, fallback: "adb devices 失败"))
        }
        let entries = Self.parseDeviceList(result.stdout)
        var devices: [Device] = []
        await withTaskGroup(of: Device.self) { group in
            for entry in entries {
                group.addTask {
                    await self.inspect(serial: entry.serial, state: entry.state)
                }
            }
            for await device in group {
                devices.append(device)
            }
        }
        return Self.sorted(devices)
    }

    func clearLogcat(serial: String) async throws {
        let result = try await run(["-s", serial, "logcat", "-c"], timeout: 8)
        guard result.status == 0 else {
            throw AdbError.commandFailed(Self.failureMessage(result, fallback: "清空失败"))
        }
    }

    func deviceTimestamp(serial: String) async -> String? {
        guard let result = try? await run(
            ["-s", serial, "shell", "date '+%m-%d %H:%M:%S.000'"],
            timeout: 5
        ), result.status == 0 else {
            return nil
        }
        let stamp = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard stamp.range(of: #"^\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return stamp
    }

    func run(_ arguments: [String], timeout: TimeInterval) async throws -> ShellOutput {
        let path = self.path
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let group = DispatchGroup()
                let outData = OSAllocatedUnfairLock(initialState: Data())
                let errData = OSAllocatedUnfairLock(initialState: Data())

                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    let data = stdout.fileHandleForReading.readDataToEndOfFile()
                    outData.withLock { $0 = data }
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    let data = stderr.fileHandleForReading.readDataToEndOfFile()
                    errData.withLock { $0 = data }
                    group.leave()
                }

                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                let timedOut = process.isRunning
                if process.isRunning {
                    process.terminate()
                    let killDeadline = Date().addingTimeInterval(0.4)
                    while process.isRunning && Date() < killDeadline {
                        Thread.sleep(forTimeInterval: 0.02)
                    }
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
                process.waitUntilExit()
                group.wait()

                let output = ShellOutput(
                    status: process.terminationStatus,
                    stdout: Self.normalize(outData.withLock { $0 }),
                    stderr: Self.normalize(errData.withLock { $0 })
                )

                if timedOut && output.stdout.isEmpty {
                    continuation.resume(throwing: AdbError.timedOut(arguments.joined(separator: " ")))
                    return
                }
                continuation.resume(returning: output)
            }
        }
    }

    static func parseDeviceList(_ output: String) -> [(serial: String, state: String)] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("List of devices") || trimmed.hasPrefix("*") {
                return nil
            }
            let parts = trimmed.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2 else { return nil }
            let token = String(parts[1])
            let state = token == "no" ? "no permissions" : token
            return (String(parts[0]), state)
        }
    }

    static func parseAvdName(_ output: String) -> String? {
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let lower = line.lowercased()
            if lower == "ok" || lower.hasPrefix("android console") || lower.hasPrefix("error") {
                continue
            }
            return line
        }
        return nil
    }

    private func inspect(serial: String, state: String) async -> Device {
        let fallbackEmulator = serial.hasPrefix("emulator-")
        guard state == "device" else {
            return Device(
                serial: serial,
                state: state,
                name: serial,
                androidVersion: "未知",
                apiLevel: "未知",
                isEmulator: fallbackEmulator
            )
        }

        let script = [
            "getprop ro.boot.qemu.avd_name",
            "getprop ro.product.model",
            "getprop ro.product.marketname",
            "getprop ro.build.version.release",
            "getprop ro.build.version.sdk",
            "getprop ro.kernel.qemu",
            "getprop ro.boot.qemu",
            "getprop ro.hardware"
        ].joined(separator: "; ")

        do {
            let result = try await run(["-s", serial, "shell", script], timeout: 8)
            let values = Self.propLines(result.stdout)
            let avd = Self.value(values, 0)
            let model = Self.value(values, 1)
            let market = Self.value(values, 2)
            let release = Self.value(values, 3)
            let sdk = Self.value(values, 4)
            let qemu = Self.value(values, 5)
            let boot = Self.value(values, 6)
            let hardware = Self.value(values, 7)
            let isEmulator = fallbackEmulator
                || qemu == "1"
                || boot == "1"
                || hardware == "ranchu"
                || hardware == "goldfish"

            var name = ""
            if isEmulator {
                if let emuName = await emulatorName(serial: serial) {
                    name = emuName
                } else if !avd.isEmpty {
                    name = avd
                } else {
                    name = model
                }
            } else if !market.isEmpty {
                name = market
            } else {
                name = model
            }
            if name.isEmpty { name = serial }

            return Device(
                serial: serial,
                state: state,
                name: name,
                androidVersion: release.isEmpty ? "未知" : release,
                apiLevel: sdk.isEmpty ? "未知" : sdk,
                isEmulator: isEmulator
            )
        } catch {
            return Device(
                serial: serial,
                state: state,
                name: serial,
                androidVersion: "未知",
                apiLevel: "未知",
                isEmulator: fallbackEmulator
            )
        }
    }

    private func emulatorName(serial: String) async -> String? {
        guard serial.hasPrefix("emulator-") else { return nil }
        guard let result = try? await run(["-s", serial, "emu", "avd", "name"], timeout: 5) else {
            return nil
        }
        guard result.status == 0 else { return nil }
        return Self.parseAvdName(result.stdout)
    }

    private static func propLines(_ output: String) -> [String] {
        var lines = output.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines
    }

    private static func value(_ lines: [String], _ index: Int) -> String {
        guard lines.indices.contains(index) else { return "" }
        return lines[index]
    }

    private static func sorted(_ devices: [Device]) -> [Device] {
        devices.sorted { lhs, rhs in
            if lhs.isEmulator != rhs.isEmulator {
                return lhs.isEmulator && !rhs.isEmulator
            }
            if lhs.isEmulator {
                let order = port(lhs.serial) - port(rhs.serial)
                if order != 0 { return order < 0 }
            }
            let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return lhs.serial < rhs.serial
        }
    }

    private static func port(_ serial: String) -> Int {
        guard let value = serial.split(separator: "-").last, let port = Int(value) else {
            return Int.max
        }
        return port
    }

    private static func normalize(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func failureMessage(_ result: ShellOutput, fallback: String) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdout.isEmpty { return stdout }
        return fallback
    }

    private static func which(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        var env = ProcessInfo.processInfo.environment
        let prefix = [
            "\(NSHomeDirectory())/Library/Android/sdk/platform-tools",
            "/opt/homebrew/bin",
            "/usr/local/bin"
        ].joined(separator: ":")
        env["PATH"] = prefix + ":" + (env["PATH"] ?? "")
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }
}

final class LogStream: @unchecked Sendable {
    private let process = Process()
    private let pipe = Pipe()
    private let lock = NSLock()
    private var leftover = Data()
    private var pending: [String] = []
    private var flushScheduled = false
    private var stopped = false
    private let onLines: @Sendable ([String]) -> Void
    private let onEnd: @Sendable () -> Void

    init(onLines: @escaping @Sendable ([String]) -> Void, onEnd: @escaping @Sendable () -> Void) {
        self.onLines = onLines
        self.onEnd = onEnd
    }

    func start(adbPath: String, serial: String, since: String?) throws {
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = ["-s", serial, "logcat", "-v", "time", "-T", since ?? "300"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if data.isEmpty {
                self.handleEOF()
                return
            }
            self.consume(data)
        }
        try process.run()
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        pipe.fileHandleForReading.readabilityHandler = nil
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { [process] in
            if process.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }

    func discardPending() {
        lock.lock()
        pending.removeAll()
        leftover.removeAll()
        lock.unlock()
    }

    private func handleEOF() {
        lock.lock()
        let shouldNotify = !stopped
        stopped = true
        let lines = pending
        pending.removeAll()
        flushScheduled = false
        lock.unlock()
        if shouldNotify, !lines.isEmpty {
            onLines(lines)
        }
        if shouldNotify {
            onEnd()
        }
    }

    private func consume(_ data: Data) {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        leftover.append(data)
        while let newline = leftover.firstIndex(of: 0x0A) {
            let lineData = leftover.subdata(in: 0..<newline)
            leftover.removeSubrange(0...newline)
            var text = String(decoding: lineData, as: UTF8.self)
            if text.hasSuffix("\r") {
                text.removeLast()
            }
            if !text.isEmpty {
                pending.append(text)
            }
        }
        let schedule = !flushScheduled && !pending.isEmpty
        if schedule {
            flushScheduled = true
        }
        lock.unlock()
        if schedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.flush()
            }
        }
    }

    private func flush() {
        lock.lock()
        flushScheduled = false
        guard !stopped else {
            pending.removeAll()
            lock.unlock()
            return
        }
        let lines = pending
        pending.removeAll()
        lock.unlock()
        if !lines.isEmpty {
            onLines(lines)
        }
    }
}
