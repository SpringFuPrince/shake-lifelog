import CloudKit
import Foundation
import OSLog

public struct CloudIdentity: Equatable {
    public let key: String
    public init(key: String) { self.key = key }
    public var displayName: String { "当前 Apple 账户（\(key.suffix(6))）" }
}

public struct CloudSync {
    public static let containerIdentifier = "iCloud.cn.shake.lifelog"
    private static let logger = Logger(subsystem: "cn.shake.lifelog", category: "Sync")
    private let container: CKContainer
    private let zone = CKRecordZone(zoneName: "LifeLog")
    private var database: CKDatabase { container.privateCloudDatabase }

    public init(containerIdentifier: String = Self.containerIdentifier) {
        container = CKContainer(identifier: containerIdentifier)
    }

    public func identity() async throws -> CloudIdentity {
        switch try await container.accountStatus() {
        case .available:
            return CloudIdentity(key: try await container.userRecordID().recordName)
        case .noAccount:
            throw ShakeError.server("请先在系统设置中登录 iCloud")
        case .restricted:
            throw ShakeError.server("此设备限制了 iCloud 访问")
        default:
            throw ShakeError.server("iCloud 暂不可用，请稍后重试")
        }
    }

    @MainActor
    public func synchronize(repository: RecordRepository, media: MediaStore, expected: CloudIdentity,
                            onRecords: () throws -> Void) async throws -> Date {
        try await checkIdentity(expected)
        do {
            try await ensureZone(repository: repository)
            try await pull(repository: repository, media: media, expected: expected, onRecords: onRecords)
            let dataAsOf = Date.now
            try repository.setSyncValue(dataAsOf.ISO8601Format(), for: "cloud.last_pull")
            let failedUploads = try await push(repository: repository, media: media, expected: expected)
            try onRecords()
            let failedMedia = try await fetchMedia(repository: repository, media: media, expected: expected,
                                                   onRecords: onRecords)
            if failedUploads > 0 || failedMedia > 0 {
                let messages = [
                    failedUploads > 0 ? "有 \(failedUploads) 条记录的照片无法上传" : nil,
                    failedMedia > 0 ? "有 \(failedMedia) 张照片尚未下载" : nil
                ]
                throw ShakeError.server(messages.compactMap { $0 }.joined(separator: "，") + "。可重试同步。")
            }
            Self.logger.info("icloud_sync_succeeded")
            return dataAsOf
        } catch {
            Self.logger.error("icloud_sync_failed")
            throw error
        }
    }

    private func checkIdentity(_ expected: CloudIdentity) async throws {
        try Task.checkCancellation()
        guard try await identity() == expected else { throw ShakeError.server("Apple 账户已变更") }
        try Task.checkCancellation()
    }

    private func ensureZone(repository: RecordRepository) async throws {
        if try repository.syncValue("cloud.zone") == nil {
            _ = try await database.save(zone)
            try repository.setSyncValue("1", for: "cloud.zone")
        }
        if try repository.syncValue("cloud.subscription") == nil {
            let subscription = CKRecordZoneSubscription(zoneID: zone.zoneID, subscriptionID: "LifeLog.changes")
            let notification = CKSubscription.NotificationInfo()
            notification.shouldSendContentAvailable = true
            subscription.notificationInfo = notification
            _ = try await database.save(subscription)
            try repository.setSyncValue("1", for: "cloud.subscription")
        }
    }

