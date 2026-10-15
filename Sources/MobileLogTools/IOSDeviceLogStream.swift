import Darwin
import Foundation
import ObjectiveC

enum IOSLogError: LocalizedError {
    case deviceUnavailable
    case streamFailed

    var errorDescription: String? {
        switch self {
        case .deviceUnavailable:
            return "设备连不上。请用数据线连接，并在设备上信任这台 Mac"
        case .streamFailed:
            return "无法开始读取日志"
        }
    }
}

final class IOSDeviceLogStream: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String] = []
    private var flushScheduled = false
    private var stopped = false
    private var delegate: StreamDelegate?
    private var logDevice: AnyObject?
    private var stream: AnyObject?
    private var mobileDevice: NSObject?
    private var connected = false
    private var cutoff = Date.distantPast
    private let onLines: @Sendable ([String]) -> Void
    private let onEnd: @Sendable () -> Void
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    init(onLines: @escaping @Sendable ([String]) -> Void, onEnd: @escaping @Sendable () -> Void) {
        self.onLines = onLines
        self.onEnd = onEnd
    }

    func start(udid: String, processNames: [String], includeDebug: Bool, cutoff: Date) throws {
        self.cutoff = cutoff.addingTimeInterval(-1)
        guard !processNames.isEmpty else { throw IOSLogError.streamFailed }
        guard let mobile = Self.openMobileDevice(udid: udid) else {
            throw IOSLogError.deviceUnavailable
        }
        do {
            guard let messaging = Self.messaging() else { throw IOSLogError.streamFailed }
            let names = Set(processNames)
            let delegate = StreamDelegate { [weak self] events in
                self?.consume(events, allowed: names, includeDebug: includeDebug)
            }
            let logDevice = try Self.makeLogDevice(mobile: mobile.object, udid: udid, messaging: messaging)
            let stream = try Self.makeStream(
                logDevice: logDevice,
                delegate: delegate,
                processNames: processNames,
                includeDebug: includeDebug,
                messaging: messaging
            )
            self.mobileDevice = mobile.object
            self.connected = true
            self.delegate = delegate
            self.logDevice = logDevice
            self.stream = stream
            Self.voidCall(messaging, stream, "startRemote")
        } catch {
            Self.closeMobileDevice(mobile.object)
            throw error
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        pending.removeAll()
        let stream = self.stream
        let mobile = mobileDevice
        let wasConnected = connected
        connected = false
        lock.unlock()
        if let stream, let messaging = Self.messaging() {
            Self.voidCall(messaging, stream, "stopRemote")
            Self.voidCall(messaging, stream, "stop")
        }
        if wasConnected, let mobile {
            Self.closeMobileDevice(mobile)
        }
        self.stream = nil
        self.logDevice = nil
        self.delegate = nil
        self.mobileDevice = nil
    }

    func discardPending() {
        lock.lock()
        pending.removeAll()
        lock.unlock()
    }

    private func consume(_ events: [NSObject], allowed: Set<String>, includeDebug: Bool) {
        var lines: [String] = []
        lines.reserveCapacity(events.count)
        lock.lock()
        let stopped = stopped
        if !stopped {
            for event in events {
                guard let line = format(event, allowed: allowed, includeDebug: includeDebug) else { continue }
                lines.append(line)
            }
        }
        lock.unlock()
        guard !stopped, !lines.isEmpty else { return }
        enqueue(lines)
    }

    private func format(_ event: NSObject, allowed: Set<String>, includeDebug: Bool) -> String? {
        if let date = field(event, "timestamp") as? Date, date < cutoff {
            return nil
        }
        let process = field(event, "process") as? String ?? ""
        guard allowed.contains(process) else { return nil }
        if !includeDebug, (field(event, "messageType") as? NSNumber)?.intValue == 2 {
            return nil
        }
        guard let message = field(event, "eventMessage") as? String else { return nil }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let stamp: String
        if let date = field(event, "timestamp") as? Date {
            stamp = formatter.string(from: date)
        } else {
            stamp = ""
        }
        let pid = (field(event, "processID") as? NSNumber)?.intValue
        let subsystem = field(event, "subsystem") as? String ?? ""
        let category = field(event, "category") as? String ?? ""
        var line = stamp.isEmpty ? process : "\(stamp) \(process)"
        if let pid {
            line += "[\(pid)]"
        }
        if !subsystem.isEmpty {
            line += " \(subsystem)"
        }
        if !category.isEmpty {
            line += " \(category)"
        }
        line += ": \(text)"
        return line
    }

    /// `value(forKey:)` raises when the key is missing, and that exception aborts the process.
    /// Log lines are `OSActivityLogMessageEvent`; opening, closing, or using the app also emits
    /// activity events that share `process` / `eventMessage` but have no `subsystem` or `category`.
    private func field(_ event: NSObject, _ key: String) -> Any? {
        guard event.responds(to: NSSelectorFromString(key)) else { return nil }
        return event.value(forKey: key)
    }

    private func enqueue(_ lines: [String]) {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        pending.append(contentsOf: lines)
        let schedule = !flushScheduled
        if schedule { flushScheduled = true }
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.flush()
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

    static func userApps(udid: String) -> [InstalledApp]? {
        guard let mobile = openMobileDevice(udid: udid) else { return nil }
        defer { closeMobileDevice(mobile.object) }
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice", RTLD_NOW),
              let lookupSymbol = dlsym(handle, "AMDeviceLookupApplications") else {
            return nil
        }
        typealias LookupFn = @convention(c) (UnsafeMutableRawPointer, CFDictionary?, UnsafeMutablePointer<Unmanaged<CFDictionary>?>) -> Int32
        var result: Unmanaged<CFDictionary>?
        let options = ["ApplicationType": "User"] as CFDictionary
        let status = unsafeBitCast(lookupSymbol, to: LookupFn.self)(mobile.pointer, options, &result)
        guard status == 0, let dictionary = result?.takeRetainedValue() as NSDictionary? else { return nil }
        var apps: [InstalledApp] = []
        for (key, value) in dictionary {
            guard let bundleID = key as? String, !bundleID.isEmpty,
                  let info = value as? NSDictionary else { continue }
            let display = trimmed(info["CFBundleDisplayName"])
            let bundleName = trimmed(info["CFBundleName"])
            let executable = trimmed(info["CFBundleExecutable"])
            let path = info["Path"] as? String ?? ""
            let process = executable.isEmpty ? processName(path: path, fallback: bundleName.isEmpty ? bundleID : bundleName) : executable
            let name = display.isEmpty ? (bundleName.isEmpty ? process : bundleName) : display
            apps.append(InstalledApp(bundleIdentifier: bundleID, name: name, processName: process))
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func trimmed(_ value: Any?) -> String {
        ((value as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func processName(path: String, fallback: String) -> String {
        let file = (path as NSString).lastPathComponent
        guard file.hasSuffix(".app") else { return fallback }
        return String(file.dropLast(4))
    }

    private static func messaging() -> UnsafeMutableRawPointer? {
        let handle = dlopen("/usr/lib/libobjc.A.dylib", RTLD_NOW)
        return dlsym(handle, "objc_msgSend")
    }

    private static func openMobileDevice(udid: String) -> (object: NSObject, pointer: UnsafeMutableRawPointer)? {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice", RTLD_NOW),
              let listSymbol = dlsym(handle, "AMDCreateDeviceList"),
              let identifierSymbol = dlsym(handle, "AMDeviceCopyDeviceIdentifier"),
              let connectSymbol = dlsym(handle, "AMDeviceConnect"),
              let validateSymbol = dlsym(handle, "AMDeviceValidatePairing"),
              let sessionSymbol = dlsym(handle, "AMDeviceStartSession") else {
            return nil
        }
        typealias ListFn = @convention(c) () -> Unmanaged<CFArray>?
        typealias CopyIDFn = @convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFString>?
        typealias StatusFn = @convention(c) (UnsafeMutableRawPointer) -> Int32
        guard let devices = unsafeBitCast(listSymbol, to: ListFn.self)()?.takeRetainedValue() else { return nil }
        let copyID = unsafeBitCast(identifierSymbol, to: CopyIDFn.self)
        let connect = unsafeBitCast(connectSymbol, to: StatusFn.self)
        let validate = unsafeBitCast(validateSymbol, to: StatusFn.self)
        let session = unsafeBitCast(sessionSymbol, to: StatusFn.self)
        for case let device as NSObject in devices as NSArray {
            let pointer = Unmanaged.passUnretained(device).toOpaque()
            guard let found = copyID(pointer)?.takeRetainedValue() as String?, found == udid else { continue }
            guard connect(pointer) == 0 else { continue }
            if validate(pointer) != 0 || session(pointer) != 0 {
                closeMobileDevice(device)
                continue
            }
            return (device, pointer)
        }
        return nil
    }

    private static func closeMobileDevice(_ device: NSObject) {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice", RTLD_NOW),
              let stopSymbol = dlsym(handle, "AMDeviceStopSession"),
              let disconnectSymbol = dlsym(handle, "AMDeviceDisconnect") else {
            return
        }
        typealias StatusFn = @convention(c) (UnsafeMutableRawPointer) -> Int32
        let pointer = Unmanaged.passUnretained(device).toOpaque()
        _ = unsafeBitCast(stopSymbol, to: StatusFn.self)(pointer)
        _ = unsafeBitCast(disconnectSymbol, to: StatusFn.self)(pointer)
    }

    private static func makeLogDevice(mobile: NSObject, udid: String, messaging: UnsafeMutableRawPointer) throws -> AnyObject {
        guard dlopen("/System/Library/PrivateFrameworks/LoggingSupport.framework/LoggingSupport", RTLD_NOW) != nil,
              let deviceClass = NSClassFromString("OSLogDevice") else {
            throw IOSLogError.streamFailed
        }
        typealias AllocFn = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>
        typealias InitFn = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer, NSString) -> Unmanaged<AnyObject>?
        let allocated = unsafeBitCast(messaging, to: AllocFn.self)(deviceClass, sel_registerName("alloc")).takeUnretainedValue()
        let pointer = Unmanaged.passUnretained(mobile).toOpaque()
        guard let created = unsafeBitCast(messaging, to: InitFn.self)(
            allocated,
            sel_registerName("initWithMobileDevice:andUDID:"),
            pointer,
            udid as NSString
        )?.takeRetainedValue() else {
            throw IOSLogError.streamFailed
        }
        return created
    }

    private static func makeStream(
        logDevice: AnyObject,
        delegate: StreamDelegate,
        processNames: [String],
        includeDebug: Bool,
        messaging: UnsafeMutableRawPointer
    ) throws -> AnyObject {
        guard let streamClass = NSClassFromString("OSActivityStream") else { throw IOSLogError.streamFailed }
        typealias AllocFn = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>
        typealias InitFn = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<AnyObject>?
        typealias SetObject = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        typealias SetUInt = @convention(c) (AnyObject, Selector, UInt64) -> Void
        typealias TrustFn = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer?) -> Bool
        let allocated = unsafeBitCast(messaging, to: AllocFn.self)(streamClass, sel_registerName("alloc")).takeUnretainedValue()
        guard let created = unsafeBitCast(messaging, to: InitFn.self)(
            allocated,
            sel_registerName("initWithDevice:"),
            logDevice
        )?.takeRetainedValue() else {
            throw IOSLogError.streamFailed
        }
        let setObject = unsafeBitCast(messaging, to: SetObject.self)
        setObject(created, sel_registerName("setDevice:"), logDevice)
        _ = unsafeBitCast(messaging, to: TrustFn.self)(created, sel_registerName("establishTrust:"), nil)
        setObject(created, sel_registerName("setDelegate:"), delegate)
        let placeholders = Array(repeating: "process == %@", count: processNames.count).joined(separator: " OR ")
        let predicate = NSPredicate(format: placeholders, argumentArray: processNames)
        setObject(created, sel_registerName("setPredicate:"), predicate)
        var options: UInt64 = 4 | 8 | 256
        if includeDebug {
            options |= 512
        }
        unsafeBitCast(messaging, to: SetUInt.self)(created, sel_registerName("setOptions:"), options)
        unsafeBitCast(messaging, to: SetUInt.self)(created, sel_registerName("setEventFilter:"), 4)
        return created
    }

    private static func voidCall(_ messaging: UnsafeMutableRawPointer, _ target: AnyObject, _ name: String) {
        typealias VoidFn = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(messaging, to: VoidFn.self)(target, sel_registerName(name))
    }

    private final class StreamDelegate: NSObject {
        private let onEvents: ([NSObject]) -> Void

        init(onEvents: @escaping ([NSObject]) -> Void) {
            self.onEvents = onEvents
        }

        @objc(activityStream:results:)
        func activityStream(_ stream: AnyObject, results: NSArray) -> Bool {
            let events = results.compactMap { $0 as? NSObject }
            if !events.isEmpty {
                onEvents(events)
            }
            return true
        }
    }
}
