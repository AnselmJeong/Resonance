import Testing
import AVFoundation
@testable import ResonanceCore

@Suite struct DirectSMBTests {
    static func fixture(padding: Int = 0, picture: Int = 0) -> (Data, Int) {
        func block(_ type: UInt8, _ bytes: Data, last: Bool = false) -> Data {
            Data([type | (last ? 128 : 0), UInt8((bytes.count >> 16) & 255), UInt8((bytes.count >> 8) & 255), UInt8(bytes.count & 255)]) + bytes
        }
        func u32(_ n: Int) -> Data { Data((0..<4).map { UInt8((n >> ($0 * 8)) & 255) }) }
        var stream = Data(repeating: 0, count: 34)
        let packed = UInt64(44100) << 44 | UInt64(1) << 41 | UInt64(15) << 36 | UInt64(88200)
        for i in 0..<8 { stream[10 + i] = UInt8((packed >> UInt64((7 - i) * 8)) & 255) }
        let tags = ["TITLE=Mélodie", "ALBUM=Fixture", "ARTIST=Performer", "COMPOSER=Composer", "TRACKNUMBER=2", "WORK=Work"]
        var comments = u32(0) + u32(tags.count)
        for tag in tags { let data = Data(tag.utf8); comments += u32(data.count) + data }
        let data = Data("fLaC".utf8) + block(0, stream) + (picture > 0 ? block(6, Data(repeating: 0, count: picture)) : Data()) + block(1, Data(repeating: 0, count: padding)) + block(4, comments, last: true)
        return (data + Data(repeating: 255, count: 32), data.count)
    }
    actor Reader: AudioRangeReader {
        nonisolated let size: Int64
        let data: Data, audioOffset: Int, short: Int
        var requests: [(Int64, Int)] = []
        init(_ data: Data, audioOffset: Int, short: Int = .max) { self.data = data; self.audioOffset = audioOffset; self.short = short; size = Int64(data.count) }
        func read(offset: Int64, count: Int) throws -> Data {
            #expect(offset + Int64(count) <= Int64(audioOffset), "Parser entered audio frames")
            requests.append((offset, count))
            guard offset < data.count else { return Data() }
            return data.subdata(in: Int(offset)..<min(Int(offset) + min(short, count), data.count))
        }
    }
    @Test func skipsLargePicturesPaddingAndMatchesLocalTags() async throws {
        let (data, end) = Self.fixture(padding: 3_000_000, picture: 8_000_000)
        let reader = Reader(data, audioOffset: end)
        let (metadata, metric) = try await FLACRangeReader.read(reader)
        #expect(metric.bytes < 1024); #expect(metric.audioOffset == end)
        #expect(metadata.value("COMPOSER") == "Composer"); #expect(metadata.picture == nil)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".flac")
        defer { try? FileManager.default.removeItem(at: file) }
        // Local parser expects a structured picture; compare equivalent fixture without picture content.
        let (small, _) = Self.fixture(); try small.write(to: file)
        let other = try MetadataReader.flac(file)
        #expect(metadata.tags == other.tags); #expect(metadata.duration == 2)
        #expect(metadata.sampleRate == 44100); #expect(metadata.bitDepth == 16); #expect(metadata.channels == 2)
    }
    @Test func shortReadsAndMalformedFilesAreBounded() async throws {
        let (data, end) = Self.fixture()
        let (_, metric) = try await FLACRangeReader.read(Reader(data, audioOffset: end, short: 3))
        #expect(metric.requests > 10)
        for bytes in [Data(), Data("nope".utf8), Data(data.prefix(20)), Data("fLaC".utf8) + Data([128, 255, 255, 255])] {
            await #expect(throws: (any Error).self) { try await FLACRangeReader.read(Reader(bytes, audioOffset: bytes.count)) }
        }
        await #expect(throws: (any Error).self) { try await FLACRangeReader.read(Reader(data, audioOffset: end, short: 0)) }
        let task = Task { try Task.checkCancellation(); return try await FLACRangeReader.read(Reader(data, audioOffset: end)) }
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") } catch { #expect(error is CancellationError) }
    }
    @Test func skipsID3PrefixWithoutReadingBodyAndMatchesLocalParser() async throws {
        let (flac, end) = Self.fixture()
        for version in [UInt8(2), 3, 4] {
            let length = 3_000_000, footer = version == 4
            let flags: UInt8 = footer ? 0x10 : 0
            let sizes: [UInt8] = (0..<4).map { UInt8((length >> ((3 - $0) * 7)) & 127) }
            var header = Data("ID3".utf8)
            header.append(contentsOf: [version, 0, flags]); header.append(contentsOf: sizes)
            let prefix = header + Data(repeating: 255, count: length + (footer ? 10 : 0))
            let reader = Reader(prefix + flac, audioOffset: prefix.count + end)
            let (metadata, metric) = try await FLACRangeReader.read(reader)
            #expect(metric.bytes < 1024)
            #expect(metric.audioOffset == prefix.count + end)
            #expect(await reader.requests.allSatisfy { $0.0 < 10 || $0.0 >= prefix.count })
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".flac")
            defer { try? FileManager.default.removeItem(at: url) }
            try (prefix + flac).write(to: url)
            #expect(try MetadataReader.flac(url).tags == metadata.tags)
        }
        for header in [Data("ID3".utf8) + Data([4,0,0,128,0,0,0]), Data("ID3".utf8) + Data([4,0,0,127,127,127,127])] {
            let bytes = header + flac
            await #expect(throws: (any Error).self) { try await FLACRangeReader.read(Reader(bytes, audioOffset: bytes.count)) }
        }
    }
    actor Server: SMBTransport {
        var files: [Data: Data]
        var failListing = false
        var bytesRead = 0
        init(_ files: [(String, Data)]) { self.files = Dictionary(uniqueKeysWithValues: files.map { (Data($0.0.utf8), $0.1) }) }
        func fail() { failListing = true }
        func list(_ path: String) throws -> [SMBFileInfo] {
            if failListing { throw AppError.message("offline") }
            let prefix = path.isEmpty ? Data() : Data((path + "/").utf8)
            var entries: [Data: SMBFileInfo] = [:]
            for (key, bytes) in files where key.starts(with: prefix) {
                let suffix = String(decoding: key.dropFirst(prefix.count), as: UTF8.self)
                let parts = suffix.split(separator: "/")
                guard let first = parts.first else { continue }
                let name = String(first)
                entries[Data(name.utf8)] = SMBFileInfo(name: name, size: parts.count > 1 ? 0 : Int64(bytes.count), modified: 1, isDirectory: parts.count > 1)
            }
            return Array(entries.values)
        }
        func stat(_ path: String) throws -> SMBFileInfo {
            guard !path.isEmpty else { return SMBFileInfo(name: "", size: 0, modified: 1, isDirectory: true) }
            if files.keys.contains(where: { $0.starts(with: Data((path + "/").utf8)) }) { return SMBFileInfo(name: path, size: 0, modified: 1, isDirectory: true) }
            guard let bytes = files[Data(path.utf8)] else { throw AppError.message("missing") }
            return SMBFileInfo(name: path, size: Int64(bytes.count), modified: 1)
        }
        func read(_ path: String, offset: Int64, count: Int) throws -> Data {
            guard let bytes = files[Data(path.utf8)] else { throw AppError.message("missing") }
            #expect(path.hasSuffix(".flac"), "Unsupported format was downloaded for scanning")
            #expect(offset + Int64(count) <= bytes.count - 32, "Scan read audio")
            bytesRead += count
            return bytes.subdata(in: Int(offset)..<(Int(offset) + count))
        }
    }
    @Test func unmountedScanKeepsExactPathsReusesTagsAndPreservesIDs() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let db = try LibraryDatabase(path: temp.appendingPathComponent("test.sqlite").path)
        var root = LibraryRoot(path: temp.appendingPathComponent("not-mounted").path)
        try await db.saveRoot(root)
        let source = SMBSource(server: "server.local", share: "Music", username: "fixture")
        try await db.setSMBSource(rootID: root.id, source: source)
        root = try #require(await db.roots().first)
        let originalID = root.id
        let server = Server([("é.flac", Self.fixture().0), ("é.flac", Self.fixture().0), ("unknown.mp3", Data(repeating: 1, count: 4096))])
        let pool = SMBSessionPool(factory: { _ in server })
        let scanner = LibraryScanner(database: db, cache: temp.appendingPathComponent("art"), remote: pool)
        let first = try await scanner.scan(root: root) { _ in }
        #expect(first.finished); #expect(first.processed == 3)
        let before = try await db.scanTracks(rootID: root.id)
        #expect(before.count == 3)
        #expect(before[Data("é.flac".utf8)]?.id != before[Data("é.flac".utf8)]?.id)
        #expect(before[Data("unknown.mp3".utf8)]?.metadataStatus == "deferred-format")
        let readCount = await server.bytesRead
        // Cache trimming must never turn a tags-only rescan into another metadata download.
        for albumID in Set(before.values.map(\.albumID)) {
            _ = try await db.saveSourceArtwork(albumID: albumID, path: temp.appendingPathComponent("evicted-cover.jpg").path)
        }
        let second = try await scanner.scan(root: root) { _ in }
        #expect(second.reused == 3); #expect(await server.bytesRead == readCount)
        await server.fail()
        await #expect(throws: (any Error).self) { try await scanner.scan(root: root) { _ in } }
        #expect(try await db.scanTracks(rootID: root.id) == before)
        try await db.setSMBSource(rootID: root.id, source: nil)
        #expect(try await db.roots().first?.id == originalID)
        #expect(try await db.scanTracks(rootID: root.id) == before)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
    @Test func localToSMBMigrationPreservesFavoritesQueueStoriesAndWorks() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let local = temp.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try Self.fixture().0.write(to: local.appendingPathComponent("song.flac"))
        let db = try LibraryDatabase(path: temp.appendingPathComponent("db.sqlite").path)
        let originalRoot = LibraryRoot(path: local.path)
        try await db.saveRoot(originalRoot)
        let scanner = LibraryScanner(database: db, cache: temp.appendingPathComponent("art"))
        _ = try await scanner.scan(root: originalRoot) { _ in }
        let album = try #require(try await db.albums().first)
        let tracks = try await db.tracks(albumID: album.id)
        try await db.setFavorite(album.id, value: true)
        try await db.editAlbum(album.id, title: "My album", artist: "My artist")
        let insight = Insight(entityID: album.id, kind: "album", language: "ko", payload: InsightPayload(sections: [], claims: [], uncertainties: []), evidence: [], model: "fixture")
        try await db.saveInsight(insight)
        let queue = QueueSnapshot(entries: tracks.map { QueueEntry(trackID: $0.id) }, index: 0, position: 1)
        try await db.setPreference("queue", value: queue)
        let works = try await db.works(trackID: tracks[0].id).map(\.id)
        try await db.setSMBSource(rootID: originalRoot.id, source: SMBSource(server: "server.local", share: "Music", username: "fixture"))
        let root = try #require(try await db.roots().first)
        try FileManager.default.moveItem(at: local, to: temp.appendingPathComponent("original-preserved"))
        let server = Server([("song.flac", Self.fixture().0)])
        let remoteScanner = LibraryScanner(database: db, cache: temp.appendingPathComponent("art"), remote: SMBSessionPool(factory: { _ in server }))
        _ = try await remoteScanner.scan(root: root) { _ in }
        let after = try #require(try await db.album(album.id))
        #expect(after.favorite); #expect(after.title == "My album"); #expect(after.artist == "My artist")
        #expect(try await db.tracks(albumID: album.id).map(\.id) == tracks.map(\.id))
        #expect(try await db.insight(entityID: album.id, language: "ko")?.id == insight.id)
        #expect(try await db.works(trackID: tracks[0].id).map(\.id) == works)
        #expect(try await db.preference("queue", as: QueueSnapshot.self)?.entries == queue.entries)
        #expect(root.id == originalRoot.id); #expect(root.path == originalRoot.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.path).contains { $0.contains("before-smb-") })
        try await db.setSMBSource(rootID: originalRoot.id, source: nil)
        #expect(try await db.tracks(albumID: album.id).map(\.id) == tracks.map(\.id))
        #expect(try await db.integrityCheck() == "ok")
    }
    @Test func uniqueLegacyUnicodePathAdoptsServerBytesWithoutChangingIDsWhenVersionChanged() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let local = temp.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let file = local.appendingPathComponent("e\u{301}.flac")
        try Self.fixture().0.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2)], ofItemAtPath: file.path)
        let db = try LibraryDatabase(path: temp.appendingPathComponent("db.sqlite").path)
        var root = LibraryRoot(path: local.path); try await db.saveRoot(root)
        _ = try await LibraryScanner(database: db, cache: temp).scan(root: root) { _ in }
        let old = try #require(await db.scanTracks(rootID: root.id).values.first)
        root.smb = SMBSource(server: "server.local", share: "Music", username: "fixture")
        try await db.setSMBSource(rootID: root.id, source: root.smb)
        try FileManager.default.removeItem(at: local)
        let server = Server([("é.flac", Self.fixture().0)])
        let scanner = LibraryScanner(database: db, cache: temp, remote: SMBSessionPool(factory: { _ in server }))
        let result = try await scanner.scan(root: root) { _ in }
        let tracks = try await db.scanTracks(rootID: root.id)
        #expect(result.reused == 0); #expect(tracks.count == 1)
        #expect(tracks[Data("é.flac".utf8)]?.id == old.id)
        #expect(tracks[Data("é.flac".utf8)]?.albumID == old.albumID)
        #expect(await server.bytesRead > 0)
        _ = try await scanner.scan(root: root) { _ in }
        #expect(try await db.scanTracks(rootID: root.id).count == 1)
    }
    @Test func completedRemoteTraversalReplacesOldFailuresEvenWhenOneFileStillFails() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let db = try LibraryDatabase(path: temp.appendingPathComponent("db.sqlite").path)
        var root = LibraryRoot(path: "/never-mounted"); root.smb = SMBSource(server: "server.local", share: "Music", username: "fixture")
        try await db.saveRoot(root)
        var old = ScanProgress(); old.finished = true
        old.issues = [ScanIssue(path: root.path + "/repaired.flac", reason: "file does not exist")]
        try await db.saveScan(rootID: root.id, scanID: "old", progress: old)
        let server = Server([("repaired.flac", Self.fixture().0), ("bad.flac", Data(repeating: 0, count: 64))])
        let scanner = LibraryScanner(database: db, cache: temp, remote: SMBSessionPool(factory: { _ in server }))
        let result = try await scanner.scan(root: root) { _ in }
        #expect(result.finished); #expect(result.errors.count == 1)
        let failures = try await db.statistics().failures
        #expect(failures.count == 1)
        #expect(failures.first?.path.hasSuffix("bad.flac") == true)
        #expect(failures.contains { $0.path.hasSuffix("repaired.flac") } == false)
    }
    @Test func legacyUnicodeFolderAndNewSongRemainInSameAlbum() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let local = temp.appendingPathComponent("local"), folder = local.appendingPathComponent("e\u{301}")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.fixture().0.write(to: folder.appendingPathComponent("old.flac"))
        let db = try LibraryDatabase(path: temp.appendingPathComponent("db.sqlite").path)
        var root = LibraryRoot(path: local.path); try await db.saveRoot(root)
        _ = try await LibraryScanner(database: db, cache: temp).scan(root: root) { _ in }
        let original = try #require(await db.scanTracks(rootID: root.id).values.first)
        root.smb = SMBSource(server: "server.local", share: "Music", username: "fixture")
        try await db.setSMBSource(rootID: root.id, source: root.smb)
        let server = Server([("é/old.flac", Self.fixture().0), ("é/new.flac", Self.fixture().0)])
        _ = try await LibraryScanner(database: db, cache: temp, remote: SMBSessionPool(factory: { _ in server })).scan(root: root) { _ in }
        let tracks = try await db.scanTracks(rootID: root.id)
        #expect(tracks.count == 2)
        #expect(tracks[Data("é/old.flac".utf8)]?.id == original.id)
        #expect(Set(tracks.values.map(\.albumID)) == [original.albumID])
    }
    struct FailingTree: SMBTransport {
        func list(_ path: String) async throws -> [SMBFileInfo] {
            if path.isEmpty { return ["Bad", "Good"].map { SMBFileInfo(name: $0, size: 0, modified: 1, isDirectory: true) } }
            if path == "Bad" { throw AppError.message("permission denied") }
            return []
        }
        func stat(_ path: String) async throws -> SMBFileInfo { SMBFileInfo(name: path, size: 0, modified: 1, isDirectory: true) }
        func read(_ path: String, offset: Int64, count: Int) async throws -> Data { Issue.record("Unexpected read"); return Data() }
    }
    @Test func partialDirectoryFailureDoesNotRemoveExistingTracks() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let db = try LibraryDatabase(path: temp.appendingPathComponent("db.sqlite").path)
        var root = LibraryRoot(path: temp.appendingPathComponent("not-mounted").path)
        root.smb = SMBSource(server: "server.local", share: "Music", username: "fixture")
        try await db.saveRoot(root)
        let section = LibrarySection(rootID: root.id, relativePath: "Bad", name: "Bad")
        try await db.saveSection(section)
        let album = Album(id: "album", rootID: root.id, sectionID: section.id, folder: root.path + "/Bad", title: "Existing", artist: "Artist")
        let tracks = ["Bad/song.flac", "Good/missing.flac"].map { Track(id: $0, rootID: root.id, albumID: album.id, relativePath: $0, title: $0) }
        try await db.upsert(album: album, tracks: tracks, scanID: "before")
        let scanner = LibraryScanner(database: db, cache: temp.appendingPathComponent("art"), remote: SMBSessionPool(factory: { _ in FailingTree() }))
        let result = try await scanner.scan(root: root) { _ in }
        #expect(!result.finished); #expect(result.errors.count == 1)
        #expect(try await db.tracks(albumID: album.id).allSatisfy(\.available))
        #expect(try await db.tracks(albumID: album.id).count == 2)
    }
    @Test func legacyTimestampConversionToleranceDoesNotMaskNewVersions() {
        var track = Track(id: "t", rootID: "r", albumID: "a", relativePath: "file.flac", title: "file", size: 10, modified: 1648197603.4390001)
        #expect(SMBFileVersion.matches(size: 10, modified: 1648197603.439, track: track))
        #expect(!SMBFileVersion.matches(size: 11, modified: track.modified, track: track))
        #expect(!SMBFileVersion.matches(size: 10, modified: track.modified + 0.00001, track: track))
        track.metadataStatus = "complete"
        #expect(!SMBFileVersion.matches(size: 10, modified: 1648197603.439, track: track))
        #expect(SMBFileVersion.matches(size: 10, modified: track.modified, track: track))
    }
    @Test func exactPathCoverageDoesNotCollapseUnicode() {
        var coverage = ScanCoverage(); coverage.files.insert("é.flac")
        #expect(coverage.isMissing("é.flac")); #expect(!coverage.isMissing("é.flac"))
    }
}
