import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

public enum MediaKind: String { case original, thumbnail, preview }

public final class MediaStore {
    public let root: URL
    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    public func url(for relativePath: String) -> URL {
        let safe = relativePath.split(separator: "/").filter { $0 != ".." && $0 != "." }.map(String.init).joined(separator: "/")
        return root.appendingPathComponent(safe)
    }

    public static func captureLocation(from data: Data) -> CaptureLocation? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              let latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
              let longitude = gps[kCGImagePropertyGPSLongitude] as? Double,
              let northOrSouth = gps[kCGImagePropertyGPSLatitudeRef] as? String,
              let eastOrWest = gps[kCGImagePropertyGPSLongitudeRef] as? String,
              ["N", "S"].contains(northOrSouth), ["E", "W"].contains(eastOrWest) else { return nil }
        return CaptureLocation(latitude: northOrSouth == "S" ? -abs(latitude) : abs(latitude),
                               longitude: eastOrWest == "W" ? -abs(longitude) : abs(longitude),
                               horizontalAccuracy: gps[kCGImagePropertyGPSHPositioningError] as? Double)
    }

    public func process(_ source: Data, recordID: String) throws -> MediaRefs {
        guard let image = Self.image(from: source) else { throw ShakeError.missingMedia }
        let original = try Self.jpeg(image, maxDimension: nil, quality: 0.92)
        let thumbnail = try Self.jpeg(image, maxDimension: 480, quality: 0.82)
        var preview = try Self.jpeg(image, maxDimension: 2048, quality: 0.82)
        if preview.count > 2_000_000 { preview = try Self.jpeg(image, maxDimension: 1600, quality: 0.68) }
        if preview.count > 2_000_000 { preview = try Self.jpeg(image, maxDimension: 1200, quality: 0.58) }
        let refs = MediaRefs(original: "\(recordID)/original.jpg", thumbnail: "\(recordID)/thumbnail.jpg", preview: "\(recordID)/preview.jpg",
                             originalSHA256: SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined())
        try save(original, at: refs.original); try save(thumbnail, at: refs.thumbnail); try save(preview, at: refs.preview)
        return refs
    }
    public func isAvailable(_ refs: MediaRefs) -> Bool {
        [refs.original, refs.thumbnail, refs.preview].allSatisfy {
            FileManager.default.fileExists(atPath: url(for: $0).path)
        }
    }

    public func installCloudPhoto(_ data: Data, refs: MediaRefs) throws {
        guard let image = Self.image(from: data) else { throw ShakeError.missingMedia }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard refs.originalSHA256 == nil || refs.originalSHA256 == hash else { throw ShakeError.missingMedia }
        try save(data, at: refs.original)
        try save(Self.jpeg(image, maxDimension: 480, quality: 0.82), at: refs.thumbnail)
        try save(Self.jpeg(image, maxDimension: 1600, quality: 0.68), at: refs.preview)
    }

    public func save(_ data: Data, at relativePath: String) throws {
        let target = url(for: relativePath)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    }
    public func data(_ relativePath: String) throws -> Data { try Data(contentsOf: url(for: relativePath)) }

    public enum ReadingPhotoSize: String, CaseIterable {
        case standard, detail

        var dimension: Int { self == .standard ? 1024 : 2048 }
        var byteLimit: Int { self == .standard ? 360_000 : 900_000 }
    }

    public func readingPhoto(_ refs: MediaRefs, size: ReadingPhotoSize) -> Data? {
        let candidates = size == .detail
            ? [refs.original, refs.preview, refs.thumbnail]
            : [refs.preview, refs.original, refs.thumbnail]
        for path in candidates {
            guard let source = CGImageSourceCreateWithURL(url(for: path) as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: size.dimension
                  ] as CFDictionary) else { continue }
            if let data = try? Self.jpeg(image, maxDimension: nil, quality: 0.82), data.count <= size.byteLimit {
                return data
            }
            if let data = try? Self.jpeg(image, maxDimension: size.dimension / 2, quality: 0.64), data.count <= size.byteLimit {
                return data
            }
        }
        return nil
    }
    public func remove(record: LifeRecord) throws {
        guard let media = record.media else { return }
        let directory = url(for: media.original).deletingLastPathComponent()
        if directory.path.hasPrefix(root.path + "/") { try? FileManager.default.removeItem(at: directory) }
    }

    public func clear() throws {
        for child in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: child)
        }
    }

    private static func image(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let orientation = properties[kCGImagePropertyOrientation] as? Int, orientation != 1,
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height)
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
    private static func resized(_ image: CGImage, maxDimension: Int?) -> CGImage {
        guard let maxDimension else { return image }
        let largest = max(image.width, image.height)
        guard largest > maxDimension else { return image }
        let scale = Double(maxDimension) / Double(largest)
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.interpolationQuality = .high
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context?.makeImage() ?? image
    }
    private static func jpeg(_ source: CGImage, maxDimension: Int?, quality: Double) throws -> Data {
        let image = resized(source, maxDimension: maxDimension)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw ShakeError.missingMedia }
        // Re-encoding from CGImage deliberately drops EXIF/GPS and other sensitive source metadata.
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ShakeError.missingMedia }
        return data as Data
    }
}
