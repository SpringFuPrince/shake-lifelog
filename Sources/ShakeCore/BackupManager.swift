import Foundation
import ZIPFoundation
public enum RestoreMode { case merge, replace }
private struct BackupManifest: Codable { var formatVersion: Int; var exportedAt: Date; var records: [LifeRecord] }

public final class BackupManager {
    private let repository: RecordRepository
    private let media: MediaStore
    public init(repository: RecordRepository, media: MediaStore) { self.repository = repository; self.media = media }

    public func export(to destination: URL) throws {
        let files = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".shake-export-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: staging) }

        let archiveURL = staging.appendingPathComponent("backup.zip")
        try writeArchive(to: archiveURL, staging: staging)

        if files.fileExists(atPath: destination.path) {
            let info = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true else { throw ShakeError.invalidBackup }
            _ = try files.replaceItemAt(destination, withItemAt: archiveURL)
        } else {
            try files.moveItem(at: archiveURL, to: destination)
        }
    }

    private func writeArchive(to destination: URL, staging: URL) throws {
        let records = try repository.list(includeDeleted: false)
        let manifest = BackupManifest(formatVersion: 1, exportedAt: .now, records: records)
        let manifestURL = staging.appendingPathComponent("manifest.json")
        try ShakeCoding.encoder.encode(manifest).write(to: manifestURL)

        let archive = try Archive(url: destination, accessMode: .create, pathEncoding: nil)
        try archive.addEntry(with: "manifest.json", fileURL: manifestURL)
        var archivedPaths = Set<String>()
        for record in records {
            guard let refs = record.media else { continue }
            for path in [refs.original, refs.thumbnail, refs.preview] where archivedPaths.insert(path).inserted {
                let source = media.url(for: path)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                let info = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard info.isRegularFile == true, info.isSymbolicLink != true else { throw ShakeError.missingMedia }
                try archive.addEntry(with: "media/\(path)", fileURL: source)
            }
        }
    }

    public func restore(from source: URL, mode: RestoreMode) throws {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let archive = try Archive(url: source, accessMode: .read, pathEncoding: nil)
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("shake-restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        for entry in archive {
            guard !entry.path.hasPrefix("/"), !entry.path.split(separator: "/").contains(".."), entry.type == .file else { continue }
            let destination = staging.appendingPathComponent(entry.path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try archive.extract(entry, to: destination)
        }
        let data = try Data(contentsOf: staging.appendingPathComponent("manifest.json"))
        let manifest = try ShakeCoding.decoder.decode(BackupManifest.self, from: data)
        guard manifest.formatVersion == 1 else { throw ShakeError.invalidBackup }
        let existing = try repository.list(includeDeleted: true)
        let existingIDs = Set(existing.map(\.id))
        let hashOwners = Dictionary(existing.compactMap { record -> (String, MediaRefs)? in
            guard let hash = record.media?.originalSHA256, let refs = record.media else { return nil }; return (hash, refs)
        }, uniquingKeysWith: { first, _ in first })
        var imported = manifest.records
        for index in imported.indices {
            guard let refs = imported[index].media else { continue }
            if let hash = refs.originalSHA256, let reused = hashOwners[hash] {
                imported[index].media = reused; continue
            }
            for path in [refs.original, refs.thumbnail, refs.preview] {
                let file = staging.appendingPathComponent("media/\(path)")
                if FileManager.default.fileExists(atPath: file.path) { try media.save(Data(contentsOf: file), at: path) }
            }
        }
        switch mode {
        case .replace: try repository.replaceAll(with: imported)
        case .merge:
            for record in imported where !existingIDs.contains(record.id) { try repository.save(record) }
        }
    }
}
