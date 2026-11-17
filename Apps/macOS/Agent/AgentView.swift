import SwiftUI
import ServiceManagement
import ShakeCore
import ShakeUI

struct AgentView: View {
    @ObservedObject var store: ShakeStore
    @ObservedObject var server: MCPServer
    @State private var logs: [AccessLog] = []
    @State private var error: String?
    @State private var login = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("本机 MCP 服务") {
                LabeledContent("状态", value: server.status.label)
                if case .failed(let reason) = server.status { Text(reason).foregroundStyle(.secondary) }
                LabeledContent("端点") {
                    Text(MCPServer.endpoint).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                HStack {
                    Button(server.status == .running ? "停止服务" : "启动服务") {
                        if server.status == .running { server.stop() } else { server.start() }
                    }.disabled(server.status == .starting)
                    Button("复制端点") { copy(MCPServer.endpoint) }
                }
                Toggle("登录时启动拾刻", isOn: $login).onChange(of: login) { _, enabled in
                    perform {
                        if enabled, SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
                        if !enabled, SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
                    }
                }
            }
            Section("Codex 接入") {
                Text("开启后，同一台 Mac 上的 Agent 可以同时读取记录的照片与文字。分析由外部 Agent 完成。")
                    .font(.subheadline).foregroundStyle(ShakeTheme.mutedInk)
                Text("把本机端点添加到 Codex，即可使用拾刻。")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("安装或更新 shake-life-log Skill") { perform { try installSkill() } }
            }
            Section("访问日志") {
                if logs.isEmpty { Text("暂无工具调用").foregroundStyle(.secondary) }
                ForEach(logs) { log in
                    LabeledContent(log.toolName) {
                        Text("\(log.resultCount) 条 · \(log.createdAt.formatted(ShakeTheme.dateTime()))")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(ShakeTheme.paper.ignoresSafeArea())
        .navigationTitle("Agent")
        .onAppear(perform: refresh)
        .onChange(of: server.logRevision) { _, _ in refresh() }
        .alert("Agent", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func refresh() {
        do {
            logs = try store.repository.accessLogs(limit: 30)
        } catch { self.error = error.localizedDescription }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); refresh() }
        catch { self.error = error.localizedDescription }
    }

    private func installSkill() throws {
        guard let source = Bundle.main.url(forResource: "shake-life-log", withExtension: nil) else {
            throw ShakeError.server("应用中没有找到 Skill 文件")
        }
        let skills = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agents/skills", isDirectory: true)
        let destination = skills.appendingPathComponent("shake-life-log", isDirectory: true)
        let files = FileManager.default
        try files.createDirectory(at: skills, withIntermediateDirectories: true)
        if files.fileExists(atPath: destination.path) {
            let staging = skills.appendingPathComponent(".shake-update-" + UUID().uuidString, isDirectory: true)
            defer { try? files.removeItem(at: staging) }
            try files.copyItem(at: source, to: staging)
            _ = try files.replaceItemAt(destination, withItemAt: staging)
        } else {
            try files.copyItem(at: source, to: destination)
        }
    }
}
