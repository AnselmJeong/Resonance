import Foundation
import CryptoKit

public enum TextKey {
    public static func normalize(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }
            .joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    public static func id(_ parts: String...) -> String { hash(parts.joined(separator: "\u{0}")) }
    public static func hash(_ string: String) -> String { SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined() }
    public static func fts(_ text: String) -> String {
        normalize(text).split(separator: " ").map { "\"\($0)\"*" }.joined(separator: " AND ")
    }
    public static func grams(_ text: String) -> Set<String> {
        let chars = Array(normalize(text)); var result = Set<String>()
        for width in 1...3 where chars.count >= width {
            for i in 0...(chars.count - width) { result.insert(String(chars[i..<(i + width)])) }
        }
        return result
    }
    public static func queryGrams(_ text: String) -> [String] {
        let chars = Array(normalize(text)), width = min(3, chars.count)
        guard width > 0 else { return [] }
        return Array(Set((0...(chars.count - width)).map { String(chars[$0..<($0 + width)]) })).sorted()
    }
}

public enum AppPaths {
    public static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Resonance", isDirectory: true)
    }
    public static var cache: URL { support.appendingPathComponent("Artwork", isDirectory: true) }
    public static func prepare() throws {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    }
}

public enum AppError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

public enum SafeLink {
    public static func url(_ value: String) -> URL? {
        guard let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}

public func clockText(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "0:00" }
    let value = max(0, Int(seconds))
    return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%d:%02d", value / 60, value % 60)
}
