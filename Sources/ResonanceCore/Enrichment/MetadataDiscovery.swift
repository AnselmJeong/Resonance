import Foundation

public struct MetadataSnapshot: Codable, Sendable {
    public var checked: Date
    public var candidates: [ReleaseCandidate]
    public var message: String
    public var confirmed: Bool
    public var artwork: String?
}
public enum MatchPolicy {
    public static func canAutomaticallyConfirm(album: Album, local: [Track], match: ReleaseMatch, candidates: [ReleaseCandidate]) -> Bool {
        let explicit = UUID(uuidString: album.musicBrainzID) != nil && album.musicBrainzID == match.candidate.id
        let barcode = !album.barcode.isEmpty && album.barcode == match.candidate.barcode && candidates.filter { $0.barcode == album.barcode }.count == 1
        guard explicit || barcode, !local.isEmpty, local.count == match.tracks.count else { return false }
        let positions = local.map { "\($0.disc):\($0.number)" }
        let remote = match.tracks.map { "\($0.disc):\($0.number)" }
        guard Set(positions).count == local.count, Set(remote) == Set(positions), Set(remote).count == remote.count else { return false }
        return local.allSatisfy { track in
            guard let other = match.tracks.first(where: { $0.disc == track.disc && $0.number == track.number }), TextKey.normalize(other.title) == TextKey.normalize(track.title) else { return false }
            if let duration = other.duration, track.duration > 0, abs(duration - track.duration) > 4 { return false }
            return true
        }
    }
}

/// An album visit can warm candidates without a model key. Only strong, consistent identifiers attach relations.
public actor MetadataDiscovery {
    let db: LibraryDatabase
    let client: MusicBrainzClient
    let artworkDirectory: URL
    private var pending: [String: Task<MetadataSnapshot, Error>] = [:]
    public init(database: LibraryDatabase, client: MusicBrainzClient, artworkDirectory: URL) { db = database; self.client = client; self.artworkDirectory = artworkDirectory }
    public func discover(album: Album, force: Bool = false) async throws -> MetadataSnapshot {
        if let task = pending[album.id] { return try await task.value }
        let task = Task { try await self.perform(album: album, force: force) }; pending[album.id] = task
        defer { pending[album.id] = nil }
        return try await task.value
    }
    private func perform(album: Album, force: Bool) async throws -> MetadataSnapshot {
        let key = "metadata-v1:" + TextKey.id(album.id, album.musicBrainzID, album.barcode, album.title, album.artist, String(album.trackCount))
        if !force, let saved = try await db.preference(key, as: MetadataSnapshot.self), Date().timeIntervalSince(saved.checked) < 86400 {
            var result = saved
            result.confirmed = try await db.confirmedMatch(album.id) != nil
            if saved.confirmed && !result.confirmed { result.message = "외부 매칭을 해제했습니다. 크레디트 검토에서 다시 연결할 수 있습니다." }
            if result.confirmed == saved.confirmed || !result.confirmed { return result }
            // A newly approved edition still needs its first artwork lookup.
        }
        if force { await client.clearCache() }
        let local = try await db.tracks(albumID: album.id)
        guard !local.isEmpty else { throw AppError.message("앨범의 곡을 찾지 못했습니다.") }
        var match = try await db.confirmedMatch(album.id)
        let candidates = try await client.search(album: album)
        var message = candidates.isEmpty ? "일치하는 판을 찾지 못했습니다. 부클릿에서 크레디트를 확인할 수 있습니다." : "\(candidates.count)개의 판 후보가 준비되었습니다. 크레디트 검토에서 확인하세요."
        if match == nil, let first = candidates.first {
            let strong = first.id == album.musicBrainzID || (!album.barcode.isEmpty && first.barcode == album.barcode && candidates.filter { $0.barcode == album.barcode }.count == 1)
            if strong, try await db.preference("metadata-skip:" + album.id, as: Bool.self) != true {
                let details = try await client.detail(candidate: first)
                if MatchPolicy.canAutomaticallyConfirm(album: album, local: local, match: details, candidates: candidates) {
                    try await db.confirmMatch(albumID: album.id, match: details); match = details
                    message = "식별자와 곡 목록이 일치해 크레디트·작품을 연결했습니다."
                }
            }
        } else if let previous = match {
            if force {
                let refreshed = try await client.detail(candidate: previous.candidate)
                let sameRecordings = refreshed.tracks.count == previous.tracks.count && refreshed.tracks.allSatisfy { track in
                    previous.tracks.contains { $0.disc == track.disc && $0.number == track.number && $0.recordingID == track.recordingID }
                }
                guard sameRecordings else { throw AppError.message("연결된 판의 곡 구성이 변경되었습니다. 크레디트 검토에서 다시 확인하세요.") }
                try await db.confirmMatch(albumID: album.id, match: refreshed, approvedOrder: true); match = refreshed
            }
            message = "연결된 판의 크레디트와 작품을 사용하고 있습니다." }
        var artwork = album.artwork
        if artwork == nil, let match, let data = try? await client.frontCover(releaseID: match.candidate.id) {
            artwork = try ArtworkCache.thumbnail(source: nil, embedded: data, key: "caa:" + match.candidate.id, directory: artworkDirectory)
            if let artwork { try await db.saveOnlineArtwork(albumID: album.id, path: artwork) }
        }
        let snapshot = MetadataSnapshot(checked: Date(), candidates: candidates, message: message, confirmed: match != nil, artwork: artwork)
        try await db.setPreference(key, value: snapshot)
        return snapshot
    }
}
