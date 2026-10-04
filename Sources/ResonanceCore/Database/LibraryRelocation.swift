import Foundation
import GRDB

extension LibraryDatabase {
    public func resolvedLibraryID(_ id: String) throws -> String {
        try pool.read { db in try String.fetchOne(db, sql: "SELECT targetID FROM libraryRedirect WHERE originalID=?", arguments: [id]) ?? id }
    }

    func scanTracks(rootID: String) throws -> [String: Track] {
        Dictionary(uniqueKeysWithValues: try list(Track.self, sql: "SELECT data FROM track WHERE rootID=?", args: [rootID]).map { ($0.relativePath, $0) })
    }

    /// Called only after traversal finishes and the root/volume is still connected.
    func finishScan(root: LibraryRoot, scanID: String, coverage: ScanCoverage) throws {
        let albums = try list(Album.self, sql: "SELECT data FROM album WHERE rootID=?", args: [root.id])
        let tracks = try list(Track.self, sql: "SELECT data FROM track WHERE rootID=?", args: [root.id])
        let byAlbum = Dictionary(grouping: tracks, by: \.albumID)
        let seenIDs = try pool.read { db in Set(try String.fetchAll(db, sql: "SELECT id FROM track WHERE rootID=? AND scanID=?", arguments: [root.id, scanID])) }
        var missing: [String: [Album]] = [:], present: [String: [Album]] = [:]
        for album in albums {
            let members = byAlbum[album.id] ?? []
            guard let fingerprint = try RelocationFingerprint.album(members) else { continue }
            // Derive the folder from root-relative track paths, also supporting a reconnected root.
            let parent = (members[0].relativePath as NSString).deletingLastPathComponent
            let folder = LibraryScanner.discNumber((parent as NSString).lastPathComponent) == nil ? parent : (parent as NSString).deletingLastPathComponent
            if coverage.folderIsMissing(folder), members.allSatisfy({ coverage.isMissing($0.relativePath) }) {
                missing[fingerprint, default: []].append(album)
            } else if members.allSatisfy({ seenIDs.contains($0.id) && coverage.files.contains($0.relativePath) && !coverage.isProtected($0.relativePath) }) {
                present[fingerprint, default: []].append(album)
            }
        }
        var pairs: [(Album, Album)] = []
        for (key, originals) in missing where originals.count == 1 && present[key]?.count == 1 {
            let old = originals[0], new = present[key]![0]
            // Conflicting explicit edition matches require human review, even with identical local tags.
            let oldMatch = try confirmedMatch(old.id), newMatch = try confirmedMatch(new.id)
            if let oldMatch, let newMatch, oldMatch.candidate.id != newMatch.candidate.id { continue }
            pairs.append((old, new))
        }
        if !pairs.isEmpty {
            try pool.backup(to: DatabaseQueue(path: path + ".before-relocation-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).sqlite"))
        }
        try pool.write { db in
            for (old, new) in pairs {
                try relocate(db, old: old, new: new, oldTracks: byAlbum[old.id]!, newTracks: byAlbum[new.id]!, scanID: scanID)
            }
            // Different local identity IDs remain linked for aliases/history. Show each credited name once.
            for row in try Row.fetchAll(db, sql: """
                SELECT t.data AS trackData,a.data AS albumData
                FROM (SELECT DISTINCT targetID FROM libraryRedirect WHERE rootID=?) r
                JOIN track t ON t.id=r.targetID JOIN album a ON a.id=t.albumID
                """, arguments: [root.id]) {
                let track = try decode(Track.self, row["trackData"]), album = try decode(Album.self, row["albumData"])
                try Self.index(db, id: track.id, kind: "track", title: track.title,
                               subtitle: ([album.title, album.artist, album.label] + Array(Set(track.credits.map(\.name))).sorted()).joined(separator: " · "),
                               albumID: album.id, sectionID: album.sectionID, format: track.format)
            }
            for data in try String.fetchAll(db, sql: "SELECT data FROM track WHERE rootID=? AND scanID<>?", arguments: [root.id, scanID]) {
                var track = try decode(Track.self, data)
                guard coverage.isMissing(track.relativePath) else { continue }
                track.available = false
                try db.execute(sql: "UPDATE track SET available=0,data=? WHERE id=?", arguments: [try json(track), track.id])
            }
        }
    }

