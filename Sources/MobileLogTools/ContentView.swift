import AppKit
import SwiftUI

enum SidebarItem: Hashable {
    case all
    case device(String)
}

@MainActor
@Observable
final class LogFindFocus {
    var serial: String?
}

struct ContentView: View {
    @Environment(DeviceStore.self) private var store
    @State private var findFocus = LogFindFocus()
    @State private var selection: SidebarItem? = .all
    @State private var exportPickerPresented = false
    @State private var filterInputs: [DevicePlatform: String] = [:]
    @State private var filterUsesRegexInputs: [DevicePlatform: Bool] = [:]
    @State private var didLoadFilterDraft = false

    var body: some View {
        VStack(spacing: 0) {
            controlBar(store: store)
            Divider()
            NavigationSplitView {
                sidebar
            } detail: {
                detail
            }
            Divider()
            statusBar
        }
        .environment(findFocus)
        .frame(minWidth: 960, minHeight: 560)
        .task {
            ensureFilterDraftsLoaded()
            await store.start()
        }
        .onChange(of: store.devices) { _, _ in
            keepVisibleSelection()
        }
        .onChange(of: store.platform) { _, _ in
            keepVisibleSelection()
        }
        .sheet(isPresented: $exportPickerPresented) {
            ExportLogSheet(devices: store.emulators + store.physicalDevices)
        }
    }

