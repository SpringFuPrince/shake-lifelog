import SwiftUI
import ShakeCore

@MainActor
public final class ShakeStore: ObservableObject {
    @Published public private(set) var records: [LifeRecord] = []
    @Published public private(set) var deletedRecords: [LifeRecord] = []
    @Published public var filter: ShakeCore.Category?
    @Published public var toast: String?
    @Published public var errorMessage: String?

    public let repository: RecordRepository
    public let media: MediaStore
    private var toastTask: Task<Void, Never>?

    public init(root: URL? = nil) throws {
        let support = try root ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                           appropriateFor: nil, create: true)
            .appendingPathComponent("Shake", isDirectory: true)
        repository = try RecordRepository(path: support.appendingPathComponent("shake.sqlite").path)
        media = try MediaStore(root: support.appendingPathComponent("Media", isDirectory: true))
        try refresh()
    }

    public var filteredRecords: [LifeRecord] {
        guard let filter else { return records }
        return records.filter { $0.category == filter }
    }

    public func refresh() throws {
        records = try repository.list()
        deletedRecords = try repository.list(deletedOnly: true)
    }

    #if DEBUG
    public func seedTimelinePhotoFixture() throws {
        let calendar = Calendar.current
        let now = calendar.startOfDay(for: .now).addingTimeInterval(12 * 60 * 60)
        for (index, color) in [Color.indigo, .orange, .pink, .teal, .brown, .purple, .green, .blue].enumerated() {
            let renderer = ImageRenderer(content: color.frame(width: 80, height: 80))
            #if os(iOS)
            let data = renderer.uiImage?.jpegData(compressionQuality: 0.8)
            #else
            let data = renderer.nsImage?.tiffRepresentation
            #endif
            guard let data else { throw ShakeError.missingMedia }
            let id = "timeline-fixture-photo-\(index)"
            let refs = try media.process(data, recordID: id)
            let daysAgo = index < 6 ? 0 : index - 5
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
            try repository.save(LifeRecord(id: id, category: .sport, capturedAt: day.addingTimeInterval(Double(-index)),
                                           payload: RecordPayload(activity: "测试照片 \(index)"), media: refs))
        }
        try repository.save(LifeRecord(id: "timeline-fixture-text", category: .knowledge, capturedAt: now,
                                       payload: RecordPayload(title: "测试文字记录")))
        try refresh()
    }
    #endif

    public func recentWeight() -> Double? { try? repository.recentWeight() }

    public func save(_ draft: RecordDraft, photo: Data?) async throws {
        guard draft.canSave, draft.hasPhoto == (photo != nil) else { throw ShakeError.invalidRecord }
        var record = LifeRecord(category: draft.category, capturedAt: draft.capturedAt,
                                payload: draft.payloadForSave, source: draft.source)
        if let photo {
            let media = self.media
            let id = record.id
            let readPhotoLocation = record.payload.captureLocation == nil
            let (refs, embeddedLocation) = try await Task.detached(priority: .userInitiated) {
                let location = readPhotoLocation ? MediaStore.captureLocation(from: photo) : nil
                return (try media.process(photo, recordID: id), location)
            }.value
            record.media = refs
            if let embeddedLocation { record.payload.captureLocation = embeddedLocation }
        }
        do {
            try repository.save(record)
        } catch {
            try? media.remove(record: record)
            throw error
        }
        try refresh()
        showToast("已保存")
    }

    public func update(_ id: String, draft: RecordDraft) throws {
        guard draft.canSave, var record = try repository.get(id) else { throw ShakeError.invalidRecord }
        record.category = draft.category
        record.payload = draft.payloadForSave
        record.capturedAt = draft.capturedAt
        record.updatedAt = .now
        record.dirty = true
        try repository.save(record)
        try refresh()
    }

    public func delete(_ record: LifeRecord) throws {
        try repository.softDelete(record.id)
        try refresh()
    }

    public func restore(_ record: LifeRecord) throws {
        try repository.restore(record.id)
        try refresh()
    }

    public func purgeExpired() {
        do {
            for record in try repository.purgeExpired() { try media.remove(record: record) }
            let remaining = try repository.list(deletedOnly: true)
            if deletedRecords != remaining { deletedRecords = remaining }
        } catch { errorMessage = error.localizedDescription }
    }

    public func report(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }

    private func showToast(_ text: String) {
        toastTask?.cancel()
        toast = text
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }
}
