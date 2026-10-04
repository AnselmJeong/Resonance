import Foundation
import GRDB

enum DiscoveryMigration {
    static func migrate(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE identityLink(kind TEXT NOT NULL, localID TEXT NOT NULL, canonicalID TEXT NOT NULL, source TEXT NOT NULL, albumID TEXT NOT NULL DEFAULT '', PRIMARY KEY(kind,localID,source,albumID));
        CREATE INDEX identity_target ON identityLink(kind,canonicalID);
        CREATE INDEX recording_mbid ON recording(mbid);
        """)
        for id in try String.fetchAll(db, sql: "SELECT id FROM album") { try tagLinks(db, albumID: id) }
        for id in try String.fetchAll(db, sql: "SELECT albumID FROM externalMatch") { try rebuild(db, albumID: id) }
    }

    /// Only corroborated co-credits on the same matched album create an identity edge.
    /// A name elsewhere in the library is never enough to merge identities.
    static func rebuild(_ db: Database, albumID: String) throws {
        try db.execute(sql: "DELETE FROM identityLink WHERE albumID=? AND source='musicbrainz'", arguments: [albumID])
        let rows = try Row.fetchAll(db, sql: """
        SELECT DISTINCT l.artistID AS localID, r.artistID AS remoteID, a.name AS localName, b.name AS remoteName
        FROM credit l JOIN credit r ON l.trackID=r.trackID AND l.role=r.role
        JOIN artist a ON a.id=l.artistID JOIN artist b ON b.id=r.artistID JOIN track t ON t.id=l.trackID
        WHERE t.albumID=? AND l.source='local' AND r.source='musicbrainz' AND l.artistID<>r.artistID
        """, arguments: [albumID])
        var candidates: [String: Set<String>] = [:]
        for row in rows where TextKey.normalize(row["localName"]) == TextKey.normalize(row["remoteName"]) {
            candidates[row["localID"], default: []].insert(row["remoteID"])
        }
        for (local, targets) in candidates where targets.count == 1 && !local.hasPrefix("mb:") {
            try insert(db, kind: "artist", local: local, target: targets.first!, albumID: albumID)
        }
        let works = try Row.fetchAll(db, sql: """
        SELECT DISTINCT l.workID AS localID, r.workID AS remoteID, a.title AS localName, b.title AS remoteName
        FROM recordingWork l JOIN recordingWork r ON l.recordingID=r.recordingID
        JOIN work a ON a.id=l.workID JOIN work b ON b.id=r.workID JOIN recording rec ON rec.id=l.recordingID
        JOIN track t ON t.id=rec.trackID WHERE t.albumID=? AND l.source='local' AND r.source='musicbrainz'
        """, arguments: [albumID])
        candidates = [:]
        for row in works where TextKey.normalize(row["localName"]) == TextKey.normalize(row["remoteName"]) {
            candidates[row["localID"], default: []].insert(row["remoteID"])
        }
        for (local, targets) in candidates where targets.count == 1 && !local.hasPrefix("mb:") {
            try insert(db, kind: "work", local: local, target: targets.first!, albumID: albumID)
        }
    }
    private static func insert(_ db: Database, kind: String, local: String, target: String, albumID: String, source: String = "musicbrainz") throws {
        let known = try String.fetchAll(db, sql: """
        WITH RECURSIVE nodes(id) AS (SELECT ? UNION SELECT ? UNION
          SELECT CASE WHEN l.localID=n.id THEN l.canonicalID ELSE l.localID END
          FROM identityLink l JOIN nodes n ON l.localID=n.id OR l.canonicalID=n.id WHERE l.kind=?)
        SELECT id FROM nodes WHERE id LIKE 'mb:%'
        """, arguments: [local, target, kind])
        guard Set(known).count <= 1 else { return }
        try db.execute(sql: "INSERT OR REPLACE INTO identityLink(kind,localID,canonicalID,source,albumID) VALUES(?,?,?,?,?)", arguments: [kind, local, target, source, albumID])
    }

    /// Import explicit identifiers already present in tags, including unchanged files in an older library.
    static func tagLinks(_ db: Database, albumID: String) throws {
        try db.execute(sql: "DELETE FROM identityLink WHERE albumID=? AND source='tag'", arguments: [albumID])
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
        func link(_ local: String, _ canonical: String, kind: String) throws {
            guard local != canonical, !local.hasPrefix("mb:") else { return }
            try insert(db, kind: kind, local: local, target: canonical, albumID: albumID, source: "tag")
        }
        for data in try String.fetchAll(db, sql: "SELECT data FROM track WHERE albumID=?", arguments: [albumID]) {
            let track = try decoder.decode(Track.self, from: Data(data.utf8))
            for (tag, role, nameTag) in [("MUSICBRAINZ_ARTISTID", "performer", "ARTIST"), ("MUSICBRAINZ_COMPOSERID", "composer", "COMPOSER"), ("MUSICBRAINZ_CONDUCTORID", "conductor", "CONDUCTOR")] {
                let names = track.tags[nameTag] ?? [], ids = track.tags[tag] ?? []
                guard !names.isEmpty, names.count == ids.count else { continue }
                for (name, id) in zip(names, ids) {
                    guard let uuid = UUID(uuidString: id), let credit = track.credits.first(where: { $0.source == "local" && $0.role == role && $0.name == name }) else { continue }
                    let canonical = "mb:" + uuid.uuidString.lowercased()
                    let artist = Artist(id: canonical, name: name, role: role, externalID: uuid.uuidString.lowercased())
                    try db.execute(sql: "INSERT OR IGNORE INTO artist(id,name,role,data) VALUES(?,?,?,?)", arguments: [canonical, name, role, try json(artist)])
                    try link(credit.artistID, canonical, kind: "artist")
                }
            }
            if let id = track.tags["MUSICBRAINZ_WORKID"]?.only, let uuid = UUID(uuidString: id), let title = track.tags["WORK"]?.only {
                let canonical = "mb:" + uuid.uuidString.lowercased(), work = Work(id: "mb:" + uuid.uuidString.lowercased(), title: title, source: "local")
                try db.execute(sql: "INSERT OR IGNORE INTO work(id,title,data) VALUES(?,?,?)", arguments: [canonical, title, try json(work)])
                for local in try String.fetchAll(db, sql: "SELECT workID FROM recordingWork WHERE recordingID=? AND source='local'", arguments: [track.recordingID]) { try link(local, canonical, kind: "work") }
            }
        }
    }
}

private extension Array { var only: Element? { count == 1 ? first : nil } }