    private func controlBar(store: DeviceStore) -> some View {
        HStack(spacing: 10) {
            TextField("输入过滤条件", text: filterInputBinding)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 220, maxWidth: 360)
                .help(filterFieldHelp)
                .onSubmit { Task { await applyFilterDraft() } }
                .id(store.platform)
            Button {
                ensureFilterDraftsLoaded()
                let enabled = filterUsesRegexInputs[store.platform] ?? false
                setDraftUsesRegex(!enabled, for: store.platform)
            } label: {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(filterInputUsesRegex ? Color.accentColor : Color.secondary)
            .help(filterInputUsesRegex ? "正则模式已开启，点应用后生效" : "文本模式。点此改用正则，点应用后生效")
            .accessibilityLabel("正则")
            if showsClearFilter {
                Button {
                    clearFilter()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("取消过滤并清空所有日志")
                .accessibilityLabel("取消过滤")
            }
            Button("应用") {
                Task { await applyFilterDraft() }
            }
            .disabled(filterDraftMatchesApplied || filterRegexIsInvalid)
            .help(filterRegexIsInvalid ? "正则表达式不合法" : "按输入框的条件重新抓取，并清空已有日志")
            if filterRegexIsInvalid {
                Text("正则不合法")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Spacer(minLength: 12)
            Toggle("实时", isOn: allLiveBinding)
                .toggleStyle(.checkbox)
                .disabled(store.visibleDevices.isEmpty || showingSingleDevice)
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
            .disabled(clearAllDisabled || showingSingleDevice)
            .help(store.platform == .ios ? "清空窗口里的日志，不会删除设备上的系统日志" : "清空所有在线设备的 logcat 缓冲")
            toolbarDivider
            Button("刷新设备") {
                Task { await store.refresh() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(store.isRefreshing || refreshDisabled)
            .help("重新检测已连接的设备")
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

    private var filterInputBinding: Binding<String> {
        Binding(
            get: { draftText(for: store.platform) },
            set: { newValue in
                ensureFilterDraftsLoaded()
                setDraftText(newValue, for: store.platform)
            }
        )
    }

    private var trimmedFilterInput: String {
        draftText(for: store.platform).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filterInputUsesRegex: Bool {
        draftUsesRegex(for: store.platform)
    }

    private func draftText(for platform: DevicePlatform) -> String {
        if didLoadFilterDraft {
            return filterInputs[platform] ?? ""
        }
        return store.appliedFilter(for: platform)
    }

    private func draftUsesRegex(for platform: DevicePlatform) -> Bool {
        if didLoadFilterDraft {
            return filterUsesRegexInputs[platform] ?? false
        }
        return store.appliedFilterUsesRegex(for: platform)
    }

    private func setDraftText(_ text: String, for platform: DevicePlatform) {
        var texts = filterInputs
        texts[platform] = text
        filterInputs = texts
    }

    private func setDraftUsesRegex(_ usesRegex: Bool, for platform: DevicePlatform) {
        var flags = filterUsesRegexInputs
        flags[platform] = usesRegex
        filterUsesRegexInputs = flags
    }

    private func ensureFilterDraftsLoaded() {
        guard !didLoadFilterDraft else { return }
        var texts: [DevicePlatform: String] = [:]
        var flags: [DevicePlatform: Bool] = [:]
        for item in DevicePlatform.allCases {
            texts[item] = store.appliedFilter(for: item)
            flags[item] = store.appliedFilterUsesRegex(for: item)
        }
        filterInputs = texts
        filterUsesRegexInputs = flags
        didLoadFilterDraft = true
    }

    private var filterRegexIsInvalid: Bool {
        !LogcatFilter.isValid(trimmedFilterInput, usesRegex: filterInputUsesRegex)
    }

    private var filterDraftMatchesApplied: Bool {
        let applied = store.filter.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedFilterInput.isEmpty && applied.isEmpty { return true }
        return trimmedFilterInput == applied && filterInputUsesRegex == store.filterUsesRegex
    }

    private var showsClearFilter: Bool {
        !trimmedFilterInput.isEmpty || !store.filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filterFieldHelp: String {
        if filterRegexIsInvalid { return "正则表达式不合法" }
        if filterInputUsesRegex { return "正则模式，区分大小写。点应用后生效。留空则显示全部。" }
        return "文本模式，不区分大小写。点应用后生效。留空则显示全部。"
    }

    private func clearFilter() {
        ensureFilterDraftsLoaded()
        setDraftText("", for: store.platform)
        guard !store.filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { await store.applyFilter("", usesRegex: store.filterUsesRegex) }
    }

    private func applyFilterDraft() async {
        ensureFilterDraftsLoaded()
        guard !filterDraftMatchesApplied, !filterRegexIsInvalid else { return }
        let platform = store.platform
        let applied = await store.applyFilter(trimmedFilterInput, usesRegex: filterInputUsesRegex)
        guard applied, store.platform == platform else { return }
        setDraftText(store.filter, for: platform)
    }

    private func changePlatform(to newPlatform: DevicePlatform) async {
        ensureFilterDraftsLoaded()
        let current = store.platform
        guard newPlatform != current else { return }
        let currentText = (filterInputs[current] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let targetText = (filterInputs[newPlatform] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let currentRegex = filterUsesRegexInputs[current] ?? false
        if !currentText.isEmpty && targetText.isEmpty {
            setDraftText(currentText, for: newPlatform)
            setDraftUsesRegex(currentRegex, for: newPlatform)
            await store.selectPlatform(newPlatform, adopting: currentText, usesRegex: currentRegex)
            return
        }
        await store.selectPlatform(newPlatform)
    }

    private var showingSingleDevice: Bool {
        guard case .device(let serial) = selection else { return false }
        return store.visibleDevices.contains { $0.serial == serial }
    }

    private var clearAllDisabled: Bool {
        if store.platform == .ios { return store.visibleDevices.isEmpty }
        return !store.hasOnlineDevice
    }

    private var refreshDisabled: Bool {
        if store.platform == .ios { return store.xcrunMissing }
        return store.adbMissing
    }

    private var platformBinding: Binding<DevicePlatform> {
        Binding(
            get: { store.platform },
            set: { newValue in
                Task { await changePlatform(to: newValue) }
            }
        )
    }

    private func keepVisibleSelection() {
        guard case .device(let serial) = selection else { return }
        if !store.visibleDevices.contains(where: { $0.serial == serial }) {
            selection = .all
        }
    }

    private var allLiveBinding: Binding<Bool> {
        Binding(
            get: { store.allDevicesLive },
            set: { store.setAllLive($0) }
        )
    }

    @ViewBuilder
    private var exportToolbarButton: some View {
        if store.visibleDevices.count == 1, let device = store.visibleDevices.first {
            SingleDeviceExportMenu(device: device)
                .disabled(showingSingleDevice)
        } else {
            Button("导出") {
                exportPickerPresented = true
            }
            .disabled(store.visibleDevices.isEmpty || showingSingleDevice)
            .help("勾选设备后导出日志和设备信息")
        }
    }

    private var sidebar: some View {
        @Bindable var store = store
        return List(selection: $selection) {
            Section {
                Picker("平台", selection: platformBinding) {
                    ForEach(DevicePlatform.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
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
                    title: store.platform == .ios ? "模拟器" : "虚拟机",
                    count: store.emulators.count,
                    field: store.platform == .ios ? $store.iosEmulatorSortField : $store.emulatorSortField,
                    ascending: store.platform == .ios ? $store.iosEmulatorSortAscending : $store.emulatorSortAscending,
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
                    field: store.platform == .ios ? $store.iosPhysicalSortField : $store.physicalSortField,
                    ascending: store.platform == .ios ? $store.iosPhysicalSortAscending : $store.physicalSortAscending,
                    isEmulator: false
                )
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        .navigationTitle("Logstream")
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
        if store.platform == .android && store.adbMissing {
            ContentUnavailableView {
                Label("找不到 adb", systemImage: "exclamationmark.triangle")
            } description: {
                Text("请安装 Android SDK platform-tools。常见路径是 ~/Library/Android/sdk/platform-tools/adb。")
            }
        } else if store.platform == .ios && store.xcrunMissing {
            ContentUnavailableView {
                Label("找不到 Xcode", systemImage: "exclamationmark.triangle")
            } description: {
                Text("请安装 Xcode，并确认 xcode-select 指向它。")
            }
        } else if store.visibleDevices.isEmpty {
            let otherPlatform: DevicePlatform = store.platform == .ios ? .android : .ios
            let otherCount = store.devices.filter { $0.platform == otherPlatform }.count
            ContentUnavailableView {
                Label(store.isRefreshing ? "正在查找设备" : "没有已连接的设备", systemImage: "cable.connector")
            } description: {
                if otherCount > 0 {
                    Text("这边没有 \(store.platform.title) 设备。\(otherPlatform.title) 有 \(otherCount) 台。")
                } else if store.platform == .ios {
                    Text("启动模拟器，或用数据线连上 iPhone、iPad，然后点刷新设备。")
                } else {
                    Text("启动模拟器或接上真机后，点刷新设备。")
                }
            } actions: {
                if otherCount > 0 {
                    Button("查看 \(otherPlatform.title)") {
                        Task { await changePlatform(to: otherPlatform) }
                    }
                }
                Button("刷新设备") {
                    Task { await store.refresh() }
                }
                .disabled(store.isRefreshing || refreshDisabled)
            }
        } else if case .device(let serial) = selection, let device = store.visibleDevices.first(where: { $0.serial == serial }) {
            DevicePane(device: device)
                .onAppear { findFocus.serial = serial }
        } else {
            allDevices
        }
    }

    private var allDevices: some View {
        @Bindable var store = store
        let phones = store.physicalDevices
        let emulators = store.emulators
        let devices = phones + emulators
        return GeometryReader { geo in
            let dividerWidth: CGFloat = 1
            let headerHeight: CGFloat = 40
            let gaps = dividerWidth * CGFloat(max(devices.count - 1, 0))
            let count = CGFloat(max(devices.count, 1))
            let columnWidth = max(Self.deviceColumnMinWidth, (geo.size.width - gaps) / count)
            let contentWidth = columnWidth * CGFloat(devices.count) + gaps
            let paneHeight = max(0, geo.size.height - headerHeight)
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        if !phones.isEmpty {
                            sectionTitle(
                                "真机",
                                field: store.platform == .ios ? $store.iosPhysicalSortField : $store.physicalSortField,
                                ascending: store.platform == .ios ? $store.iosPhysicalSortAscending : $store.physicalSortAscending,
                                isEmulator: false
                            )
                            .frame(
                                width: groupWidth(count: phones.count, columnWidth: columnWidth, dividerWidth: dividerWidth),
                                alignment: .leading
                            )
                        }
                        if !phones.isEmpty && !emulators.isEmpty {
                            Rectangle()
                                .fill(.separator)
                                .frame(width: dividerWidth, height: headerHeight)
                        }
                        if !emulators.isEmpty {
                            sectionTitle(
                                store.platform == .ios ? "模拟器" : "虚拟机",
                                field: store.platform == .ios ? $store.iosEmulatorSortField : $store.emulatorSortField,
                                ascending: store.platform == .ios ? $store.iosEmulatorSortAscending : $store.emulatorSortAscending,
                                isEmulator: true
                            )
                            .frame(
                                width: groupWidth(count: emulators.count, columnWidth: columnWidth, dividerWidth: dividerWidth),
                                alignment: .leading
                            )
                        }
                    }
                    .frame(height: headerHeight, alignment: .leading)
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                            if index > 0 {
                                Rectangle()
                                    .fill(.separator)
                                    .frame(width: dividerWidth, height: paneHeight)
                            }
                            DevicePane(device: device)
                                .frame(width: columnWidth, height: paneHeight, alignment: .top)
                        }
                    }
                    .frame(height: paneHeight, alignment: .top)
                }
                .frame(width: max(contentWidth, geo.size.width), height: geo.size.height, alignment: .topLeading)
            }
        }
    }

    private func groupWidth(count: Int, columnWidth: CGFloat, dividerWidth: CGFloat) -> CGFloat {
        columnWidth * CGFloat(count) + dividerWidth * CGFloat(max(count - 1, 0))
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
                ForEach(DeviceSortField.cases(for: store.platform)) { item in
                    Text(item.title(platform: store.platform, isEmulator: isEmulator)).tag(item)
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

    private static let deviceColumnMinWidth: CGFloat = 320

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

private enum PendingFind {
    case next
    case previous
}

private struct DevicePane: View {
    @Environment(DeviceStore.self) private var store
    @Environment(LogFindFocus.self) private var findFocus
    @State private var searchVisible = false
    @State private var searchText = ""
    @State private var appliedSearchText = ""
    @State private var searchMatchCase = false
    @State private var searchWholeWord = false
    @State private var searchUsesRegex = false
    @State private var matchCount = 0
    @State private var matchIndex = 0
    @State private var searchScrollToken = 0
    @State private var searchEpoch = 0
    @State private var matchedEpoch = -1
    @State private var searchFieldFocused = false
    @State private var searchSelectToken = 0
    @State private var pendingFind: PendingFind?
    @State private var editorBridge = LogEditorBridge()
    let device: Device

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                DeviceToolbarLayout(spacing: 8, lineSpacing: 6) {
                    Text(device.name)
                        .font(.headline)
                        .lineLimit(1)
                    Toggle("实时", isOn: liveBinding)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .foregroundStyle(.primary)
                        .fixedSize()
                        .help("开启后始终显示最新日志。离开底部会关闭，滚回底部会重新开启。")
                    Button(store.isPaused(device.serial) ? "开始记录" : "暂停记录") {
                        Task { await store.toggleRecording(serial: device.serial) }
                    }
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(!device.isOnline)
                    .help(store.isPaused(device.serial) ? "从现在开始记录，暂停期间的日志不会补上" : "停止追加新日志，已有内容保留")
                    Button("清空日志") {
                        Task { await store.clearLogs(serial: device.serial) }
                    }
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(device.platform == .android && !device.isOnline)
                    .help(device.platform == .ios ? "清空窗口里的日志，不会删除设备上的系统日志" : "清空这台设备的 logcat 缓冲")
                    Rectangle()
                        .fill(.separator)
                        .frame(width: 1, height: 16)
                    SingleDeviceExportMenu(device: device, compact: true)
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
                        Text(recordingLabel)
                    }
                    Text("\(store.lineCount(for: device.serial)) 行")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if device.platform == .ios {
                    debugLevelToggle
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
                    snapshot: store.logSnapshot(for: device.serial),
                    isLive: store.isLive(device.serial),
                    onLiveChange: { store.setLive(device.serial, $0) },
                    searchQuery: searchVisible ? appliedSearchText : "",
                    searchMatchCase: searchMatchCase,
                    searchWholeWord: searchWholeWord,
                    searchUsesRegex: searchUsesRegex,
                    searchEpoch: searchEpoch,
                    searchMatchIndex: matchCount == 0 ? -1 : min(matchIndex, matchCount) - 1,
                    searchScrollToken: searchScrollToken,
                    editorBridge: editorBridge,
                    onMatchCount: { count, epoch in
                        guard epoch == searchEpoch else { return }
                        matchedEpoch = epoch
                        guard searchVisible else {
                            if matchCount != 0 { matchCount = 0 }
                            return
                        }
                        matchCount = count
                        if let pending = pendingFind {
                            pendingFind = nil
                            guard count > 0 else {
                                matchIndex = 0
                                return
                            }
                            switch pending {
                            case .next:
                                if matchIndex <= 0 || matchIndex > count {
                                    matchIndex = 1
                                } else {
                                    matchIndex = matchIndex >= count ? 1 : matchIndex + 1
                                }
                            case .previous:
                                if matchIndex <= 0 || matchIndex > count {
                                    matchIndex = count
                                } else {
                                    matchIndex = matchIndex <= 1 ? count : matchIndex - 1
                                }
                            }
                            searchScrollToken += 1
                            return
                        }
                        if count == 0 {
                            matchIndex = 0
                        } else if matchIndex == 0 || matchIndex > count {
                            matchIndex = min(max(matchIndex, 1), count)
                        }
                    },
                    onBecomeFirstResponder: { findFocus.serial = device.serial },
                    onSelectMatch: { index in
                        findFocus.serial = device.serial
                        matchIndex = index + 1
                        searchScrollToken += 1
                    },
                    onHighlightMatch: { index in
                        let number = index + 1
                        guard number != matchIndex else { return }
                        matchIndex = number
                    }
                )
                if store.logSnapshot(for: device.serial).lines.isEmpty {
                    Text(emptyMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                if searchVisible {
                    searchPanel
                        .padding(.top, 8)
                        .padding(.trailing, 16)
                }
            }
            .onAppear {
                if findFocus.serial == nil || !store.visibleDevices.contains(where: { $0.serial == findFocus.serial }) {
                    findFocus.serial = device.serial
                }
            }
            .task(id: searchText) {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, searchVisible, appliedSearchText != searchText else { return }
                searchEpoch += 1
                appliedSearchText = searchText
            }
            .onChange(of: appliedSearchText) { _, _ in
                guard searchVisible, pendingFind == nil else { return }
                matchIndex = appliedSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1
                searchScrollToken += 1
            }
            .background {
                if isFindTarget {
                    hiddenShortcut("f", action: openSearch)
                    hiddenShortcut("g", action: findNextFromShortcut)
                    hiddenShortcut("g", modifiers: [.command, .shift], action: findPreviousFromShortcut)
                    if searchVisible {
                        hiddenShortcut("c", modifiers: [.command, .option], action: toggleMatchCase)
                        hiddenShortcut("w", modifiers: [.command, .option], action: toggleWholeWord)
                        hiddenShortcut("r", modifiers: [.command, .option], action: toggleRegex)
                        Button(action: closeSearch) {}
                            .keyboardShortcut(.cancelAction)
                            .opacity(0)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var searchPanel: some View {
        HStack(spacing: 4) {
            HStack(spacing: 1) {
                FindTextField(
                    text: $searchText,
                    isFocused: searchFieldFocused,
                    selectAllToken: searchSelectToken,
                    onFocus: { findFocus.serial = device.serial },
                    onSubmit: showNextMatch,
                    onShiftSubmit: showPreviousMatch,
                    onCancel: closeSearch
                )
                .frame(minWidth: 88, idealWidth: 120, maxWidth: 160)
                searchOption("Aa", isOn: searchMatchCase, help: "区分大小写（⌥⌘C）", action: toggleMatchCase)
                searchOption("ab", isOn: searchWholeWord, help: "全词匹配（⌥⌘W）", action: toggleWholeWord)
                searchOption(".*", isOn: searchUsesRegex, help: "使用正则表达式（⌥⌘R）", action: toggleRegex)
            }
            .padding(.leading, 6)
            .padding(.trailing, 3)
            .padding(.vertical, 2)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(searchFieldIsError ? Color.red : Color(nsColor: .separatorColor), lineWidth: 1)
            }

            if let status = searchStatus {
                Text(status.label)
                    .font(.caption)
                    .foregroundStyle(status.isError ? Color.red : Color.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .help(status.help)
            }

            searchIconButton("chevron.up", label: "上一个", help: "上一个匹配（⇧⌘G）", action: showPreviousMatch)
                .disabled(matchCount == 0 || searchRegexInvalid)
            searchIconButton("chevron.down", label: "下一个", help: "下一个匹配（⌘G）", action: showNextMatch)
                .disabled(matchCount == 0 || searchRegexInvalid)
            searchIconButton("xmark", label: "关闭", help: "关闭（Escape）", action: closeSearch)
        }
        .padding(6)
        .fixedSize(horizontal: true, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.separator)
        }
        .shadow(color: .black.opacity(0.16), radius: 8, y: 2)
    }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchRegexInvalid: Bool {
        LogSearch.isInvalid(
            query: searchText,
            matchCase: searchMatchCase,
            wholeWord: searchWholeWord,
            usesRegex: searchUsesRegex
        )
    }

    private var searchFieldIsError: Bool {
        guard !trimmedSearch.isEmpty else { return false }
        if searchRegexInvalid { return true }
        return appliedSearchText == searchText && matchedEpoch == searchEpoch && matchCount == 0
    }

    private var searchStatus: (label: String, isError: Bool, help: String)? {
        guard !trimmedSearch.isEmpty else { return nil }
        if searchRegexInvalid {
            return ("正则不合法", true, "正则表达式无法编译")
        }
        guard appliedSearchText == searchText, matchedEpoch == searchEpoch else { return nil }
        if matchCount == 0 {
            return ("无结果", true, "没有匹配")
        }
        return ("\(displayedMatchIndex)/\(matchCount)", false, "当前匹配 / 匹配总数")
    }

    private var displayedMatchIndex: Int {
        guard matchCount > 0 else { return 0 }
        return min(max(matchIndex, 1), matchCount)
    }

    private var isFindTarget: Bool {
        findFocus.serial == device.serial
    }

    private func searchOption(
        _ title: String,
        isOn: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .frame(minWidth: 18)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
        .help(help)
        .accessibilityLabel(help)
    }

    private func searchIconButton(
        _ systemName: String,
        label: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(label)
    }

    private func hiddenShortcut(
        _ key: KeyEquivalent,
        modifiers: EventModifiers = .command,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {}
            .keyboardShortcut(key, modifiers: modifiers)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func closeSearch() {
        guard searchVisible else { return }
        pendingFind = nil
        searchEpoch += 1
        searchVisible = false
        searchFieldFocused = false
        DispatchQueue.main.async {
            editorBridge.focus()
        }
    }

    private func openSearch() {
        findFocus.serial = device.serial
        if let selection = editorBridge.singleLineSelection() {
            searchText = selection
        }
        pendingFind = nil
        searchVisible = true
        searchEpoch += 1
        if appliedSearchText != searchText {
            appliedSearchText = searchText
        } else if !trimmedSearch.isEmpty {
            if matchIndex == 0 { matchIndex = 1 }
            searchScrollToken += 1
        }
        searchSelectToken += 1
        searchFieldFocused = true
    }

    private func findNextFromShortcut() {
        findFocus.serial = device.serial
        if searchVisible, appliedSearchText == searchText, pendingFind == nil, matchedEpoch == searchEpoch {
            showNextMatch()
            return
        }
        beginNavigation(.next)
    }

    private func findPreviousFromShortcut() {
        findFocus.serial = device.serial
        if searchVisible, appliedSearchText == searchText, pendingFind == nil, matchedEpoch == searchEpoch {
            showPreviousMatch()
            return
        }
        beginNavigation(.previous)
    }

    private func beginNavigation(_ direction: PendingFind) {
        let wasVisible = searchVisible
        searchVisible = true
        searchFieldFocused = false
        guard !trimmedSearch.isEmpty, !searchRegexInvalid else {
            pendingFind = nil
            return
        }
        pendingFind = direction
        if appliedSearchText != searchText {
            matchIndex = 0
            searchEpoch += 1
            appliedSearchText = searchText
            return
        }
        if !wasVisible {
            searchEpoch += 1
        }
    }

    private func toggleMatchCase() {
        searchMatchCase.toggle()
        applySearchOptions()
    }

    private func toggleWholeWord() {
        searchWholeWord.toggle()
        applySearchOptions()
    }

    private func toggleRegex() {
        searchUsesRegex.toggle()
        applySearchOptions()
    }

    private func applySearchOptions() {
        guard searchVisible, !trimmedSearch.isEmpty else { return }
        pendingFind = nil
        searchEpoch += 1
        if appliedSearchText != searchText {
            appliedSearchText = searchText
        } else {
            matchIndex = 1
            searchScrollToken += 1
        }
    }

    private func showNextMatch() {
        guard matchCount > 0 else { return }
        findFocus.serial = device.serial
        matchIndex = matchIndex >= matchCount ? 1 : max(matchIndex, 0) + 1
        searchScrollToken += 1
    }

    private func showPreviousMatch() {
        guard matchCount > 0 else { return }
        findFocus.serial = device.serial
        matchIndex = matchIndex <= 1 ? matchCount : matchIndex - 1
        searchScrollToken += 1
    }

    private var debugLevelToggle: some View {
        Toggle("调试", isOn: debugBinding)
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .disabled(!device.isOnline)
            .help("显示 Debug 级别。默认只显示 Default、Info、Error 和 Fault")
    }

    private var recordingLabel: String {
        store.isPaused(device.serial) ? "已暂停" : "记录中"
    }

    private var debugBinding: Binding<Bool> {
        Binding(
            get: { store.includesDebug(device.serial) },
            set: { enabled in
                Task { await store.setIncludesDebug(serial: device.serial, enabled: enabled) }
            }
        )
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

private struct FindTextField: NSViewRepresentable {
    @Binding var text: String
    var isFocused: Bool
    var selectAllToken: Int
    var onFocus: () -> Void
    var onSubmit: () -> Void
    var onShiftSubmit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.placeholderString = "搜索"
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        if let cell = field.cell as? NSTextFieldCell {
            cell.sendsActionOnEndEditing = false
            cell.isScrollable = true
            cell.wraps = false
            cell.usesSingleLineMode = true
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
        let token = selectAllToken
        guard isFocused, context.coordinator.appliedSelectToken != token else {
            if !isFocused {
                context.coordinator.wantsFocus = false
            }
            return
        }
        context.coordinator.wantsFocus = true
        DispatchQueue.main.async {
            guard context.coordinator.wantsFocus, context.coordinator.parent.selectAllToken == token else { return }
            guard let window = field.window else { return }
            context.coordinator.applyingFocus = true
            window.makeFirstResponder(field)
            context.coordinator.applyingFocus = false
            guard let editor = field.currentEditor(), context.coordinator.wantsFocus else { return }
            editor.selectAll(nil)
            context.coordinator.appliedSelectToken = token
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FindTextField
        var appliedSelectToken = -1
        var wantsFocus = false
        var applyingFocus = false

        init(_ parent: FindTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if parent.text != field.stringValue {
                parent.text = field.stringValue
            }
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.onFocus()
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            if !applyingFocus {
                wantsFocus = false
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    parent.onShiftSubmit()
                } else {
                    parent.onSubmit()
                }
                return true
            }
            if commandSelector == #selector(NSResponder.insertLineBreak(_:)) {
                parent.onShiftSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            return false
        }
    }
}

private struct DeviceToolbarLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6
    var minimumTitleWidth: CGFloat = 72

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? intrinsicWidth(subviews)
        let rows = arrange(maxWidth: width, subviews: subviews)
        return CGSize(width: proposal.width ?? (rows.map(\.width).max() ?? 0), height: height(of: rows))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                item.subview.place(
                    at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Item {
        var subview: LayoutSubview
        var size: CGSize
    }

    private struct Row {
        var items: [Item] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func height(of rows: [Row]) -> CGFloat {
        rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(rows.count - 1, 0))
    }

    private func intrinsicWidth(_ subviews: Subviews) -> CGFloat {
        let widths = subviews.map { $0.sizeThatFits(.unspecified).width }
        return widths.reduce(0, +) + spacing * CGFloat(max(widths.count - 1, 0))
    }

    private func arrange(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        guard let title = subviews.first else { return [] }
        let controls = subviews.dropFirst().map { subview in
            Item(subview: subview, size: subview.sizeThatFits(.unspecified))
        }
        let controlsWidth = controls.reduce(CGFloat(0)) { $0 + $1.size.width } + spacing * CGFloat(max(controls.count - 1, 0))
        let gap: CGFloat = controls.isEmpty ? 0 : spacing
        let leftover = maxWidth - controlsWidth - gap
        if leftover >= minimumTitleWidth {
            let titleSize = measured(title, width: leftover)
            var row = Row(items: [Item(subview: title, size: titleSize)], width: titleSize.width, height: titleSize.height)
            append(controls, to: &row)
            return [row]
        }

        let titleSize = measured(title, width: maxWidth)
        var rows = [Row(items: [Item(subview: title, size: titleSize)], width: titleSize.width, height: titleSize.height)]
        var row = Row()
        for control in controls {
            let needed = row.items.isEmpty ? control.size.width : row.width + spacing + control.size.width
            if !row.items.isEmpty, needed > maxWidth {
                rows.append(row)
                row = Row()
            }
            append([control], to: &row)
        }
        if !row.items.isEmpty {
            rows.append(row)
        }
        return rows
    }

    private func measured(_ subview: LayoutSubview, width: CGFloat) -> CGSize {
        let height = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        return CGSize(width: max(0, width), height: height)
    }

    private func append(_ items: [Item], to row: inout Row) {
        for item in items {
            row.width = row.items.isEmpty ? item.size.width : row.width + spacing + item.size.width
            row.height = max(row.height, item.size.height)
            row.items.append(item)
        }
    }
}
