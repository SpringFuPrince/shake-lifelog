import CloudKit
import SwiftUI
import CryptoKit
import ShakeCore

@MainActor
public final class CloudSettings: ObservableObject {
    @Published public private(set) var store: ShakeStore
    @Published public private(set) var enabled = false
    @Published public private(set) var syncing = false
    @Published public private(set) var dataAsOf: Date?
    @Published public private(set) var failure: String?
    @Published public private(set) var account: CloudIdentity?
    @Published public private(set) var checkingAccount = false
    @Published public var error: String?
    private let root: URL
    private let local: ShakeStore
    private let settings: UserDefaults
    private lazy var sync = CloudSync()
    private var pendingRetry: Task<Void, Never>?
    private var activeSync: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var lastCheckedAccount: CloudIdentity?
    private var accountEpoch = UUID()
    private var resetQueued = false
    private var systemIdentityNeedsVerification = false
    private var observers: [any NSObjectProtocol] = []

    public init(settings: UserDefaults = .standard, root: URL? = nil) throws {
        self.settings = settings
        self.root = try root ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: true)
            .appendingPathComponent("Shake", isDirectory: true)
        let local = try ShakeStore(root: self.root)
        self.local = local
        store = local
        if settings.string(forKey: "cloud.enabledAccount") != nil || settings.string(forKey: "cloud.lastLocalAccount") != nil { checkingAccount = true }
    }

    public var canServeAgent: Bool { !checkingAccount }
    public var status: String {
        if checkingAccount || syncing { return "正在同步" }
        if failure != nil { return "同步异常" }
        if !enabled { return "未启用" }
        if (try? store.repository.pendingChanges(limit: 1).isEmpty) == false { return "待同步" }
        return dataAsOf == nil ? "正在同步" : "已同步"
    }

    public func start() {
        guard monitor == nil else { return }
        let notifications = NotificationCenter.default
        observers.append(notifications.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.accountDidChange() }
        })
        observers.append(notifications.addObserver(forName: .shakeCloudPush, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.retry() }
        })
        monitor = Task {
            await refreshAccount()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                if store === local, settings.string(forKey: "cloud.enabledAccount") != nil {
                    await refreshAccount()
                } else if let account, store !== local {
                    do {
                        let current = try await sync.identity()
                        if current != account { accountDidChange(); continue }
                    } catch {
                        if let error = error as? CKError, error.code != .notAuthenticated {
                            retry()
                            continue
                        }
                        if case ShakeError.server(let message) = error,
                           message != "请先在系统设置中登录 iCloud" {
                            retry()
                            continue
                        }
                        accountDidChange()
                        continue
                    }
                }
                retry()
            }
        }
    }

    public func accountDidChange() {
        guard !resetQueued else { return }
        resetQueued = true
        systemIdentityNeedsVerification = true
        checkingAccount = true
        accountEpoch = UUID()
        account = nil
        lastCheckedAccount = nil
        dataAsOf = nil
        pendingRetry?.cancel()
        pendingRetry = nil
        activeSync?.cancel()
        Task {
            await activeSync?.value
            activeSync = nil
            store = local
            enabled = false
            await refreshAccount()
            resetQueued = false
        }
    }

    public func refreshAccount() async {
        let epoch = accountEpoch
        let previousAccount = account
        defer { if epoch == accountEpoch { checkingAccount = false } }
        // CloudKit is available only when Xcode has signed this build with the container entitlement.
        guard Bundle.main.object(forInfoDictionaryKey: "ShakeCloudEnabled") as? String == "YES" else { return }
        do {
            let identity = try await sync.identity()
            guard epoch == accountEpoch else { return }
            lastCheckedAccount = identity
            account = identity
            failure = nil
            systemIdentityNeedsVerification = false
            cacheSystemIdentity(for: identity)
            if settings.string(forKey: "cloud.enabledAccount") == identity.key {
                if store === local || previousAccount != identity { store = try accountStore(identity) }
                enabled = true
                loadFreshness()
                retry()
            } else if settings.string(forKey: "cloud.lastLocalAccount") == identity.key {
                store = try accountStore(identity)
                loadFreshness()
            }
        } catch {
            guard epoch == accountEpoch else { return }
            let enabledKey = settings.string(forKey: "cloud.enabledAccount")
            if let key = enabledKey ?? settings.string(forKey: "cloud.lastLocalAccount") {
                if !systemIdentityNeedsVerification, let cloudError = error as? CKError,
                   [.networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited].contains(cloudError.code),
                   cachedSystemIdentityMatches(accountKey: key) {
                    do {
                        let cached = CloudIdentity(key: key)
                        if store === local || previousAccount != cached { store = try accountStore(cached) }
                        account = cached
                        enabled = enabledKey != nil
                        loadFreshness()
                    } catch {
                        failure = message(for: error)
                        return
                    }
                }
                failure = message(for: error)
            }
        }
    }

    public func prepareEnable() async throws -> CloudIdentity {
        guard Bundle.main.object(forInfoDictionaryKey: "ShakeCloudEnabled") as? String == "YES" else {
            throw ShakeError.server("此构建尚未配置 iCloud 签名")
        }
        let identity = try await sync.identity()
        lastCheckedAccount = identity
        account = identity
        return identity
    }

    public func enable(_ identity: CloudIdentity) async throws {
        guard try await sync.identity() == identity, lastCheckedAccount == identity else {
            throw ShakeError.server("Apple 账户已变更，请重新确认")
        }
        if store === local {
            let destination = try accountStore(identity)
            try transferLocal(to: destination)
            store = destination
        }
        systemIdentityNeedsVerification = false
        cacheSystemIdentity(for: identity)
        settings.set(identity.key, forKey: "cloud.enabledAccount")
        enabled = true
        loadFreshness()
        retry()
    }

    public func disable() async {
        enabled = false
        activeSync?.cancel()
        await activeSync?.value
        failure = nil
        settings.removeObject(forKey: "cloud.enabledAccount")
        if let account { settings.set(account.key, forKey: "cloud.lastLocalAccount") }
    }

    public func scheduleLocalChange() {
        guard enabled, activeSync == nil, pendingRetry == nil,
              (try? store.repository.pendingChanges(limit: 1).isEmpty) == false else { return }
        pendingRetry = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            pendingRetry = nil
            retry()
        }
    }

    public func retry() {
        guard !checkingAccount || account != nil, enabled, let account, activeSync == nil else { return }
        let target = store
        let epoch = accountEpoch
        syncing = true
        failure = nil
        activeSync = Task {
            defer {
                syncing = false
                activeSync = nil
            }
            do {
                target.purgeExpired()
                _ = try await sync.synchronize(repository: target.repository, media: target.media,
                                               expected: account, onRecords: target.refresh)
            } catch is CancellationError {
            } catch {
                if accountEpoch == epoch { failure = message(for: error) }
            }
            if accountEpoch == epoch { loadFreshness() }
        }
    }

    public func handleBackgroundPush() async -> Bool {
        guard enabled, !checkingAccount else { return false }
        retry()
        await activeSync?.value
        return failure == nil
    }

    public func clearDevice() async throws {
        let target = store
        await disable()
        try target.repository.clearLocalData()
        try target.media.clear()
        try target.refresh()
        dataAsOf = nil
    }

    public func clearCloud() async throws {
        guard enabled, let account, try await sync.identity() == account else {
            throw ShakeError.server("请先启用当前 Apple 账户的 iCloud 同步")
        }
        await activeSync?.value
        let target = store
        let epoch = accountEpoch
        _ = try await sync.synchronize(repository: target.repository, media: target.media,
                                       expected: account, onRecords: target.refresh)
        guard epoch == accountEpoch else { throw ShakeError.server("Apple 账户已变更") }
        for record in try target.repository.clearCloudRecords() { try target.media.remove(record: record) }
        try target.refresh()
        retry()
    }

    private func transferLocal(to destination: ShakeStore) throws {
        for record in try local.repository.list(includeDeleted: true, limit: Int.max) {
            guard try destination.repository.get(record.id, includeDeleted: true) == nil else { continue }
            if let refs = record.media {
                for path in [refs.original, refs.preview, refs.thumbnail] {
                    try destination.media.save(local.media.data(path), at: path)
                }
            }
            try destination.repository.save(record)
        }
        try destination.refresh()
        try local.repository.clearLocalData()
        try local.refresh()
        try local.media.clear()
    }

    private func cacheSystemIdentity(for account: CloudIdentity) {
        guard let identity = FileManager.default.ubiquityIdentityToken,
              let encoded = try? NSKeyedArchiver.archivedData(withRootObject: identity, requiringSecureCoding: true) else { return }
        settings.set(encoded, forKey: "cloud.systemIdentity." + account.key)
    }

    private func cachedSystemIdentityMatches(accountKey: String) -> Bool {
        guard let current = FileManager.default.ubiquityIdentityToken as? NSObject,
              let stored = settings.data(forKey: "cloud.systemIdentity." + accountKey),
              let encoded = try? NSKeyedArchiver.archivedData(withRootObject: current, requiringSecureCoding: true),
              let previous = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [type(of: current)], from: stored) else { return false }
        return current.isEqual(previous) || encoded == stored
    }

    private func accountStore(_ identity: CloudIdentity) throws -> ShakeStore {
        let hash = SHA256.hash(data: Data(identity.key.utf8)).map { String(format: "%02x", $0) }.joined()
        return try ShakeStore(root: root.appendingPathComponent("Accounts/\(hash)", isDirectory: true))
    }

    private func loadFreshness() {
        dataAsOf = (try? store.repository.syncValue("cloud.last_pull")).flatMap { try? Date($0, strategy: .iso8601) }
    }

    private func message(for error: Error) -> String {
        guard let cloud = error as? CKError else { return error.localizedDescription }
        switch cloud.code {
        case .quotaExceeded: return "iCloud 储存空间不足。释放空间后重试。"
        case .notAuthenticated, .permissionFailure: return "请检查系统 iCloud 登录及拾刻的 iCloud 权限。"
        case .networkUnavailable, .networkFailure: return "网络不可用。恢复网络后将自动重试。"
        case .requestRateLimited, .serviceUnavailable, .zoneBusy: return "iCloud 已推迟同步，稍后会自动重试。"
        default: return cloud.localizedDescription
        }
    }
}

public extension Notification.Name {
    static let shakeCloudPush = Notification.Name("Shake.CloudPush")
}
