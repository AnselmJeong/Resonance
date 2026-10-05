import Foundation
import GRDB

extension LibraryDatabase {
    public func updateAttachments(albumID: String, paths: [String]) throws -> Album? {
        guard var album = try album(albumID) else { return nil }
        guard album.attachments != paths else { return album }
        album.attachments = paths
        try pool.write { db in try db.execute(sql: "UPDATE album SET data=? WHERE id=?", arguments: [try json(album), album.id]) }
        return album
    }
    public func identityMembers(_ id: String, kind: String) throws -> [String] {
        try pool.read { db in try String.fetchAll(db, sql: """
        WITH RECURSIVE members(id) AS (
          SELECT ? UNION SELECT CASE WHEN l.localID=m.id THEN l.canonicalID ELSE l.localID END
          FROM identityLink l JOIN members m ON l.localID=m.id OR l.canonicalID=m.id WHERE l.kind=?
        ) SELECT id FROM members ORDER BY id
        """, arguments: [id, kind]) }
    }
    public func canonicalID(_ id: String, kind: String) throws -> String {
        let members = try identityMembers(id, kind: kind)
        return members.first(where: { $0.hasPrefix("mb:") }) ?? members.first ?? id
    }
    public func linkIdentity(_ id: String, to target: String, kind: String) throws { try linkIdentities(id, to: [target], kind: kind) }
    /// Joins several confirmed entries to `id` at once, all or nothing.
    /// A user link is keyed by its local end, so each new edge hangs off a member that has none yet; earlier links are never replaced.
    public func linkIdentities(_ id: String, to targets: [String], kind: String) throws {
        guard ["artist", "work"].contains(kind) else { return }
        func exists(_ value: String) throws -> Bool { kind == "artist" ? try artist(value) != nil : try work(value) != nil }
        guard try exists(id) else { throw AppError.message("연결할 대상을 찾지 못했습니다.") }
        var joined = Set(try identityMembers(id, kind: kind)), groups: [Set<String>] = []
        for target in targets where !joined.contains(target) {
            guard try exists(target) else { throw AppError.message("연결할 대상을 찾지 못했습니다.") }
            let members = Set(try identityMembers(target, kind: kind))
            groups.append(members); joined.formUnion(members)
        }
        guard !groups.isEmpty else { return }
        guard joined.filter({ $0.hasPrefix("mb:") }).count <= 1 else { throw AppError.message("서로 다른 MusicBrainz ID입니다. 외부 매칭을 먼저 검토하세요.") }
        var taken = Set(try pool.read { db in try String.fetchAll(db, sql: "SELECT localID FROM identityLink WHERE kind=? AND source='user' AND albumID=''", arguments: [kind]) })
        var linked = Set(try identityMembers(id, kind: kind)), edges: [(String, String)] = []
        for members in groups {
            if let free = members.sorted().first(where: { !taken.contains($0) }) { edges.append((free, id)); taken.insert(free) }
            else if let free = linked.sorted().first(where: { !taken.contains($0) }), let target = members.sorted().first { edges.append((free, target)); taken.insert(free) }
            else { throw AppError.message("기존 수동 연결이 얽혀 있습니다. 연결을 해제한 뒤 다시 시도하세요.") }
            linked.formUnion(members)
        }
        try pool.write { db in
            for (local, canonical) in edges { try db.execute(sql: "INSERT INTO identityLink(kind,localID,canonicalID,source,albumID) VALUES(?,?,?,'user','')", arguments: [kind, local, canonical]) }
        }
    }
    /// Undoes the listener's links and the automatic same-name links of this group; those names then stay apart until linked by hand.
    public func unlinkIdentity(_ id: String, kind: String) throws {
        let members = try identityMembers(id, kind: kind)
        let names = kind == "artist" ? try members.compactMap { try artist($0)?.name }.map(TextKey.normalize) : []
        let split = Set(try preference(NamesakeLinks.splitKey, as: [String].self) ?? []).union(names)
        let data = try json(split.sorted())
        try pool.write { db in
            for member in members { try db.execute(sql: "DELETE FROM identityLink WHERE kind=? AND source='user' AND (localID=? OR canonicalID=?)", arguments: [kind, member, member]) }
            if kind == "artist" {
                try db.execute(sql: "INSERT OR REPLACE INTO preference(key,data) VALUES(?,?)", arguments: [NamesakeLinks.splitKey, data])
                try NamesakeLinks.rebuild(db)
            }
        }
    }
    public func displayTracks(_ tracks: [Track]) throws -> [Track] {
        var identities: [String: String] = [:]
        return try tracks.map { original in
            var track = original, credits: [String: Credit] = [:]
            for var credit in track.credits {
                if identities[credit.artistID] == nil { identities[credit.artistID] = try canonicalID(credit.artistID, kind: "artist") }
                credit.artistID = identities[credit.artistID]!
                let key = credit.artistID + "|" + credit.role
                if let previous = credits[key] {
                    var merged = credit.source != "local" ? credit : previous
                    let attributes = Array(Set((previous.attributes ?? []) + (credit.attributes ?? []))).sorted()
                    merged.attributes = attributes.isEmpty ? nil : attributes
                    credits[key] = merged
                } else { credits[key] = credit }
            }
            track.credits = credits.values.sorted { ($0.role, $0.name) < ($1.role, $1.name) }
            return track
        }
    }
    func displayWorks(_ values: [Work]) throws -> [Work] {
        var result: [String: Work] = [:]
        for value in values {
            let id = try canonicalID(value.id, kind: "work")
            result[id] = try work(id) ?? value
        }
        return result.values.sorted { $0.title < $1.title }
    }
    public func artistTracks(_ id: String, sectionID: String? = nil, role: String? = nil) throws -> [Track] {
        let ids = try identityMembers(id, kind: "artist"), marks = ids.map { _ in "?" }.joined(separator: ",")
        var args = StatementArguments(ids)
        var sql = "SELECT DISTINCT t.data FROM track t JOIN credit c ON c.trackID=t.id JOIN album a ON a.id=t.albumID WHERE c.artistID IN (\(marks))"
        if let sectionID { sql += " AND a.sectionID=?"; args += [sectionID] }
        if let role { sql += " AND c.role=?"; args += [role] }
        sql += " ORDER BY a.title,t.disc,t.number LIMIT 2000"
        return try displayTracks(list(Track.self, sql: sql, args: args))
    }
    public func workTracks(_ id: String) throws -> [Track] {
        let ids = try identityMembers(id, kind: "work"), marks = ids.map { _ in "?" }.joined(separator: ",")
        return try displayTracks(list(Track.self, sql: """
        WITH RECURSIVE works(id) AS (
          SELECT id FROM work WHERE id IN (\(marks))
          UNION SELECT child.id FROM work child JOIN works parent ON json_extract(child.data,'$.parentID')=parent.id
          UNION SELECT CASE WHEN link.localID=w.id THEN link.canonicalID ELSE link.localID END
            FROM identityLink link JOIN works w ON link.localID=w.id OR link.canonicalID=w.id WHERE link.kind='work'
        ) SELECT DISTINCT t.data FROM track t JOIN recording r ON r.trackID=t.id JOIN recordingWork rw ON rw.recordingID=r.id
          WHERE rw.workID IN (SELECT id FROM works) ORDER BY t.albumID,t.disc,t.number LIMIT 2000
        """, args: StatementArguments(ids)))
    }
    public func childWorks(_ id: String) throws -> [Work] {
        try list(Work.self, sql: "SELECT data FROM work WHERE json_extract(data,'$.parentID')=? ORDER BY title", args: [id])
    }
    public func relatedAlbums(trackID: String, limit: Int = 6) throws -> [RelatedAlbum] {
        guard let track = try track(trackID) else { return [] }
        var result: [String: RelatedAlbum] = [:]
        func add(_ tracks: [Track], reason: String, rank: Int) throws {
            for other in tracks where other.albumID != track.albumID && (result[other.albumID]?.rank ?? -1) < rank {
                if let album = try album(other.albumID) { result[album.id] = RelatedAlbum(album: album, trackID: other.id, reason: reason, rank: rank) }
            }
        }
        for work in try works(trackID: trackID) { try add(workTracks(work.id), reason: "같은 작품 · \(work.title)", rank: 100) }
        for credit in track.credits.prefix(8) {
            try add(artistTracks(credit.artistID), reason: "같은 \(credit.roleLabel) · \(credit.name)", rank: credit.role == "composer" ? 40 : 60)
        }
        // Unmatched libraries remain explorable. These are explicitly labelled candidates, never identity edges.
        if result.count < limit {
            let leads = track.credits.filter { ["performer", "composer"].contains($0.role) }.prefix(2)
            for credit in leads {
                let candidates = try identityCandidates(credit.artistID, kind: "artist", query: credit.name)
                for candidate in candidates.prefix(12) where TextKey.normalize(candidate.name) == TextKey.normalize(credit.name) {
                    try add(artistTracks(candidate.id, role: credit.role), reason: "이름이 같은 \(credit.roleLabel) · \(credit.name) · 미확인", rank: 10)
                }
            }
        }
        return Array(result.values.sorted { $0.rank != $1.rank ? $0.rank > $1.rank : $0.album.title < $1.album.title }.prefix(limit))
    }
    public func identityCandidates(_ id: String, kind: String, query: String) throws -> [IdentityCandidate] {
        let excluded = Set(try identityMembers(id, kind: kind))
        let hits = try search(query, limit: 60).filter { $0.kind == kind && !excluded.contains($0.entityID) }
        var seen = Set<String>(), result: [IdentityCandidate] = []
        for hit in hits {
            let canonical = try canonicalID(hit.entityID, kind: kind)
            guard seen.insert(canonical).inserted else { continue }
            let tracks = kind == "artist" ? try artistTracks(canonical) : try workTracks(canonical)
            let titles = try Array(Set(tracks.map(\.albumID)).sorted().prefix(3)).compactMap { try album($0)?.title }
            result.append(IdentityCandidate(id: canonical, name: hit.title, detail: titles.joined(separator: " · ")))
        }
        return result
    }
    public func storyEntities(in text: String, entityID: String? = nil, kind: String? = nil) throws -> [StoryEntity] {
        let normalized = " " + TextKey.normalize(text) + " "
        let rows = try pool.read { db in try Row.fetchAll(db, sql: "SELECT DISTINCT entityID,kind,title FROM searchContent WHERE kind IN ('artist','work','album') AND length(titleKey)>=2 AND instr(?, titleKey)>0 LIMIT 200", arguments: [normalized]) }
        var result: [StoryEntity] = try rows.compactMap { row in
            let kind: String = row["kind"], id: String = row["entityID"]
            // Retained historical artists/works with no remaining tracks are not valid navigation targets.
            if kind == "artist", try artistTracks(id).isEmpty { return nil }
            if kind == "work", try workTracks(id).isEmpty { return nil }
            return StoryEntity(kind: kind, id: kind == "album" ? id : try canonicalID(id, kind: kind), name: row["title"])
        }
        let aliases = try pool.read { db in try Row.fetchAll(db, sql: "SELECT artist.id, alias.value AS name FROM artist, json_each(artist.data,'$.aliases') alias WHERE length(alias.value)>=2") }
        for row in aliases {
            let name: String = row["name"], id: String = row["id"]
            if normalized.contains(TextKey.normalize(name)), try !artistTracks(id).isEmpty {
                result.append(StoryEntity(kind: "artist", id: try canonicalID(id, kind: "artist"), name: name))
            }
        }
        // Resolve repeated local names from the story's own credits, without merging library identities.
        var context: [Track] = []
        if let entityID {
            switch kind {
            case "album": context = try tracks(albumID: entityID)
            case "track": context = try track(entityID).map { [$0] } ?? []
            case "artist": context = try artistTracks(entityID)
            case "work": context = try workTracks(entityID)
            default: break
            }
        }
        var preferred = Set(context.flatMap(\.credits).map { "artist|" + $0.artistID })
        for track in context {
            preferred.insert("album|" + track.albumID)
            for work in try works(trackID: track.id) { preferred.insert("work|" + work.id) }
        }
        let groups = Dictionary(grouping: result, by: { TextKey.normalize($0.name) })
        return groups.values.flatMap { values in
            let contextual = values.filter { preferred.contains($0.kind + "|" + $0.id) }
            return contextual.isEmpty ? values : contextual
        }
    }
    public func recordingDetails(trackID: String) throws -> MatchedTrack? {
        guard let track = try track(trackID), let match = try confirmedMatch(track.albumID) else { return nil }
        return match.tracks.first { $0.disc == track.disc && $0.number == track.number }
    }
    public func saveOnlineArtwork(albumID: String, path: String) throws {
        let albumID = try resolvedLibraryID(albumID)
        guard var album = try album(albumID), album.artwork == nil else { return }
        album.artwork = path
        try pool.write { db in
            try db.execute(sql: "UPDATE album SET data=? WHERE id=?", arguments: [try json(album), albumID])
            try db.execute(sql: "INSERT OR REPLACE INTO assertion(entityID,field,value,source) VALUES(?,'artwork',?,'musicbrainz')", arguments: [albumID, path])
        }
    }
}
