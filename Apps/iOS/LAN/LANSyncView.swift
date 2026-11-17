import ShakeCore
import ShakeUI
import SwiftUI

struct LANSyncView: View {
    @ObservedObject var store: ShakeStore
    @State private var pairing: LANPairing?
    @State private var showScanner = false
    @State private var transfer: Task<Void, Never>?
    @State private var completed = 0
    @State private var total = 0
    @State private var result: String?
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                if let pairing {
                    Label(pairing.name, systemImage: "desktopcomputer")
                    Button("重新扫码") { showScanner = true }.disabled(transfer != nil)
                } else {
                    Button { showScanner = true } label: { Label("扫描 Mac 二维码", systemImage: "qrcode.viewfinder") }
                }
            } header: {
                Text("配对")
            } footer: {
                Text("两台设备需连接同一 Wi-Fi。请在 Mac 拾刻开启局域网接收，并保持接收页面打开。")
            }

            if pairing != nil {
                Section {
                    LabeledContent("可发送记录", value: store.records.count.formatted())
                    if transfer != nil {
                        ProgressView(value: Double(completed), total: Double(max(1, total))) {
                            Text("正在同步 \(completed) / \(total)")
                        }
                        Button("取消同步", role: .cancel) { transfer?.cancel() }
                    } else {
                        Button("同步到 Mac", action: synchronize).disabled(store.records.isEmpty)
                    }
                    if let result { Text(result).foregroundStyle(.secondary) }
                    if let error { Text(error).foregroundStyle(.secondary) }
                } footer: {
                    Text("先核对记录 ID，再发送 Mac 尚未导入的记录和照片。")
                }
            } else if let error {
                Section { Text(error).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("局域网同步")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showScanner) {
            NavigationStack {
                LANScanner(onCode: scanned, onError: { message in
                    showScanner = false
                    error = message
                })
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("扫描配对二维码")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { showScanner = false } } }
            }
        }
        .onDisappear { transfer?.cancel() }
    }

    private func scanned(_ code: String) {
        showScanner = false
        do { pairing = try LANPairing(code: code); error = nil; result = nil }
        catch { pairing = nil; self.error = error.localizedDescription }
    }

    private func synchronize() {
        guard transfer == nil, let pairing else { return }
        let records = store.records
        let media = store.media
        total = records.count
        completed = 0
        result = nil
        error = nil
        transfer = Task {
            defer { transfer = nil }
            var progress = LANSyncProgress()
            do {
                try await LANConnection.synchronize(records, media: media, pairing: pairing) { update in
                    progress = update
                    completed = update.completed
                }
            } catch {
                if !Task.isCancelled {
                    self.error = (error as? LANSyncError)?.errorDescription ?? LANSyncError.disconnected.errorDescription
                }
            }
            let status = Task.isCancelled ? "已取消" : (completed == total ? "已处理" : "同步中断")
            result = "\(status) \(completed) / \(total) 条。Mac 导入 \(progress.imported) 条，跳过 \(progress.skipped) 条，失败 \(progress.failed) 条。"
        }
    }
}
