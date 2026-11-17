import Foundation
import Network

public struct LANSyncProgress: Sendable {
    public var imported = 0
    public var skipped = 0
    public var failed = 0
    public var completed: Int { imported + skipped + failed }
    public init() {}
}

public enum LANConnection {
    public static func send(_ frame: Data, over connection: NWConnection) async throws {
        var length = UInt32(frame.count).bigEndian
        let prefix = withUnsafeBytes(of: &length) { Data($0) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: prefix + frame, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    public static func receive(over connection: NWConnection, limit: Int) async throws -> Data {
        let prefix = try await read(over: connection, count: 4)
        let count = prefix.reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= limit else { throw LANSyncError.invalidTransfer }
        return try await read(over: connection, count: count)
    }

    private static func read(over connection: NWConnection, count: Int) async throws -> Data {
        var result = Data()
        while result.count < count {
            try Task.checkCancellation()
            let remaining = count - result.count
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: min(remaining, 65_536)) { data, _, _, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: LANSyncError.disconnected) }
                }
            }
            result.append(data)
        }
        return result
    }

    public static func synchronize(_ records: [LifeRecord], media: MediaStore, pairing: LANPairing,
                                   onProgress: @MainActor (LANSyncProgress) -> Void) async throws {
        var progress = LANSyncProgress()
        for offset in stride(from: 0, to: records.count, by: LANWire.maxInventoryIDs) {
            try Task.checkCancellation()
            let batch = records[offset..<min(offset + LANWire.maxInventoryIDs, records.count)]
            let validRecords = batch.filter { UUID(uuidString: $0.id) != nil }
            progress.failed += batch.count - validRecords.count
            let ids = validRecords.map(\.id)
            let missing = try await missingRecordIDs(ids, pairing: pairing)
            progress.skipped += ids.count - missing.count
            await onProgress(progress)

            for record in validRecords where missing.contains(record.id) {
                try Task.checkCancellation()
                do {
                    let item = try await Task.detached(priority: .userInitiated) {
                        try LANRecord.prepare(record, media: media)
                    }.value
                    switch try await request(item, pairing: pairing) {
                    case .imported: progress.imported += 1
                    case .skipped: progress.skipped += 1
                    case .rejected: progress.failed += 1
                    }
                } catch let error as LANSyncError where error == .missingPhoto || error == .recordTooLarge {
                    progress.failed += 1
                }
                await onProgress(progress)
            }
        }
    }

    public static func missingRecordIDs(_ ids: [String], pairing: LANPairing) async throws -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let request = try LANWire.sealInventory(ids, pairing: pairing)
        let response = try await exchange(request, pairing: pairing, responseLimit: LANWire.maxInventoryBytes)
        return try LANWire.openMissingIDs(response, request: request, offered: ids, pairing: pairing)
    }

    public static func request(_ item: LANRecord, pairing: LANPairing) async throws -> LANReceipt {
        let request = try LANWire.sealRequest(item, pairing: pairing)
        let response = try await exchange(request, pairing: pairing, responseLimit: LANWire.maxReceiptBytes)
        return try LANWire.openReceipt(response, request: request, pairing: pairing)
    }

    private static func exchange(_ request: Data, pairing: LANPairing, responseLimit: Int) async throws -> Data {
        try Task.checkCancellation()
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let connection = NWConnection(host: NWEndpoint.Host(pairing.host),
                                      port: NWEndpoint.Port(rawValue: pairing.port)!, using: parameters)
        connection.start(queue: DispatchQueue.global(qos: .userInitiated))
        defer { connection.cancel() }
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    try await send(request, over: connection)
                    return try await receive(over: connection, limit: responseLimit)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(20))
                    throw LANSyncError.timedOut
                }
                defer { group.cancelAll(); connection.cancel() }
                guard let response = try await group.next() else { throw LANSyncError.disconnected }
                return response
            }
        } onCancel: {
            connection.cancel()
        }
    }
}
