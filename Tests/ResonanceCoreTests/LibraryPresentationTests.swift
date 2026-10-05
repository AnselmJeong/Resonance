import Testing
import AVFoundation
@testable import ResonanceCore

struct LibraryPresentationTests {
    @Test func groupsKeepPhysicalRootsAndStableSelections() {
        let first = LibraryRoot(path: "/Volumes/One/Artist")
        var second = LibraryRoot(path: "/Volumes/Two/artist"); second.status = "연결 안 됨"
        let third = LibraryRoot(path: "/Volumes/One/Composer")
        let grouped = LibraryRootGroup.grouping([first, third, second])
        #expect(grouped.map(\.name) == ["Artist", "Composer"])
        #expect(grouped[0].rootIDs == [first.id, second.id])
        #expect(!grouped[0].connected)
        #expect(grouped[0].help.contains(second.path))
        #expect(LibraryRootGroup.grouping([second])[0].id == grouped[0].id)
        let sections = [first, second, third].map { LibrarySection(rootID: $0.id, relativePath: "Pianist", name: "Pianist") }
        let collections = grouped[0].collections(from: sections)
        #expect(collections.count == 1)
        #expect(collections[0].sectionIDs == Array(sections.prefix(2)).map(\.id))
        #expect(LibraryRootGroup.grouping([second])[0].collections(from: sections)[0].id == collections[0].id)
        let names = ["Mémoire", "Me\u{301}moire", "Memoire", "Artist ", "Artist"].map { LibraryRoot(path: "/Volumes/Names/" + $0) }
        #expect(LibraryRootGroup.grouping(names).count == 4)
    }

    @Test func groupedBrowsingSearchAndStatisticsUseAllMembers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try LibraryDatabase(path: directory.appendingPathComponent("test.sqlite").path)
        let roots = ["One/Artist", "Two/Artist", "Three/Composer"].map { LibraryRoot(path: directory.appendingPathComponent($0).path) }
        let sections = roots.map { LibrarySection(rootID: $0.id, relativePath: "Shared", name: "Shared") }
        for (root, section) in zip(roots, sections) { try await db.saveRoot(root); try await db.saveSection(section) }
        for n in 0..<6 {
            let r = n % 3
            let album = Album(id: "a\(n)", rootID: roots[r].id, sectionID: sections[r].id, folder: roots[r].path, title: "Shared \(n)", artist: "Shared Musician", date: "202\(n)")
            let track = Track(id: "t\(n)", rootID: roots[r].id, albumID: album.id, relativePath: "\(n).flac", title: "Shared Track", tags: ["WORK": ["Shared Work"]], credits: [Credit(artistID: "musician", name: "Shared Musician", role: "composer")])
            try await db.upsert(album: album, tracks: [track], scanID: "seed")
        }
        let group = LibraryRootGroup.grouping(roots)[0]
        let ids = group.rootIDs
        let first = try await db.albums(rootIDs: ids, limit: 2)
        let second = try await db.albums(rootIDs: ids, limit: 2, offset: 2)
        #expect((first + second).map(\.id) == ["a0", "a1", "a3", "a4"])
        #expect(try await db.albums(rootIDs: ids, sort: "date").map(\.id) == ["a4", "a3", "a1", "a0"])
        let collection = group.collections(from: sections)[0]
        #expect(try await db.albums(rootIDs: ids, sectionIDs: collection.sectionIDs).count == 4)
        #expect(try await db.albums(rootIDs: []).isEmpty)
        #expect(try await db.albums(rootIDs: ids, sectionIDs: [sections[2].id]).isEmpty)
        let hits = try await db.search("Shared", rootIDs: ids, sectionIDs: collection.sectionIDs)
        #expect(hits.filter { $0.kind == "artist" }.count == 1)
        #expect(hits.filter { $0.kind == "work" }.count == 4)
        #expect(Set(hits.filter { $0.kind == "track" }.map(\.entityID)) == Set(["t0", "t1", "t3", "t4"]))
        #expect(try await db.search("Shared", rootIDs: []).isEmpty)
        #expect(try await db.search("Shared", sectionIDs: []).isEmpty)
        let stats = try await db.statistics()
        #expect(stats.albums == 6 && stats.songs == 6)
        #expect(stats.roots.allSatisfy { $0.albums == 2 && $0.songs == 2 })
        _ = try await db.removeRoot(roots[0].id)
        #expect(try await db.albums(rootIDs: ids).map(\.id) == ["a1", "a4"])
        #expect(try await db.statistics().songs == 4)
    }

    @Test func failedPathsSurviveCancellationAndExportQuotedCSV() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try LibraryDatabase(path: directory.appendingPathComponent("test.sqlite").path)
        let root = LibraryRoot(path: "/Volumes/One/=Artist")
        try await db.saveRoot(root)
        let path = root.path + "/앨범, \"곡\"\n01.flac"
        var complete = ScanProgress(); complete.finished = true
        complete.errors = ["읽기 오류"]; complete.issues = [ScanIssue(path: path, reason: "=bad, \"tag\"\n내용")]
        try await db.saveScan(rootID: root.id, scanID: "complete", progress: complete)
        var partial = ScanProgress(); partial.cancelled = true; partial.issues = complete.issues
        try await db.saveScan(rootID: root.id, scanID: "partial", progress: partial)
        let stats = try await db.statistics()
        #expect(stats.failures.count == 1)
        #expect(stats.failures[0].path == path)
        let csv = String(decoding: stats.failureCSV(), as: UTF8.self)
        #expect(csv.hasPrefix("\u{FEFF}"))
        #expect(csv.contains("\"'=Artist\""))
        #expect(csv.contains("앨범, \"\"곡\"\"\n01.flac"))
        #expect(csv.contains("\"'=bad, \"\"tag\"\"\n내용\""))
        #expect(csv.hasSuffix("\r\n"))
        var repaired = ScanProgress(); repaired.finished = true; repaired.issues = []
        try await db.saveScan(rootID: root.id, scanID: "repaired", progress: repaired)
        #expect(try await db.statistics().failures.isEmpty)
    }

    @Test func legacyScanHistoryAndBatchSummary() throws {
        let data = Data(#"{"discovered":3,"processed":2,"reused":1,"albums":1,"errors":["bad.flac: invalid"],"current":"bad.flac","finished":true,"cancelled":false}"#.utf8)
        let old = try JSONDecoder().decode(ScanProgress.self, from: data)
        #expect(old.issues == nil)
        var summary = ScanSummary()
        summary.include(old, root: LibraryRoot(path: "/One/Artist"))
        var second = ScanProgress(); second.processed = 4; second.finished = true
        summary.include(second, root: LibraryRoot(path: "/Two/Artist"))
        #expect(summary.processed == 6 && summary.completedRoots == 2)
        #expect(summary.title.contains("확인"))
        second.cancelled = true; second.finished = false
        summary.include(second, root: LibraryRoot(path: "/Three/Artist"))
        #expect(summary.title == "스캔을 중지했습니다")
    }
}
