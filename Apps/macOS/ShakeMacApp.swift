import AppKit
import CloudKit
import SwiftUI
import ShakeCore
import ShakeUI

@main
struct ShakeMacApp: App {
    private let setup: Result<CloudSettings, Error>
    private let viewSettings: UserDefaults
    @StateObject private var server: MCPServer
    @NSApplicationDelegateAdaptor(MacDelegate.self) private var delegate

    init() {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let raw = environment["SHAKE_UI_TEST_STORE"], let id = UUID(uuidString: raw),
           let port = environment["SHAKE_UI_TEST_MCP_PORT"].flatMap(UInt16.init),
           let settings = UserDefaults(suiteName: "test." + id.uuidString) {
            viewSettings = settings
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
            setup = Result {
                let cloud = try CloudSettings(settings: settings, root: root)
                if environment["SHAKE_UI_TEST_PHOTO_GRID"] == "1" {
                    try cloud.store.seedTimelinePhotoFixture()
                }
                return cloud
            }
            _server = StateObject(wrappedValue: MCPServer(port: port, settings: settings))
            return
        }
        #endif
        viewSettings = .standard
        setup = Result { try CloudSettings() }
        _server = StateObject(wrappedValue: MCPServer(settings: .standard))
    }

    var body: some Scene {
        Window("拾刻", id: "main") {
            switch setup {
            case .success(let cloud):
                MacRoot(cloud: cloud, server: server)
                    .defaultAppStorage(viewSettings)
                    .frame(minWidth: 760, minHeight: 520)
                    .preferredColorScheme(.light)
            case .failure(let error):
                ContentUnavailableView("无法打开本机记录", systemImage: "exclamationmark.circle",
                                       description: Text(error.localizedDescription))
            }
        }
        .defaultSize(width: 1040, height: 700)

        MenuBarExtra("拾刻", systemImage: "camera.aperture") {
            if case .success(let cloud) = setup { MenuCommands(cloud: cloud, server: server) }
            else { Button("退出拾刻") { NSApp.terminate(nil) } }
        }
    }
}

final class MacDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.object(forInfoDictionaryKey: "ShakeCloudEnabled") as? String == "YES" {
            NSApp.registerForRemoteNotifications()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        NotificationCenter.default.post(name: .shakeCloudPush, object: nil)
    }
}

private struct MacRoot: View {
    @ObservedObject var cloud: CloudSettings
    @ObservedObject var server: MCPServer

    var body: some View {
        Group {
            if cloud.checkingAccount { ProgressView("正在检查 iCloud 账户") }
            else { MacWorkspace(cloud: cloud, store: cloud.store, server: server).id(ObjectIdentifier(cloud.store)) }
        }
        .tint(ShakeTheme.accent)
        .environment(\.locale, ShakeTheme.locale)
        .background(ShakeTheme.paper.ignoresSafeArea())
        .task { cloud.start(); server.launchIfNeeded(cloud: cloud) }
        .onChange(of: cloud.checkingAccount) { _, checking in
            if checking { server.disconnect() }
        }
    }
}

private struct MacWorkspace: View {
    private enum Page: String, CaseIterable, Identifiable {
        case timeline, agent, settings
        var id: Self { self }
        var title: String {
            switch self {
            case .timeline: "时间线"
            case .agent: "Agent"
            case .settings: "设置"
            }
        }
        var icon: String {
            switch self {
            case .timeline: "clock"
            case .agent: "link"
            case .settings: "gearshape"
            }
        }
    }

    @ObservedObject var cloud: CloudSettings
    @ObservedObject var store: ShakeStore
    @ObservedObject var server: MCPServer
    @State private var selection: Page? = .timeline

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $selection) { page in
                Label(page.title, systemImage: page.icon)
                    .font(.body.weight(.medium))
                    .accessibilityIdentifier("workspace.page.\(page.rawValue)")
                    .tag(page)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(ShakeTheme.card)
            .safeAreaInset(edge: .bottom) {
                Label(cloud.enabled ? "iCloud · " + cloud.status : "本机存储", systemImage: cloud.enabled ? "icloud" : "externaldrive")
                    .font(.caption).foregroundStyle(ShakeTheme.mutedInk).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(ShakeTheme.card)
            }
            .navigationTitle("拾刻")
            .navigationSplitViewColumnWidth(min: 170, ideal: 205, max: 250)
        } detail: {
            switch selection ?? .timeline {
            case .timeline: TimelineView(store: store, retryMedia: cloud.enabled ? { cloud.retry() } : nil)
            case .agent: AgentView(store: store, server: server)
            case .settings: SettingsView(cloud: cloud, store: store, localSync: AnyView(
                NavigationLink {
                    LANReceiverView(store: store)
                } label: {
                    Label("局域网同步", systemImage: "wifi")
                }
            ))
            }
        }
        .onChange(of: store.records) { _, _ in cloud.scheduleLocalChange() }
        .onChange(of: store.deletedRecords) { _, _ in cloud.scheduleLocalChange() }
        .onAppear { store.purgeExpired() }
    }
}

private struct MenuCommands: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var cloud: CloudSettings
    @ObservedObject var server: MCPServer

    var body: some View {
        Button("打开拾刻") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Text("MCP · " + server.status.label)
        if case .failed(let reason) = server.status { Text(reason) }
        Button(server.status == .running ? "停止 MCP" : "启动 MCP") {
            if server.status == .running { server.stop() } else { server.start() }
        }.disabled(server.status == .starting)
        Button("立即同步") { cloud.retry() }.disabled(!cloud.enabled || cloud.syncing)
        Divider()
        Button("退出拾刻") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
