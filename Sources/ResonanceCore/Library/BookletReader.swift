import Foundation
import PDFKit

public struct BookletPage: Identifiable, Codable, Sendable {
    public var id: Int { number }
    public var number: Int
    public var text: String
}
public struct BookletText: Sendable {
    public var pages: [BookletPage]
    public var pageCount: Int
    public var hasText: Bool { pages.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
}
public enum BookletSource {
    public static func url(albumID: String, path: String, page: Int) -> URL {
        var parts = URLComponents(); parts.scheme = "resonance-booklet"; parts.host = "page"
        parts.queryItems = [.init(name: "album", value: albumID), .init(name: "file", value: TextKey.hash(path)), .init(name: "page", value: String(page))]
        return parts.url!
    }
    public static func reference(_ url: URL) -> (albumID: String, fileID: String, page: Int)? {
        guard url.scheme == "resonance-booklet", url.host == "page", let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        func value(_ key: String) -> String? { parts.queryItems?.first { $0.name == key }?.value }
        guard let album = value("album"), let file = value("file"), let page = value("page").flatMap(Int.init), page > 0 else { return nil }
        return (album, file, page)
    }
    public static func validatedURL(path: String, album: Album, roots: [LibraryRoot]) throws -> URL {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard album.attachments.contains(path), url.pathExtension.lowercased() == "pdf",
              let root = roots.first(where: { $0.id == album.rootID }),
              url.path.hasPrefix(URL(fileURLWithPath: root.path).resolvingSymlinksInPath().path + "/") else {
            throw AppError.message("이 앨범의 음악 폴더에 속한 PDF만 열 수 있습니다.")
        }
        return url
    }
}
public actor BookletReader {
    private var cache: [String: BookletText] = [:]
    public init() {}
    public func attachments(for album: Album) -> [String] {
        let folder = URL(fileURLWithPath: album.folder)
        guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return album.attachments }
        let discovered = items.filter {
            guard $0.pathExtension.lowercased() == "pdf", let values = try? $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }.map(\.path)
        return Array(Set(album.attachments.filter { FileManager.default.fileExists(atPath: $0) } + discovered)).sorted()
    }
    public func read(_ url: URL) throws -> BookletText {
        guard FileManager.default.fileExists(atPath: url.path) else { throw AppError.message("부클릿 파일을 찾을 수 없습니다. 음악 볼륨을 연결한 뒤 다시 열어 주세요.") }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard (values.fileSize ?? 0) <= 100 * 1024 * 1024 else { throw AppError.message("100 MB보다 큰 부클릿은 외부 PDF 앱에서 열어 주세요.") }
        let key = url.path + ":\(values.fileSize ?? 0):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        if let saved = cache[key] { return saved }
        guard let document = PDFDocument(url: url), !document.isLocked else { throw AppError.message("부클릿을 읽을 수 없습니다. 손상되었거나 암호로 보호된 PDF입니다.") }
        guard document.pageCount <= 500 else { throw AppError.message("500쪽보다 긴 PDF는 외부 PDF 앱에서 열어 주세요.") }
        var pages: [BookletPage] = []
        for i in 0..<document.pageCount {
            try Task.checkCancellation()
            pages.append(BookletPage(number: i + 1, text: String((document.page(at: i)?.string ?? "").prefix(30000))))
        }
        let result = BookletText(pages: pages, pageCount: document.pageCount)
        if cache.count >= 8 { cache.removeAll() }; cache[key] = result
        return result
    }
    public static func evidence(album: Album, path: String, pages: [BookletPage]) -> [Evidence] {
        pages.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.prefix(6).map {
            Evidence(title: "\(URL(fileURLWithPath: path).lastPathComponent) · \($0.number)쪽", url: BookletSource.url(albumID: album.id, path: path, page: $0.number).absoluteString, text: String($0.text.prefix(8000)))
        }
    }
}