    private func relocate(_ db: Database, old: Album, new: Album, oldTracks: [Track], newTracks: [Track], scanID: String) throws {
        let newByFingerprint = try Dictionary(uniqueKeysWithValues: newTracks.map { (try RelocationFingerprint.track($0)!, $0) })
        var remap: [String: String] = [new.id: old.id]
        try moveEntityData(db, from: new.id, to: old.id)
        try db.execute(sql: "INSERT OR IGNORE INTO externalMatch(albumID,releaseID,data,confirmedAt) SELECT ?,releaseID,data,confirmedAt FROM externalMatch WHERE albumID=?", arguments: [old.id, new.id])
        try db.execute(sql: "DELETE FROM externalMatch WHERE albumID=?", arguments: [new.id])
        try db.execute(sql: "INSERT OR IGNORE INTO preference(key,data) SELECT ?,data FROM preference WHERE key=?", arguments: ["metadata-skip:" + old.id, "metadata-skip:" + new.id])
        try db.execute(sql: "INSERT OR IGNORE INTO identityLink(kind,localID,canonicalID,source,albumID) SELECT kind,localID,canonicalID,source,? FROM identityLink WHERE albumID=?", arguments: [old.id, new.id])
        try db.execute(sql: "DELETE FROM identityLink WHERE albumID=?", arguments: [new.id])
        var relocated: [Track] = []
        for original in oldTracks {
            let incoming = newByFingerprint[try RelocationFingerprint.track(original)!]!
            remap[incoming.id] = original.id
            try moveEntityData(db, from: incoming.id, to: original.id)
            // Both local identities are supported by the same complete recording metadata.
            // Keep aliases and user links on either artist/work reachable after merging credits.
            for credit in incoming.credits where credit.source == "local" {
                if let previous = original.credits.first(where: { $0.source == "local" && $0.role == credit.role && $0.name == credit.name }), previous.artistID != credit.artistID {
                    try db.execute(sql: "INSERT OR IGNORE INTO identityLink(kind,localID,canonicalID,source,albumID) VALUES('artist',?,?,'relocation',?)", arguments: [credit.artistID, previous.artistID, old.id])
                }
            }
            let workPairs = try Row.fetchAll(db, sql: """
                SELECT a.workID AS originalID,b.workID AS incomingID FROM recordingWork a
                JOIN work wa ON wa.id=a.workID JOIN recordingWork b ON b.recordingID=? AND b.source=a.source
                JOIN work wb ON wb.id=b.workID AND wb.title=wa.title
                WHERE a.recordingID=? AND a.source='local' AND a.workID<>b.workID
                """, arguments: [incoming.recordingID, original.recordingID])
            for pair in workPairs {
                try db.execute(sql: "INSERT OR IGNORE INTO identityLink(kind,localID,canonicalID,source,albumID) VALUES('work',?,?,'relocation',?)", arguments: [pair["incomingID"] as String, pair["originalID"] as String, old.id])
            }
            try db.execute(sql: "INSERT OR IGNORE INTO credit(trackID,artistID,role,source) SELECT ?,artistID,role,source FROM credit WHERE trackID=?", arguments: [original.id, incoming.id])
            try db.execute(sql: "INSERT OR IGNORE INTO recordingWork(recordingID,workID,source) SELECT ?,workID,source FROM recordingWork WHERE recordingID=?", arguments: [original.recordingID, incoming.recordingID])
            try db.execute(sql: "UPDATE recording SET mbid=COALESCE(mbid,(SELECT mbid FROM recording WHERE trackID=?)) WHERE trackID=?", arguments: [incoming.id, original.id])
            try db.execute(sql: "DELETE FROM credit WHERE trackID=?", arguments: [incoming.id])
            try db.execute(sql: "DELETE FROM recordingWork WHERE recordingID=?", arguments: [incoming.recordingID])
            try db.execute(sql: "DELETE FROM recording WHERE trackID=?", arguments: [incoming.id])
            try removeSearchEntity(db, id: incoming.id)
            try db.execute(sql: "DELETE FROM track WHERE id=?", arguments: [incoming.id])
            var track = original
            track.relativePath = incoming.relativePath; track.modified = incoming.modified; track.available = true
            track.credits = Array(Set(original.credits + incoming.credits)).sorted { ($0.role, $0.name, $0.artistID) < ($1.role, $1.name, $1.artistID) }
            try db.execute(sql: "UPDATE track SET path=?,scanID=?,available=1,data=? WHERE id=?", arguments: [track.relativePath, scanID, try json(track), track.id])
            relocated.append(track)
        }
        var album = new
        album.id = old.id; album.favorite = old.favorite || new.favorite
        album.artwork = new.artwork ?? old.artwork
        for row in try Row.fetchAll(db, sql: "SELECT field,value FROM assertion WHERE entityID=? AND (source='user' OR (source='musicbrainz' AND field='artwork')) ORDER BY CASE source WHEN 'user' THEN 1 ELSE 0 END", arguments: [old.id]) {
            let field: String = row["field"], value: String = row["value"]
            switch field {
            case "title": album.title = value
            case "artist": album.artist = value
            case "sectionID": album.sectionID = value
            case "artwork":
                let relocatedPath = value.hasPrefix(old.folder + "/") ? new.folder + value.dropFirst(old.folder.count) : value
                album.artwork = relocatedPath
                try db.execute(sql: "UPDATE assertion SET value=? WHERE entityID=? AND field='artwork' AND value=?", arguments: [relocatedPath, old.id, value])
            default: break
            }
        }
        album.trackCount = relocated.count; album.duration = relocated.reduce(0) { $0 + $1.duration }
        let groupingKey = try String.fetchOne(db, sql: "SELECT groupingKey FROM album WHERE id=?", arguments: [new.id])
        try removeSearchEntity(db, id: new.id)
        try db.execute(sql: "UPDATE searchContent SET albumID=?,sectionID=? WHERE albumID IN (?,?)", arguments: [old.id, album.sectionID, old.id, new.id])
        try db.execute(sql: "DELETE FROM album WHERE id=?", arguments: [new.id])
        try db.execute(sql: "UPDATE album SET groupingKey=?,sectionID=?,title=?,artist=?,date=?,favorite=?,data=? WHERE id=?", arguments: [groupingKey, album.sectionID, album.title, album.artist, album.date, album.favorite, try json(album), album.id])
        for (from, to) in remap {
            try db.execute(sql: "UPDATE libraryRedirect SET targetID=? WHERE targetID=?", arguments: [to, from])
            try db.execute(sql: "INSERT OR REPLACE INTO libraryRedirect(originalID,targetID,rootID) VALUES(?,?,?)", arguments: [from, to, old.rootID])
        }
        if let data = try String.fetchOne(db, sql: "SELECT data FROM preference WHERE key='queue'") {
            var queue = try decode(QueueSnapshot.self, data)
            for i in queue.entries.indices { queue.entries[i].trackID = remap[queue.entries[i].trackID] ?? queue.entries[i].trackID }
            try db.execute(sql: "UPDATE preference SET data=? WHERE key='queue'", arguments: [try json(queue)])
        }
        try Self.index(db, id: album.id, kind: "album", title: album.title, subtitle: [album.artist, album.label, album.date].joined(separator: " · "), albumID: album.id, sectionID: album.sectionID)
        try DiscoveryMigration.tagLinks(db, albumID: album.id)
        try DiscoveryMigration.rebuild(db, albumID: album.id)
    }

    private func moveEntityData(_ db: Database, from: String, to: String) throws {
        try db.execute(sql: "INSERT OR IGNORE INTO assertion(entityID,field,value,source) SELECT ?,field,value,source FROM assertion WHERE entityID=?", arguments: [to, from])
        try db.execute(sql: "DELETE FROM assertion WHERE entityID=?", arguments: [from])
        for data in try String.fetchAll(db, sql: "SELECT data FROM insight WHERE entityID=?", arguments: [from]) {
            var insight = try decode(Insight.self, data); insight.entityID = to
            try db.execute(sql: "UPDATE insight SET entityID=?,data=? WHERE id=?", arguments: [to, try json(insight), insight.id])
        }
    }
    private func removeSearchEntity(_ db: Database, id: String) throws {
        try db.execute(sql: "DELETE FROM searchFTS WHERE rowid IN (SELECT id FROM searchContent WHERE entityID=?)", arguments: [id])
        try db.execute(sql: "DELETE FROM searchContent WHERE entityID=?", arguments: [id])
    }
}
