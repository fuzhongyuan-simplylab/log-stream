import SwiftUI

enum SidebarItem: Hashable {
    case all
    case device(String)
}

struct ContentView: View {
    @Environment(DeviceStore.self) private var store
    @State private var selection: SidebarItem? = .all

    var body: some View {
        @Bindable var store = store

        VStack(spacing: 0) {
            controlBar(store: store)
            Divider()
            NavigationSplitView {
                sidebar
            } detail: {
                detail
            }
        }
        .frame(minWidth: 960, minHeight: 560)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            statusBar
        }
        .task {
            await store.start()
        }
        .onChange(of: store.filter) { _, _ in
            store.filterDidChange()
        }
        .onChange(of: store.devices) { _, _ in
            guard case .device(let serial) = selection else { return }
            if !store.devices.contains(where: { $0.serial == serial }) {
                selection = .all
            }
        }
    }

    private func controlBar(store: DeviceStore) -> some View {
        @Bindable var store = store
        return HStack(spacing: 10) {
            Text("过滤")
            TextField("例如 KeyboardHeight", text: $store.filter)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 220, maxWidth: 360)
                .help("不区分大小写，匹配整行日志。留空则显示全部。下次打开会记住。")
            if !store.filter.isEmpty {
                Button("清除") {
                    store.filter = ""
                }
                .controlSize(.small)
            }
            Spacer(minLength: 12)
            Button("刷新设备") {
                Task { await store.refresh() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(store.isRefreshing || store.adbMissing)
            .help("重新检测已连接的虚拟机和真机")
            Button("清空全部日志") {
                Task { await store.clearAllLogs() }
            }
            .keyboardShortcut(.delete, modifiers: [.command, .shift])
            .disabled(!store.hasOnlineDevice)
            .help("清空所有在线设备的 logcat 缓冲")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                Label("全部设备", systemImage: "rectangle.split.3x1")
                    .tag(SidebarItem.all)
            }
            Section("虚拟机（\(store.emulators.count)）") {
                if store.emulators.isEmpty {
                    Text("未连接")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.emulators) { device in
                        deviceRow(device)
                            .tag(SidebarItem.device(device.serial))
                    }
                }
            }
            Section("真机（\(store.physicalDevices.count)）") {
                if store.physicalDevices.isEmpty {
                    Text("未连接")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.physicalDevices) { device in
                        deviceRow(device)
                            .tag(SidebarItem.device(device.serial))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 340)
        .navigationTitle("Android 日志")
    }

    private func deviceRow(_ device: Device) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .lineLimit(1)
                Text(device.versionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !device.isOnline {
                    Text(device.stateLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: device.symbolName)
        }
        .contextMenu {
            Button("清空日志") {
                Task { await store.clearLogs(serial: device.serial) }
            }
            .disabled(!device.isOnline)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if store.adbMissing {
            ContentUnavailableView {
                Label("找不到 adb", systemImage: "exclamationmark.triangle")
            } description: {
                Text("请安装 Android SDK platform-tools。常见路径是 ~/Library/Android/sdk/platform-tools/adb。")
            }
        } else if store.devices.isEmpty {
            ContentUnavailableView {
                Label(store.isRefreshing ? "正在查找设备" : "没有已连接的设备", systemImage: "cable.connector")
            } description: {
                Text("启动模拟器或接上真机后，点刷新设备。")
            } actions: {
                Button("刷新设备") {
                    Task { await store.refresh() }
                }
                .disabled(store.isRefreshing)
            }
        } else if case .device(let serial) = selection, let device = store.devices.first(where: { $0.serial == serial }) {
            DevicePane(device: device)
        } else {
            allDevices
        }
    }

    @ViewBuilder
    private var allDevices: some View {
        let emulators = store.emulators
        let phones = store.physicalDevices
        if !emulators.isEmpty && !phones.isEmpty {
            VStack(spacing: 0) {
                sectionTitle("虚拟机")
                deviceColumns(emulators)
                Divider()
                sectionTitle("真机")
                deviceColumns(phones)
            }
        } else {
            deviceColumns(store.devices)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }

    private func deviceColumns(_ devices: [Device]) -> some View {
        GeometryReader { geo in
            let width = max(320, geo.size.width / CGFloat(max(devices.count, 1)))
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                        if index > 0 {
                            Divider()
                        }
                        DevicePane(device: device)
                            .frame(width: width, height: geo.size.height)
                    }
                }
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text(store.summaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(store.adbPath)
            Spacer()
            if let errorMessage = store.errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(errorMessage)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

private struct DevicePane: View {
    @Environment(DeviceStore.self) private var store
    let device: Device

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(device.kindLabel, systemImage: device.symbolName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(device.name)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button("清空日志") {
                        Task { await store.clearLogs(serial: device.serial) }
                    }
                    .controlSize(.small)
                    .disabled(!device.isOnline)
                    .help("清空这台设备的 logcat 缓冲")
                }
                HStack(spacing: 6) {
                    Text(device.serial)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("·")
                    Text(device.versionLabel)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(store.lineCount(for: device.serial)) 行")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if !device.isOnline {
                    Text(device.stateLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let warning = store.warning(for: device.serial) {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)

            Divider()

            ZStack {
                LogTextView(lines: store.logLines(for: device.serial))
                if store.logLines(for: device.serial).isEmpty {
                    Text(emptyMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyMessage: String {
        if !device.isOnline {
            return "设备\(device.stateLabel)，无法读取日志"
        }
        let needle = store.filter.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty {
            return "没有匹配「\(needle)」的日志"
        }
        return "等待日志…"
    }
}
