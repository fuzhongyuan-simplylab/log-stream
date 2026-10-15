import SwiftUI

enum SidebarItem: Hashable {
    case all
    case device(String)
}

struct ContentView: View {
    @Environment(DeviceStore.self) private var store
    @State private var selection: SidebarItem? = .all
    @State private var exportPickerPresented = false

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
        .sheet(isPresented: $exportPickerPresented) {
            ExportLogSheet(devices: store.emulators + store.physicalDevices)
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
            Toggle("实时", isOn: allLiveBinding)
                .toggleStyle(.checkbox)
                .disabled(store.devices.isEmpty || showingSingleDevice)
                .help("开启后所有设备都跟随最新日志。某台设备滚离底部会单独关闭实时模式，滚回底部会重新开启。")
            Button("开始") {
                Task { await store.startAll() }
            }
            .disabled(!store.canStartAll || showingSingleDevice)
            .help("开始所有已暂停的在线设备")
            Button("暂停") {
                store.pauseAll()
            }
            .disabled(!store.canPauseAll || showingSingleDevice)
            .help("暂停所有正在记录的在线设备。已有日志保留，暂停期间的日志不会补上")
            Button("清空") {
                Task { await store.clearAllLogs() }
            }
            .keyboardShortcut(.delete, modifiers: [.command, .shift])
            .disabled(!store.hasOnlineDevice || showingSingleDevice)
            .help("清空所有在线设备的 logcat 缓冲")
            toolbarDivider
            Button("刷新设备") {
                Task { await store.refresh() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(store.isRefreshing || store.adbMissing)
            .help("重新检测已连接的虚拟机和真机")
            toolbarDivider
            exportToolbarButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var toolbarDivider: some View {
        Divider()
            .frame(height: 16)
    }

    private var showingSingleDevice: Bool {
        guard case .device(let serial) = selection else { return false }
        return store.devices.contains { $0.serial == serial }
    }

    private var allLiveBinding: Binding<Bool> {
        Binding(
            get: { store.allDevicesLive },
            set: { store.setAllLive($0) }
        )
    }

    @ViewBuilder
    private var exportToolbarButton: some View {
        if store.devices.count == 1, let device = store.devices.first {
            SingleDeviceExportMenu(device: device)
                .disabled(showingSingleDevice)
        } else {
            Button("导出") {
                exportPickerPresented = true
            }
            .disabled(store.devices.isEmpty || showingSingleDevice)
            .help("勾选设备后导出日志和设备信息")
        }
    }

    private var sidebar: some View {
        @Bindable var store = store
        return List(selection: $selection) {
            Section {
                Label("全部设备", systemImage: "rectangle.split.3x1")
                    .tag(SidebarItem.all)
            }
            Section {
                if store.emulators.isEmpty {
                    Text("未连接")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.emulators) { device in
                        deviceRow(device)
                            .tag(SidebarItem.device(device.serial))
                    }
                }
            } header: {
                listHeader(
                    title: "虚拟机",
                    count: store.emulators.count,
                    field: $store.emulatorSortField,
                    ascending: $store.emulatorSortAscending,
                    isEmulator: true
                )
            }
            Section {
                if store.physicalDevices.isEmpty {
                    Text("未连接")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.physicalDevices) { device in
                        deviceRow(device)
                            .tag(SidebarItem.device(device.serial))
                    }
                }
            } header: {
                listHeader(
                    title: "真机",
                    count: store.physicalDevices.count,
                    field: $store.physicalSortField,
                    ascending: $store.physicalSortAscending,
                    isEmulator: false
                )
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        .navigationTitle("Android 日志")
    }

    private func listHeader(
        title: String,
        count: Int,
        field: Binding<DeviceSortField>,
        ascending: Binding<Bool>,
        isEmulator: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title)（\(count)）")
            sortControls(field: field, ascending: ascending, isEmulator: isEmulator)
        }
        .textCase(nil)
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
                } else if store.isPaused(device.serial) {
                    Text("已暂停")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: device.symbolName)
        }
        .contextMenu {
            Button(store.isPaused(device.serial) ? "开始记录" : "暂停记录") {
                Task { await store.toggleRecording(serial: device.serial) }
            }
            .disabled(!device.isOnline)
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

    private var allDevices: some View {
        @Bindable var store = store
        let emulators = store.emulators
        let phones = store.physicalDevices
        return VStack(spacing: 0) {
            if !emulators.isEmpty {
                sectionTitle(
                    "虚拟机",
                    field: $store.emulatorSortField,
                    ascending: $store.emulatorSortAscending,
                    isEmulator: true
                )
                deviceColumns(emulators)
            }
            if !emulators.isEmpty && !phones.isEmpty {
                Divider()
            }
            if !phones.isEmpty {
                sectionTitle(
                    "真机",
                    field: $store.physicalSortField,
                    ascending: $store.physicalSortAscending,
                    isEmulator: false
                )
                deviceColumns(phones)
            }
        }
    }

    private func sectionTitle(
        _ title: String,
        field: Binding<DeviceSortField>,
        ascending: Binding<Bool>,
        isEmulator: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.headline)
            sortControls(field: field, ascending: ascending, isEmulator: isEmulator)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func sortControls(
        field: Binding<DeviceSortField>,
        ascending: Binding<Bool>,
        isEmulator: Bool
    ) -> some View {
        HStack(spacing: 2) {
            Picker("排序", selection: field) {
                ForEach(DeviceSortField.allCases) { item in
                    Text(item.title(isEmulator: isEmulator)).tag(item)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("调整排列顺序。侧边栏和全部设备页面使用同一顺序。")
            Button {
                ascending.wrappedValue.toggle()
            } label: {
                Image(systemName: ascending.wrappedValue ? "arrow.up" : "arrow.down")
            }
            .buttonStyle(.borderless)
            .help(ascending.wrappedValue ? "当前升序，点击改为降序" : "当前降序，点击改为升序")
        }
        .controlSize(.small)
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
            if let exportNotice = store.exportNotice, !exportNotice.isEmpty {
                Text(exportNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(exportNotice)
            }
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
                HStack(alignment: .center, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Label(device.kindLabel, systemImage: device.symbolName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(device.name)
                            .font(.headline)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    HStack(alignment: .center, spacing: 8) {
                        Toggle("实时", isOn: liveBinding)
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                            .foregroundStyle(.primary)
                            .help("开启后始终显示最新日志。离开底部会关闭，滚回底部会重新开启。")
                        Button(store.isPaused(device.serial) ? "开始记录" : "暂停记录") {
                            Task { await store.toggleRecording(serial: device.serial) }
                        }
                        .controlSize(.small)
                        .disabled(!device.isOnline)
                        .help(store.isPaused(device.serial) ? "从现在开始记录，暂停期间的日志不会补上" : "停止追加新日志，已有内容保留")
                        Button("清空日志") {
                            Task { await store.clearLogs(serial: device.serial) }
                        }
                        .controlSize(.small)
                        .disabled(!device.isOnline)
                        .help("清空这台设备的 logcat 缓冲")
                        Rectangle()
                            .fill(.separator)
                            .frame(width: 1, height: 16)
                        SingleDeviceExportMenu(device: device, compact: true)
                    }
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
                    if device.isOnline {
                        Text(store.isPaused(device.serial) ? "已暂停" : "记录中")
                    }
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
                LogTextView(
                    lines: store.logLines(for: device.serial),
                    isLive: store.isLive(device.serial),
                    onLiveChange: { store.setLive(device.serial, $0) }
                )
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

    private var liveBinding: Binding<Bool> {
        Binding(
            get: { store.isLive(device.serial) },
            set: { store.setLive(device.serial, $0) }
        )
    }

    private var emptyMessage: String {
        if !device.isOnline {
            return "设备\(device.stateLabel)，无法读取日志"
        }
        let needle = store.filter.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty {
            return "没有匹配「\(needle)」的日志"
        }
        if store.isPaused(device.serial) {
            return "已暂停"
        }
        return "等待日志…"
    }
}
