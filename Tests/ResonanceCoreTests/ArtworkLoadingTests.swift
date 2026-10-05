import Testing
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ResonanceCore

@Suite struct ArtworkLoadingTests {
    actor Server: SMBTransport {
        let png: Data
        var reads = 0
        var active = 0
        var maximum = 0
        init(_ png: Data) { self.png = png }
        func list(_ path: String) async throws -> [SMBFileInfo] {
            active += 1; maximum = max(maximum, active)
            defer { active -= 1 }
            try await Task.sleep(for: .milliseconds(80))
            // Covers stored inside CD folders must still be found after checking the album folder.
            return path.hasSuffix("CD1") ? [.init(name: "folder.png", size: Int64(png.count), modified: 1)] : []
        }
        func stat(_ path: String) throws -> SMBFileInfo { .init(name: path, size: Int64(png.count), modified: 1) }
        func read(_ path: String, offset: Int64, count: Int) throws -> Data {
            #expect(path.hasSuffix("folder.png"), "Artwork loading must not download audio")
            reads += 1
            return png.subdata(in: Int(offset)..<min(png.count, Int(offset) + count))
        }
    }
    func image() throws -> Data {
        let provider = try #require(CGDataProvider(data: Data([255, 0, 0, 255]) as CFData))
        let image = try #require(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let writer = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, image, nil)
        #expect(CGImageDestinationFinalize(writer))
        return data as Data
    }
    @Test func cacheTrimsUnreferencedImagesBeforeCurrentAlbumCovers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = (0..<3).map { directory.appendingPathComponent("\($0).jpg") }
        for (index, path) in paths.enumerated() {
            _ = FileManager.default.createFile(atPath: path.path, contents: nil)
            let file = try FileHandle(forWritingTo: path)
            try file.truncate(atOffset: 18 * 1024 * 1024); try file.close()
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index))], ofItemAtPath: path.path)
        }
        try ArtworkCache.trim(directory: directory, megabytes: 50, preserving: Set(paths.prefix(2).map(\.path)))
        #expect(FileManager.default.fileExists(atPath: paths[0].path))
        #expect(FileManager.default.fileExists(atPath: paths[1].path))
        #expect(!FileManager.default.fileExists(atPath: paths[2].path))
    }
    @Test func visibleArtworkIsBoundedPersistedAndReused() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try LibraryDatabase(path: directory.appendingPathComponent("test.sqlite").path)
        let root = LibraryRoot(path: "/never-mounted/Music")
        let section = LibrarySection(rootID: root.id, relativePath: "Artist", name: "Artist")
        try await db.saveRoot(root); try await db.saveSection(section)
        let source = SMBSource(server: "fixture.local", share: "Music", username: "fixture")
        let server = Server(try image()), sessions = SMBSessionPool(factory: { _ in server })
        let cache = directory.appendingPathComponent("art")
        let loader = SMBArtworkLoader(database: db, cache: cache, sessions: sessions)
        var albums: [Album] = []
        for n in 0..<6 {
            let album = Album(id: "a\(n)", rootID: root.id, sectionID: section.id, folder: root.path + "/Artist/\(n)", title: "Album \(n)", artist: "Artist", artwork: n == 0 ? directory.appendingPathComponent("evicted.jpg").path : nil)
            let track = Track(id: "t\(n)", rootID: root.id, albumID: album.id, relativePath: "Artist/\(n)/CD1/01.flac", title: "Track", format: "FLAC")
            try await db.upsert(album: album, tracks: [track], scanID: "fixture")
            albums.append(album)
        }
        try await withThrowingTaskGroup(of: String?.self) { group in
            for album in albums + [albums[0]] { group.addTask { try await loader.load(album: album, source: source) } }
            for try await path in group { #expect(path.map { FileManager.default.fileExists(atPath: $0) } == true) }
        }
        #expect(await server.reads == 6)
        #expect(await server.maximum <= 2)
        for album in albums {
            let saved = try #require(await db.album(album.id))
            #expect(saved.artwork != nil)
            let restarted = SMBArtworkLoader(database: db, cache: cache, sessions: sessions)
            _ = try await restarted.load(album: album, source: source)
        }
        #expect(await server.reads == 6)
        let custom = directory.appendingPathComponent("custom.png"); try image().write(to: custom)
        try await db.editAlbum(albums[0].id, title: "My title", artist: "My artist", artwork: custom.path)
        #expect(try await loader.load(album: albums[0], source: source) == custom.path)
        #expect(await server.reads == 6)
    }
}
