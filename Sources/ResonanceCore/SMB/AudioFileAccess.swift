import Foundation
import CryptoKit

public final class AudioFileLease: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var cleanup: (@Sendable () -> Void)?
    init(url: URL, cleanup: (@Sendable () -> Void)? = nil) { self.url = url; self.cleanup = cleanup }
    public func release() { lock.lock(); let action = cleanup; cleanup = nil; lock.unlock(); action?() }
    deinit { release() }
}

/// Playback-only cache. Scanners cannot obtain a full-file download through this API.
public actor AudioFileAccess {
    public typealias Password = @Sendable (SMBConnection) async throws -> String
    typealias Download = @Sendable (SMBConnection, String, String, URL) async throws -> Void
    private var connections: [SMBConnection] = []
    private let directory: URL
    private let password: Password
    private let download: Download
    private let capacity: Int64
    private let pool: SMBSessionPool?
    private struct Receipt: Codable {
        var originalSize: Int64
        var cachedSize: Int64
        var digest: String
    }
    private struct Flight {
        var task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<AudioFileLease, Error>]
    }
    private var inFlight: [String: Flight] = [:]
    private var leases: [String: Int] = [:]
    private var reservations: [String: Int64] = [:]
    private var cleaned = false

    public init(directory: URL, capacity: Int64 = 4 * 1024 * 1024 * 1024, password: @escaping Password) {
        self.directory = directory; self.capacity = capacity; self.password = password
        let pool = SMBSessionPool(password: password); self.pool = pool
        self.download = { connection, path, _, destination in try await pool.download(connection, path: path, to: destination) }
    }
    init(directory: URL, capacity: Int64, password: @escaping Password, download: @escaping Download) {
        self.directory = directory; self.capacity = capacity; self.password = password; self.download = download; pool = nil
    }
    public func configure(_ connections: [SMBConnection]) async { self.connections = connections; await pool?.reset() }
    public func beginScan() {} // Compatibility with the old diagnostic; never used for metadata.

    public func resolve(root: LibraryRoot, track: Track) async throws -> AudioFileLease {
        if let source = root.smb {
            try source.validate()
            let remote = try source.path(track.relativePath)
            // Re-stat before using cache, so a changed remote file cannot silently reuse an old version.
            if let pool {
                let transport = try await pool.session(source)
                let version = try await transport.stat(remote)
                guard SMBFileVersion.matches(size: version.size, modified: version.modified, track: track) else { throw AppError.message("원격 음원이 변경되었습니다. 라이브러리를 재스캔하세요.") }
            }
            let file = try await cached(remote: remote, sourceID: root.id, size: track.size, modified: track.modified, connection: source.connection)
            do {
                if let pool {
                    let transport = try await pool.session(source)
                    let version = try await transport.stat(remote)
                    guard SMBFileVersion.matches(size: version.size, modified: version.modified, track: track) else { throw AppError.message("재생 준비 중 원본이 변경되었습니다. 라이브러리를 재스캔하세요.") }
                }
                try Task.checkCancellation(); return file
            } catch { file.release(); throw error }
        }
        return try await resolve(URL(fileURLWithPath: root.path).appendingPathComponent(track.relativePath), size: track.size, modified: track.modified)
    }
    public func resolve(_ url: URL, size: Int64, modified: Double) async throws -> AudioFileLease {
        try Task.checkCancellation()
        do {
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }; _ = try handle.read(upToCount: 1)
            return AudioFileLease(url: url)
        } catch {
            guard Self.isMissingFile(error), let connection = connections.filter({ $0.enabled && url.path.hasPrefix($0.mountPath + "/") }).max(by: { $0.mountPath.count < $1.mountPath.count }) else { throw error }
            return try await cached(remote: connection.remotePath(for: url), sourceID: connection.id, size: size, modified: modified, connection: connection)
        }
    }
    static func isMissingFile(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain && ns.code == 2 { return true }
        if ns.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(ns.code) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isMissingFile(underlying) }
        return false
    }
    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !cleaned {
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.pathExtension == "partial" {
                try FileManager.default.removeItem(at: url)
            }
            cleaned = true
        }
    }
    private func cached(remote: String, sourceID: String, size: Int64, modified: Double, connection: SMBConnection) async throws -> AudioFileLease {
        try Task.checkCancellation(); try connection.validate(); try SMBSource.validatePath(remote)
        guard size > 0, modified.isFinite, size <= capacity else { throw AppError.message("파일 크기를 확인할 수 없거나 재생 캐시 용량을 초과했습니다.") }
        try prepareDirectory()
        let key = TextKey.id(sourceID, connection.server, connection.share, connection.username, remote, String(size), String(modified))
        let ext = (remote as NSString).pathExtension.lowercased()
        let destination = directory.appendingPathComponent(key + "." + ext)
        let receipt = directory.appendingPathComponent(key + ".sha256")
        if Self.validCache(destination, receipt: receipt, originalSize: size) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
            return lease(destination, key: key)
        }
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if var flight = inFlight[key] {
                    if flight.task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                    flight.waiters[waiter] = continuation; inFlight[key] = flight; return
                }
                let staging = directory.appendingPathComponent(UUID().uuidString + ".partial", isDirectory: true)
                do {
                    try makeRoom(for: size)
                    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                } catch { continuation.resume(throwing: error); return }
                reservations[key] = size
                let task = Task {
                    let partial = staging.appendingPathComponent("audio." + ext)
                    let result: Result<URL, Error>
                    do {
                        defer { try? FileManager.default.removeItem(at: staging) }
                        let secret = try await password(connection)
                        try Task.checkCancellation()
                        try await download(connection, remote, secret, partial)
                        try Task.checkCancellation()
                        guard (try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(size) else { throw AppError.message("SMB 다운로드가 완전하지 않습니다.") }
                        // Header validation is not an audio integrity test. The digest verifies cache reuse only.
                        try FLACPlaybackCache.prepare(partial, originalSize: size)
                        _ = try await MetadataReader.read(partial)
                        let cachedSize = (try FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value ?? 0
                        let record = Receipt(originalSize: size, cachedSize: cachedSize, digest: try Self.digest(partial))
                        let receiptData = try JSONEncoder().encode(record)
                        try Task.checkCancellation()
                        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                        try FileManager.default.moveItem(at: partial, to: destination)
                        try receiptData.write(to: receipt, options: .atomic)
                        result = .success(destination)
                    } catch { result = .failure(error) }
                    complete(key, result: result)
                }
                inFlight[key] = Flight(task: task, waiters: [waiter: continuation])
            }
        } onCancel: { Task { await self.cancel(key: key, waiter: waiter) } }
    }
    private func complete(_ key: String, result: Result<URL, Error>) {
        guard let flight = inFlight.removeValue(forKey: key) else { return }
        reservations[key] = nil
        for waiter in flight.waiters.values {
            switch result {
            case .success(let url): waiter.resume(returning: lease(url, key: key))
            case .failure(let error): waiter.resume(throwing: error)
            }
        }
    }
    private func cancel(key: String, waiter: UUID) {
        guard var flight = inFlight[key], let continuation = flight.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(throwing: CancellationError())
        if flight.waiters.isEmpty { flight.task.cancel() }
        inFlight[key] = flight
    }
    private static func validCache(_ url: URL, receipt: URL, originalSize: Int64) -> Bool {
        guard let actual = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              let data = try? Data(contentsOf: receipt) else { return false }
        if let record = try? JSONDecoder().decode(Receipt.self, from: data) {
            return record.originalSize == originalSize && record.cachedSize > 0 && record.cachedSize <= originalSize
                && record.cachedSize == Int64(actual) && record.digest == (try? digest(url))
        }
        // Preserve old native caches, but refresh ID3-wrapped files through the compatibility step.
        guard Int64(actual) == originalSize, let expected = String(data: data, encoding: .utf8),
              url.pathExtension.lowercased() != "flac" || (try? FLACPlaybackCache.hasID3Prefix(url)) == false else { return false }
        return expected == (try? digest(url))
    }
    private static func digest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }; var hash = SHA256()
        while let bytes = try file.read(upToCount: 1024 * 1024), !bytes.isEmpty { try Task.checkCancellation(); hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func lease(_ url: URL, key: String) -> AudioFileLease {
        leases[key, default: 0] += 1
        return AudioFileLease(url: url) { Task { await self.release(key) } }
    }
    private func release(_ key: String) { leases[key] = max(0, (leases[key] ?? 1) - 1) }
    private func makeRoom(for incoming: Int64) throws {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
        let files = entries.compactMap { url -> (URL, Int64, Date)? in
            guard url.pathExtension != "sha256", let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]), values.isDirectory != true else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = files.reduce(Int64(0)) { $0 + $1.1 } + reservations.values.reduce(0, +)
        for (url, size, _) in files where total + incoming > capacity {
            let key = url.deletingPathExtension().lastPathComponent
            guard leases[key, default: 0] == 0, inFlight[key] == nil else { continue }
            try fm.removeItem(at: url); try? fm.removeItem(at: directory.appendingPathComponent(key + ".sha256")); total -= size
        }
        guard total + incoming <= capacity else { throw AppError.message("재생 캐시가 사용 중입니다. 현재/다음 곡을 위한 여유 공간이 없습니다.") }
        let free = (try fm.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard incoming + reservations.values.reduce(0, +) + 64 * 1024 * 1024 <= free else { throw AppError.message("음원을 받을 디스크 여유 공간이 부족합니다.") }
    }
}
