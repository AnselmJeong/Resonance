import Foundation

enum AlbumGrouping {
    static func value(_ tags: [String: [String]], _ keys: String...) -> String {
        keys.compactMap { tags[$0]?.first }.first { !$0.isEmpty } ?? ""
    }

    /// Track performers describe individual recordings, not separate editions of an album.
    static func key(root: LibraryRoot, relativePath: String, tags: [String: [String]]) -> String {
        // Pure path operations: identity lookup must not stat every file on a network volume.
        let parent = ((root.path as NSString).appendingPathComponent(relativePath) as NSString).deletingLastPathComponent
        let folder = LibraryScanner.discNumber((parent as NSString).lastPathComponent) == nil ? parent : (parent as NSString).deletingLastPathComponent
        let title = value(tags, "ALBUM")
        return TextKey.id(root.id, String(folder.dropFirst(root.path.count)), title.isEmpty ? (folder as NSString).lastPathComponent : title,
                          value(tags, "BARCODE", "UPC"))
    }

    static func artist(tracks: [Track], fallback: String) -> String {
        let explicit = Set(tracks.map { value($0.tags, "ALBUMARTIST", "ALBUM ARTIST") }.filter { !$0.isEmpty })
        if !explicit.isEmpty { return explicit.count == 1 ? explicit.first! : "Various Artists" }
        let performers = Set(tracks.flatMap { $0.tags["ARTIST"] ?? [] }.filter { !$0.isEmpty })
        return performers.count > 1 ? "Various Artists" : performers.first ?? fallback
    }
}
