import Foundation

/// Visible cards and album details share a bounded loader, separate from scanning and playback.
public actor SMBArtworkLoader {
    private let database: LibraryDatabase
    private let cache: URL
    private let sessions: SMBSessionPool
    private var active: Set<String> = []
    private var retryAfter: [String: Date] = [:]

    public init(database: LibraryDatabase, cache: URL, sessions: SMBSessionPool) {
        self.database = database; self.cache = cache; self.sessions = sessions
    }

    public func load(album: Album, source: SMBSource) async throws -> String? {
        if let path = album.artwork, FileManager.default.fileExists(atPath: path) { return path }
        while active.count >= 2 || active.contains(album.id) {
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        active.insert(album.id)
        defer { active.remove(album.id) }
        // Another card/detail request may have filled the cache while this request waited.
        guard let current = try await database.album(album.id) else { return nil }
        if let path = current.artwork, FileManager.default.fileExists(atPath: path) { return path }
        if let date = retryAfter[album.id], date > Date() { return nil }
        do {
            let tracks = try await database.tracks(albumID: album.id)
            guard let track = tracks.first(where: { $0.available }) else { return nil }
            let transport = try await sessions.session(source)
            if let path = try await SMBArtwork.load(source: source, track: track, transport: transport, cache: cache) {
                let saved = try await database.saveSourceArtwork(albumID: album.id, path: path)
                retryAfter[album.id] = nil
                return saved.artwork
            }
            retryAfter[album.id] = Date().addingTimeInterval(300)
            return nil
        } catch {
            if !Task.isCancelled {
                retryAfter[album.id] = Date().addingTimeInterval(30)
                await sessions.invalidate(source)
            }
            throw error
        }
    }
}
