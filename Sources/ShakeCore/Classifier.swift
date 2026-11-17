import Foundation
import Vision
import CoreML

public protocol ImageClassifying {
    func classify(_ imageData: Data) async throws -> [Classification]
}

public enum ClassifierError: LocalizedError {
    case invalidLabels
    public var errorDescription: String? { "暂未识别照片类别，请手动选择" }
}

public struct ShakeClassifier: ImageClassifying {
    private let modelURL: URL?

    public init(modelURL: URL? = Bundle.main.url(forResource: "ShakeClassifier", withExtension: "mlmodelc")) {
        self.modelURL = modelURL
    }

    public func classify(_ imageData: Data) async throws -> [Classification] {
        let modelURL = self.modelURL
        return try await Task.detached(priority: .userInitiated) {
            let handler = VNImageRequestHandler(data: imageData)
            let observations: [VNClassificationObservation]
            if let modelURL {
                let model = try VNCoreMLModel(for: MLModel(contentsOf: modelURL))
                let request = VNCoreMLRequest(model: model)
                try handler.perform([request])
                observations = request.results as? [VNClassificationObservation] ?? []
            } else {
                let request = VNClassifyImageRequest()
                try handler.perform([request])
                observations = request.results ?? []
            }
            var scores: [Category: Double] = [:]
            for observation in observations.prefix(60) {
                guard let category = Self.category(for: observation.identifier) else { continue }
                scores[category] = max(scores[category] ?? 0, Double(observation.confidence))
            }
            guard !scores.isEmpty else { throw ClassifierError.invalidLabels }
            return Category.allCases
                .map { Classification(category: $0, confidence: scores[$0] ?? 0) }
                .sorted { $0.confidence > $1.confidence }
        }.value
    }

    private static func category(for label: String) -> Category? {
        let normalized = label.lowercased().replacingOccurrences(of: "_", with: " ")
        if let direct = Category.allCases.first(where: { $0.rawValue == normalized || $0.title == label }) {
            return direct
        }
        let vocabulary: [(Category, [String])] = [
            (.weight, ["weighing scale", "bathroom scale", "weight scale"]),
            (.sport, ["exercise", "treadmill", "sports", "running", "sports watch", "fitness", "cycling", "basketball", "tennis", "dumbbell", "barbell"]),
            (.knowledge, ["book", "document", "text", "magazine", "notebook", "printed page"]),
            (.food, ["food", "meal", "cuisine", "dish", "fruit", "vegetable", "pizza", "rice", "soup", "sandwich", "cake"]),
            (.mood, ["landscape", "flower", "sunset", "pet", "scenery", "sky", "nature"])
        ]
        return vocabulary.first { _, words in
            words.contains { normalized.range(of: "\\b" + $0 + "\\b", options: .regularExpression) != nil }
        }?.0
    }
}

public enum ClassificationPolicy {
    public static func draft(from classifications: [Classification], at date: Date, lastWeight: Double?) -> (draft: RecordDraft, alternatives: [Classification], modelUnavailable: Bool) {
        guard let best = classifications.first else {
            return (RecordDraft(capturedAt: date, lastWeight: lastWeight, hasPhoto: true,
                                needsCategory: true, source: .camera), [], true)
        }
        return (RecordDraft(category: best.category, capturedAt: date, lastWeight: lastWeight,
                            hasPhoto: true, source: .camera),
                best.confidence < 0.7 ? Array(classifications.prefix(3)) : [], false)
    }
}
