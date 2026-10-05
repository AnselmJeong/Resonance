import Foundation

public protocol AudioRangeReader: Sendable {
    var size: Int64 { get }
    func read(offset: Int64, count: Int) async throws -> Data
}

public struct SMBRangeReader: AudioRangeReader {
    public let size: Int64
    public let path: String
    public let transport: any SMBTransport
    public init(size: Int64, path: String, transport: any SMBTransport) { self.size = size; self.path = path; self.transport = transport }
    public func read(offset: Int64, count: Int) async throws -> Data { try await transport.read(path, offset: offset, count: count) }
}

public struct MetadataReadMetrics: Codable, Sendable {
    public var bytes = 0
    public var requests = 0
    public var elapsed: Double = 0
    public var audioOffset: Int64 = 0
    public var status = "complete"
}

/// RFC 9639 metadata walk. No speculative buffer fills and no audio-frame reads.
public enum FLACRangeReader {
    public static func read(_ reader: any AudioRangeReader, includePicture: Bool = false) async throws -> (AudioMetadata, MetadataReadMetrics) {
        var metrics = MetadataReadMetrics(), result = AudioMetadata()
        let start = Date(), maxBytes = includePicture ? 16 * 1024 * 1024 : 2 * 1024 * 1024
        func exact(_ offset: Int64, _ count: Int) async throws -> Data {
            try Task.checkCancellation()
            guard offset >= 0, count >= 0, offset <= reader.size, Int64(count) <= reader.size - offset,
                  count <= maxBytes - metrics.bytes else { throw AppError.message("잘리거나 읽기 상한을 초과한 FLAC 메타데이터입니다.") }
            var data = Data()
            while data.count < count {
                try Task.checkCancellation()
                guard Date().timeIntervalSince(start) < 60 else { throw AppError.message("FLAC 태그 읽기 시간이 초과되었습니다.") }
                let wanted = min(64 * 1024, count - data.count)
                let part = try await reader.read(offset: offset + Int64(data.count), count: wanted)
                metrics.requests += 1; metrics.bytes += part.count
                guard !part.isEmpty, part.count <= wanted else { throw AppError.message("FLAC 메타데이터를 끝까지 읽지 못했습니다.") }
                data.append(part)
            }
            return data
        }
        guard reader.size > 0 else { throw AppError.message("서버 파일의 크기가 0바이트입니다. 원본 파일을 확인하세요.") }
        var signature = try await exact(0, 4), prefix: Int64 = 0
        if signature.prefix(3) == Data("ID3".utf8) {
            let header = signature + (try await exact(4, 6))
            prefix = try FLACPrefix.streamOffset(after: header, fileSize: reader.size)
            signature = try await exact(prefix, 4)
        }
        guard signature == Data("fLaC".utf8) else { throw AppError.message("파일은 열리지만 FLAC 시작 정보가 없습니다. 원본이 손상되었거나 다른 형식일 수 있습니다.") }
        var offset: Int64 = prefix + 4, sawComments = false
        for index in 0..<512 {
            let header = [UInt8](try await exact(offset, 4))
            let type = header[0] & 127, last = header[0] & 128 != 0
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            offset += 4
            guard type != 127, index != 0 || type == 0, type != 0 || index == 0,
                  offset <= reader.size, Int64(length) <= reader.size - offset,
                  offset + Int64(length) - prefix <= 64 * 1024 * 1024 else { throw AppError.message("잘못된 FLAC 블록 길이 또는 순서입니다.") }
            if type == 0 {
                guard length == 34 else { throw AppError.message("잘못된 STREAMINFO입니다.") }
                let bytes = [UInt8](try await exact(offset, length))
                let packed = bytes[10..<18].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                result.sampleRate = Int(packed >> 44); result.channels = Int((packed >> 41) & 7) + 1
                result.bitDepth = Int((packed >> 36) & 31) + 1
                guard result.sampleRate > 0, result.bitDepth >= 4 else { throw AppError.message("잘못된 FLAC 기술 정보입니다.") }
                result.duration = Double(packed & 0xFFFFFFFFF) / Double(result.sampleRate)
            } else if type == 4 {
                guard !sawComments else { throw AppError.message("중복 VORBIS_COMMENT 블록입니다.") }; sawComments = true
                var bytes = ByteReader(data: try await exact(offset, length))
                _ = try bytes.bytes(bytes.u32(little: true))
                let count = try bytes.u32(little: true)
                guard count <= 20_000 else { throw AppError.message("Vorbis tag 개수 상한 초과") }
                for _ in 0..<count {
                    let length = try bytes.u32(little: true)
                    guard length <= 1024 * 1024 else { throw AppError.message("Vorbis tag 크기 상한 초과") }
                    guard let line = String(data: try bytes.bytes(length), encoding: .utf8) else { throw AppError.message("잘못된 UTF-8 태그입니다.") }
                    if let equal = line.firstIndex(of: "=") {
                        result.tags[String(line[..<equal]).uppercased(), default: []].append(String(line[line.index(after: equal)...]))
                    }
                }
            } else if type == 6 && includePicture && length <= 12 * 1024 * 1024 {
                var bytes = ByteReader(data: try await exact(offset, length))
                let kind = try bytes.u32()
                _ = try bytes.bytes(bytes.u32()); _ = try bytes.bytes(bytes.u32())
                for _ in 0..<4 { _ = try bytes.u32() }
                let picture = try bytes.bytes(bytes.u32())
                if kind == 3 || result.picture == nil { result.picture = picture }
            }
            // PICTURE/PADDING/SEEKTABLE/unknown blocks are skipped without reading their bodies.
            offset += Int64(length)
            if last {
                metrics.audioOffset = offset; metrics.elapsed = Date().timeIntervalSince(start)
                return (result, metrics)
            }
        }
        throw AppError.message("FLAC 블록 개수 상한 초과")
    }
}
