import Foundation

/// Compatibility with files carrying an ID3v2 tag before the native FLAC stream.
/// The tag body is skipped, never downloaded to locate the FLAC signature.
enum FLACPrefix {
    static func streamOffset(after header: Data, fileSize: Int64) throws -> Int64 {
        let bytes = [UInt8](header)
        guard bytes.count == 10, header.prefix(3) == Data("ID3".utf8),
              (2...4).contains(bytes[3]), bytes[4] != 255,
              bytes[6...9].allSatisfy({ $0 < 128 }) else {
            throw AppError.message("잘못된 ID3 시작 태그입니다.")
        }
        let reserved: UInt8 = bytes[3] == 2 ? 0x3f : bytes[3] == 3 ? 0x1f : 0x0f
        guard bytes[5] & reserved == 0 else { throw AppError.message("알 수 없는 ID3 시작 태그 플래그입니다.") }
        let length = bytes[6...9].reduce(Int64(0)) { ($0 << 7) | Int64($1) }
        let offset = 10 + length + (bytes[3] == 4 && bytes[5] & 0x10 != 0 ? 10 : 0)
        guard offset <= 64 * 1024 * 1024, fileSize >= 4, offset <= fileSize - 4 else {
            throw AppError.message("잘리거나 크기 상한을 초과한 ID3 시작 태그입니다.")
        }
        return offset
    }
}
