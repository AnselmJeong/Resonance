import Foundation
import GRDB

extension LibraryDatabase {
    /// A consistent SQLite backup precedes the transaction. Only root transport data changes;
    /// IDs, paths, album metadata, assertions, stories and queue references remain untouched.
    public func setSMBSource(rootID: String, source: SMBSource?) throws {
        try updateSMBRoots([(rootID, source)])
    }
    public func setSMBSources(_ sources: [String: SMBSource]) throws {
        try updateSMBRoots(sources.map { ($0.key, $0.value) })
    }
    private func updateSMBRoots(_ changes: [(String, SMBSource?)]) throws {
        let existing = try roots()
        let updates = try changes.map { id, source -> LibraryRoot in
            try source?.validate()
            guard var root = existing.first(where: { $0.id == id }) else { throw AppError.message("라이브러리를 찾지 못했습니다.") }
            root.smb = source; root.status = source == nil ? "연결 확인 필요" : "연결됨"
            return root
        }
        guard !updates.isEmpty else { return }
        try pool.backup(to: DatabaseQueue(path: path + ".before-smb-" + UUID().uuidString + ".sqlite"))
        try pool.write { db in
            for root in updates { try db.execute(sql: "UPDATE root SET data=? WHERE id=?", arguments: [try json(root), root.id]) }
        }
    }
    func saveSMBRead(rootID: String, path: String, metrics: MetadataReadMetrics) throws {
        try pool.write { db in
            try db.execute(sql: "INSERT INTO smbReadMetric(rootID,path,data) VALUES(?,?,?) ON CONFLICT(rootID,path) DO UPDATE SET data=excluded.data", arguments: [rootID, path, try json(metrics)])
        }
    }
    public func smbReadMetrics(rootID: String) throws -> [MetadataReadMetrics] {
        try list(MetadataReadMetrics.self, sql: "SELECT data FROM smbReadMetric WHERE rootID=?", args: [rootID])
    }
}

extension LibraryDatabase {
    public func saveSourceArtwork(albumID: String, path: String) throws -> Album {
        guard var album = try album(albumID) else { throw AppError.message("앨범을 찾지 못했습니다.") }
        guard album.artwork.map({ FileManager.default.fileExists(atPath: $0) }) != true else { return album }
        let userArtwork = try pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assertion WHERE entityID=? AND field='artwork' AND source='user'", arguments: [albumID]) ?? 0 }
        guard userArtwork == 0 else { return album }
        album.artwork = path
        try pool.write { db in try db.execute(sql: "UPDATE album SET data=? WHERE id=?", arguments: [try json(album), album.id]) }
        return album
    }
}
