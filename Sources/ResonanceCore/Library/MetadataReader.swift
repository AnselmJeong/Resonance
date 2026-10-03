import Foundation
import AVFoundation

public struct AudioMetadata: Sendable {
    public var tags: [String: [String]] = [:]
    public var duration: Double = 0
    public var sampleRate = 0
    public var bitDepth = 0
    public var channels = 0
    public var picture: Data?
    public init() {}
    public func value(_ keys: String...) -> String { keys.compactMap { tags[$0]?.first }.first(where: { !$0.isEmpty }) ?? "" }
}

private struct ByteReader {
    let data: Data; var offset = 0
    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, count <= data.count - offset else { throw AppError.message("잘린 FLAC 메타데이터") }
        defer { offset += count }; return data.subdata(in: offset..<(offset + count))
    }
    mutating func u32(little: Bool = false) throws -> Int {
        let b = [UInt8](try bytes(4))
        return little ? Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16 | Int(b[3]) << 24 : Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
    }
}

public enum MetadataReader {
    public static func flac(_ url: URL) throws -> AudioMetadata {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let fileSize = UInt64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        guard try handle.read(upToCount: 4) == Data("fLaC".utf8) else { throw AppError.message("FLAC 헤더가 올바르지 않습니다.") }
        var result = AudioMetadata(), total = 0
        for _ in 0..<512 {
            guard let header = try handle.read(upToCount: 4), header.count == 4 else { throw AppError.message("잘린 FLAC block header") }
            let b = [UInt8](header), last = b[0] & 128 != 0, type = b[0] & 127
            let length = Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3]); total += length
            guard total <= 64 * 1024 * 1024 else { throw AppError.message("FLAC 메타데이터 크기 상한 초과") }
            guard try handle.offset() + UInt64(length) <= fileSize else { throw AppError.message("잘린 FLAC metadata block") }
            if [0, 4, 6].contains(type), length <= 12 * 1024 * 1024 {
                guard let block = try handle.read(upToCount: length), block.count == length else { throw AppError.message("잘린 FLAC metadata block") }
                if type == 0 {
                    guard block.count == 34 else { throw AppError.message("잘못된 STREAMINFO") }
                    let s = [UInt8](block), packed = s[10..<18].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                    result.sampleRate = Int(packed >> 44); result.channels = Int((packed >> 41) & 7) + 1; result.bitDepth = Int((packed >> 36) & 31) + 1
                    if result.sampleRate > 0 { result.duration = Double(packed & 0xFFFFFFFFF) / Double(result.sampleRate) }
                } else if type == 4 {
                    var reader = ByteReader(data: block)
                    _ = try reader.bytes(reader.u32(little: true))
                    let count = try reader.u32(little: true)
                    guard count <= 20_000 else { throw AppError.message("Vorbis tag 개수 상한 초과") }
                    for _ in 0..<count {
                        let size = try reader.u32(little: true); guard size <= 1024 * 1024 else { throw AppError.message("Vorbis tag 크기 상한 초과") }
                        let line = String(decoding: try reader.bytes(size), as: UTF8.self)
                        if let equal = line.firstIndex(of: "=") {
                            let key = String(line[..<equal]).uppercased(), value = String(line[line.index(after: equal)...])
                            result.tags[key, default: []].append(value)
                        }
                    }
                } else if type == 6 {
                    var reader = ByteReader(data: block)
                    let pictureType = try reader.u32()
                    _ = try reader.bytes(reader.u32()); _ = try reader.bytes(reader.u32())
                    for _ in 0..<4 { _ = try reader.u32() }
                    let size = try reader.u32(), picture = try reader.bytes(size)
                    if pictureType == 3 || result.picture == nil { result.picture = picture }
                }
            } else {
                let current = try handle.offset(); try handle.seek(toOffset: current + UInt64(length))
            }
            if last { guard result.sampleRate > 0 else { throw AppError.message("STREAMINFO가 없습니다.") }; return result }
        }
        throw AppError.message("FLAC block 개수 상한 초과")
    }

    public static func read(_ url: URL) async throws -> AudioMetadata {
        if url.pathExtension.lowercased() == "flac" { return try flac(url) }
        if ["ape", "cue"].contains(url.pathExtension.lowercased()) { return AudioMetadata() }
        let asset = AVURLAsset(url: url)
        var result = AudioMetadata()
        result.duration = try await asset.load(.duration).seconds
        if !result.duration.isFinite { result.duration = 0 }
        let items = try await asset.load(.metadata)
        for item in items {
            if let key = item.commonKey {
                let keys: [AVMetadataKey: String] = [.commonKeyTitle: "TITLE", .commonKeyAlbumName: "ALBUM", .commonKeyArtist: "ARTIST", .commonKeyCreationDate: "DATE"]
                if key == .commonKeyArtwork { result.picture = try? await item.load(.dataValue) }
                if let tag = keys[key], let value = try? await item.load(.stringValue) { result.tags[tag, default: []].append(value) }
            }
            let id3 = ["id3/TCOM": "COMPOSER", "id3/TPE2": "ALBUMARTIST", "id3/TRCK": "TRACKNUMBER", "id3/TPOS": "DISCNUMBER", "id3/TDRC": "DATE", "id3/TYER": "YEAR", "id3/TSRC": "ISRC", "id3/TPUB": "LABEL"]
            if let identifier = item.identifier?.rawValue, let tag = id3[identifier], let value = try? await item.load(.stringValue) { result.tags[tag, default: []].append(value) }
        }
        if let file = try? AVAudioFile(forReading: url) {
            result.sampleRate = Int(file.fileFormat.sampleRate); result.channels = Int(file.fileFormat.channelCount)
            result.duration = Double(file.length) / file.fileFormat.sampleRate
        }
        return result
    }
}
