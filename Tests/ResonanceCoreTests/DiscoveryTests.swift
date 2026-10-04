import Testing
import AVFoundation
import GRDB
import PDFKit
import CoreText
@testable import ResonanceCore

@Suite(.serialized) struct DiscoveryTests {
    private func fixture(_ directory: URL) async throws -> (LibraryDatabase, LibraryRoot, [Album], [Track]) {
        let db = try LibraryDatabase(path: directory.appendingPathComponent("library.sqlite").path)
        let root = LibraryRoot(path: directory.appendingPathComponent("music").path)
        let section = LibrarySection(rootID: root.id, relativePath: "", name: "Classical")
        try await db.saveRoot(root); try await db.saveSection(section)
        var albums: [Album] = [], tracks: [Track] = []
        for i in 0..<3 {
            let album = Album(id: "album\(i)", rootID: root.id, sectionID: section.id, folder: root.path, title: "Album \(i)", artist: "Same Name", artwork: "fixture-cover")
            let track = Track(id: "track\(i)", rootID: root.id, albumID: album.id, relativePath: "\(i).flac", title: "Shared Piece", number: 1, duration: 200 + Double(i), tags: ["WORK": ["Shared Piece"]], credits: [Credit(artistID: "local\(i)", name: "Same Name", role: "performer")])
            try await db.upsert(album: album, tracks: [track], scanID: "scan"); albums.append(album); tracks.append(track)
        }
        return (db, root, albums, tracks)
    }
    private func match(_ track: Track, artistID: String = "mb:person", workID: String = "mb:work") -> ReleaseMatch {
        let candidate = ReleaseCandidate(id: "release", title: "Album", artist: "Same Name", date: "2020", barcode: "", trackCount: 1, score: 100, reasons: [], country: "", disambiguation: "")
        return ReleaseMatch(candidate: candidate, tracks: [MatchedTrack(disc: 1, number: 1, title: track.title, recordingID: "recording-" + track.id,
            credits: [Credit(artistID: artistID, name: "Same Name", role: "performer", source: "musicbrainz", attributes: ["piano"])], works: [Work(id: workID, title: "Shared Piece", source: "musicbrainz")], duration: track.duration, recordingDate: "2019-05-01")])
    }
    @Test func identityRequiresEvidenceAndRemovalPreservesLocalCredits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (db, _, albums, tracks) = try await fixture(directory)
        #expect(try await db.artistTracks("local0").count == 1)
        #expect(try await db.relatedAlbums(trackID: "track0").allSatisfy { $0.reason.contains("미확인") })
        for i in 0..<2 { try await db.confirmMatch(albumID: albums[i].id, match: match(tracks[i])) }
        #expect(Set(try await db.artistTracks("local0").map(\.id)) == ["track0", "track1"])
        #expect(Set(try await db.workTracks("mb:work").map(\.id)) == ["track0", "track1"])
        #expect(try await db.track("track0")?.credits.count == 1)
        #expect(try await db.rawTrack("track0")?.credits.count == 2)
        #expect(try await db.track("track0")?.credits.first?.attributes == ["piano"])
        let related = try await db.relatedAlbums(trackID: "track0")
        #expect(related.first?.album.id == "album1"); #expect(related.first?.reason.hasPrefix("같은 작품") == true)
        try await db.upsert(album: albums[0], tracks: [tracks[0]], scanID: "rescan")
        #expect(try await db.track("track0")?.credits.first?.attributes == ["piano"])
        try await db.removeMatch(albumID: albums[0].id)
        #expect(try await db.artistTracks("local0").map(\.id) == ["track0"])
        #expect(try await db.workTracks("mb:work").map(\.id) == ["track1"])
        #expect(try await db.track("track0")?.credits.first?.source == "local")
        #expect(try await db.preference("metadata-skip:album0", as: Bool.self) == true)
    }
    @Test func userLinksCanBeUndoneWithoutMergingNamesakes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (db, _, albums, tracks) = try await fixture(directory)
        try await db.linkIdentity("local0", to: "local1", kind: "artist")
        #expect(try await db.artistTracks("local0").count == 2)
        #expect(try await db.artistTracks("local2").count == 1)
        try await db.unlinkIdentity("local1", kind: "artist")
        #expect(try await db.artistTracks("local0").count == 1)
        try await db.confirmMatch(albumID: albums[0].id, match: match(tracks[0], artistID: "mb:one"))
        try await db.confirmMatch(albumID: albums[1].id, match: match(tracks[1], artistID: "mb:two"))
        do { try await db.linkIdentity("local0", to: "local1", kind: "artist"); Issue.record("Different external people merged") } catch {}
        #expect(try await db.artistTracks("local0").count == 1)
    }
    @Test func explicitTagIDsConnectWithoutNetworkAndRemainAfterRescan() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (db, _, albums, original) = try await fixture(directory)
        let person = UUID().uuidString.lowercased(), work = UUID().uuidString.lowercased()
        for i in 0..<2 {
            var track = original[i]
            track.tags["ARTIST"] = ["Same Name"]; track.tags["MUSICBRAINZ_ARTISTID"] = [person]; track.tags["MUSICBRAINZ_WORKID"] = [work]
            try await db.upsert(album: albums[i], tracks: [track], scanID: "tags")
        }
        #expect(try await db.artistTracks("mb:" + person).count == 2)
        #expect(try await db.workTracks("mb:" + work).count == 2)
        #expect(try await db.works(trackID: "track0").first?.id == "mb:" + work)
        try await db.upsert(album: albums[0], tracks: [original[0]], scanID: "removed-tag")
        #expect(try await db.artistTracks("mb:" + person).count == 1)
    }
    @Test func automaticMatchingRejectsGuessworkAndWrongTrackStructure() {
        var album = Album(id: "a", rootID: "r", sectionID: "s", folder: "/", title: "Album", artist: "Same Name", barcode: "123")
        let track = Track(id: "t", rootID: "r", albumID: "a", relativePath: "a.flac", title: "Shared Piece", number: 1, duration: 200)
        var matched = match(track); matched.candidate.barcode = "123"
        #expect(MatchPolicy.canAutomaticallyConfirm(album: album, local: [track], match: matched, candidates: [matched.candidate]))
        #expect(!MatchPolicy.canAutomaticallyConfirm(album: album, local: [track], match: matched, candidates: [matched.candidate, matched.candidate]))
        matched.tracks[0].duration = 220
        #expect(!MatchPolicy.canAutomaticallyConfirm(album: album, local: [track], match: matched, candidates: [matched.candidate]))
        matched.tracks[0].duration = 200; matched.tracks[0].disc = 2
        #expect(!MatchPolicy.canAutomaticallyConfirm(album: album, local: [track], match: matched, candidates: [matched.candidate]))
        album.barcode = ""; matched.tracks[0].disc = 1
        #expect(!MatchPolicy.canAutomaticallyConfirm(album: album, local: [track], match: matched, candidates: [matched.candidate]))
    }
    @Test func internalStoryLinksAreUnambiguousAndPreserveText() {
        let text = "Bach and Bachman met Claude Debussy. 모차르트의 작품."
        let entities = [StoryEntity(kind: "artist", id: "bach", name: "Bach"), StoryEntity(kind: "artist", id: "debussy", name: "Debussy"), StoryEntity(kind: "artist", id: "claude", name: "Claude Debussy"), StoryEntity(kind: "artist", id: "mozart", name: "모차르트")]
        let spans = StoryLinker.spans(text, entities: entities)
        #expect(spans.map(\.text).joined() == text)
        #expect(spans.filter { $0.url != nil }.map(\.text) == ["Bach", "Claude Debussy", "모차르트"])
        #expect(StoryLinker.spans("Bach", entities: entities + [StoryEntity(kind: "artist", id: "other", name: "Bach")]).allSatisfy { $0.url == nil })
        #expect(DiscoveryLink.entity(URL(string: "resonance://artist/mb:123")!)?.id == "mb:123")
        #expect(DiscoveryLink.entity(URL(string: "resonance://artist/path/escape")!) == nil)
        #expect(DiscoveryLink.entity(URL(string: "https://artist/123")!) == nil)
    }
    @Test func storyLinksUseAlbumContextAndApprovedAliases() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (db, _, _, _) = try await fixture(directory)
        let all = try await db.storyEntities(in: "Same Name plays.")
        #expect(StoryLinker.spans("Same Name plays.", entities: all).allSatisfy { $0.url == nil })
        let context = try await db.storyEntities(in: "Same Name plays.", entityID: "album0", kind: "album")
        #expect(StoryLinker.spans("Same Name plays.", entities: context).first?.url?.lastPathComponent == "local0")
        try await db.addAlias(artistID: "local0", alias: "바흐")
        let aliases = try await db.storyEntities(in: "바흐의 연주.", entityID: "album0", kind: "album")
        #expect(StoryLinker.spans("바흐의 연주.", entities: aliases).first?.url?.lastPathComponent == "local0")
        try await db.linkIdentity("local0", to: "local1", kind: "artist")
        #expect(try await db.artists().count == 2)
    }
    @Test func bookletExtractsPagesAndReferencesOnlyOwnedDocuments() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("booklet.pdf")
        let data = NSMutableData()
        let writer = CGDataConsumer(data: data as CFMutableData)!
        var rect = CGRect(x: 0, y: 0, width: 400, height: 400)
        let context = CGContext(consumer: writer, mediaBox: &rect, nil)!
        for line in ["Piano performed by Example Artist", "Recording made in May 2019"] {
            context.beginPDFPage(nil); context.textPosition = CGPoint(x: 30, y: 330)
            let string = NSAttributedString(string: line, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 14, nil)])
            CTLineDraw(CTLineCreateWithAttributedString(string), context); context.endPDFPage()
        }
        context.closePDF(); try (data as Data).write(to: url)
        let root = LibraryRoot(path: directory.path)
        let album = Album(id: "album", rootID: root.id, sectionID: "s", folder: directory.path, title: "Album", artist: "Artist", attachments: [url.path])
        #expect(try BookletSource.validatedURL(path: url.path, album: album, roots: [root]) == url)
        let reader = BookletReader(), read = try await reader.read(url)
        #expect(read.pageCount == 2); #expect(read.hasText); #expect(read.pages[0].text.contains("Example Artist"))
        let evidence = BookletReader.evidence(album: album, path: url.path, pages: [read.pages[1]])
        #expect(evidence.count == 1); #expect(!evidence[0].url.contains(directory.path))
        let reference = try #require(BookletSource.reference(URL(string: evidence[0].url)!))
        #expect(reference.page == 2); #expect(reference.albumID == album.id)
        let db = try LibraryDatabase(path: directory.appendingPathComponent("booklet.sqlite").path)
        let service = InsightService(database: db, provider: BookletFixtureProvider(source: evidence[0]))
        var settings = InfoSettings(); settings.enabled = true; settings.model = "fixture"; settings.endpoint = "http://localhost:11434/api/chat"
        let story = try await service.generate(entityID: album.id, kind: "album", context: "Selected booklet page", evidence: evidence, settings: settings, key: "")
        #expect(story.evidence[0].url == evidence[0].url)
        #expect(try await db.insight(entityID: album.id, language: settings.language)?.evidence.first?.url == evidence[0].url)
        do { _ = try BookletSource.validatedURL(path: "/tmp/unrelated.pdf", album: album, roots: [root]); Issue.record("Unowned PDF accepted") } catch {}
    }
}

private struct BookletFixtureProvider: LLMProvider {
    let source: Evidence
    func summarize(prompt: String, settings: InfoSettings, key: String) async throws -> (InsightPayload, Int, Int) {
        #expect(prompt.contains("Recording made in May 2019"))
        #expect(!prompt.contains("Piano performed by Example Artist"))
        return (InsightPayload(sections: [.init(title: "녹음", text: "2019년 5월 녹음.", source_ids: [source.id])], claims: [.init(text: "녹음일", source_id: source.id, quote: "Recording made in May 2019")], uncertainties: []), 1, 1)
    }
}
