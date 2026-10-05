import Testing
import AVFoundation
import GRDB
@testable import ResonanceCore

@Suite struct LibraryMigrationSnapshotTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RESONANCE_COLLECTION_SNAPSHOT"] != nil))
    func folderCollectionsOnLibraryCopy() async throws {
        let sourcePath = try #require(ProcessInfo.processInfo.environment["RESONANCE_COLLECTION_SNAPSHOT"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ResonanceCollectionSnapshot-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = Configuration(); config.readonly = true
        let source = try DatabaseQueue(path: sourcePath, configuration: config)
        let path = directory.appendingPathComponent("Library.sqlite").path, copy = try DatabaseQueue(path: path)
        try source.backup(to: copy)
        let before = try await copy.read { sql in
            (try String.fetchAll(sql, sql: "SELECT data FROM track ORDER BY id"),
             try String.fetchAll(sql, sql: "SELECT id FROM insight ORDER BY id"),
             try String.fetchAll(sql, sql: "SELECT id FROM album WHERE favorite=1 ORDER BY id"),
             try String.fetchOne(sql, sql: "SELECT data FROM preference WHERE key='queue'"),
             try Int.fetchOne(sql, sql: "SELECT COUNT(*) FROM section")!)
        }
        let db = try LibraryDatabase(path: path)
        #expect(try await copy.read { try String.fetchAll($0, sql: "SELECT data FROM track ORDER BY id") } == before.0)
        let roots = try await db.roots(), scanner = LibraryScanner(database: db, cache: directory.appendingPathComponent("Artwork"))
        for root in roots {
            let result = try await scanner.scan(root: root) { _ in }
            #expect(result.finished); #expect(!result.cancelled)
            print("COLLECTION COPY ROOT: \(root.name), \(result.processed) files, \(result.errors.count) errors")
        }
        let sections = try await db.sections()
        for section in sections {
            let root = try #require(roots.first { $0.id == section.rootID })
            #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: root.path).appendingPathComponent(section.relativePath).path))
            #expect(section.name == LibrarySection.folderName(rootPath: root.path, relativePath: section.relativePath))
            #expect(!section.hidden); #expect(section.order == 0)
        }
        #expect(try await copy.read { try String.fetchAll($0, sql: "SELECT id FROM insight ORDER BY id") } == before.1)
        #expect(try await copy.read { try String.fetchAll($0, sql: "SELECT id FROM album WHERE favorite=1 ORDER BY id") } == before.2)
        #expect(try await copy.read { try String.fetchOne($0, sql: "SELECT data FROM preference WHERE key='queue'") } == before.3)
        #expect(try await db.integrityCheck() == "ok")
        #expect(try await copy.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").count } == 0)
        print("COLLECTION COPY: \(before.4) -> \(sections.count) collections; \(before.0.count) original tracks; favorites, stories and queue preserved")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RESONANCE_RELOCATION_SNAPSHOT"] != nil))
    func relocationOnLibraryCopy() async throws {
        let sourcePath = try #require(ProcessInfo.processInfo.environment["RESONANCE_RELOCATION_SNAPSHOT"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ResonanceRelocationSnapshot-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = Configuration(); config.readonly = true
        let source = try DatabaseQueue(path: sourcePath, configuration: config)
        let path = directory.appendingPathComponent("Library.sqlite").path, copy = try DatabaseQueue(path: path)
        try source.backup(to: copy)
        let db = try LibraryDatabase(path: path)
        let root = try #require(try await db.roots().first { $0.path.hasSuffix("/Artist") })
        let before = try await db.counts(), beforeAlbums = try await db.albums(rootID: root.id, limit: 100_000)
        let old = beforeAlbums.filter { $0.folder.contains("/Alexander Tharaud/") }
        #expect(old.count == 4)
        let oldTracks = try await db.scanTracks(rootID: root.id).values.filter { $0.relativePath.hasPrefix("Alexander Tharaud/") }
        #expect(oldTracks.count == 106)
        let queue = try await db.preference("queue", as: QueueSnapshot.self)
        let insightIDs = try await copy.read { try String.fetchAll($0, sql: "SELECT id FROM insight ORDER BY id") }
        let scanner = LibraryScanner(database: db, cache: directory.appendingPathComponent("Artwork"))
        let scan = try await scanner.scan(root: root) { _ in }
        #expect(scan.finished); #expect(!scan.cancelled)
        let after = try await db.counts()
        #expect(after.albums == before.albums - 4); #expect(after.tracks == before.tracks - 106)
        for album in old {
            let current = try #require(try await db.album(album.id))
            #expect(current.folder.contains("/Alexandre Tharaud/"))
            #expect(current.trackCount == album.trackCount)
            #expect(!album.favorite || current.favorite)
        }
        for oldTrack in oldTracks {
            let current = try #require(try await db.rawTrack(oldTrack.id))
            #expect(current.tags == oldTrack.tags); #expect(current.size == oldTrack.size)
            #expect(current.relativePath == oldTrack.relativePath.replacingOccurrences(of: "Alexander Tharaud/", with: "Alexandre Tharaud/"))
            #expect(current.available)
        }
        let saved = try await db.preference("queue", as: QueueSnapshot.self)
        #expect(saved?.entries.map(\.id) == queue?.entries.map(\.id)); #expect(saved?.index == queue?.index); #expect(saved?.position == queue?.position)
        #expect(try await copy.read { try String.fetchAll($0, sql: "SELECT id FROM insight ORDER BY id") } == insightIDs)
        #expect(try await db.integrityCheck() == "ok")
        #expect(try await copy.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").count } == 0)
        let second = try await scanner.scan(root: root) { _ in }
        #expect(second.finished); #expect(try await db.counts().tracks == after.tracks)
        #expect(try await db.counts().albums == after.albums)
        print("RELOCATION COPY: \(before.albums) -> \(after.albums) albums; \(before.tracks) -> \(after.tracks) tracks; \(scan.errors.count) unrelated errors; 106 original track IDs preserved; repeat scan stable")
    }

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
