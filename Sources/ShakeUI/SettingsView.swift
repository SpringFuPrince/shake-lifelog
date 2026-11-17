import SwiftUI
import UniformTypeIdentifiers
import ShakeCore

public struct SettingsView: View {
    @ObservedObject var cloud: CloudSettings
    @ObservedObject var store: ShakeStore
    private let localSync: AnyView?
    @State private var pendingAccount: CloudIdentity?
    @State private var showsEnable = false
    @State private var showsDeleted = false
    @State private var showsExport = false
    @State private var export: BackupDocument?
    @State private var confirmation: ClearTarget?

    private enum ClearTarget: String, Identifiable {
        case device, cloud
        var id: Self { self }
        var title: String { self == .device ? "仅清除此设备" : "删除此 iCloud 账户下的拾刻数据" }
        var message: String {
            self == .device ? "本机未同步的记录会丢失。再次启用同步后，可以下载 iCloud 上仍存在的记录。"
            : "已同步记录及照片将从当前 Apple 账户的拾刻数据中删除。离线设备将在之后同步时应用变更。"
        }
    }

    public init(cloud: CloudSettings, store: ShakeStore, localSync: AnyView? = nil) {
        self.cloud = cloud
        self.store = store
        self.localSync = localSync
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("同步") {
                    NavigationLink {
                        cloudSyncSettings
                    } label: {
                        Label("iCloud 同步", systemImage: "icloud")
                    }
                    .accessibilityIdentifier("settings.sync.icloud")
                    if let localSync { localSync.accessibilityIdentifier("settings.sync.lan") }
                }
                Section("记录与备份") {
                    Button("最近删除") { showsDeleted = true }
                    Button("导出备份") { prepareExport() }
                }
                Section("隐私") {
                    Text("照片在设备上分类。照片文件会去除位置元数据，拍摄地点单独保存在记录中，随备份、局域网同步和已启用的 iCloud 同步转移。")
                    Text("体重和心情保存在设备上。手动同步时，这些记录会发送给配对的 Mac。启用 iCloud 后，也会同步到当前账户的私有数据库。在 Mac 开启本机 MCP 后，同一台 Mac 上的 Agent 可以查询已有的记录和照片预览。")
                    Button(ClearTarget.device.title, role: .destructive) { confirmation = .device }
                    if cloud.enabled {
                        Button(ClearTarget.cloud.title, role: .destructive) { confirmation = .cloud }
                    }
                }
                .font(.subheadline)
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .scrollContentBackground(.hidden)
            .background(ShakeTheme.paper.ignoresSafeArea())
            .navigationTitle(settingsTitle)
        }
        .sheet(isPresented: $showsDeleted) { RecentlyDeletedView(store: store) }
        .fileExporter(isPresented: $showsExport, document: export, contentType: .zip,
                      defaultFilename: "Shake-Backup.zip") { result in
            if case .failure(let error) = result { cloud.error = error.localizedDescription }
            export = nil
        }
        .confirmationDialog("启用 iCloud 同步", isPresented: $showsEnable, titleVisibility: .visible) {
            Button("确认并启用") {
                if let pendingAccount { perform { try await cloud.enable(pendingAccount) } }
            }
        } message: {
            Text("将本机记录和媒体同步到\(pendingAccount?.displayName ?? "当前 Apple 账户")。")
        }
        .alert(confirmation?.title ?? "清除数据", isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
        ), presenting: confirmation) { target in
            Button("确认清除", role: .destructive) {
                perform {
                    switch target {
                    case .device: try await cloud.clearDevice()
                    case .cloud: try await cloud.clearCloud()
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: { target in Text(target.message) }
        .alert("拾刻", isPresented: Binding(get: { cloud.error != nil }, set: { if !$0 { cloud.error = nil } })) {
            Button("好") { cloud.error = nil }
        } message: { Text(cloud.error ?? "") }
    }

    private var settingsTitle: String {
        #if os(macOS)
        "设置"
        #else
        "我的"
        #endif
    }

    private var cloudSyncSettings: some View {
        Form {
            Section("iCloud 同步") {
                LabeledContent("状态", value: cloud.status)
                if let account = cloud.account { LabeledContent("账户", value: account.displayName) }
                if let date = cloud.dataAsOf { LabeledContent("最近成功拉取", value: date.formatted(ShakeTheme.dateTime())) }
                if let error = cloud.failure {
                    Text(error).font(.subheadline).foregroundStyle(.secondary)
                }
                if cloud.enabled {
                    Button("立即同步") { cloud.retry() }.disabled(cloud.syncing)
                    Button("关闭同步") { Task { await cloud.disable() } }
                } else {
                    Button("启用 iCloud 同步") {
                        perform {
                            pendingAccount = try await cloud.prepareEnable()
                            showsEnable = true
                        }
                    }.disabled(cloud.checkingAccount)
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .scrollContentBackground(.hidden)
        .background(ShakeTheme.paper.ignoresSafeArea())
        .navigationTitle("iCloud 同步")
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await action() }
            catch { cloud.error = error.localizedDescription }
        }
    }

    private func prepareExport() {
        perform {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
            defer { try? FileManager.default.removeItem(at: file) }
            try BackupManager(repository: store.repository, media: store.media).export(to: file)
            export = try BackupDocument(data: Data(contentsOf: file))
            showsExport = true
        }
    }
}

private struct BackupDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.zip]
    let data: Data
    init(data: Data) throws { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw ShakeError.invalidBackup }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
