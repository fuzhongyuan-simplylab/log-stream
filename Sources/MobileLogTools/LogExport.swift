import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum LogExportDestination: String, CaseIterable, Identifiable {
    case clipboard
    case file

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clipboard:
            return "复制到剪贴板"
        case .file:
            return "导出为文件"
        }
    }
}

enum LogExportPresenter {
    @MainActor
    static func export(
        store: DeviceStore,
        devices: [Device],
        destination: LogExportDestination,
        singleFile: Bool
    ) {
        guard !devices.isEmpty else { return }
        switch destination {
        case .clipboard:
            let text = store.exportText(for: devices)
            let board = NSPasteboard.general
            board.clearContents()
            if board.setString(text, forType: .string) {
                store.noteExport(copiedMessage(count: devices.count))
            } else {
                store.reportExportFailure("复制到剪贴板失败")
            }
        case .file:
            if devices.count == 1 || singleFile {
                let text = store.exportText(for: devices)
                let name = devices.count == 1
                    ? store.exportFileName(for: devices[0])
                    : store.combinedExportFileName()
                saveFile(text: text, suggestedName: name) { result in
                    switch result {
                    case .success:
                        store.noteExport(savedMessage(count: devices.count, fileCount: 1))
                    case .failure(let error):
                        store.reportExportFailure("导出失败：\(error.localizedDescription)")
                    case nil:
                        break
                    }
                }
            } else {
                let files = devices.map { device in
                    (name: store.exportFileName(for: device), text: store.exportText(for: [device]))
                }
                saveFiles(files) { result in
                    switch result {
                    case .success(let count):
                        store.noteExport(savedMessage(count: devices.count, fileCount: count))
                    case .failure(let error):
                        store.reportExportFailure("导出失败：\(error.localizedDescription)")
                    case nil:
                        break
                    }
                }
            }
        }
    }

    private static func copiedMessage(count: Int) -> String {
        count == 1 ? "已复制 1 台设备的日志" : "已复制 \(count) 台设备的日志"
    }

    private static func savedMessage(count: Int, fileCount: Int) -> String {
        if fileCount == 1 {
            return count == 1 ? "已导出 1 台设备的日志" : "已导出 \(count) 台设备的日志到 1 个文件"
        }
        return "已导出 \(count) 台设备的日志到 \(fileCount) 个文件"
    }

    @MainActor
    private static func saveFile(
        text: String,
        suggestedName: String,
        completion: @escaping (Result<Void, Error>?) -> Void
    ) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedName
        panel.title = "导出日志"
        panel.prompt = "导出"
        present(panel) { response in
            guard response == .OK, let url = panel.url else {
                completion(nil)
                return
            }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    @MainActor
    private static func saveFiles(
        _ files: [(name: String, text: String)],
        completion: @escaping (Result<Int, Error>?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "导出"
        panel.title = "选择导出文件夹"
        panel.message = "每台设备会保存为一个 txt 文件"
        present(panel) { response in
            guard response == .OK, let directory = panel.url else {
                completion(nil)
                return
            }
            do {
                for file in files {
                    let url = directory.appendingPathComponent(file.name)
                    try file.text.write(to: url, atomically: true, encoding: .utf8)
                }
                completion(.success(files.count))
            } catch {
                completion(.failure(error))
            }
        }
    }

    @MainActor
    private static func present(
        _ panel: NSSavePanel,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }
}

struct SingleDeviceExportMenu: View {
    @Environment(DeviceStore.self) private var store
    let device: Device
    var compact = false

    var body: some View {
        Menu("导出") {
            Button("复制到剪贴板") {
                LogExportPresenter.export(store: store, devices: [device], destination: .clipboard, singleFile: true)
            }
            Button("导出为文件") {
                LogExportPresenter.export(store: store, devices: [device], destination: .file, singleFile: true)
            }
        }
        .controlSize(compact ? .small : .regular)
        .fixedSize()
        .help("导出这台设备的日志和设备信息")
    }
}

struct ExportLogSheet: View {
    @Environment(DeviceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let devices: [Device]

    @State private var selected: Set<String>
    @State private var destination: LogExportDestination = .clipboard
    @State private var singleFile = true

    init(devices: [Device]) {
        self.devices = devices
        _selected = State(initialValue: Set(devices.map(\.serial)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("导出日志")
                .font(.title2)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)

            Form {
                Section("设备") {
                    Toggle("全选", isOn: allSelected)
                        .toggleStyle(.checkbox)
                    ForEach(devices) { device in
                        Toggle(isOn: selection(device.serial)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                Text("\(device.kindLabel) · \(device.serial) · \(device.versionLabel)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                Section("方式") {
                    Picker("导出到", selection: $destination) {
                        ForEach(LogExportDestination.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    if destination == .file && selected.count > 1 {
                        Picker("文件", selection: $singleFile) {
                            Text("合并为一个文件").tag(true)
                            Text("每台设备一个文件").tag(false)
                        }
                        .pickerStyle(.radioGroup)
                    } else if destination == .clipboard && selected.count > 1 {
                        Text("多台设备会合并后复制到剪贴板")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("取消", role: .cancel) {
                    dismiss()
                }
                Button("导出") {
                    commit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
            .padding(16)
        }
        .frame(minWidth: 460, minHeight: 420)
    }

    private var allSelected: Binding<Bool> {
        Binding(
            get: { !devices.isEmpty && selected.count == devices.count },
            set: { isOn in
                selected = isOn ? Set(devices.map(\.serial)) : []
            }
        )
    }

    private func selection(_ serial: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(serial) },
            set: { isOn in
                if isOn {
                    selected.insert(serial)
                } else {
                    selected.remove(serial)
                }
            }
        )
    }

    private func commit() {
        let chosen = devices.filter { selected.contains($0.serial) }
        let destination = destination
        let singleFile = singleFile
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            LogExportPresenter.export(
                store: store,
                devices: chosen,
                destination: destination,
                singleFile: singleFile
            )
        }
    }
}
