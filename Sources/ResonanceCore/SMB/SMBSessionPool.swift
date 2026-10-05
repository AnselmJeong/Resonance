import Foundation

/// Pools a small, fixed number of connections. A scanner and the playback cache use separate pools.
public actor SMBSessionPool {
    public typealias Factory = @Sendable (SMBSource) async throws -> any SMBTransport
    private let factory: Factory
    private var sessions: [String: Task<any SMBTransport, Error>] = [:]
    public init(password: @escaping AudioFileAccess.Password) {
        factory = { source in try await SMBClient.connect(source.connection, password: password(source.connection)) }
    }
    public init(factory: @escaping Factory) { self.factory = factory }
    public func session(_ source: SMBSource) async throws -> any SMBTransport {
        let key = source.credentialAccount
        if let task = sessions[key] { return try await task.value }
        // Normally two Aurender shares. Drop idle references rather than growing without bound.
        if sessions.count >= 4 { sessions.removeAll() }
        let task = Task { try await factory(source) }; sessions[key] = task
        do { return try await task.value } catch { sessions[key] = nil; throw error }
    }
    public func reset() { sessions.removeAll() }
    public func invalidate(_ source: SMBSource) { sessions[source.credentialAccount] = nil }

    public func download(_ connection: SMBConnection, path: String, to destination: URL) async throws {
        let source = SMBSource(server: connection.server, share: connection.share, username: connection.username)
        let transport = try await session(source)
        do {
            let before = try await transport.stat(path)
            guard !before.isDirectory, !before.isSymbolicLink, before.size > 0 else { throw AppError.message("재생할 SMB 파일을 확인하세요.") }
            guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw AppError.message("캐시 파일을 만들지 못했습니다.") }
            let file = try FileHandle(forWritingTo: destination); defer { try? file.close() }
            var offset: Int64 = 0
            while offset < before.size {
                try Task.checkCancellation()
                let count = Int(min(1024 * 1024, before.size - offset))
                let data = try await transport.read(path, offset: offset, count: count)
                guard !data.isEmpty, data.count <= count else { throw AppError.message("SMB 다운로드가 중간에 끝났습니다.") }
                try file.write(contentsOf: data); offset += Int64(data.count)
            }
            try file.synchronize()
            let after = try await transport.stat(path)
            guard before.size == after.size, before.modified == after.modified else { throw AppError.message("받는 동안 원본이 변경되었습니다. 재스캔 후 다시 시도하세요.") }
        } catch { invalidate(source); throw error }
    }
}
