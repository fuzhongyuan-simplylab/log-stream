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
    @State private var filterInput = ""
    @State private var filterInputUsesRegex = false
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
            if !didLoadFilterDraft {
                filterInput = store.filter
                filterInputUsesRegex = store.filterUsesRegex
                didLoadFilterDraft = true
            }
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
            TextField("输入过滤条件", text: $filterInput)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 220, maxWidth: 360)
                .help(filterFieldHelp)
                .onSubmit { Task { await applyFilterDraft() } }
            Button {
                filterInputUsesRegex.toggle()
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

    private var trimmedFilterInput: String {
        filterInput.trimmingCharacters(in: .whitespacesAndNewlines)
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
        filterInput = ""
        guard !store.filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { await store.applyFilter("", usesRegex: store.filterUsesRegex) }
    }

    private func applyFilterDraft() async {
        guard !filterDraftMatchesApplied, !filterRegexIsInvalid else { return }
        await store.applyFilter(trimmedFilterInput, usesRegex: filterInputUsesRegex)
        filterInput = store.filter
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
                Task { await store.selectPlatform(newValue) }
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
        .navigationTitle("移动日志")
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
                        Task { await store.selectPlatform(otherPlatform) }
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

private struct DevicePane: View {
    @Environment(DeviceStore.self) private var store
    @Environment(LogFindFocus.self) private var findFocus
    @FocusState private var searchFocused: Bool
    @State private var searchVisible = false
    @State private var searchText = ""
    @State private var appliedSearchText = ""
    @State private var searchUsesRegex = false
    @State private var matchCount = 0
    @State private var matchIndex = 0
    @State private var searchScrollToken = 0
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
                    appFilter
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
                    onLiveChange: { store.setLive(device.serial, $0) },
                    searchQuery: searchVisible ? appliedSearchText : "",
                    searchUsesRegex: searchUsesRegex,
                    searchMatchIndex: matchCount == 0 ? -1 : min(matchIndex, matchCount) - 1,
                    searchScrollToken: searchScrollToken,
                    onMatchCount: { count in
                        guard searchVisible else {
                            if matchCount != 0 { matchCount = 0 }
                            return
                        }
                        guard count != matchCount else { return }
                        matchCount = count
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
                if store.logLines(for: device.serial).isEmpty {
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
            .onChange(of: searchFocused) { _, focused in
                if focused {
                    findFocus.serial = device.serial
                }
            }
            .task(id: searchText) {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, searchVisible else { return }
                appliedSearchText = searchText
            }
            .onChange(of: appliedSearchText) { _, _ in
                guard searchVisible else { return }
                matchIndex = appliedSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1
                searchScrollToken += 1
            }
            .onChange(of: searchUsesRegex) { _, _ in
                guard searchVisible, !trimmedSearch.isEmpty else { return }
                if appliedSearchText != searchText {
                    appliedSearchText = searchText
                } else {
                    matchIndex = 1
                    searchScrollToken += 1
                }
            }
            .background {
                if isFindTarget {
                    Button(action: toggleSearch) {}
                        .keyboardShortcut("f", modifiers: .command)
                        .opacity(0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var searchPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("搜索", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($searchFocused)
                    .help(searchUsesRegex ? "正则模式，区分大小写" : "文本模式，不区分大小写")
                    .onSubmit { showNextMatch() }
                    .onExitCommand { closeSearch() }
                Button {
                    searchUsesRegex.toggle()
                } label: {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(searchUsesRegex ? Color.accentColor : Color.secondary)
                .help(searchUsesRegex ? "正则模式已开启，区分大小写" : "文本模式。点此改用正则")
                .accessibilityLabel("正则")
            }
            HStack(spacing: 6) {
                if !trimmedSearch.isEmpty {
                    if searchRegexInvalid {
                        Text("正则不合法")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text("\(displayedMatchIndex)/\(matchCount)")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .help("当前匹配 / 匹配总数")
                    }
                }
                Spacer(minLength: 12)
                findButton(
                    "上一个",
                    shortcut: KeyboardShortcut("g", modifiers: [.command, .shift]),
                    help: "跳到当前选中匹配的上一条",
                    action: showPreviousMatch
                )
                findButton(
                    "下一个",
                    shortcut: KeyboardShortcut("g", modifiers: .command),
                    help: "跳到当前选中匹配的下一条",
                    action: showNextMatch
                )
            }
        }
        .padding(8)
        .frame(width: 280)
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
        guard searchUsesRegex, !trimmedSearch.isEmpty else { return false }
        return (try? NSRegularExpression(pattern: trimmedSearch)) == nil
    }

    private func closeSearch() {
        searchVisible = false
        searchFocused = false
    }

    private func toggleSearch() {
        findFocus.serial = device.serial
        searchVisible.toggle()
        guard searchVisible else { return }
        if appliedSearchText != searchText {
            appliedSearchText = searchText
        } else if !trimmedSearch.isEmpty {
            if matchIndex == 0 { matchIndex = 1 }
            searchScrollToken += 1
        }
        DispatchQueue.main.async { searchFocused = true }
    }

    private var displayedMatchIndex: Int {
        guard matchCount > 0 else { return 0 }
        return min(max(matchIndex, 1), matchCount)
    }

    private var isFindTarget: Bool {
        findFocus.serial == device.serial
    }

    private func findButton(
        _ title: String,
        shortcut: KeyboardShortcut,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Group {
            if isFindTarget {
                Button(title, action: action)
                    .keyboardShortcut(shortcut)
                    .help(help)
            } else {
                Button(title, action: action)
                    .help(help)
            }
        }
        .controlSize(.small)
        .disabled(matchCount == 0)
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

    private var appFilter: some View {
        HStack(spacing: 8) {
            Menu {
                let apps = store.apps(for: device.serial)
                if apps.isEmpty {
                    Text(store.isLoadingApps(device.serial) ? "正在读取应用…" : "没有已安装的应用")
                } else {
                    ForEach(apps) { app in
                        Toggle(app.name, isOn: appSelection(app.bundleIdentifier))
                    }
                }
            } label: {
                Text(appSelectionLabel)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!device.isOnline)
            .help("选择后开始接收这些应用的日志，可多选")
            Toggle("调试", isOn: debugBinding)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .disabled(!device.isOnline || store.selectedBundleIDs(for: device.serial).isEmpty)
                .help("显示 Debug 级别。默认只显示 Default、Info、Error 和 Fault")
        }
    }

    private var appSelectionLabel: String {
        let names = store.selectedAppNames(for: device.serial)
        if names.isEmpty { return "选择应用" }
        if names.count == 1 { return names[0] }
        return "已选 \(names.count) 个应用"
    }

    private var recordingLabel: String {
        if device.platform == .ios && store.selectedBundleIDs(for: device.serial).isEmpty {
            return "未选择应用"
        }
        return store.isPaused(device.serial) ? "已暂停" : "记录中"
    }

    private func appSelection(_ bundleID: String) -> Binding<Bool> {
        Binding(
            get: { store.selectedBundleIDs(for: device.serial).contains(bundleID) },
            set: { selected in
                Task { await store.setAppSelected(serial: device.serial, bundleID: bundleID, selected: selected) }
            }
        )
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
        if device.platform == .ios && store.selectedBundleIDs(for: device.serial).isEmpty {
            if store.isLoadingApps(device.serial) { return "正在读取应用…" }
            if store.apps(for: device.serial).isEmpty { return "没有已安装的应用" }
            return "选择应用后开始记录"
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
