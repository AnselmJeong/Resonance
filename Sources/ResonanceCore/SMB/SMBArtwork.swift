import Foundation

/// Optional artwork fetched by the background collector or visible cards, separately from tag scanning.
public enum SMBArtwork {
    public static func load(source: SMBSource, track: Track, transport: any SMBTransport, cache: URL) async throws -> String? {
        let parent = (track.relativePath as NSString).deletingLastPathComponent
        let folder = LibraryScanner.discNumber((parent as NSString).lastPathComponent) == nil ? parent : (parent as NSString).deletingLastPathComponent
        let folders = folder == parent ? [folder] : [folder, parent]
        let preferred = ["cover", "folder", "front"]
        for folder in folders {
            let remoteFolder = try source.path(folder)
            let entries = try await transport.list(remoteFolder)
            let covers = entries.filter { !$0.isDirectory && !$0.isSymbolicLink && $0.size > 0 && $0.size <= 12 * 1024 * 1024 && ["jpg", "jpeg", "png"].contains(($0.name as NSString).pathExtension.lowercased()) }
                .sorted {
                    let lhs = preferred.firstIndex(of: ($0.name as NSString).deletingPathExtension.lowercased()) ?? 9
                    let rhs = preferred.firstIndex(of: ($1.name as NSString).deletingPathExtension.lowercased()) ?? 9
                    return (lhs, $0.name) < (rhs, $1.name)
                }
            for cover in covers.prefix(6) {
                let path = remoteFolder.isEmpty ? cover.name : remoteFolder + "/" + cover.name
                var data = Data()
                while data.count < cover.size {
                    try Task.checkCancellation()
                    let wanted = Int(min(1024 * 1024, cover.size - Int64(data.count)))
                    let part = try await transport.read(path, offset: Int64(data.count), count: wanted)
                    guard !part.isEmpty, part.count <= wanted else { throw AppError.message("커버를 읽지 못했습니다.") }
                    data.append(part)
                }
                if let image = try ArtworkCache.thumbnail(source: nil, embedded: data, key: track.albumID + ":smb-art:" + path + ":" + String(cover.modified), directory: cache) { return image }
            }
        }
        guard track.format == "FLAC" else { return nil }
        let picture = try await FLACRangeReader.read(SMBRangeReader(size: track.size, path: source.path(track.relativePath), transport: transport), includePicture: true).0.picture
        return try ArtworkCache.thumbnail(source: nil, embedded: picture, key: track.albumID + ":smb-art:" + String(track.modified), directory: cache)
    }
}
