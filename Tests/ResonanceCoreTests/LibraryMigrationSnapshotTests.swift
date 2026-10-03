import Testing
import AVFoundation
import GRDB
@testable import ResonanceCore

@Suite struct LibraryMigrationSnapshotTests {
    /// The provided database is read-only; migrations only run against a fresh backup copy.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RESONANCE_LIBRARY_SNAPSHOT"] != nil))
    func migrationOnLibraryCopy() async throws {
        let sourcePath = try #require(ProcessInfo.processInfo.environment["RESONANCE_LIBRARY_SNAPSHOT"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ResonanceMigration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("Library.sqlite").path
        var config = Configuration(); config.readonly = true
        let source = try DatabaseQueue(path: sourcePath, configuration: config)
        let copy = try DatabaseQueue(path: path)
        try source.backup(to: copy)
        let before = try await copy.read { db in
            (try String.fetchAll(db, sql: "SELECT data FROM track ORDER BY id"),
             try String.fetchOne(db, sql: "SELECT data FROM preference WHERE key='queue'"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM credit")!,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM album")!)
        }
        let db = try LibraryDatabase(path: path)
        let after = try await copy.read { sql in
            (try String.fetchAll(sql, sql: "SELECT data FROM track ORDER BY id"),
             try String.fetchOne(sql, sql: "SELECT data FROM preference WHERE key='queue'"),
             try Int.fetchOne(sql, sql: "SELECT COUNT(*) FROM credit")!)
        }
        #expect(before.0.count == after.0.count); #expect(before.1 == after.1); #expect(before.2 == after.2)
        let roots = try await db.roots()
        let rootsByID = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0) })
        var identities: [String: String] = [:]
        for root in roots { identities.merge(try await db.albumIdentities(rootID: root.id)) { first, _ in first } }
        for (original, changed) in zip(before.0, after.0) {
            var lhs = try JSONDecoder().decode(Track.self, from: Data(original.utf8))
            let rhs = try JSONDecoder().decode(Track.self, from: Data(changed.utf8))
            lhs.albumID = rhs.albumID
            #expect(lhs == rhs)
            let root = try #require(rootsByID[rhs.rootID])
            #expect(identities[AlbumGrouping.key(root: root, relativePath: rhs.relativePath, tags: rhs.tags)] == rhs.albumID)
        }
        let brokenLinks = try await copy.read { sql in
            try Int.fetchOne(sql, sql: "SELECT COUNT(*) FROM searchContent WHERE kind IN ('album','track','work') AND albumID IS NOT NULL AND NOT EXISTS (SELECT 1 FROM album WHERE id=searchContent.albumID)")!
        }
        #expect(brokenLinks == 0); #expect(try await db.integrityCheck() == "ok")
        let violations = try await copy.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").count }
        #expect(violations == 0)
        let albums = try await db.albums(limit: 100_000)
        print("MIGRATION COPY: \(before.3) -> \(albums.count) visible albums; \(after.0.count) tracks; \(after.2) credits; queue unchanged")
        for album in albums where album.title.localizedCaseInsensitiveContains("Tribute") && album.title.contains("Kreisler") || album.title.contains("Harmonie du soir") {
            print("MIGRATION ALBUM: \(album.title) | \(album.artist) | \(album.trackCount) tracks")
        }
        let reopened = try LibraryDatabase(path: path)
        #expect(try await reopened.albums(limit: 100_000) == albums)
    }
}
