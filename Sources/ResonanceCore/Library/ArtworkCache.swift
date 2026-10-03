import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ArtworkCache {
    public static func thumbnail(source: URL?, embedded: Data?, key: String, directory: URL, pixels: Int = 480) throws -> String? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(TextKey.hash(key + ":\(pixels)") + ".jpg")
        if FileManager.default.fileExists(atPath: destination.path) { return destination.path }
        var imageSource: CGImageSource?
        if let source { imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) }
        if imageSource == nil, let embedded { imageSource = CGImageSourceCreateWithData(embedded as CFData, nil) }
        guard let imageSource, let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: pixels, kCGImageSourceShouldCacheImmediately: false] as CFDictionary) else { return nil }
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        guard let writer = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(writer, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { try? FileManager.default.removeItem(at: temporary); return nil }
        if FileManager.default.fileExists(atPath: destination.path) { try? FileManager.default.removeItem(at: temporary) } else { try FileManager.default.moveItem(at: temporary, to: destination) }
        return destination.path
    }
    public static func trim(directory: URL, megabytes: Int) throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        let sorted = files.compactMap { url -> (URL, Int, Date)? in
            guard url.pathExtension == "jpg", let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = sorted.reduce(0) { $0 + $1.1 }
        for (url, size, _) in sorted where total > max(50, megabytes) * 1024 * 1024 { try FileManager.default.removeItem(at: url); total -= size }
    }
}
