import Foundation
import ShakeCore

struct MCPTools {
    let store: ShakeStoreSnapshot

    struct Failure: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    struct Result {
        var data: [String: Any]
        var photos: [Data] = []
        var count = 0
    }

    private static let pageLimit = 12
    private static let defaultLimit = 6
    private static let string = ["type": "string"]
    private static let categoryValues = (ShakeCore.Category.allCases + [.daily]).map(\.rawValue)
    private static let photoSize: [String: Any] = [
        "type": "string", "enum": MediaStore.ReadingPhotoSize.allCases.map(\.rawValue),
        "default": "standard", "description": "standard 最长边 1024，detail 最长边 2048。两种尺寸均随记录返回照片。"
    ]

    static let definitions: [[String: Any]] = [
        tool("list_categories", "查看可查询的类别及原始字段说明。", [:]),
        tool("search_records", "筛选并分页读取完整记录。有照片的记录同时返回 JPEG 图像和原始字段。", [
            "from": ["type": "string", "format": "date", "description": "记录的当地起始日期，含当日；可省略。"],
            "to": ["type": "string", "format": "date", "description": "记录的当地截止日期，含当日；可省略。"],
            "category": ["type": "string", "enum": categoryValues],
            "keyword": ["type": "string", "maxLength": 120, "description": "匹配保存的标题、正文、备注、标签或活动名称。看照片时可省略。"],
            "order": ["type": "string", "enum": ["newest", "oldest"], "default": "newest"],
            "limit": ["type": "integer", "minimum": 1, "maximum": pageLimit, "default": defaultLimit],
            "cursor": ["type": "string", "description": "上一页返回的 next_cursor；保持日期、类别、关键词和排序不变。"],
            "photo_size": photoSize
        ]),
        tool("get_records", "按 ID 顺序读取一条或多条完整记录，同时返回各自的 JPEG 照片。", [
            "ids": ["type": "array", "minItems": 1, "maxItems": pageLimit, "items": string],
            "photo_size": photoSize
        ], required: ["ids"])
    ]

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any],
                             required: [String] = []) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
         "annotations": ["readOnlyHint": true, "openWorldHint": false]]
    }

    func call(_ name: String, _ args: [String: Any]) throws -> Result {
        var result = Result(data: [
            "sync_status": store.status, "data_as_of": store.dataAsOf?.ISO8601Format() as Any? ?? NSNull()
        ])
        switch name {
        case "list_categories":
            guard args.isEmpty else { throw Failure(text: "list_categories 不接收参数") }
            result.data["categories"] = categories()
        case "search_records":
            let query: Search = try input(args, keys: ["from", "to", "category", "keyword", "order", "limit", "cursor", "photo_size"])
            let (records, next) = try search(query)
            try add(records.map(\.record), photoSize: query.photo_size, to: &result)
            result.data["next_cursor"] = next as Any? ?? NSNull()
        case "get_records":
            let query: Selection = try input(args, keys: ["ids", "photo_size"])
            guard (1...Self.pageLimit).contains(query.ids.count),
                  query.ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else {
                throw Failure(text: "ids 须包含 1–12 个有效记录 ID")
            }
            var seen = Set<String>()
            var missing: [String] = []
            var records: [LifeRecord] = []
            for id in query.ids where seen.insert(id).inserted {
                if let record = try store.repository.get(id) { records.append(record) }
                else { missing.append(id) }
            }
            try add(records, photoSize: query.photo_size, to: &result)
            result.data["missing_ids"] = missing
        default:
            throw Failure(text: "未知工具，请用 tools/list 获取当前接口")
        }
        return result
    }

    private func input<T: Decodable>(_ args: [String: Any], keys: Set<String>) throws -> T {
        guard args.keys.allSatisfy(keys.contains) else { throw Failure(text: "存在未支持的参数") }
        do {
            return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: args))
        } catch {
            throw Failure(text: "参数缺失、类型不正确或取值无效")
        }
    }

    private enum Order: String, Codable { case newest, oldest }

    private struct Search: Decodable {
        let from: String?
        let to: String?
        let category: ShakeCore.Category?
        let keyword: String?
        let order: Order?
        let limit: Int?
        let cursor: String?
        let photo_size: String?
    }

    private struct Selection: Decodable {
        let ids: [String]
        let photo_size: String?
    }

    private struct Filter: Codable, Equatable {
        let from: String?
        let to: String?
        let category: ShakeCore.Category?
        let keyword: String
        let order: Order

        func matches(_ record: LifeRecord) -> Bool {
            let day = (from != nil || to != nil) ? record.captureDay : ""
            if let from, day < from { return false }
            if let to, day > to { return false }
            if keyword.isEmpty { return true }
            let fields = record.payload
            let text = [fields.title, fields.content, fields.note, fields.activity].compactMap { $0 }
            return (text + (fields.tags ?? [])).contains { $0.localizedCaseInsensitiveContains(keyword) }
        }
    }

    private struct Cursor: Codable {
        let filter: Filter
        let position: RecordRepository.Position
    }

    private typealias Row = (record: LifeRecord, position: RecordRepository.Position)

    private func search(_ query: Search) throws -> ([Row], String?) {
        let filter = Filter(from: query.from, to: query.to, category: query.category,
                            keyword: query.keyword?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                            order: query.order ?? .newest)
        let limit = query.limit ?? Self.defaultLimit
        guard (1...Self.pageLimit).contains(limit), filter.keyword.count <= 120 else {
            throw Failure(text: "limit 须为 1–12，关键词最多 120 个字符")
        }
        let from = try dayDate(filter.from)
        let to = try dayDate(filter.to)
        if let from, let to, from > to { throw Failure(text: "起始日期不能晚于截止日期") }

        var position: RecordRepository.Position?
        if let token = query.cursor {
            guard token.utf8.count <= 4096, let data = Data(base64Encoded: token),
                  let cursor = try? JSONDecoder().decode(Cursor.self, from: data), cursor.filter == filter else {
                throw Failure(text: "分页游标无效或筛选条件已改变")
            }
            position = cursor.position
        }
        var matches: [Row] = []
        let batchSize = 64
        while matches.count <= limit {
            // UTC bounds are deliberately wide enough for records captured in any time zone.
            let batch = try store.repository.recordPage(category: filter.category,
                capturedFrom: from?.addingTimeInterval(-86_400), capturedBefore: to?.addingTimeInterval(172_800),
                after: position, oldestFirst: filter.order == .oldest, limit: batchSize)
            matches.append(contentsOf: batch.filter { filter.matches($0.record) }.prefix(limit + 1 - matches.count))
            guard batch.count == batchSize, let last = batch.last else { break }
            position = last.position
        }
        let page = Array(matches.prefix(limit))
        let next = try matches.count > limit ? page.last.map {
            try JSONEncoder().encode(Cursor(filter: filter, position: $0.position)).base64EncodedString()
        } : nil
        return (page, next)
    }

    private func dayDate(_ value: String?) throws -> Date? {
        guard let value else { return nil }
        let formatter = Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day().dateSeparator(.dash)
        guard value.utf8.count == 10, let date = try? formatter.parse(value), date.formatted(formatter) == value else {
            throw Failure(text: "日期须为有效的 YYYY-MM-DD")
        }
        return date
    }

    private func add(_ records: [LifeRecord], photoSize: String?, to result: inout Result) throws {
        guard let size = MediaStore.ReadingPhotoSize(rawValue: photoSize ?? "standard") else {
            throw Failure(text: "photo_size 须为 standard 或 detail")
        }
        var items: [[String: Any]] = []
        for record in records {
            var photo: [String: Any] = ["status": "none"]
            if let refs = record.media {
                photo["status"] = "unavailable"
                if let jpeg = store.media.readingPhoto(refs, size: size) {
                    result.photos.append(jpeg)
                    // The initial JSON text block is at index 0.
                    photo = ["status": "available", "content_index": result.photos.count]
                }
            }
            var fields = record.payload
            fields.captureLocation = nil
            items.append([
                "id": record.id, "date": record.captureDay, "captured_at": record.capturedAt.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)),
                "timezone": record.timezone, "category": record.category.rawValue, "source": record.source.rawValue,
                "fields": try JSONSerialization.jsonObject(with: ShakeCoding.encoder.encode(fields)), "photo": photo
            ])
        }
        result.data["records"] = items
        result.count = items.count
    }

    private func categories() -> [[String: Any]] {
        (ShakeCore.Category.allCases + [.daily]).map { category in
            let fields: [String: Any]
            switch category {
            case .food: fields = ["meal": Meal.allCases.map(\.rawValue), "eatenPercent": "食用比例 0–100"]
            case .weight: fields = ["weight": "千克", "weightInherited": "是否沿用旧值，true 表示这次未确认测量"]
            case .mood: fields = ["mood": Mood.allCases.map(\.rawValue), "intensity": "强度 1–5"]
            case .knowledge: fields = ["title": "标题", "content": "正文", "tags": "标签列表"]
            case .sport: fields = ["activity": "运动名称", "durationMinutes": "分钟"]
            case .daily: fields = [:]
            }
            return ["id": category.rawValue, "title": category.title,
                    "fields": fields.merging(["note": "备注"], uniquingKeysWith: { existing, _ in existing })]
        }
    }
}

struct ShakeStoreSnapshot {
    let repository: RecordRepository
    let media: MediaStore
    let status: String
    let dataAsOf: Date?
}
