import Testing
import AVFoundation
import GRDB
@testable import ResonanceCore

@Suite(.serialized) final class CoreTests {
    private var temporaryDirectories: [URL] = []
    deinit { for url in temporaryDirectories { try? FileManager.default.removeItem(at: url) } }
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ResonanceTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url); return url
    }
    private func database(_ directory: URL) throws -> LibraryDatabase { try LibraryDatabase(path: directory.appendingPathComponent("test.sqlite").path) }
    private func flac(tags: [String] = [], samples: UInt64 = 96000) -> Data {
        var stream = Data(repeating: 0, count: 34)
        let packed = UInt64(96000) << 44 | UInt64(1) << 41 | UInt64(23) << 36 | samples
        for i in 0..<8 { stream[10 + i] = UInt8((packed >> UInt64((7 - i) * 8)) & 255) }
        func little(_ n: Int) -> Data { Data((0..<4).map { UInt8((n >> ($0 * 8)) & 255) }) }
        var comments = little(0) + little(tags.count)
        for tag in tags { comments += little(tag.utf8.count); comments += Data(tag.utf8) }
        return Data("fLaC".utf8) + Data([0, 0, 0, 34]) + stream + Data([132, UInt8((comments.count >> 16) & 255), UInt8((comments.count >> 8) & 255), UInt8(comments.count & 255)]) + comments
    }
    private func writeAudio(_ root: URL, path: String, tags: [String]) throws {
        let url = root.appendingPathComponent(path); try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try flac(tags: tags).write(to: url)
    }
    private func sample(_ directory: URL) async throws -> (LibraryDatabase, LibraryRoot, LibrarySection, Album, Track) {
        let db = try database(directory), root = LibraryRoot(path: directory.appendingPathComponent("music").path)
        let section = LibrarySection(rootID: root.id, relativePath: "Classic", name: "Classic")
        let album = Album(id: "album-1", rootID: root.id, sectionID: section.id, folder: root.path, title: "Mémoire", artist: "Alexandre Tharaud", date: "2026-09-25", label: "Warner", barcode: "1200214264086")
        let track = Track(id: "track-1", rootID: root.id, albumID: album.id, relativePath: "Impromptu.flac", title: "Impromptu", number: 1, credits: [Credit(artistID: "gounod", name: "Charles Gounod", role: "composer")])
        try await db.saveRoot(root); try await db.saveSection(section); try await db.upsert(album: album, tracks: [track], scanID: "scan")
        return (db, root, section, album, track)
    }
    @Test func testFLACRepeatedTagsAndBounds() throws {
        let dir = try temporary(), url = dir.appendingPathComponent("valid.flac")
        try flac(tags: ["album=Mémoire", "COMPOSER=Charles Gounod", "composer=Germaine Tailleferre", "TRACKNUMBER=1/27"]).write(to: url)
        let metadata = try MetadataReader.flac(url)
        #expect(metadata.sampleRate == 96000); #expect(metadata.bitDepth == 24); #expect(metadata.channels == 2); #expect(metadata.duration == 1)
        #expect(metadata.tags["COMPOSER"]?.count == 2); #expect(LibraryScanner.number(metadata.value("TRACKNUMBER")) == 1)
        for bad in [Data("fLaC".utf8), Data("bad!".utf8), Data("fLaC".utf8) + Data([128, 0, 0, 34]) + Data(repeating: 0, count: 10)] {
            try bad.write(to: url); #expect(throws: (any Error).self) { try MetadataReader.flac(url) }
        }
    }
    @Test func testUnicodeSearchAndUntrustedFTSInput() async throws {
        let (db, _, section, album, track) = try await sample(temporary())
        for query in ["Memoire", "Mémoire", "Mémoire", "MEMOIRE", "Memoire\" OR *"] {
            let result = try await db.search(query)
            if query.contains(" OR ") { continue }
            #expect(result.contains { $0.entityID == album.id })
        }
        let empty = try await db.search("\"()* -"); #expect(empty.isEmpty)
        try await db.addAlias(artistID: "gounod", alias: "구노")
        let korean = try await db.search("구노"); #expect(korean.contains { $0.entityID == "gounod" })
        try await db.addAlias(artistID: "gounod", alias: "シャルル・グノー")
        let japanese = try await db.search("グノ"); #expect(japanese.contains { $0.entityID == "gounod" })
        try await db.upsert(album: album, tracks: [track], scanID: "new-scan")
        let aliasAfterRescan = try await db.search("구노"); #expect(aliasAfterRescan.contains { $0.entityID == "gounod" })
        let sectionPeople = try await db.search("Gounod", sectionID: section.id); #expect(sectionPeople.contains { $0.kind == "artist" })
    }
    @Test func testRootAlbumBrowsingKeepsScopeAcrossPagesAndFilters() async throws {
        let dir = try temporary(), db = try database(dir)
        let roots = ["Artist", "Composer", "Contemporary"].map { LibraryRoot(path: dir.appendingPathComponent($0).path) }
        let sections = roots.map { LibrarySection(rootID: $0.id, relativePath: "Shared", name: "Shared") }
        for (root, section) in zip(roots, sections) {
            try await db.saveRoot(root); try await db.saveSection(section)
        }
        for index in 0..<5 {
            let rootIndex = index % 2
            let album = Album(id: "scoped-\(index)", rootID: roots[rootIndex].id, sectionID: sections[rootIndex].id, folder: roots[rootIndex].path, title: "Album \(index)", artist: "Same artist", date: "202\(index)")
            try await db.upsert(album: album, tracks: [], scanID: "scan")
        }
        #expect(try await db.albums().count == 5)
        let first = try await db.albums(rootID: roots[0].id, limit: 2)
        let second = try await db.albums(rootID: roots[0].id, limit: 2, offset: 2)
        #expect((first + second).map(\.id) == ["scoped-0", "scoped-2", "scoped-4"])
        #expect(try await db.albums(rootID: roots[1].id).map(\.id) == ["scoped-1", "scoped-3"])
        #expect(try await db.albums(rootID: roots[2].id).isEmpty)
        #expect(try await db.albums(rootID: "missing-root").isEmpty)
        #expect(try await db.albums(rootID: roots[0].id, sort: "date").map(\.id) == ["scoped-4", "scoped-2", "scoped-0"])
        #expect(try await db.albums(rootID: roots[0].id, sectionID: sections[1].id).isEmpty)
        try await db.setFavorite("scoped-2", value: true)
        try await db.setFavorite("scoped-3", value: true)
        #expect(try await db.albums(rootID: roots[0].id, favorites: true).map(\.id) == ["scoped-2"])
        // The imported root remains authoritative even after a custom collection move.
        try await db.editAlbum("scoped-2", title: "Album 2", artist: "Same artist", sectionID: sections[1].id)
        #expect(try await db.albums(rootID: roots[0].id).map(\.id) == ["scoped-0", "scoped-2", "scoped-4"])
        var hidden = sections[0]; hidden.hidden = true; try await db.saveSection(hidden)
        #expect(try await db.albums(rootID: roots[0].id).map(\.id) == ["scoped-2"])
        #expect(try await db.albums().count == 3)
    }

    @Test func testRootSearchUsesTrackRelationshipsForSharedEntities() async throws {
        let dir = try temporary(), db = try database(dir)
        let roots = ["Artist", "Composer", "Contemporary"].map { LibraryRoot(path: dir.appendingPathComponent($0).path) }
        var works: [String] = []
        for (index, root) in roots.enumerated() {
            let section = LibrarySection(rootID: root.id, relativePath: "Shared", name: "Shared")
            try await db.saveRoot(root); try await db.saveSection(section)
            guard index < 2 else { continue }
            let album = Album(id: "album-\(index)", rootID: root.id, sectionID: section.id, folder: root.path, title: "Shared Album", artist: "Shared Artist")
            let track = Track(id: "track-\(index)", rootID: root.id, albumID: album.id, relativePath: "01.flac", title: "Shared Track", number: 1, format: index == 0 ? "FLAC" : "MP3", tags: ["WORK": ["Shared Work"]], credits: [Credit(artistID: "shared-artist", name: "Shared Artist", role: "composer"), Credit(artistID: "unique-\(index)", name: "Shared Performer \(index)", role: "performer")])
            try await db.upsert(album: album, tracks: [track], scanID: "scan")
            works.append(TextKey.id(album.id, "work", "Shared Work"))
        }
        // Link one work to recordings in both roots. Its search document still points at root 0.
        let raw = try GRDB.DatabaseQueue(path: db.path)
        let sharedWorkID = works[0]
        try await raw.write { db in
            try db.execute(sql: "INSERT INTO recordingWork(recordingID,workID,source) VALUES(?,?,'musicbrainz')", arguments: ["recording:track-1", sharedWorkID])
        }
        let first = try await db.search("Shared", rootID: roots[0].id)
        #expect(Set(first.map(\.entityID)) == Set(["album-0", "track-0", "shared-artist", "unique-0", works[0]]))
        let second = try await db.search("Shared", rootID: roots[1].id)
        #expect(Set(second.map(\.entityID)) == Set(["album-1", "track-1", "shared-artist", "unique-1", works[0], works[1]]))
        #expect(try await db.search("Shared", rootID: roots[2].id).isEmpty)
        #expect(try await db.search("Shared", rootID: "missing-root").isEmpty)
        #expect(try await db.search("Shared").count == 9)
        #expect(try await db.search("Shared", rootID: roots[0].id, format: "MP3").isEmpty)
        #expect(try await db.search("Shared", rootID: roots[1].id, format: "MP3").map(\.entityID) == ["track-1"])
        let composerHits = try await db.search("Shared", rootID: roots[0].id, role: "composer")
        #expect(Set(composerHits.map(\.entityID)) == Set(["shared-artist", "track-0"]))
        _ = try await db.removeRoot(roots[0].id)
        #expect(try await db.search("Shared", rootID: roots[0].id).isEmpty)
        #expect(try await db.search("Shared", rootID: roots[1].id).contains { $0.entityID == works[0] })
    }

    @Test func testMultidiscCopiesExclusionsAndSymlink() async throws {
        let dir = try temporary(), music = dir.appendingPathComponent("music"), external = dir.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        try writeAudio(music, path: "Classic/Artist/Album/CD 1/01.flac", tags: ["ALBUM=Same title", "ARTIST=Artist", "DISCNUMBER=1", "TRACKNUMBER=1"])
        try writeAudio(music, path: "Classic/Artist/Album/CD 2/01.flac", tags: ["ALBUM=Same title", "ARTIST=Artist", "DISCNUMBER=2", "TRACKNUMBER=1"])
        try writeAudio(music, path: "Classic/Artist/Other edition/01.flac", tags: ["ALBUM=Same title", "ARTIST=Artist", "TRACKNUMBER=1"])
        try writeAudio(music, path: "__backup__/01.flac", tags: ["ALBUM=Excluded"])
        try writeAudio(external, path: "escaped.flac", tags: ["ALBUM=Escaped"])
        try FileManager.default.createSymbolicLink(at: music.appendingPathComponent("loop"), withDestinationURL: music)
        try FileManager.default.createSymbolicLink(at: music.appendingPathComponent("escape"), withDestinationURL: external)
        let db = try database(dir), root = LibraryRoot(path: music.path)
        try await db.saveRoot(root)
        let scanner = LibraryScanner(database: db, cache: dir.appendingPathComponent("cache"))
        let first = try await scanner.scan(root: root) { _ in }
        #expect(first.processed == 3); #expect(first.finished)
        let albums = try await db.albums(); #expect(albums.count == 2)
        let joined = try #require(albums.first { $0.trackCount == 2 }), tracks = try await db.tracks(albumID: joined.id)
        #expect(tracks.map(\.disc) == [1, 2])
        try await db.editAlbum(joined.id, title: "수동 표시명", artist: "수동 연주자", sectionID: joined.sectionID)
        try await db.setFavorite(joined.id, value: true)
        let second = try await scanner.scan(root: root) { _ in }
        #expect(second.reused == 3)
        let stored = try await db.album(joined.id); #expect(stored?.title == "수동 표시명"); #expect(stored?.favorite == true)
        // A changed file must also preserve manual assertions.
        try writeAudio(music, path: "Classic/Artist/Album/CD 1/01.flac", tags: ["ALBUM=Same title", "ARTIST=Artist", "DISCNUMBER=1", "TRACKNUMBER=1", "COMMENT=changed"])
        _ = try await scanner.scan(root: root) { _ in }
        let edited = try await db.album(joined.id); #expect(edited?.title == "수동 표시명")
        let integrity = try await db.integrityCheck(); #expect(integrity == "ok")
    }
    @Test func testCompilationGroupingAcrossScanBatchesAndEditions() async throws {
        let dir = try temporary(), music = dir.appendingPathComponent("music")
        for disc in 1...2 {
            for number in 1...(disc == 1 ? 20 : 22) {
                try writeAudio(music, path: "Classic/Tribute/CD\(disc)/\(number).flac", tags: ["ALBUM=Tribute (CD\(disc))", "ARTIST=Performer \(number % 6)", "DISCNUMBER=\(disc)", "TRACKNUMBER=\(number)"])
            }
        }
        try writeAudio(music, path: "Classic/Other edition/1.flac", tags: ["ALBUM=Tribute (CD1)", "ARTIST=Solo artist"])
        try writeAudio(music, path: "Classic/Tribute/CD1/different-upc.flac", tags: ["ALBUM=Tribute (CD1)", "ARTIST=Solo artist", "UPC=another-edition"])
        for number in 1...2 {
            try writeAudio(music, path: "Classic/Explicit/\(number).flac", tags: ["ALBUM=Explicit compilation", "ALBUMARTIST=Album Ensemble", "ARTIST=Performer \(number)"])
        }
        let db = try database(dir), root = LibraryRoot(path: music.path)
        try await db.saveRoot(root)
        let scanner = LibraryScanner(database: db, cache: dir.appendingPathComponent("cache"))
        let first = try await scanner.scan(root: root) { _ in }
        #expect(first.finished); #expect(first.errors.isEmpty); #expect(first.processed == 46)
        let albums = try await db.albums()
        #expect(albums.count == 5)
        let discs = albums.filter { $0.artist == "Various Artists" }
        #expect(discs.map(\.trackCount).sorted() == [20, 22])
        #expect(albums.first { $0.title == "Explicit compilation" }?.artist == "Album Ensemble")
        for album in discs {
            let tracks = try await db.tracks(albumID: album.id)
            #expect(Set(tracks.flatMap(\.credits).filter { $0.role == "performer" }.map(\.name)).count == 6)
        }
        let second = try await scanner.scan(root: root) { _ in }
        #expect(second.reused == 46)
        #expect(try await db.albums().map(\.id) == albums.map(\.id))
        #expect(try await db.search("Various Artists").filter { $0.kind == "album" }.count == 2)
    }

    @Test func testLegacyCompilationMigrationPreservesTracksQueueAndCredits() async throws {
        let dir = try temporary(), music = dir.appendingPathComponent("music")
        let root = LibraryRoot(path: music.path), section = LibrarySection(rootID: root.id, relativePath: "Classic", name: "Classic")
        var seed: LibraryDatabase? = try database(dir)
        try await seed!.saveRoot(root); try await seed!.saveSection(section)
        var fragments: [String: (Album, [Track])] = [:]
        for disc in 1...2 {
            for number in 1...(disc == 1 ? 20 : 22) {
                let performer = disc == 1 ? (number <= 14 ? "Ricci" : "Kreisler") : "Performer \(number % 6)"
                let relative = "Classic/Tribute/CD\(disc)/\(number).flac", title = "Tribute (CD\(disc))"
                let tags = ["ALBUM": [title], "ARTIST": [performer], "DISCNUMBER": ["\(disc)"], "TRACKNUMBER": ["\(number)"], "WORK": ["Shared work"]]
                try writeAudio(music, path: relative, tags: tags.flatMap { key, values in values.map { key + "=" + $0 } })
                let values = try music.appendingPathComponent(relative).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let oldID = TextKey.id(root.id, "/Classic/Tribute", title, performer, "")
                let album = Album(id: oldID, rootID: root.id, sectionID: section.id, folder: music.appendingPathComponent("Classic/Tribute").path, title: title, artist: performer)
                let track = Track(id: TextKey.id(root.id, relative), rootID: root.id, albumID: oldID, relativePath: relative, title: "Piece \(disc)-\(number)", number: number, disc: disc, duration: 1, size: Int64(values.fileSize!), modified: values.contentModificationDate!.timeIntervalSince1970, tags: tags, credits: [Credit(artistID: TextKey.id(oldID, "performer", performer), name: performer, role: "performer")])
                if fragments[oldID] == nil { fragments[oldID] = (album, []) }
                fragments[oldID]!.1.append(track)
            }
        }
        for (album, tracks) in fragments.values { try await seed!.upsert(album: album, tracks: tracks, scanID: "old") }
        #expect(try await seed!.albums().count == 8)
        let originalTracks = fragments.values.flatMap { $0.1 }.sorted { $0.id < $1.id }
        let favorite = try #require(fragments.values.first { $0.0.artist == "Kreisler" })
        let aliasTrack = try #require(fragments.values.first { $0.0.artist == "Ricci" }?.1.first), artistID = aliasTrack.credits[0].artistID
        try await seed!.setFavorite(favorite.0.id, value: true)
        try await seed!.editAlbum(favorite.0.id, title: "My Tribute CD1", artist: "My compilation", sectionID: section.id)
        try await seed!.addAlias(artistID: artistID, alias: "Legacy alias")
        let queue = QueueSnapshot(entries: originalTracks.prefix(3).map { QueueEntry(trackID: $0.id) }, index: 1, position: 12)
        try await seed!.setPreference("queue", value: queue)
        let candidate = ReleaseCandidate(id: "partial", title: favorite.0.title, artist: favorite.0.artist, date: "", barcode: "", trackCount: favorite.1.count, score: 100, reasons: [], country: "", disambiguation: "")
        let match = ReleaseMatch(candidate: candidate, tracks: favorite.1.map { MatchedTrack(disc: $0.disc, number: $0.number, title: $0.title, recordingID: "remote-" + $0.id, credits: [], works: []) })
        try await seed!.confirmMatch(albumID: favorite.0.id, match: match)
        let insight = Insight(entityID: favorite.0.id, kind: "album", language: "ko", payload: InsightPayload(sections: [], claims: [], uncertainties: []), evidence: [], model: "fixture")
        try await seed!.saveInsight(insight)
        seed = nil
        // Recreate the pre-fix schema in this disposable fixture, then exercise the real migration.
        let raw = try DatabaseQueue(path: dir.appendingPathComponent("test.sqlite").path)
        try await raw.write { db in
            try db.execute(sql: "DROP INDEX album_grouping; ALTER TABLE album DROP COLUMN groupingKey; DROP TABLE albumMergeArchive; DELETE FROM grdb_migrations WHERE identifier='v3-album-grouping'")
        }
        let beforeBytes = try Data(contentsOf: music.appendingPathComponent(aliasTrack.relativePath))
        let db = try database(dir), albums = try await db.albums()
        #expect(albums.count == 2); #expect(albums.map(\.trackCount).sorted() == [20, 22])
        #expect(albums.first { $0.id == favorite.0.id }?.favorite == true)
        #expect(albums.first { $0.id == favorite.0.id }?.title == "My Tribute CD1")
        #expect(albums.first { $0.id != favorite.0.id }?.artist == "Various Artists")
        for original in originalTracks {
            let track = try #require(try await db.track(original.id))
            #expect(track.tags == original.tags); #expect(track.credits == original.credits)
            #expect(track.relativePath == original.relativePath); #expect(albums.contains { $0.id == track.albumID })
        }
        let restored = try #require(try await db.preference("queue", as: QueueSnapshot.self))
        #expect(restored.entries == queue.entries); #expect(restored.index == queue.index); #expect(restored.position == 12)
        #expect(try await db.artist(artistID)?.aliases == ["Legacy alias"])
        #expect(try await db.confirmedMatch(favorite.0.id) == nil)
        #expect(try await db.insight(entityID: favorite.0.id, language: "ko") == nil)
        let archived = try await raw.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM albumMergeArchive") }
        #expect(archived == 8)
        let oldWorks = try await db.works(trackID: aliasTrack.id)
        let scanner = LibraryScanner(database: db, cache: dir.appendingPathComponent("cache"))
        let rescanned = try await scanner.scan(root: root) { _ in }
        #expect(rescanned.reused == 42)
        #expect(try Data(contentsOf: music.appendingPathComponent(aliasTrack.relativePath)) == beforeBytes)
        try writeAudio(music, path: aliasTrack.relativePath, tags: aliasTrack.tags.flatMap { k, vs in vs.map { k + "=" + $0 } } + ["COMMENT=changed"])
        _ = try await scanner.scan(root: root) { _ in }
        #expect(try await db.albums().count == 2)
        #expect(try await db.track(aliasTrack.id)?.credits == aliasTrack.credits)
        #expect(try await db.works(trackID: aliasTrack.id).map(\.id) == oldWorks.map(\.id))
        #expect(try await db.search("Tribute").filter { $0.kind == "album" }.count == 2)
        #expect(try await db.integrityCheck() == "ok")
        let reopened = try database(dir)
        #expect(try await reopened.albums().map(\.id) == albums.map(\.id))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.contains("before-migration") })
    }
    @Test func testDisconnectAndPartialFailurePreserveIndex() async throws {
        let dir = try temporary(), music = dir.appendingPathComponent("music")
        try writeAudio(music, path: "Jazz/Album/01.flac", tags: ["ALBUM=Album", "TRACKNUMBER=1"])
        let db = try database(dir), root = LibraryRoot(path: music.path); try await db.saveRoot(root)
        let scanner = LibraryScanner(database: db, cache: dir.appendingPathComponent("cache"))
        _ = try await scanner.scan(root: root) { _ in }
        let album = try #require(try await db.albums().first), track = try #require(try await db.tracks(albumID: album.id).first)
        let disconnected = dir.appendingPathComponent("disconnected")
        try FileManager.default.moveItem(at: music, to: disconnected)
        do { _ = try await scanner.scan(root: root) { _ in }; Issue.record("Offline scan succeeded") } catch {}
        let preserved = try await db.track(track.id); #expect(preserved?.available == true)
        try FileManager.default.moveItem(at: disconnected, to: music)
        try Data("bad".utf8).write(to: music.appendingPathComponent("Jazz/Album/01.flac"))
        let failed = try await scanner.scan(root: root) { _ in }; #expect(!(failed.errors.isEmpty))
        let retained = try await db.track(track.id); #expect(retained?.available == true)
        try FileManager.default.removeItem(at: music.appendingPathComponent("Jazz/Album/01.flac"))
        _ = try await scanner.scan(root: root) { _ in }
        let missing = try await db.track(track.id); #expect(missing?.available == false)
        let count = try await db.counts(); #expect(count.tracks == 1)
    }
    @Test func testBackupQueueAndAssertions() async throws {
        let dir = try temporary(), (db, _, _, album, _) = try await sample(dir)
        try await db.setFavorite(album.id, value: true)
        let snapshot = QueueSnapshot(entries: [QueueEntry(trackID: "track-1")], position: 23.5)
        try await db.setPreference("queue", value: snapshot)
        let path = dir.appendingPathComponent("backup.sqlite").path; try await db.backup(to: path)
        let backup = try LibraryDatabase(path: path), saved = try await backup.preference("queue", as: QueueSnapshot.self)
        #expect(saved?.position == 23.5)
        let favorite = try await backup.album(album.id); #expect(favorite?.favorite == true)
        let result = try await backup.integrityCheck(); #expect(result == "ok")
    }
    @Test func testRemoveRootPreservesOtherLibraryAndOriginalFiles() async throws {
        let dir = try temporary(), (db, root, section, album, track) = try await sample(dir)
        let original = URL(fileURLWithPath: root.path).appendingPathComponent(track.relativePath)
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = flac(tags: ["TITLE=Original"]); try bytes.write(to: original)
        let other = LibraryRoot(path: dir.appendingPathComponent("other").path)
        let otherSection = LibrarySection(rootID: other.id, relativePath: "Jazz", name: "Jazz")
        let otherAlbum = Album(id: "other-album", rootID: other.id, sectionID: otherSection.id, folder: other.path, title: "Remaining album", artist: "Remaining artist")
        let otherTrack = Track(id: "other-track", rootID: other.id, albumID: otherAlbum.id, relativePath: "01.flac", title: "Remaining track", number: 1, credits: track.credits)
        try await db.saveRoot(other); try await db.saveSection(otherSection)
        try await db.upsert(album: otherAlbum, tracks: [otherTrack], scanID: "other-scan")
        try await db.addAlias(artistID: "gounod", alias: "구노")
        let sharedWork = Work(id: "shared-work", title: "Shared composition", source: "musicbrainz")
        func match(_ album: Album, _ track: Track) -> ReleaseMatch {
            let candidate = ReleaseCandidate(id: album.id + "-release", title: album.title, artist: album.artist, date: "", barcode: "", trackCount: 1, score: 100, reasons: [], country: "", disambiguation: "")
            return ReleaseMatch(candidate: candidate, tracks: [MatchedTrack(disc: 1, number: 1, title: track.title, recordingID: "remote-" + track.id, credits: [], works: [sharedWork])])
        }
        try await db.confirmMatch(albumID: otherAlbum.id, match: match(otherAlbum, otherTrack))
        try await db.confirmMatch(albumID: album.id, match: match(album, track))
        try await db.editAlbum(album.id, title: "Removed library title", artist: album.artist, sectionID: section.id)
        try await db.editAlbum(otherAlbum.id, title: otherAlbum.title, artist: otherAlbum.artist, sectionID: section.id)
        let entries = [QueueEntry(trackID: track.id), QueueEntry(trackID: otherTrack.id)]
        try await db.setPreference("queue", value: QueueSnapshot(entries: entries, index: 1, position: 23.5))
        let removed = try await db.removeRoot(root.id)
        #expect(removed == [track.id])
        #expect(try Data(contentsOf: original) == bytes)
        #expect(try await db.roots().map(\.id) == [other.id])
        #expect(try await db.sections().map(\.id) == [otherSection.id])
        #expect(try await db.album(album.id) == nil)
        #expect(try await db.album(otherAlbum.id)?.sectionID == otherSection.id)
        #expect(try await db.track(track.id) == nil)
        #expect(try await db.confirmedMatch(album.id) == nil)
        #expect(try await db.search("Removed library title").isEmpty)
        #expect(try await db.search("Impromptu").isEmpty)
        #expect(try await db.search("구노").contains { $0.entityID == "gounod" })
        #expect(try await db.workTracks(sharedWork.id).map(\.id) == [otherTrack.id])
        #expect(try await db.search("Shared composition").first?.albumID == otherAlbum.id)
        let queue = try #require(try await db.preference("queue", as: QueueSnapshot.self))
        #expect(queue.entries == [entries[1]]); #expect(queue.index == 0); #expect(queue.position == 23.5)
        #expect(try await db.integrityCheck() == "ok")
        // Reconnecting the same root must start from its tags, without removed overrides.
        try await db.saveRoot(root); try await db.saveSection(section)
        try await db.upsert(album: album, tracks: [track], scanID: "reconnect")
        #expect(try await db.album(album.id)?.title == album.title)
        _ = try await db.removeRoot(root.id); _ = try await db.removeRoot(other.id)
        #expect(try await db.search("구노").isEmpty)
        #expect(try await db.search("Shared composition").isEmpty)
        #expect(try await db.preference("queue", as: QueueSnapshot.self)?.entries.isEmpty == true)
    }
    @Test func testRemoveRootAfterScanCancellationDoesNotReappear() async throws {
        let dir = try temporary(), music = dir.appendingPathComponent("music"), db = try database(dir)
        for n in 1...50 { try writeAudio(music, path: "Album/\(n).flac", tags: ["ALBUM=Scan fixture", "TRACKNUMBER=\(n)"]) }
        let root = LibraryRoot(path: music.path); try await db.saveRoot(root)
        let scanner = LibraryScanner(database: db, cache: dir.appendingPathComponent("cache"))
        let task = Task { try await scanner.scan(root: root) { _ in withUnsafeCurrentTask { $0?.cancel() } } }
        let progress = try await task.value
        #expect(progress.cancelled)
        #expect(progress.processed == 25)
        _ = try await db.removeRoot(root.id)
        let reopened = try LibraryDatabase(path: db.path), counts = try await reopened.counts()
        #expect(counts.albums == 0); #expect(counts.tracks == 0)
        #expect(try await reopened.roots().isEmpty)
        #expect(try await reopened.scanHistory().isEmpty)
        #expect(try await reopened.search("Scan fixture").isEmpty)
        #expect(FileManager.default.fileExists(atPath: music.appendingPathComponent("Album/50.flac").path))
    }
    @Test func testRemovingQueuedTracksPreservesCurrentOrResetsPosition() {
        let a = QueueEntry(trackID: "a"), b = QueueEntry(trackID: "b"), c = QueueEntry(trackID: "c")
        let queue = QueueSnapshot(entries: [a, b, c], index: 1, position: 42)
        let before = queue.removingTracks(["a"])
        #expect(before.entries == [b, c]); #expect(before.index == 0); #expect(before.position == 42)
        let current = queue.removingTracks(["b"])
        #expect(current.entries == [a, c]); #expect(current.index == 1); #expect(current.position == 0)
        let all = queue.removingTracks(["a", "b", "c"])
        #expect(all.entries.isEmpty); #expect(all.position == 0); #expect(all.index == 0)
    }
    @Test func testExternalMatchingRetainsLocalFactsAndRejectsStructure() async throws {
        let (db, _, _, album, track) = try await sample(temporary())
        let candidate = ReleaseCandidate(id: UUID().uuidString, title: album.title, artist: album.artist, date: album.date, barcode: "1200214263720", trackCount: 1, score: 30, reasons: ["Different CD edition"], country: "FR", disambiguation: "CD")
        let credit = Credit(artistID: "mb:tailleferre", name: "Germaine Tailleferre", role: "composer", source: "musicbrainz")
        let wrong = ReleaseMatch(candidate: candidate, tracks: [MatchedTrack(disc: 2, number: 1, title: "Impromptu", recordingID: "remote", credits: [credit], works: [])])
        do { try await db.confirmMatch(albumID: album.id, match: wrong); Issue.record("Wrong disc accepted") } catch {}
        let match = ReleaseMatch(candidate: candidate, tracks: [MatchedTrack(disc: 1, number: 1, title: "Impromptu", recordingID: "remote", credits: [credit], works: [])])
        try await db.confirmMatch(albumID: album.id, match: match)
        let merged = try await db.track(track.id); #expect(merged?.credits.count == 2)
        try await db.upsert(album: album, tracks: [track], scanID: "rescan")
        let rescan = try await db.track(track.id); #expect(rescan?.credits.contains(credit) ?? false)
        try await db.removeMatch(albumID: album.id)
        let restored = try await db.track(track.id); #expect(restored?.credits == track.credits)
    }
    @Test func testEvidenceAndLinkValidation() throws {
        let source = Evidence(title: "Official", url: "https://example.com/album", text: "This recording features a solo piano performance.")
        let valid = InsightPayload(sections: [.init(title: "녹음", text: "피아노 녹음", source_ids: [source.id])], claims: [.init(text: "피아노", source_id: source.id, quote: "a solo piano performance")], uncertainties: [])
        #expect(throws: Never.self) { try valid.validate(evidence: [source]) }
        let fabricated = InsightPayload(sections: valid.sections, claims: [.init(text: "Made up", source_id: source.id, quote: "Recorded in Paris in 2024")], uncertainties: [])
        #expect(throws: (any Error).self) { try fabricated.validate(evidence: [source]) }
        let unknown = InsightPayload(sections: [.init(title: "Bad", text: "Bad", source_ids: ["unknown"])], claims: valid.claims, uncertainties: [])
        #expect(throws: (any Error).self) { try unknown.validate(evidence: [source]) }
        let typographic = InsightPayload(sections: valid.sections, claims: [.init(text: "피아노", source_id: source.id, quote: "This  recording … SOLO piano"), .init(text: "Made up", source_id: source.id, quote: "Recorded in Paris in 2024")], uncertainties: [])
        #expect(try typographic.verified(evidence: [source]).claims.count == 1)
        #expect(SafeLink.url("javascript:alert(1)") == nil); #expect(SafeLink.url("file:///tmp/private") == nil); #expect(PublicWebURL.validate("http://127.0.0.1/private") == nil); #expect(PublicWebURL.validate("http://server.local") == nil)
    }
    @Test func testOfflineInsight() async throws {
        let dir = try temporary(), db = try database(dir)
        let source = Evidence(title: "Official", url: "https://example.com/album", text: "This recording features a solo piano performance.")
        let payload = InsightPayload(sections: [.init(title: "녹음", text: "피아노 녹음", source_ids: [source.id])], claims: [.init(text: "피아노", source_id: source.id, quote: "a solo piano performance")], uncertainties: [])
        let insight = Insight(entityID: "target", kind: "album", language: "ko", payload: payload, evidence: [source], model: "fixture")
        try await db.saveInsight(insight)
        let reopened = try LibraryDatabase(path: db.path), cached = try await reopened.insight(entityID: "target", language: "ko")
        #expect(cached?.payload.sections.first?.text == "피아노 녹음"); #expect(cached?.evidence.first?.url == source.url)
    }
    @Test func testActualMemoireMetadataScanAndDecode() async throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let music = project.appendingPathComponent("Alexandre Tharaud")
        guard FileManager.default.fileExists(atPath: music.path) else { print("SKIP: local example music is not distributed with source"); return }
        let dir = try temporary(), db = try database(dir), root = LibraryRoot(path: music.path)
        try await db.saveRoot(root)
        let scanner = LibraryScanner(database: db, cache: dir.appendingPathComponent("cache")), progress = try await scanner.scan(root: root) { _ in }
        #expect(progress.processed == 27); #expect(progress.errors.isEmpty)
        let albums = try await db.albums(); #expect(albums.count == 1)
        let album = try #require(albums.first), tracks = try await db.tracks(albumID: album.id)
        #expect(tracks.map(\.number) == Array(1...27)); #expect(tracks.filter { $0.title == "Impromptu" }.map(\.number) == [2, 10])
        #expect(tracks.filter { $0.credits.contains { $0.role == "composer" } }.count == 3)
        #expect(album.barcode == "1200214264086"); #expect(abs((tracks.reduce(0) { $0 + $1.duration }) - (3879)) <= 5)
        for track in tracks {
            #expect(track.sampleRate == 96000); #expect(track.bitDepth == 24)
            let file = try AVAudioFile(forReading: music.appendingPathComponent(track.relativePath))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32768))
            var decoded: AVAudioFramePosition = 0
            while file.framePosition < file.length { try file.read(into: buffer); guard buffer.frameLength > 0 else { break }; decoded += AVAudioFramePosition(buffer.frameLength) }
            #expect(decoded == file.length)
        }
        let again = try await scanner.scan(root: root) { _ in }; #expect(again.reused == 27)
        print("REAL SAMPLE: 27 FLACs fully decoded; 27/27 incremental reuse; original format 24-bit/96kHz; two Impromptu IDs preserved")
    }
    @Test func testMP3TagsDurationAndNativeDecode() async throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = project.appendingPathComponent("Tests/Fixtures/tagged-silence.mp3")
        let metadata = try await MetadataReader.read(url)
        #expect(metadata.value("TITLE") == "Fixture Song")
        #expect(metadata.value("ALBUM") == "Fixture Album")
        #expect(metadata.value("ARTIST") == "Test Performer")
        #expect(metadata.value("COMPOSER") == "Test Composer")
        #expect(metadata.value("ALBUMARTIST") == "Test Album Artist")
        #expect(LibraryScanner.number(metadata.value("TRACKNUMBER")) == 2)
        #expect(LibraryScanner.number(metadata.value("DISCNUMBER")) == 1)
        #expect(abs(metadata.duration - 2) < 0.1)
        let file = try AVAudioFile(forReading: url), buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192))
        while file.framePosition < file.length { try file.read(into: buffer); if buffer.frameLength == 0 { break } }
        #expect(file.framePosition == file.length)
    }
}

