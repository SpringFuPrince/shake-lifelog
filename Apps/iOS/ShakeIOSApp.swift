import SwiftUI
import CloudKit
import ShakeCore
import ShakeUI

@main
struct ShakeIOSApp: App {
    private let setup: Result<CloudSettings, Error>
    private let viewSettings: UserDefaults
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var push
    init() {
        #if DEBUG
        let testID = ProcessInfo.processInfo.environment["SHAKE_UI_TEST_STORE"].flatMap(UUID.init(uuidString:))
        let testSettings = testID.flatMap { UserDefaults(suiteName: "test." + $0.uuidString) }
        viewSettings = testSettings ?? .standard
        #else
        viewSettings = .standard
        #endif
        setup = Result {
            #if DEBUG
            if let id = testID, let defaults = testSettings {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
                let cloud = try CloudSettings(settings: defaults, root: root)
                if ProcessInfo.processInfo.environment["SHAKE_UI_TEST_PHOTO_GRID"] == "1" {
                    try cloud.store.seedTimelinePhotoFixture()
                }
                if ProcessInfo.processInfo.environment["SHAKE_UI_TEST_TIMELINE_FIXTURE"] == "1" {
                    let now = Date.now
                    let repository = cloud.store.repository
                    try repository.database.transaction {
                        for index in 1...10_000 {
                            let date = now.addingTimeInterval(Double(index - 10_000) * 7_200)
                            let record = LifeRecord(id: "timeline-fixture-\(index)", category: .sport,
                                                    capturedAt: date, payload: RecordPayload(activity: "Timeline fixture \(index)"))
                            try repository.save(record)
                        }
                    }
                    try cloud.store.refresh()
                }
                return cloud
            }
            #endif
            return try CloudSettings()
        }
    }

    var body: some Scene {
        WindowGroup {
            switch setup {
            case .success(let cloud):
                MobileRoot(cloud: cloud)
                    .defaultAppStorage(viewSettings)
                    .onAppear { push.cloud = cloud }
            case .failure(let error):
                ContentUnavailableView("无法打开本机记录", systemImage: "exclamationmark.circle",
                                       description: Text(error.localizedDescription))
            }
        }
    }
}

final class PushDelegate: NSObject, UIApplicationDelegate {
    weak var cloud: CloudSettings?

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { @MainActor in
            guard let cloud, cloud.enabled else { completionHandler(.noData); return }
            let applied = await cloud.handleBackgroundPush()
            completionHandler(applied ? .newData : .failed)
        }
    }
}

private struct MobileRoot: View {
    @ObservedObject var cloud: CloudSettings
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Group {
            if cloud.checkingAccount {
                ProgressView("正在检查 iCloud 账户")
            } else {
                MobileTabs(cloud: cloud, store: cloud.store)
                    .id(ObjectIdentifier(cloud.store))
            }
        }
        .tint(ShakeTheme.accent)
        .preferredColorScheme(.light)
        .environment(\.locale, ShakeTheme.locale)
        .task {
            cloud.start()
            if Bundle.main.object(forInfoDictionaryKey: "ShakeCloudEnabled") as? String == "YES" {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
        .onChange(of: phase) { _, phase in
            guard phase == .active else { return }
            if !cloud.checkingAccount, !cloud.enabled { cloud.store.purgeExpired() }
            cloud.retry()
        }
    }
}

private struct MobileTabs: View {
    private enum Page { case home, timeline, camera, settings }
    @ObservedObject var cloud: CloudSettings
    @ObservedObject var store: ShakeStore
    @State private var page = Page.home
    @State private var manualDraft: RecordDraft?

    var body: some View {
        TabView(selection: $page) {
            DashboardView(store: store, onTimeline: { page = .timeline }, onManual: { manual($0) },
                          retryMedia: cloud.enabled ? { cloud.retry() } : nil)
                .tabItem { Label("首页", systemImage: "house") }.tag(Page.home)
            TimelineView(store: store, retryMedia: cloud.enabled ? { cloud.retry() } : nil)
                .tabItem { Label("时间线", systemImage: "clock") }.tag(Page.timeline)
            CameraView(store: store) { page = .home; manual(nil) }
                .tabItem { Label("拍摄", systemImage: "camera") }.tag(Page.camera)
            SettingsView(cloud: cloud, store: store, localSync: AnyView(
                NavigationLink { LANSyncView(store: store) } label: { Label("局域网同步", systemImage: "wifi") }
            ))
                .tabItem { Label("我的", systemImage: "person.crop.circle") }.tag(Page.settings)
        }
        .sheet(isPresented: Binding(get: { manualDraft != nil }, set: { if !$0 { manualDraft = nil } })) {
            if let manualDraft {
                RecordEditorView(draft: manualDraft, lastWeight: store.recentWeight(),
                                 allowsPhotoSelection: true) { draft, photo in
                    try await store.save(draft, photo: photo)
                }
            }
        }
        .onChange(of: store.records) { _, _ in cloud.scheduleLocalChange() }
        .onChange(of: store.deletedRecords) { _, _ in cloud.scheduleLocalChange() }
        .onAppear { store.purgeExpired() }
    }

    private func manual(_ category: ShakeCore.Category?) {
        manualDraft = RecordDraft(category: category ?? .food, lastWeight: store.recentWeight(), needsCategory: category == nil)
    }
}
