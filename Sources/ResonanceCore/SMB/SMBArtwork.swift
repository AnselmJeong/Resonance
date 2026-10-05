import Foundation

/// Optional album-level artwork, requested only when opening an album. Never called by the scanner.
public enum SMBArtwork {
    public static func load(source: SMBSource, track: Track, transport: any SMBTransport, cache: URL) async throws -> String? {
        let parent = (track.relativePath as NSString).deletingLastPathComponent
        let folder = LibraryScanner.discNumber((parent as NSString).lastPathComponent) == nil ? parent : (parent as NSString).deletingLastPathComponent
        let remoteFolder = try source.path(folder)
        let entries = try await transport.list(remoteFolder)
        let preferred = ["cover", "folder", "front"]
        let covers = entries.filter { !$0.isDirectory && !$0.isSymbolicLink && $0.size > 0 && $0.size <= 12 * 1024 * 1024 && ["jpg", "jpeg", "png"].contains(($0.name as NSString).pathExtension.lowercased()) }
            .sorted { (preferred.firstIndex(of: ($0.name as NSString).deletingPathExtension.lowercased()) ?? 9) < (preferred.firstIndex(of: ($1.name as NSString).deletingPathExtension.lowercased()) ?? 9) }
        var picture: Data?
        if let cover = covers.first {
            let path = remoteFolder.isEmpty ? cover.name : remoteFolder + "/" + cover.name
            var data = Data()
            while data.count < cover.size {
                try Task.checkCancellation()
                let wanted = Int(min(1024 * 1024, cover.size - Int64(data.count)))
                let part = try await transport.read(path, offset: Int64(data.count), count: wanted)
                guard !part.isEmpty, part.count <= wanted else { throw AppError.message("커버를 읽지 못했습니다.") }
                data.append(part)
            }
            picture = data
        } else if track.format == "FLAC" {
            picture = try await FLACRangeReader.read(SMBRangeReader(size: track.size, path: source.path(track.relativePath), transport: transport), includePicture: true).0.picture
        }
        return try ArtworkCache.thumbnail(source: nil, embedded: picture, key: track.albumID + ":smb-art:" + String(track.modified), directory: cache)
    }
}
