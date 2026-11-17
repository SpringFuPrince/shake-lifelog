import CryptoKit
import Foundation

public struct LANRecord: Codable, Sendable {
    public let record: LifeRecord
    public let photo: Data?

    public init(record: LifeRecord, photo: Data?) {
        self.record = record
        self.photo = photo
    }

    public static func prepare(_ record: LifeRecord, media: MediaStore) throws -> Self {
        guard let refs = record.media else { return Self(record: record, photo: nil) }
        let url = media.url(for: refs.original)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw LANSyncError.missingPhoto
        }
        guard size <= LANWire.maxPhotoBytes else { throw LANSyncError.recordTooLarge }
        guard let photo = try? media.data(refs.original) else { throw LANSyncError.missingPhoto }
        return Self(record: record, photo: photo)
    }
}

public enum LANReceipt: String, Codable, Sendable {
    case imported, skipped, rejected
}

public enum LANWire {
    public static let maxPhotoBytes = 20 * 1_024 * 1_024
    public static let maxFrameBytes = 28 * 1_024 * 1_024
    public static let maxReceiptBytes = 256
    public static let maxInventoryIDs = 256
    public static let maxInventoryBytes = 12 * 1_024
    private static let requestContext = Data("shake-lan-v2/record".utf8)
    private static let receiptContext = Data("shake-lan-v2/receipt".utf8)
    private static let inventoryContext = Data("shake-lan-v2/inventory".utf8)
    private static let missingContext = Data("shake-lan-v2/missing".utf8)

    // The authenticated inventory has a small frame limit and carries IDs only.
    public static func sealInventory(_ ids: [String], pairing: LANPairing) throws -> Data {
        try validateIDs(ids, allowEmpty: false)
        return try seal(ShakeCoding.encoder.encode(ids), pairing: pairing, context: inventoryContext)
    }

    public static func openInventory(_ bytes: Data, pairing: LANPairing) throws -> [String] {
        guard bytes.count <= maxInventoryBytes else { throw LANSyncError.invalidTransfer }
        let ids = try ShakeCoding.decoder.decode([String].self, from: open(bytes, pairing: pairing, context: inventoryContext))
        try validateIDs(ids, allowEmpty: false)
        return ids
    }

    public static func sealMissingIDs(_ ids: [String], request: Data, pairing: LANPairing) throws -> Data {
        try validateIDs(ids, allowEmpty: true)
        return try seal(ShakeCoding.encoder.encode(ids), pairing: pairing,
                        context: missingContext + Data(SHA256.hash(data: request)))
    }

    public static func openMissingIDs(_ bytes: Data, request: Data, offered: [String], pairing: LANPairing) throws -> Set<String> {
        guard bytes.count <= maxInventoryBytes else { throw LANSyncError.invalidTransfer }
        let payload = try open(bytes, pairing: pairing, context: missingContext + Data(SHA256.hash(data: request)))
        let ids = try ShakeCoding.decoder.decode([String].self, from: payload)
        try validateIDs(ids, allowEmpty: true)
        let missing = Set(ids)
        guard missing.isSubset(of: Set(offered)) else { throw LANSyncError.invalidTransfer }
        return missing
    }

    private static func validateIDs(_ ids: [String], allowEmpty: Bool) throws {
        guard (allowEmpty || !ids.isEmpty), ids.count <= maxInventoryIDs,
              Set(ids).count == ids.count, ids.allSatisfy({ UUID(uuidString: $0) != nil }) else {
            throw LANSyncError.invalidTransfer
        }
    }

    public static func sealRequest(_ item: LANRecord, pairing: LANPairing) throws -> Data {
        guard (item.photo?.count ?? 0) <= maxPhotoBytes else { throw LANSyncError.recordTooLarge }
        let plaintext = try ShakeCoding.encoder.encode(item)
        guard plaintext.count + 28 <= maxFrameBytes else { throw LANSyncError.recordTooLarge }
        return try seal(plaintext, pairing: pairing, context: requestContext)
    }

    public static func openRequest(_ bytes: Data, pairing: LANPairing) throws -> LANRecord {
        guard bytes.count <= maxFrameBytes else { throw LANSyncError.recordTooLarge }
        let plaintext = try open(bytes, pairing: pairing, context: requestContext)
        return try ShakeCoding.decoder.decode(LANRecord.self, from: plaintext)
    }

    public static func sealReceipt(_ receipt: LANReceipt, request: Data, pairing: LANPairing) throws -> Data {
        try seal(Data(receipt.rawValue.utf8), pairing: pairing, context: receiptContext + Data(SHA256.hash(data: request)))
    }

    public static func openReceipt(_ bytes: Data, request: Data, pairing: LANPairing) throws -> LANReceipt {
        let plaintext = try open(bytes, pairing: pairing, context: receiptContext + Data(SHA256.hash(data: request)))
        guard let value = String(data: plaintext, encoding: .utf8), let receipt = LANReceipt(rawValue: value) else {
            throw LANSyncError.invalidTransfer
        }
        return receipt
    }

    private static func seal(_ plaintext: Data, pairing: LANPairing, context: Data) throws -> Data {
        guard let result = try AES.GCM.seal(plaintext, using: SymmetricKey(data: pairing.secret),
                                            authenticating: context).combined else { throw LANSyncError.invalidTransfer }
        return result
    }

    private static func open(_ bytes: Data, pairing: LANPairing, context: Data) throws -> Data {
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: SymmetricKey(data: pairing.secret),
                                    authenticating: context)
        } catch {
            throw LANSyncError.invalidTransfer
        }
    }
}
