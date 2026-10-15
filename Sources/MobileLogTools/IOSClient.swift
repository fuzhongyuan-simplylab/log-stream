import Darwin
import Foundation
import os

struct InstalledApp: Identifiable, Hashable, Sendable {
    var id: String { bundleIdentifier }
    var bundleIdentifier: String
    var name: String
    var processName: String
}

enum IOSClient {
    static let xcrunPath = "/usr/bin/xcrun"

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: xcrunPath)
    }

    static func listDevices() async throws -> [Device] {
        let result = try await run(["devicectl", "list", "devices", "--json-output", "-", "--timeout", "20", "--quiet"], timeout: 25)
        guard result.status == 0 else {
            throw IOSClientError.commandFailed(failureMessage(result, fallback: "无法列出 iOS 设备"))
        }
        let parsed = parseDevices(Data(result.stdout.utf8))
        let reachable = IOSDeviceLogStream.reachableUDIDs()
        return parsed.map { device in
            guard !device.isEmulator, reachable.contains(device.serial) else { return device }
            var online = device
            online.state = "device"
            return online
        }
    }

    static func listApps(udid: String) async throws -> [InstalledApp] {
        let result = try await run(
            ["devicectl", "device", "info", "apps", "--device", udid, "--json-output", "-", "--timeout", "30", "--quiet"],
            timeout: 35
        )
        guard result.status == 0 else {
            throw IOSClientError.commandFailed(failureMessage(result, fallback: "无法读取应用列表"))
        }
        return parseApps(Data(result.stdout.utf8))
    }

    static func simulatorArguments(udid: String, processNames: [String], includeDebug: Bool) -> [String] {
        [
            "simctl", "spawn", udid,
            "log", "stream",
            "--style", "syslog",
            "--color", "none",
            "--level", includeDebug ? "debug" : "info",
            "--predicate", processPredicate(processNames)
        ]
    }

    static func processPredicate(_ names: [String]) -> String {
        names.map { name in
            "process == \"\(escapePredicate(name))\""
        }.joined(separator: " OR ")
    }

    private static func escapePredicate(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func run(_ arguments: [String], timeout: TimeInterval) async throws -> ShellOutput {
        let path = xcrunPath
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
                    stdout: String(decoding: outData.withLock { $0 }, as: UTF8.self)
                        .replacingOccurrences(of: "\r\n", with: "\n")
                        .replacingOccurrences(of: "\r", with: "\n"),
                    stderr: String(decoding: errData.withLock { $0 }, as: UTF8.self)
                        .replacingOccurrences(of: "\r\n", with: "\n")
                        .replacingOccurrences(of: "\r", with: "\n")
                )
                if timedOut && output.stdout.isEmpty {
                    continuation.resume(throwing: IOSClientError.timedOut(arguments.joined(separator: " ")))
                    return
                }
                continuation.resume(returning: output)
            }
        }
    }

    private static func parseDevices(_ data: Data) -> [Device] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let entries = result["devices"] as? [[String: Any]] else {
            return []
        }
        return entries.compactMap(device(from:))
    }

    private static func device(from entry: [String: Any]) -> Device? {
        let properties = entry["properties"] as? [String: Any] ?? [:]
        let hardware = dictionary(properties["hardware"]) ?? dictionary(entry["hardwareProperties"]) ?? [:]
        let info = dictionary(entry["deviceProperties"]) ?? [:]
        let connection = dictionary(properties["connection"]) ?? dictionary(entry["connectionProperties"]) ?? [:]
        guard string(hardware["platform"]) == "iOS" else { return nil }
        let udid = string(hardware["udid"])
        guard !udid.isEmpty else { return nil }
        let reality = string(hardware["reality"])
        let isSimulator = reality == "simulated"
        let connectionState = string(connection["state"])
        let tunnelState = string(connection["tunnelState"])
        let bootState = string(info["bootState"])
        let transport = string(connection["transportType"])
        let connected = connectionState == "connected" || tunnelState == "connected" || (isSimulator && bootState == "booted")
        if isSimulator && !connected {
            return nil
        }
        let marketing = string(hardware["marketingName"])
        let name = string(info["name"])
        let displayName = !name.isEmpty ? name : (!marketing.isEmpty ? marketing : udid)
        let version = string(info["osVersionNumber"])
        let product = string(hardware["deviceType"])
        return Device(
            platform: .ios,
            serial: udid,
            state: connected ? "device" : "offline",
            name: displayName,
            androidVersion: version.isEmpty ? "未知" : version,
            apiLevel: "",
            isEmulator: isSimulator,
            productType: product,
            transport: transport
        )
    }

    private static func parseApps(_ data: Data) -> [InstalledApp] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let apps = result["apps"] as? [[String: Any]] else {
            return []
        }
        var seen: Set<String> = []
        var parsed: [InstalledApp] = []
        for app in apps {
            let bundleID = string(app["bundleIdentifier"])
            guard !bundleID.isEmpty, seen.insert(bundleID).inserted else { continue }
            let name = string(app["name"])
            let process = processName(url: string(app["url"]), fallback: name.isEmpty ? bundleID : name)
            parsed.append(InstalledApp(
                bundleIdentifier: bundleID,
                name: name.isEmpty ? process : name,
                processName: process
            ))
        }
        return parsed.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func processName(url: String, fallback: String) -> String {
        var path = url
        if path.hasSuffix("/") {
            path.removeLast()
        }
        let last = (path as NSString).lastPathComponent
        if last.hasSuffix(".app") {
            let name = String(last.dropLast(4))
            if !name.isEmpty { return name }
        }
        return fallback
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private static func string(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    private static func failureMessage(_ result: ShellOutput, fallback: String) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdout.isEmpty { return stdout }
        return fallback
    }
}

enum IOSClientError: LocalizedError {
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