@Suite struct SourcePolicyTests {
    private let album = StoryRequest(entityID: "a", kind: "album", title: "12 Dreams for Piano", context: "", queries: ["12 Dreams for Piano Aleksander Dębicz album"], required: [["12 Dreams for Piano"], ["Aleksander Dębicz"]], related: ["Warner Classics"])
    @Test func dropsSocialVideoAndStorefrontPages() {
        for url in ["https://www.youtube.com/watch?v=1", "https://youtu.be/1", "https://www.instagram.com/p/1", "https://m.facebook.com/x", "https://music.apple.com/album/1", "https://open.spotify.com/album/1", "https://muso.ai/profile/1", "https://www.pinterest.co.kr/pin/1", "https://x.com/a"] {
            #expect(SourcePolicy.isBlocked(url), "\(url)")
        }
        #expect(!SourcePolicy.isBlocked("https://culture.pl/en/article/surrendering-to-dreams"))
        #expect(!SourcePolicy.isBlocked("https://en.wikipedia.org/wiki/Aleksander_Dębicz"))
    }
    @Test func ranksTrustedRelevantPagesFirst() {
        let found = [
            SourceCandidate(title: "Aleksander Dębicz", url: "https://www.youtube.com/watch?v=1", snippet: "12 Dreams for Piano recording session"),
            SourceCandidate(title: "Some other dream album", url: "https://blog.example/dreams", snippet: "Unrelated piano music"),
            SourceCandidate(title: "12 Dreams for Piano - Album", url: "https://shop.example/12-dreams", snippet: "Aleksander Debicz piano"),
            SourceCandidate(title: "Surrendering to Dreams: A Chat with Aleksander Dębicz", url: "https://culture.pl/en/article/surrendering-to-dreams", snippet: "his newest album '12 Dreams for Piano'"),
            SourceCandidate(title: "12 Dreams for Piano", url: "https://www.warnerclassics.com/release/12-dreams-for-piano", snippet: "Aleksander Dębicz · Warner Classics"),
        ]
        let ranked = SourcePolicy.rank(found, for: album)
        #expect(ranked.map(\.url) == ["https://www.warnerclassics.com/release/12-dreams-for-piano", "https://culture.pl/en/article/surrendering-to-dreams", "https://shop.example/12-dreams"])
    }
    @Test func picksOnePagePerSiteFirst() {
        let pages = ["https://a.example/1", "https://a.example/2", "https://b.example/1", "https://c.example/1"].map { SourceCandidate(title: $0, url: $0) }
        #expect(SourcePolicy.pick(pages).map(\.url) == ["https://a.example/1", "https://b.example/1", "https://c.example/1"])
    }
}
