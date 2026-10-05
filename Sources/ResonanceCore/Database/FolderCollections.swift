import Foundation
import GRDB

/// Collection membership is derived from root-relative music paths, never a display override.
enum FolderCollections {
    static func migrate(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE section ADD COLUMN present INTEGER NOT NULL DEFAULT 1")
        try reconcileMembership(db)
    }

    static func reconcileMembership(_ db: Database, rootID: String? = nil) throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
        let roots = try Row.fetchAll(db, sql: "SELECT id,path FROM root" + (rootID == nil ? "" : " WHERE id=?"), arguments: rootID.map { [$0] } ?? [])
        for root in roots {
            let id: String = root["id"], path: String = root["path"]
            for data in try String.fetchAll(db, sql: "SELECT data FROM section WHERE rootID=?", arguments: [id]) {
                var section = try decoder.decode(LibrarySection.self, from: Data(data.utf8))
                section.name = LibrarySection.folderName(rootPath: path, relativePath: section.relativePath)
                section.hidden = false; section.order = 0
                let updated = try json(section)
                if updated != data { try db.execute(sql: "UPDATE section SET data=? WHERE id=?", arguments: [updated, section.id]) }
            }
            // Track paths also repair albums previously assigned to a collection in a different root.
            for row in try Row.fetchAll(db, sql: """
                SELECT a.data, (SELECT MIN(t.path) FROM track t WHERE t.albumID=a.id) AS musicPath
                FROM album a WHERE a.rootID=?
                """, arguments: [id]) {
                guard let musicPath: String = row["musicPath"] else { continue }
                var album = try decoder.decode(Album.self, from: Data((row["data"] as String).utf8))
                let relative = LibrarySection.folderPath(for: musicPath)
                let section = LibrarySection(rootID: id, relativePath: relative, name: LibrarySection.folderName(rootPath: path, relativePath: relative))
                try db.execute(sql: "INSERT OR IGNORE INTO section(id,rootID,data) VALUES(?,?,?)", arguments: [section.id, id, try json(section)])
                if album.sectionID != section.id {
                    album.sectionID = section.id
                    try db.execute(sql: "UPDATE album SET sectionID=?,data=? WHERE id=?", arguments: [section.id, try json(album), album.id])
                }
                try db.execute(sql: "UPDATE searchContent SET sectionID=? WHERE albumID=? AND (sectionID IS NULL OR sectionID<>?)", arguments: [section.id, album.id, section.id])
            }
            try db.execute(sql: "DELETE FROM assertion WHERE field='sectionID' AND entityID IN (SELECT id FROM album WHERE rootID=?)", arguments: [id])
        }
    }
}
