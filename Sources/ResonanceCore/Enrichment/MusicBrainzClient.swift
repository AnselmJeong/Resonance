import Foundation

public actor MusicBrainzClient {
    private let http: HTTPClient
    public init(http: HTTPClient = HTTPClient(interval: 1.1)) { self.http = http }
    private func request(entity: String, id: String? = nil, query: String? = nil, inc: String? = nil) async throws -> [String: Any] {
        var url = URLComponents(string: "https://musicbrainz.org/ws/2/\(entity)/\(id ?? "")")!
        url.queryItems = [.init(name: "fmt", value: "json")]
        if let query { url.queryItems?.append(.init(name: "query", value: query)); url.queryItems?.append(.init(name: "limit", value: "12")) }
        if let inc { url.queryItems?.append(.init(name: "inc", value: inc)) }
        var req = URLRequest(url: url.url!); req.timeoutInterval = 30
        req.setValue("Resonance/0.2.0 (personal macOS music library; https://musicbrainz.org/doc/MusicBrainz_API)", forHTTPHeaderField: "User-Agent")
        guard let body = try JSONSerialization.jsonObject(with: await http.send(req)) as? [String: Any] else { throw AppError.message("MusicBrainz 응답 형식 오류") }
        return body
    }
    private func quoted(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
    public func search(album: Album) async throws -> [ReleaseCandidate] {
        var releases: [[String: Any]] = []
        if UUID(uuidString: album.musicBrainzID) != nil { releases = [try await request(entity: "release", id: album.musicBrainzID, inc: "recordings+artist-credits")] }
        else {
            if !album.barcode.isEmpty { releases = (try await request(entity: "release", query: "barcode:\(quoted(album.barcode))"))["releases"] as? [[String: Any]] ?? [] }
            if releases.isEmpty { releases = (try await request(entity: "release", query: "release:\(quoted(album.title)) AND artist:\(quoted(album.artist))"))["releases"] as? [[String: Any]] ?? [] }
        }
        return releases.compactMap { release in
            guard let id = release["id"] as? String, let title = release["title"] as? String else { return nil }
            let artists = (release["artist-credit"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: ", ")
            let barcode = release["barcode"] as? String ?? "", media = release["media"] as? [[String: Any]] ?? []
            let count = media.reduce(0) { $0 + (($1["track-count"] as? Int) ?? ($1["tracks"] as? [Any])?.count ?? 0) }
            var score = 0, reasons: [String] = []
            if id == album.musicBrainzID { score += 100; reasons.append("로컬 MusicBrainz ID 일치") }
            if !barcode.isEmpty, barcode == album.barcode { score += 60; reasons.append("판 UPC 일치") }
            if TextKey.normalize(title) == TextKey.normalize(album.title) { score += 20; reasons.append("앨범명 일치") }
            if TextKey.normalize(artists) == TextKey.normalize(album.artist) { score += 15; reasons.append("앨범 아티스트 일치") }
            if count > 0, count == album.trackCount { score += 15; reasons.append("트랙 수 일치") }
            if !barcode.isEmpty, !album.barcode.isEmpty, barcode != album.barcode { reasons.append("⚠ UPC가 다른 판") }
            if count > 0, count != album.trackCount { reasons.append("⚠ 트랙 수 불일치") }
            return ReleaseCandidate(id: id, title: title, artist: artists, date: release["date"] as? String ?? "", barcode: barcode, trackCount: count, score: score, reasons: reasons, country: release["country"] as? String ?? "", disambiguation: release["disambiguation"] as? String ?? "")
        }.sorted { $0.score > $1.score }
    }

    public func detail(candidate: ReleaseCandidate) async throws -> ReleaseMatch {
        let release = try await request(entity: "release", id: candidate.id, inc: "recordings+artist-credits")
        var result: [MatchedTrack] = []
        for medium in release["media"] as? [[String: Any]] ?? [] {
            let disc = medium["position"] as? Int ?? 1
            for track in medium["tracks"] as? [[String: Any]] ?? [] {
                try Task.checkCancellation()
                guard result.count < 300 else { throw AppError.message("큰 박스 세트는 디스크별 검토가 필요합니다.") }
                guard let recording = track["recording"] as? [String: Any], let id = recording["id"] as? String else { continue }
                let detail = try await request(entity: "recording", id: id, inc: "artist-rels+work-rels+artist-credits")
                var credits = Self.artistRelations(detail), works: [Work] = []
                for ac in detail["artist-credit"] as? [[String: Any]] ?? [] {
                    if let artist = ac["artist"] as? [String: Any], let aid = artist["id"] as? String, let name = artist["name"] as? String { credits.append(Credit(artistID: "mb:" + aid, name: name, role: "performer", source: "musicbrainz")) }
                }
                for relation in detail["relations"] as? [[String: Any]] ?? [] {
                    if let work = relation["work"] as? [String: Any], let wid = work["id"] as? String, let title = work["title"] as? String {
                        works.append(Work(id: "mb:" + wid, title: title, source: "musicbrainz"))
                        let workDetail = try await request(entity: "work", id: wid, inc: "artist-rels")
                        credits += Self.artistRelations(workDetail)
                    }
                }
                result.append(MatchedTrack(disc: disc, number: track["position"] as? Int ?? Int(track["number"] as? String ?? "") ?? result.count + 1, title: track["title"] as? String ?? recording["title"] as? String ?? "", recordingID: id, credits: Array(Set(credits)), works: works))
            }
        }
        return ReleaseMatch(candidate: candidate, tracks: result)
    }
    private static func artistRelations(_ entity: [String: Any]) -> [Credit] {
        (entity["relations"] as? [[String: Any]] ?? []).compactMap { relation in
            guard let artist = relation["artist"] as? [String: Any], let id = artist["id"] as? String, let name = artist["name"] as? String, let type = relation["type"] as? String else { return nil }
            let roles = ["composer": "composer", "arranger": "arranger", "orchestrator": "arranger", "instrument": "performer", "vocal": "performer", "performer": "performer", "conductor": "conductor", "lyricist": "lyricist"]
            guard let role = roles[type] else { return nil }
            return Credit(artistID: "mb:" + id, name: name, role: role, source: "musicbrainz")
        }
    }
}
