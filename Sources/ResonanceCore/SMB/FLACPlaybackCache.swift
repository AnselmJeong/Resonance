import Foundation

/// Converts only a private, fully downloaded staging file to native FLAC for Core Audio.
/// Server bytes and library metadata remain unchanged. No audio frames are decoded or rewritten.
enum FLACPlaybackCache {
    static func hasID3Prefix(_ url: URL) throws -> Bool {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        return try file.read(upToCount: 3) == Data("ID3".utf8)
    }

    static func prepare(_ url: URL, originalSize: Int64) throws {
        guard url.pathExtension.lowercased() == "flac", try hasID3Prefix(url) else { return }
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        let header = try input.read(upToCount: 10) ?? Data()
        let start = try FLACPrefix.streamOffset(after: header, fileSize: originalSize)
        try input.seek(toOffset: UInt64(start))
        guard try input.read(upToCount: 4) == Data("fLaC".utf8) else { throw AppError.message("ID3 태그 뒤에 FLAC 스트림이 없습니다.") }
        var end = originalSize
        // Older taggers often added both ID3v2 and a 128-byte ID3v1 trailer. Core Audio
        // otherwise throws on the final audio packet. Restrict this to ID3-wrapped FLAC.
        if originalSize - start >= 128 {
            try input.seek(toOffset: UInt64(originalSize - 128))
            if try input.read(upToCount: 3) == Data("TAG".utf8) { end -= 128 }
        }
        guard end - start >= 42 else { throw AppError.message("ID3 태그 안의 FLAC 스트림이 잘렸습니다.") }
        let output = try FileHandle(forWritingTo: url); defer { try? output.close() }
        var offset = start
        while offset < end {
            try Task.checkCancellation()
            try input.seek(toOffset: UInt64(offset))
            let wanted = Int(min(1024 * 1024, end - offset))
            guard let bytes = try input.read(upToCount: wanted), !bytes.isEmpty else { throw AppError.message("FLAC 재생 캐시를 끝까지 읽지 못했습니다.") }
            try output.seek(toOffset: UInt64(offset - start))
            try output.write(contentsOf: bytes)
            offset += Int64(bytes.count)
        }
        try output.truncate(atOffset: UInt64(end - start))
    }
}
