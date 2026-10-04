import Testing
import AVFoundation
@testable import ResonanceCore

private final class MetadataFixtureProtocol: URLProtocol {
    static var calls: [String: Int] = [:]
    static let lock = NSLock()
    static let releaseID = "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa"
    static let recordingID = "bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb"
    static let workID = "cccccccc-cccc-4ccc-cccc-cccccccccccc"
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        Self.lock.lock(); Self.calls[request.url!.absoluteString, default: 0] += 1; Self.lock.unlock()
        let object: [String: Any]
        if path.contains("/release/") {
            object = ["id": Self.releaseID, "title": "Album", "barcode": "123", "artist-credit": [["name": "Performer"]], "media": [["position": 1, "tracks": [["position": 1, "title": "Piece", "length": 200000, "recording": ["id": Self.recordingID]]]]]]
        } else if path.contains("/recording/") {
            object = ["id": Self.recordingID, "artist-credit": [["artist": ["id": "person", "name": "Performer"]]], "relations": [["type": "instrument", "attributes": ["piano"], "artist": ["id": "person", "name": "Performer"]], ["type": "performance", "begin": "2020-05-01", "work": ["id": Self.workID, "title": "Piece"]]]]
        } else {
            object = ["id": Self.workID, "relations": [["type": "parts", "direction": "backward", "work": ["id": "parent", "title": "Suite"]], ["type": "composer", "artist": ["id": "composer", "name": "Composer"]]]]
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: object))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct MetadataDiscoveryTests {
    private func client() -> MusicBrainzClient {
        MetadataFixtureProtocol.calls = [:]
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MetadataFixtureProtocol.self]
        return MusicBrainzClient(http: HTTPClient(session: URLSession(configuration: config)))
    }
    @Test func albumVisitsShareRequestsAndRespectUnlink() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try LibraryDatabase(path: directory.appendingPathComponent("library.sqlite").path)
        let root = LibraryRoot(path: directory.path), section = LibrarySection(rootID: "r", relativePath: "", name: "Music")
        var actualSection = section; actualSection.rootID = root.id
        try await db.saveRoot(root); try await db.saveSection(actualSection)
        let album = Album(id: "a", rootID: root.id, sectionID: actualSection.id, folder: directory.path, title: "Album", artist: "Performer", barcode: "123", musicBrainzID: MetadataFixtureProtocol.releaseID, artwork: "cover", trackCount: 1)
        let track = Track(id: "t", rootID: root.id, albumID: album.id, relativePath: "01.flac", title: "Piece", number: 1, duration: 200, credits: [Credit(artistID: "local", name: "Performer", role: "performer")])
        try await db.upsert(album: album, tracks: [track], scanID: "scan")
        let client = client(), service = MetadataDiscovery(database: db, client: client, artworkDirectory: directory)
        async let first = service.discover(album: album)
        async let second = service.discover(album: album)
        let results = try await [first, second]
        #expect(results.allSatisfy { $0.confirmed })
        #expect(try await db.recordingDetails(trackID: "t")?.recordingDate == "2020-05-01")
        #expect(try await db.works(trackID: "t").first?.parentTitle == "Suite")
        #expect(try await db.childWorks("mb:parent").count == 1)
        #expect(try await db.workTracks("mb:parent").map(\.id) == ["t"])
        #expect(try await db.track("t")?.credits.first(where: { $0.role == "performer" })?.attributes == ["piano"])
        #expect(MetadataFixtureProtocol.calls.values.allSatisfy { $0 == 1 })
        let count = MetadataFixtureProtocol.calls.values.reduce(0, +)
        _ = try await service.discover(album: album)
        #expect(MetadataFixtureProtocol.calls.values.reduce(0, +) == count)
        var renamed = track; renamed.title = "Piece (local display title)"
        try await db.upsert(album: album, tracks: [renamed], scanID: "changed-title")
        #expect(try await service.discover(album: album, force: true).confirmed)
        #expect(try await db.track("t")?.title == renamed.title)
        try await db.removeMatch(albumID: album.id)
        #expect(try await service.discover(album: album).confirmed == false)
        _ = try await service.discover(album: album, force: true)
        #expect(try await db.confirmedMatch(album.id) == nil)
    }
}
