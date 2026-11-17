import Foundation

public enum Category: String, Codable, CaseIterable, Identifiable, Sendable {
    case food, weight, mood, knowledge, sport, daily
    public static let allCases: [Self] = [.food, .weight, .mood, .knowledge, .sport]
    public var id: String { rawValue }
    public var title: String {
        switch self { case .food: "饮食"; case .weight: "体重"; case .mood: "心情"; case .knowledge: "知识"; case .sport: "运动"; case .daily: "日常" }
    }
    public var systemImage: String {
        switch self { case .food: "fork.knife"; case .weight: "scalemass"; case .mood: "face.smiling"; case .knowledge: "book"; case .sport: "figure.run"; case .daily: "sparkles" }
    }
}

public enum Meal: String, Codable, CaseIterable, Identifiable, Sendable {
    case breakfast, lunch, dinner, snack
    public var id: String { rawValue }
    public var title: String { switch self { case .breakfast: "早餐"; case .lunch: "午餐"; case .dinner: "晚餐"; case .snack: "加餐" } }
    public static func at(_ date: Date, timeZone: TimeZone = .current) -> Meal {
        var calendar = Calendar.current; calendar.timeZone = timeZone
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        switch minute {
        case 300..<630: return .breakfast
        case 630..<870: return .lunch
        case 870..<1020: return .snack
        case 1020..<1290: return .dinner
        default: return .snack
        }
    }
}

public enum Mood: String, Codable, CaseIterable, Identifiable, Sendable {
    case happy, calm, down, anxious, tired, excited
    public var id: String { rawValue }
    public var title: String { switch self { case .happy: "开心"; case .calm: "平静"; case .down: "低落"; case .anxious: "焦虑"; case .tired: "疲惫"; case .excited: "兴奋" } }
}

public struct CaptureLocation: Codable, Hashable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let horizontalAccuracy: Double?

    public init?(latitude: Double, longitude: Double, horizontalAccuracy: Double? = nil) {
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }

    private enum CodingKeys: String, CodingKey { case latitude, longitude, horizontalAccuracy }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let latitude = try values.decode(Double.self, forKey: .latitude)
        let longitude = try values.decode(Double.self, forKey: .longitude)
        let accuracy = try values.decodeIfPresent(Double.self, forKey: .horizontalAccuracy)
        guard let location = Self(latitude: latitude, longitude: longitude, horizontalAccuracy: accuracy) else {
            throw DecodingError.dataCorruptedError(forKey: .latitude, in: values, debugDescription: "Invalid capture coordinates")
        }
        self = location
    }
}

public struct RecordPayload: Codable, Equatable, Sendable {
    public var meal: Meal?
    public var eatenPercent: Int?
    public var weight: Double?
    public var weightInherited: Bool?
    public var mood: Mood?
    public var intensity: Int?
    public var title: String?
    public var content: String?
    public var note: String?
    public var tags: [String]?
    public var activity: String?
    public var durationMinutes: Int?
    public var captureLocation: CaptureLocation?

    public init(meal: Meal? = nil, eatenPercent: Int? = nil, weight: Double? = nil, weightInherited: Bool? = nil, mood: Mood? = nil, intensity: Int? = nil, title: String? = nil, content: String? = nil, note: String? = nil, tags: [String]? = nil, activity: String? = nil, durationMinutes: Int? = nil) {
        self.meal = meal; self.eatenPercent = eatenPercent; self.weight = weight; self.weightInherited = weightInherited
        self.mood = mood; self.intensity = intensity; self.title = title; self.content = content; self.note = note; self.tags = tags
        self.activity = activity; self.durationMinutes = durationMinutes
    }

    public static func defaults(for category: Category, at date: Date = .now, timeZone: TimeZone = .current, lastWeight: Double? = nil) -> RecordPayload {
        switch category {
        case .food: return RecordPayload(meal: Meal.at(date, timeZone: timeZone), eatenPercent: 80)
        case .weight: return RecordPayload(weight: lastWeight, weightInherited: lastWeight != nil)
        case .mood: return RecordPayload(mood: .calm)
        case .knowledge, .sport, .daily: return RecordPayload()
        }
    }

