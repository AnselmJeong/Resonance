import Foundation
import AMSMB2

struct SMBConnectionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

public struct SMBFileInfo: Sendable, Equatable {
    public let name: String
    public let size: Int64
    public let modified: Double
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public init(name: String, size: Int64, modified: Double, isDirectory: Bool = false, isSymbolicLink: Bool = false) {
        self.name = name; self.size = size; self.modified = modified; self.isDirectory = isDirectory; self.isSymbolicLink = isSymbolicLink
    }
}

public protocol SMBTransport: Sendable {
    func list(_ path: String) async throws -> [SMBFileInfo]
    func stat(_ path: String) async throws -> SMBFileInfo
    func read(_ path: String, offset: Int64, count: Int) async throws -> Data
}

/// One persistent connection per instance. A gate serializes complete library operations,
/// including across actor suspension points. Scanning and playback own separate instances.
public actor SMBClient: SMBTransport {
    private let manager: SMB2Manager
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private init(manager: SMB2Manager) { self.manager = manager }
    public static func connect(_ connection: SMBConnection, password: String) async throws -> SMBClient {
        try connection.validate()
        guard !password.isEmpty, !password.contains("\0") else { throw SMBConnectionError(message: "설정에서 SMB 비밀번호를 저장하세요.") }
        var components = URLComponents(); components.scheme = "smb"; components.host = connection.server
        guard let url = components.url, let manager = SMB2Manager(url: url, credential: URLCredential(user: connection.username, password: password, persistence: .none)) else {
            throw SMBConnectionError(message: "SMB 서버 주소를 확인하세요.")
        }
        manager.timeout = 15
        do { try await manager.connectShare(name: connection.share) }
        catch { throw sanitized(error) }
        try Task.checkCancellation()
        return SMBClient(manager: manager)
    }
    private func enter() async { if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true } }
    private func leave() { if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() } }
    public func list(_ path: String) async throws -> [SMBFileInfo] {
        try SMBSource.validatePath(path)
        await enter(); defer { leave() }; try Task.checkCancellation()
        do {
            let entries = try await manager.contentsOfDirectory(atPath: path, recursive: false)
            try Task.checkCancellation()
            return try entries.map { values in
                guard let name = values[.nameKey] as? String, !name.contains("/") else { throw AppError.message("SMB 서버가 잘못된 파일명을 반환했습니다.") }
                try SMBSource.validatePath(name)
                return Self.info(values, name: name)
            }
        } catch { throw Self.sanitized(error) }
    }
    public func stat(_ path: String) async throws -> SMBFileInfo {
        try SMBSource.validatePath(path)
        await enter(); defer { leave() }; try Task.checkCancellation()
        do { return Self.info(try await manager.attributesOfItem(atPath: path), name: path.split(separator: "/").last.map(String.init) ?? "") }
        catch { throw Self.sanitized(error) }
    }
    public func read(_ path: String, offset: Int64, count: Int) async throws -> Data {
        try SMBSource.validatePath(path)
        guard offset >= 0, count >= 0, count <= 1024 * 1024, offset <= Int64.max - Int64(count) else { throw AppError.message("SMB 읽기 범위가 잘못되었습니다.") }
        if count == 0 { return Data() }
        await enter(); defer { leave() }; try Task.checkCancellation()
        do {
            // This overload bounds libsmb2 reads to exactly the requested range (no read-ahead).
            let data: Data = try await manager.contents(atPath: path, range: offset..<(offset + Int64(count)), progress: nil)
            try Task.checkCancellation(); return data
        } catch { throw Self.sanitized(error) }
    }
    private static func info(_ values: [URLResourceKey: any Sendable], name: String) -> SMBFileInfo {
        let size = (values[.fileSizeKey] as? Int64) ?? Int64(values[.fileSizeKey] as? Int ?? 0)
        return SMBFileInfo(name: name, size: size, modified: (values[.contentModificationDateKey] as? Date)?.timeIntervalSince1970 ?? 0,
                           isDirectory: values[.isDirectoryKey] as? Bool ?? false, isSymbolicLink: values[.isSymbolicLinkKey] as? Bool ?? false)
    }
    private static func sanitized(_ error: Error) -> Error {
        if error is CancellationError { return error }
        let code = (error as NSError).code
        switch code {
        case 2: return AppError.message("SMB 서버에서 파일 또는 폴더를 찾지 못했습니다.")
        case 13, 1: return AppError.message("SMB 인증 또는 읽기 권한을 확인하세요.")
        case 60: return SMBConnectionError(message: "SMB 응답 시간이 초과되었습니다. 서버와 로컬 네트워크 권한을 확인하세요.")
        default: return SMBConnectionError(message: "SMB 연결에 실패했습니다 (코드 \(code)). 서버 주소·계정·로컬 네트워크 권한을 확인하세요.")
        }
    }
}