    @MainActor
    private func pull(repository: RecordRepository, media: MediaStore, expected: CloudIdentity, onRecords: () throws -> Void) async throws {
        var token: CKServerChangeToken?
        if let value = try repository.syncValue("cloud.token"), let data = Data(base64Encoded: value) {
            token = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
        }
        while true {
            let page: (modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, Error>],
                       deletions: [CKDatabase.RecordZoneChange.Deletion], changeToken: CKServerChangeToken, moreComing: Bool)
            do {
                page = try await database.recordZoneChanges(inZoneWith: zone.zoneID, since: token,
                                                            desiredKeys: ["body"], resultsLimit: 100)
            } catch let error as CKError where error.code == .changeTokenExpired && token != nil {
                token = nil
                try repository.setSyncValue(nil, for: "cloud.token")
                continue
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
                try repository.setSyncValue(nil, for: "cloud.zone")
                try repository.setSyncValue(nil, for: "cloud.subscription")
                try repository.setSyncValue(nil, for: "cloud.token")
                throw error
            }
            try await checkIdentity(expected)
            for result in page.modificationResultsByID.values {
                let record = try result.get().record
                let incoming = try decode(record)
                let previous = try repository.get(incoming.id, includeDeleted: true)
                try repository.applyRemote(incoming)
                if let previous, previous.media != nil,
                   try repository.get(incoming.id, includeDeleted: true)?.media == nil {
                    try media.remove(record: previous)
                }
            }
            for deletion in page.deletions {
                let id = deletion.recordID.recordName
                let previous = try repository.get(id, includeDeleted: true)
                try repository.applyCloudDeletion(id: id)
                if let previous { try media.remove(record: previous) }
            }
            let archive = try NSKeyedArchiver.archivedData(withRootObject: page.changeToken, requiringSecureCoding: true)
            try repository.setSyncValue(archive.base64EncodedString(), for: "cloud.token")
            try onRecords()
            token = page.changeToken
            if !page.moreComing { return }
        }
    }

    private func push(repository: RecordRepository, media: MediaStore, expected: CloudIdentity) async throws -> Int {
        let pending = try repository.pendingChanges(limit: Int.max)
        var failures = 0
        for record in pending {
            try await checkIdentity(expected)
            let id = CKRecord.ID(recordName: record.id, zoneID: zone.zoneID)
            let cloud: CKRecord
            do {
                cloud = try await database.record(for: id)
            } catch let error as CKError where error.code == .unknownItem {
                cloud = CKRecord(recordType: "LifeRecord", recordID: id)
            }
            try await checkIdentity(expected)
            guard let current = try repository.get(record.id, includeDeleted: true),
                  current.dirty, current.updatedAt == record.updatedAt else { continue }

            var outgoing = current
            let previous = cloud["body"] == nil ? nil : try decode(cloud)
            if let previous {
                if previous.deletedAt != nil, outgoing.deletedAt == nil,
                   !previous.allowsRestore(outgoing) {
                    try repository.applyRemote(previous)
                    continue
                }
                outgoing.revision = previous.revision + 1
            } else {
                outgoing.revision = current.revision + 1
            }
            outgoing.dirty = false
            cloud["body"] = try ShakeCoding.encoder.encode(outgoing)
            if let refs = current.media {
                let file = media.url(for: refs.original)
                if FileManager.default.fileExists(atPath: file.path) {
                    cloud["photo"] = CKAsset(fileURL: file)
                } else if previous?.media != refs || cloud["photo"] == nil {
                    failures += 1
                    continue
                }
            } else {
                cloud["photo"] = nil
            }
            do {
                let saved = try await database.save(cloud)
                try await checkIdentity(expected)
                let accepted = try decode(saved)
                try repository.markSynced(id: current.id, revision: accepted.revision, matching: current.updatedAt)
            } catch let error as CKError where error.code == .serverRecordChanged {
                if let server = error.serverRecord { try repository.applyRemote(decode(server)) }
                continue
            }
        }
        return failures
    }

    @MainActor
    private func fetchMedia(repository: RecordRepository, media: MediaStore, expected: CloudIdentity,
                            onRecords: () throws -> Void) async throws -> Int {
        let missing = try repository.list(includeDeleted: true).filter { record in
            guard let refs = record.media else { return false }
            return !media.isAvailable(refs)
        }
        var failures = 0
        for offset in stride(from: 0, to: missing.count, by: 25) {
            try await checkIdentity(expected)
            let batch = missing.dropFirst(offset).prefix(25)
            let ids = batch.map { CKRecord.ID(recordName: $0.id, zoneID: zone.zoneID) }
            let result = try await database.records(for: ids, desiredKeys: ["body", "photo"])
            try await checkIdentity(expected)

            for (record, id) in zip(batch, ids) {
                try Task.checkCancellation()
                guard let refs = record.media,
                      let current = try repository.get(record.id, includeDeleted: true),
                      current.media == refs else { continue }
                do {
                    guard let cloud = try result[id]?.get(), try decode(cloud).media == refs,
                          let url = (cloud["photo"] as? CKAsset)?.fileURL else {
                        throw ShakeError.missingMedia
                    }
                    try media.installCloudPhoto(Data(contentsOf: url), refs: refs)
                } catch {
                    failures += 1
                }
            }
            try onRecords()
        }
        return failures
    }

    private func decode(_ cloud: CKRecord) throws -> LifeRecord {
        guard let data = cloud["body"] as? Data else { throw ShakeError.invalidRecord }
        let record = try ShakeCoding.decoder.decode(LifeRecord.self, from: data)
        guard record.id == cloud.recordID.recordName else { throw ShakeError.invalidRecord }
        return record
    }
}