    public func preservingText(in category: Category, at date: Date = .now, lastWeight: Double? = nil) -> RecordPayload {
        var next = Self.defaults(for: category, at: date, lastWeight: lastWeight)
        next.note = note; next.title = title; next.content = content; next.tags = tags; next.activity = activity
        next.captureLocation = captureLocation
        return next
    }

    public var hasUserContent: Bool {
        [title, content, note].contains { !($0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) } || !(tags?.isEmpty ?? true)
    }
}

public struct MediaRefs: Codable, Equatable, Sendable {
    public var original: String
    public var thumbnail: String
    public var preview: String
    public var originalSHA256: String?
    public init(original: String, thumbnail: String, preview: String, originalSHA256: String? = nil) {
        self.original = original; self.thumbnail = thumbnail; self.preview = preview; self.originalSHA256 = originalSHA256
    }
}

public enum RecordSource: String, Codable, Sendable { case manual, camera }

public struct LifeRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var category: Category
    public var capturedAt: Date
    public var timezone: String
    public var payload: RecordPayload
    public var media: MediaRefs?
    public var updatedAt: Date
    public var deletedAt: Date?
    public var restoredFrom: Date?
    public var revision: Int64
    public var dirty: Bool
    public var source: RecordSource

    public init(id: String = UUID().uuidString.lowercased(), category: Category, capturedAt: Date = .now, timezone: String = TimeZone.current.identifier, payload: RecordPayload, media: MediaRefs? = nil, updatedAt: Date = .now, deletedAt: Date? = nil, revision: Int64 = 0, dirty: Bool = true, source: RecordSource = .manual, restoredFrom: Date? = nil) {
        self.id = id; self.category = category; self.capturedAt = capturedAt; self.timezone = timezone; self.payload = payload
        self.media = media; self.updatedAt = updatedAt; self.deletedAt = deletedAt; self.restoredFrom = restoredFrom; self.revision = revision; self.dirty = dirty; self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case id, category, capturedAt, timezone, payload, media, updatedAt, deletedAt, restoredFrom, revision, dirty, source
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        category = try values.decode(Category.self, forKey: .category)
        capturedAt = try values.decode(Date.self, forKey: .capturedAt)
        timezone = try values.decode(String.self, forKey: .timezone)
        payload = try values.decode(RecordPayload.self, forKey: .payload)
        media = try values.decodeIfPresent(MediaRefs.self, forKey: .media)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        deletedAt = try values.decodeIfPresent(Date.self, forKey: .deletedAt)
        restoredFrom = try values.decodeIfPresent(Date.self, forKey: .restoredFrom)
        revision = try values.decodeIfPresent(Int64.self, forKey: .revision) ?? 0
        dirty = try values.decodeIfPresent(Bool.self, forKey: .dirty) ?? false
        source = try values.decodeIfPresent(RecordSource.self, forKey: .source) ?? .manual
    }

    // Foundation round trips can shift a millisecond boundary when a Date is re-encoded.
    private static let deletionTimestampTolerance: TimeInterval = 0.002

    public var isRecoverableDeletion: Bool {
        guard let deletedAt else { return false }
        // SQLite and CloudKit encode dates to millisecond precision.
        return abs(updatedAt.timeIntervalSince(deletedAt)) < Self.deletionTimestampTolerance
    }

    public func explicitlyRestores(_ deletion: Date) -> Bool {
        restoredFrom.map { abs($0.timeIntervalSince(deletion)) < Self.deletionTimestampTolerance } ?? false
    }

    func allowsRestore(_ restored: LifeRecord) -> Bool {
        guard let deletion = deletedAt, isRecoverableDeletion else { return false }
        return restored.explicitlyRestores(deletion)
    }

    public var captureTimeZone: TimeZone { TimeZone(identifier: timezone) ?? .gmt }

    public var captureDay: String {
        capturedAt.formatted(Date.ISO8601FormatStyle(timeZone: captureTimeZone).year().month().day().dateSeparator(.dash))
    }

    public var summary: String {
        switch category {
        case .food: return [payload.meal?.title, payload.eatenPercent.map { "食用 \($0)%" }].compactMap { $0 }.joined(separator: " · ")
        case .weight: return payload.weight.map { String(format: "%.1f kg", $0) } ?? "未记录数值"
        case .mood: return [payload.mood?.title, payload.intensity.map { "强度 \($0)/5" }].compactMap { $0 }.joined(separator: " · ")
        case .knowledge: return payload.title?.isEmpty == false ? payload.title! : "知识片段"
        case .sport:
            return [payload.activity, payload.durationMinutes.map { "\($0) 分钟" }]
                .compactMap { $0 }.joined(separator: " · ").nonempty ?? "运动记录"
        case .daily: return payload.note?.isEmpty == false ? payload.note! : "日常片段"
        }
    }
}

