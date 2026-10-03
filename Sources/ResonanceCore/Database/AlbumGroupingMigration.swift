import Foundation
import GRDB

/// Runs inside GRDB's migration transaction, after the existing automatic backup.
enum AlbumGroupingMigration {
    static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            ALTER TABLE album ADD COLUMN groupingKey TEXT;
            CREATE TABLE albumMergeArchive(originalID TEXT PRIMARY KEY, mergedID TEXT NOT NULL, rootID TEXT NOT NULL,
                album TEXT NOT NULL, assertions TEXT NOT NULL, externalMatch TEXT, insights TEXT NOT NULL);
            """)
        let decoder = JSONDecoder()
        let roots = try String.fetchAll(db, sql: "SELECT data FROM root").map { try decoder.decode(LibraryRoot.self, from: Data($0.utf8)) }
        let rootsByID = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0) })
        let albums = try String.fetchAll(db, sql: "SELECT data FROM album").map { try decoder.decode(Album.self, from: Data($0.utf8)) }
        let tracks = try String.fetchAll(db, sql: "SELECT data FROM track ORDER BY disc,number,path").map { try decoder.decode(Track.self, from: Data($0.utf8)) }
        let tracksByAlbum = Dictionary(grouping: tracks, by: \.albumID)
        var groups: [String: [Album]] = [:]
        for album in albums {
            guard let root = rootsByID[album.rootID], let track = tracksByAlbum[album.id]?.first else { continue }
            let key = AlbumGrouping.key(root: root, relativePath: track.relativePath, tags: track.tags)
            groups[key, default: []].append(album)
        }
        for (key, group) in groups {
            if group.count == 1 {
                try db.execute(sql: "UPDATE album SET groupingKey=? WHERE id=?", arguments: [key, group[0].id])
            } else {
                try merge(db, key: key, albums: group, tracksByAlbum: tracksByAlbum)
            }
        }
        try db.execute(sql: "CREATE UNIQUE INDEX album_grouping ON album(groupingKey)")
    }

    private static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private static func merge(_ db: Database, key: String, albums: [Album], tracksByAlbum: [String: [Track]]) throws {
        // Prefer the most explicitly edited record, then the largest original fragment.
        var edits: [String: Int] = [:]
        for album in albums {
            edits[album.id] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assertion WHERE entityID=? AND source='user'", arguments: [album.id]) ?? 0
        }
        let originals = albums.sorted {
            if edits[$0.id] != edits[$1.id] { return edits[$0.id, default: 0] > edits[$1.id, default: 0] }
            let lhs = tracksByAlbum[$0.id]?.count ?? 0, rhs = tracksByAlbum[$1.id]?.count ?? 0
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
        var merged = originals[0]
        var tracks = originals.flatMap { tracksByAlbum[$0.id] ?? [] }
        for original in originals {
            let assertions = try Row.fetchAll(db, sql: "SELECT field,value,source FROM assertion WHERE entityID=?", arguments: [original.id]).map {
                ["field": $0["field"] as String, "value": $0["value"] as String, "source": $0["source"] as String]
            }
            let match = try String.fetchOne(db, sql: "SELECT data FROM externalMatch WHERE albumID=?", arguments: [original.id])
            let insights = try String.fetchAll(db, sql: "SELECT data FROM insight WHERE entityID=?", arguments: [original.id])
            try db.execute(sql: "INSERT INTO albumMergeArchive(originalID,mergedID,rootID,album,assertions,externalMatch,insights) VALUES(?,?,?,?,?,?,?)",
                           arguments: [original.id, merged.id, original.rootID, try json(original), try json(assertions), match, try json(insights)])
            if original.id != merged.id {
                try db.execute(sql: "INSERT OR IGNORE INTO assertion(entityID,field,value,source) SELECT ?,field,value,source FROM assertion WHERE entityID=?", arguments: [merged.id, original.id])
            }
            // Fragment-level matches/stories no longer describe the combined track list.
            // Keep their exact original data in the archive instead of presenting stale facts.
            try db.execute(sql: "DELETE FROM externalMatch WHERE albumID=?", arguments: [original.id])
            try db.execute(sql: "DELETE FROM insight WHERE entityID=?", arguments: [original.id])
        }
        merged.favorite = originals.contains { $0.favorite }
        merged.artwork = merged.artwork ?? originals.compactMap(\.artwork).first
        merged.attachments = Array(Set(originals.flatMap(\.attachments))).sorted()
        merged.trackCount = tracks.count; merged.duration = tracks.reduce(0) { $0 + $1.duration }
        merged.artist = AlbumGrouping.artist(tracks: tracks, fallback: merged.artist)
        for row in try Row.fetchAll(db, sql: "SELECT field,value FROM assertion WHERE entityID=? AND source='user'", arguments: [merged.id]) {
            let field: String = row["field"], value: String = row["value"]
            switch field {
            case "title": merged.title = value
            case "artist": merged.artist = value
            case "sectionID": merged.sectionID = value
            case "artwork": merged.artwork = value
            default: break
            }
        }
        try db.execute(sql: "UPDATE album SET groupingKey=?,sectionID=?,title=?,artist=?,favorite=?,data=? WHERE id=?",
                       arguments: [key, merged.sectionID, merged.title, merged.artist, merged.favorite, try json(merged), merged.id])
        for index in tracks.indices {
            tracks[index].albumID = merged.id
            let track = tracks[index]
            try db.execute(sql: "UPDATE track SET albumID=?,data=? WHERE id=?", arguments: [merged.id, try json(track), track.id])
            try LibraryDatabase.index(db, id: track.id, kind: "track", title: track.title,
                                      subtitle: ([merged.title, merged.artist, merged.label] + track.credits.map(\.name)).joined(separator: " · "),
                                      albumID: merged.id, sectionID: merged.sectionID, format: track.format)
        }
        for original in originals {
            try db.execute(sql: "UPDATE searchContent SET albumID=?,sectionID=? WHERE albumID=? AND kind='work'", arguments: [merged.id, merged.sectionID, original.id])
            guard original.id != merged.id else { continue }
            try db.execute(sql: "DELETE FROM searchFTS WHERE rowid IN (SELECT id FROM searchContent WHERE kind='album' AND entityID=?)", arguments: [original.id])
            try db.execute(sql: "DELETE FROM searchGram WHERE docID IN (SELECT id FROM searchContent WHERE kind='album' AND entityID=?)", arguments: [original.id])
            try db.execute(sql: "DELETE FROM searchContent WHERE kind='album' AND entityID=?", arguments: [original.id])
            try db.execute(sql: "DELETE FROM assertion WHERE entityID=?", arguments: [original.id])
            try db.execute(sql: "DELETE FROM album WHERE id=?", arguments: [original.id])
        }
        try LibraryDatabase.index(db, id: merged.id, kind: "album", title: merged.title,
                                  subtitle: [merged.artist, merged.label, merged.date].joined(separator: " · "), albumID: merged.id, sectionID: merged.sectionID)
    }
}
