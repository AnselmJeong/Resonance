import Testing
import AVFoundation
import GRDB
@testable import ResonanceCore

@Suite(.serialized) final class RelocationTests {
    private var directories: [URL] = []
    deinit { for directory in directories { try? FileManager.default.removeItem(at: directory) } }
    private func fixture(count: Int = 2) async throws -> (URL, LibraryDatabase, LibraryRoot, LibraryScanner) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Relocation-" + UUID().uuidString)
        directories.append(dir)
        let music = dir.appendingPathComponent("music")
        for n in 1...count { try audio(music.appendingPathComponent("Old/Bach/\(n).flac"), number: n) }
        let db = try LibraryDatabase(path: dir.appendingPathComponent("Library.sqlite").path), root = LibraryRoot(path: music.path)
        try await db.saveRoot(root)
        let scanner = LibraryScanner(database: db, cache: dir.appendingPathComponent("cache"))
        let result = try await scanner.scan(root: root) { _ in }; #expect(result.errors.isEmpty)
        return (dir, db, root, scanner)
    }
    private func audio(_ url: URL, number: Int, edition: String = "original") throws {
        var stream = Data(repeating: 0, count: 34)
        let packed = UInt64(44100) << 44 | UInt64(1) << 41 | UInt64(15) << 36 | UInt64(44100 * number)
        for i in 0..<8 { stream[10 + i] = UInt8((packed >> UInt64((7 - i) * 8)) & 255) }
        func little(_ n: Int) -> Data { Data((0..<4).map { UInt8((n >> ($0 * 8)) & 255) }) }
        let tags = ["ALBUM=Bach", "ARTIST=Performer", "TITLE=Piece \(number)", "TRACKNUMBER=\(number)", "WORK=Work \(number)", "COMMENT=\(edition)"]
        var comments = little(0) + little(tags.count)
        for tag in tags { comments += little(tag.utf8.count); comments += Data(tag.utf8) }
        let data = Data("fLaC".utf8) + Data([0, 0, 0, 34]) + stream + Data([132, UInt8((comments.count >> 16) & 255), UInt8((comments.count >> 8) & 255), UInt8(comments.count & 255)]) + comments
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    private func match(_ album: Album, _ tracks: [Track], id: String = "release") -> ReleaseMatch {
        let candidate = ReleaseCandidate(id: id, title: album.title, artist: album.artist, date: "", barcode: "", trackCount: tracks.count, score: 100, reasons: [], country: "", disambiguation: "")
        return ReleaseMatch(candidate: candidate, tracks: tracks.map {
            MatchedTrack(disc: $0.disc, number: $0.number, title: $0.title, recordingID: "recording-\($0.number)",
                         credits: [Credit(artistID: "mb:performer", name: "Performer", role: "performer", source: "musicbrainz")],
                         works: [Work(id: "mb:work-\($0.number)", title: "Work \($0.number)", source: "musicbrainz")])
        })
    }
    private func checkIntegrity(_ db: LibraryDatabase) async throws {
        let integrity = try await db.integrityCheck()
        #expect(integrity == "ok")
        let violations = try await db.pool.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").count }
        #expect(violations == 0)
    }

    @Test func renamePreservesIdentityAndHistoryDespiteUnrelatedError() async throws {
        let (dir, db, root, scanner) = try await fixture()
        let music = URL(fileURLWithPath: root.path)
        let original = try #require(try await db.albums().first), tracks = try await db.tracks(albumID: original.id)
        try await db.setFavorite(original.id, value: true)
        try await db.editAlbum(original.id, title: "My Bach", artist: "My performer", sectionID: original.sectionID)
        try await db.confirmMatch(albumID: original.id, match: match(original, tracks))
        let insight = Insight(entityID: original.id, kind: "album", language: "ko", payload: InsightPayload(sections: [], claims: [], uncertainties: []), evidence: [], model: "fixture")
        try await db.saveInsight(insight)
        let queue = QueueSnapshot(entries: tracks.map { QueueEntry(trackID: $0.id) }, index: 1, position: 4)
        try await db.setPreference("queue", value: queue)
        let before = try Data(contentsOf: music.appendingPathComponent("Old/Bach/1.flac"))
        try Data("booklet".utf8).write(to: music.appendingPathComponent("Old/Bach/booklet.pdf"))
        try FileManager.default.moveItem(at: music.appendingPathComponent("Old"), to: music.appendingPathComponent("New"))
        try Data("bad flac".utf8).write(to: music.appendingPathComponent("bad.flac"))
        let result = try await scanner.scan(root: root) { _ in }
        #expect(result.finished); #expect(result.errors.count == 1)
        let albums = try await db.albums(), moved = try #require(albums.first)
        #expect(albums.count == 1); #expect(moved.id == original.id); #expect(moved.favorite)
        #expect(moved.title == "My Bach"); #expect(moved.artist == "My performer"); #expect(moved.sectionID == original.sectionID)
        #expect(moved.folder.hasSuffix("New/Bach")); #expect(moved.attachments.first?.hasSuffix("New/Bach/booklet.pdf") == true)
        #expect(try await db.tracks(albumID: moved.id).map(\.id) == tracks.map(\.id))
        #expect(try await db.confirmedMatch(moved.id)?.candidate.id == "release")
        #expect(try await db.insight(entityID: moved.id, language: "ko")?.id == insight.id)
        #expect(try await db.works(trackID: tracks[0].id).count == 1)
        let restored = try #require(try await db.preference("queue", as: QueueSnapshot.self))
        #expect(restored.entries == queue.entries); #expect(restored.index == 1); #expect(restored.position == 4)
        #expect(try Data(contentsOf: music.appendingPathComponent("New/Bach/1.flac")) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.contains("before-relocation") })
        // Move back, then rename the files too. Neither operation may reuse a deleted path-derived ID.
        try FileManager.default.moveItem(at: music.appendingPathComponent("New"), to: music.appendingPathComponent("Old"))
        try FileManager.default.moveItem(at: music.appendingPathComponent("Old/Bach/1.flac"), to: music.appendingPathComponent("Old/Bach/renamed.flac"))
        _ = try await scanner.scan(root: root) { _ in }
        #expect(try await db.albums().count == 1)
        #expect(try await db.tracks(albumID: moved.id).map(\.id) == tracks.map(\.id))
        let repeatScan = try await scanner.scan(root: root) { _ in }; #expect(repeatScan.reused == 2)
        let reopened = try LibraryDatabase(path: db.path)
        #expect(try await reopened.albums().first?.id == original.id)
        try await checkIntegrity(reopened)
    }

    @Test func existingDuplicatesMergeBothSidesAndRedirectQueue() async throws {
        let (_, db, root, scanner) = try await fixture()
        let music = URL(fileURLWithPath: root.path), original = try #require(try await db.albums().first)
        let oldTracks = try await db.tracks(albumID: original.id)
        try FileManager.default.copyItem(at: music.appendingPathComponent("Old"), to: music.appendingPathComponent("New"))
        _ = try await scanner.scan(root: root) { _ in }
        #expect(try await db.albums().count == 2) // An actual copy remains a separate album.
        let duplicate = try #require(try await db.albums().first { $0.id != original.id })
        let newTracks = try await db.tracks(albumID: duplicate.id)
        try await db.setFavorite(duplicate.id, value: true)
        try await db.editAlbum(duplicate.id, title: "Edited new copy", artist: "Performer", sectionID: duplicate.sectionID)
        try await db.confirmMatch(albumID: duplicate.id, match: match(duplicate, newTracks))
        let aliasArtist = try #require(newTracks[0].credits.first).artistID
        try await db.addAlias(artistID: aliasArtist, alias: "My alias")
        let story = Insight(entityID: newTracks[0].id, kind: "track", language: "ko", payload: InsightPayload(sections: [], claims: [], uncertainties: []), evidence: [], model: "fixture")
        try await db.saveInsight(story)
        let queue = QueueSnapshot(entries: [QueueEntry(trackID: oldTracks[0].id), QueueEntry(trackID: newTracks[1].id)], index: 1, position: 9)
        try await db.setPreference("queue", value: queue)
        try FileManager.default.removeItem(at: music.appendingPathComponent("Old"))
        _ = try await scanner.scan(root: root) { _ in }
        let album = try #require(try await db.album(original.id))
        #expect(try await db.albums().count == 1); #expect(try await db.counts().tracks == 2)
        #expect(album.favorite); #expect(album.title == "Edited new copy")
        #expect(try await db.album(duplicate.id)?.id == original.id)
        #expect(try await db.track(newTracks[0].id)?.id == oldTracks[0].id)
        #expect(try await db.insight(entityID: newTracks[0].id, language: "ko")?.entityID == oldTracks[0].id)
        #expect(try await db.confirmedMatch(original.id)?.candidate.id == "release")
        #expect(try await db.artist(aliasArtist)?.aliases.contains("My alias") == true)
        #expect(try await db.artistTracks(aliasArtist).count == 2)
        #expect(try await db.works(trackID: newTracks[0].id).count == 1)
        // A still-open player may persist the old queue object after the merge.
        try await db.setPreference("queue", value: queue)
        let saved = try #require(try await db.preference("queue", as: QueueSnapshot.self))
        #expect(saved.entries.map(\.trackID) == [oldTracks[0].id, oldTracks[1].id])
        #expect(saved.entries.map(\.id) == queue.entries.map(\.id)); #expect(saved.index == 1); #expect(saved.position == 9)
        try await db.setFavorite(duplicate.id, value: false)
        #expect(try await db.album(original.id)?.favorite == false)
        _ = try await scanner.scan(root: root) { _ in }
        #expect(try await db.albums().count == 1)
        #expect(try await db.search("Edited new copy").filter { $0.kind == "album" }.count == 1)
        let hit = try #require(try await db.search("Piece 1").first { $0.kind == "track" })
        // Once in the album artist field and once in the distinct recording credits.
        #expect(hit.subtitle.components(separatedBy: "Performer").count == 3)
        try await checkIntegrity(db)
        _ = try await db.removeRoot(root.id)
        #expect(try await db.roots().isEmpty); try await checkIntegrity(db)
    }

    @Test func ambiguousCopiesAndDifferentEditionsAreNotMerged() async throws {
        let (_, db, root, scanner) = try await fixture()
        let music = URL(fileURLWithPath: root.path)
        for name in ["Copy1", "Copy2"] { try FileManager.default.copyItem(at: music.appendingPathComponent("Old"), to: music.appendingPathComponent(name)) }
        try FileManager.default.removeItem(at: music.appendingPathComponent("Old"))
        _ = try await scanner.scan(root: root) { _ in }
        #expect(try await db.albums().count == 3)
        let stale = try #require(try await db.albums().first { $0.folder.hasSuffix("Old/Bach") })
        #expect(try await db.tracks(albumID: stale.id).allSatisfy { !$0.available })
        let (_, other, otherRoot, otherScanner) = try await fixture()
        let otherMusic = URL(fileURLWithPath: otherRoot.path)
        try FileManager.default.removeItem(at: otherMusic.appendingPathComponent("Old"))
        for n in 1...2 { try audio(otherMusic.appendingPathComponent("New/Bach/\(n).flac"), number: n, edition: "different") }
        _ = try await otherScanner.scan(root: otherRoot) { _ in }
        #expect(try await other.albums().count == 2)
    }

    @Test func failedScopesExclusionsAndSymlinksPreserveOnlyTheirRecords() async throws {
        let (_, db, root, scanner) = try await fixture()
        let original = try #require(try await db.albums().first), tracks = try await db.tracks(albumID: original.id)
        // A read failure under Old cannot prove anything about its missing siblings.
        var coverage = ScanCoverage(); coverage.protectedPaths.insert("Old")
        try await db.finishScan(root: root, scanID: "unknown", coverage: coverage)
        #expect(try await db.tracks(albumID: original.id).allSatisfy(\.available))
        var excluded = root; excluded.exclusions.append("Old")
        _ = try await scanner.scan(root: excluded) { _ in }
        #expect(try await db.tracks(albumID: original.id).allSatisfy(\.available))
        let music = URL(fileURLWithPath: root.path)
        try FileManager.default.removeItem(at: music.appendingPathComponent("Old/Bach/1.flac"))
        try Data("bad".utf8).write(to: music.appendingPathComponent("Old/Bach/2.flac"))
        _ = try await scanner.scan(root: root) { _ in }
        #expect(try await db.track(tracks[0].id)?.available == false)
        #expect(try await db.track(tracks[1].id)?.available == true)
        let destination = music.deletingLastPathComponent().appendingPathComponent("moved")
        try FileManager.default.moveItem(at: music.appendingPathComponent("Old"), to: destination)
        try FileManager.default.createSymbolicLink(at: music.appendingPathComponent("Old"), withDestinationURL: destination)
        _ = try await scanner.scan(root: root) { _ in }
        #expect(try await db.track(tracks[1].id)?.available == true)
    }

    @Test func cancelledScanDefersRelocationUntilComplete() async throws {
        let (_, db, root, scanner) = try await fixture(count: 26)
        let original = try #require(try await db.albums().first), music = URL(fileURLWithPath: root.path)
        try FileManager.default.moveItem(at: music.appendingPathComponent("Old"), to: music.appendingPathComponent("New"))
        let task = Task { try await scanner.scan(root: root) { progress in
            if !progress.finished { withUnsafeCurrentTask { $0?.cancel() } }
        } }
        let cancelled = try await task.value
        #expect(cancelled.cancelled); #expect(!cancelled.finished)
        #expect(try await db.album(original.id)?.folder == original.folder)
        #expect(try await db.tracks(albumID: original.id).allSatisfy(\.available))
        _ = try await scanner.scan(root: root) { _ in }
        #expect(try await db.albums().count == 1); #expect(try await db.counts().tracks == 26)
        try await checkIntegrity(db)
    }
}