private extension String {
    var nonempty: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}

public struct RecordDraft: Equatable {
    public private(set) var category: Category
    public var capturedAt: Date
    public var payload: RecordPayload
    public var hasPhoto: Bool
    public var needsCategory: Bool
    public let source: RecordSource
    private var optionsConfirmed = false

    public init(category: Category = .food, capturedAt: Date = .now, lastWeight: Double? = nil,
                hasPhoto: Bool = false, needsCategory: Bool = false, source: RecordSource = .manual) {
        self.category = category
        self.capturedAt = capturedAt
        self.hasPhoto = hasPhoto
        self.needsCategory = needsCategory
        self.source = source
        payload = .defaults(for: category, at: capturedAt, lastWeight: lastWeight)
    }

    public init(record: LifeRecord) {
        self.init(category: record.category, capturedAt: record.capturedAt, hasPhoto: record.media != nil, source: record.source)
        payload = record.payload
        optionsConfirmed = true
    }

    public mutating func select(_ category: Category, lastWeight: Double? = nil) {
        if self.category != category {
            self.category = category
            payload = payload.preservingText(in: category, at: capturedAt, lastWeight: lastWeight)
            optionsConfirmed = false
        }
        needsCategory = false
    }

    public mutating func confirmOptions() { optionsConfirmed = true }

    public var payloadForSave: RecordPayload {
        var result = payload
        if result.weightInherited == true {
            result.weight = nil
            result.weightInherited = nil
        }
        return result
    }

    public var canSave: Bool {
        guard !needsCategory else { return false }
        if let weight = payload.weight, !weight.isFinite || weight <= 0 { return false }
        if let duration = payload.durationMinutes, duration <= 0 { return false }
        if hasPhoto || payload.hasUserContent { return true }
        switch category {
        case .weight: return payloadForSave.weight != nil
        case .sport: return payload.activity?.nonempty != nil || payload.durationMinutes != nil
        case .food, .mood: return optionsConfirmed
        case .knowledge, .daily: return false
        }
    }
}

public struct Classification: Equatable, Sendable {
    public var category: Category
    public var confidence: Double
    public init(category: Category, confidence: Double) { self.category = category; self.confidence = confidence }
}

public enum ShakeError: LocalizedError {
    case invalidRecord, missingMedia, invalidBackup, unauthorized, server(String), modelUnavailable
    public var errorDescription: String? {
        switch self {
        case .invalidRecord: "请至少填写一项有效内容"
        case .missingMedia: "图片文件不存在或不可用"
        case .invalidBackup: "备份文件无效或版本不兼容"
        case .unauthorized: "登录已失效，请重新登录"
        case .server(let message): message
        case .modelUnavailable: "分类模型未安装，请手动选择类别"
        }
    }
}

public enum ShakeCoding {
    private static func formatter(fractional: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter
    }
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter(fractional: true).string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            if let date = formatter(fractional: true).date(from: value) ?? formatter(fractional: false).date(from: value) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid ISO8601 date: \(value)"))
        }
        return decoder
    }()
}
