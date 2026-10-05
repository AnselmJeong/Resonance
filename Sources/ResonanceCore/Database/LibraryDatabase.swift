import Foundation
import GRDB

public actor LibraryDatabase {
    public nonisolated let path: String
    let pool: DatabasePool
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(path: String) throws {
        self.path = path
        let hadDatabase = FileManager.default.fileExists(atPath: path)
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration(); config.busyMode = .timeout(5)
        pool = try DatabasePool(path: path, configuration: config)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
            CREATE TABLE root(id TEXT PRIMARY KEY, path TEXT UNIQUE NOT NULL, data TEXT NOT NULL);
            CREATE TABLE section(id TEXT PRIMARY KEY, rootID TEXT NOT NULL REFERENCES root(id), data TEXT NOT NULL);
            CREATE TABLE album(id TEXT PRIMARY KEY, rootID TEXT NOT NULL REFERENCES root(id), sectionID TEXT NOT NULL REFERENCES section(id), title TEXT NOT NULL, artist TEXT NOT NULL, date TEXT NOT NULL, favorite INTEGER NOT NULL DEFAULT 0, data TEXT NOT NULL);
            CREATE INDEX album_section ON album(sectionID, title);
            CREATE TABLE track(id TEXT PRIMARY KEY, rootID TEXT NOT NULL REFERENCES root(id), albumID TEXT NOT NULL REFERENCES album(id), path TEXT NOT NULL, disc INTEGER NOT NULL, number INTEGER NOT NULL, format TEXT NOT NULL, available INTEGER NOT NULL, scanID TEXT NOT NULL, data TEXT NOT NULL, UNIQUE(rootID,path));
            CREATE INDEX track_album ON track(albumID, disc, number);
            CREATE TABLE artist(id TEXT PRIMARY KEY, name TEXT NOT NULL, role TEXT NOT NULL, data TEXT NOT NULL);
            CREATE TABLE credit(trackID TEXT NOT NULL REFERENCES track(id), artistID TEXT NOT NULL REFERENCES artist(id), role TEXT NOT NULL, source TEXT NOT NULL, PRIMARY KEY(trackID,artistID,role,source));
            CREATE INDEX credit_artist ON credit(artistID,trackID);
            CREATE TABLE recording(id TEXT PRIMARY KEY, trackID TEXT NOT NULL UNIQUE REFERENCES track(id), mbid TEXT);
            CREATE TABLE work(id TEXT PRIMARY KEY, title TEXT NOT NULL, data TEXT NOT NULL);
            CREATE TABLE recordingWork(recordingID TEXT NOT NULL REFERENCES recording(id), workID TEXT NOT NULL REFERENCES work(id), source TEXT NOT NULL, PRIMARY KEY(recordingID,workID,source));
            CREATE TABLE assertion(entityID TEXT NOT NULL, field TEXT NOT NULL, value TEXT NOT NULL, source TEXT NOT NULL, PRIMARY KEY(entityID,field,source));
            CREATE TABLE externalMatch(albumID TEXT PRIMARY KEY REFERENCES album(id), releaseID TEXT NOT NULL, data TEXT NOT NULL, confirmedAt DOUBLE NOT NULL);
            CREATE TABLE evidence(id TEXT PRIMARY KEY, data TEXT NOT NULL);
            CREATE TABLE insight(id TEXT PRIMARY KEY, entityID TEXT NOT NULL, language TEXT NOT NULL, created DOUBLE NOT NULL, data TEXT NOT NULL);
            CREATE INDEX insight_entity ON insight(entityID,language,created DESC);
            CREATE TABLE preference(key TEXT PRIMARY KEY, data TEXT NOT NULL);
            CREATE TABLE scanRun(id TEXT PRIMARY KEY, rootID TEXT NOT NULL, date DOUBLE NOT NULL, data TEXT NOT NULL);
            CREATE TABLE usage(id TEXT PRIMARY KEY, month TEXT NOT NULL, reserved DOUBLE NOT NULL, actual DOUBLE, inputTokens INTEGER, outputTokens INTEGER, state TEXT NOT NULL);
            CREATE INDEX usage_month ON usage(month);
            CREATE TABLE searchContent(id INTEGER PRIMARY KEY, entityID TEXT NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL, subtitle TEXT NOT NULL, normalized TEXT NOT NULL, albumID TEXT, sectionID TEXT, format TEXT, role TEXT, UNIQUE(entityID,kind));
            CREATE VIRTUAL TABLE searchFTS USING fts5(title, subtitle, tokenize='unicode61 remove_diacritics 2');
            CREATE TABLE searchGram(gram TEXT NOT NULL, docID INTEGER NOT NULL REFERENCES searchContent(id) ON DELETE CASCADE, PRIMARY KEY(gram,docID)) WITHOUT ROWID;
            """)
        }
        migrator.registerMigration("v2-search-ranking") { db in
            try db.execute(sql: "ALTER TABLE searchContent ADD COLUMN titleKey TEXT NOT NULL DEFAULT ''")
            for row in try Row.fetchAll(db, sql: "SELECT id,title FROM searchContent") {
                let id: Int64 = row["id"], title: String = row["title"]
                try db.execute(sql: "UPDATE searchContent SET titleKey=? WHERE id=?", arguments: [TextKey.normalize(title), id])
            }
        }
        migrator.registerMigration("v3-album-grouping") { db in try AlbumGroupingMigration.migrate(db) }
        migrator.registerMigration("v4-discovery") { db in try DiscoveryMigration.migrate(db) }
        migrator.registerMigration("v5-library-relocation") { db in
            try db.execute(sql: "CREATE TABLE libraryRedirect(originalID TEXT PRIMARY KEY, targetID TEXT NOT NULL, rootID TEXT NOT NULL REFERENCES root(id))")
        }
        migrator.registerMigration("v6-folder-collections") { db in try FolderCollections.migrate(db) }
        migrator.registerMigration("v7-direct-smb") { db in
            try db.execute(sql: "CREATE TABLE smbReadMetric(rootID TEXT NOT NULL REFERENCES root(id) ON DELETE CASCADE,path TEXT NOT NULL,data TEXT NOT NULL,PRIMARY KEY(rootID,path))")
        }
        migrator.registerMigration("v8-search-document-index") { db in
            // Updating one track must not scan every trigram in a large music library.
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS searchGram_docID ON searchGram(docID)")
        }
        migrator.registerMigration("v9-search-album-index") { db in
            // Folder reconciliation updates search rows per album; avoid a full-table walk for every album.
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS searchContent_albumID ON searchContent(albumID)")
        }
        migrator.registerMigration("v10-namesake-links") { db in try NamesakeLinks.rebuild(db) }
        if hadDatabase, try !pool.read({ try migrator.hasCompletedMigrations($0) }) {
            let backupPath = path + ".before-migration-\(Int(Date().timeIntervalSince1970)).sqlite"
            try pool.backup(to: DatabaseQueue(path: backupPath))
        }
        try migrator.migrate(pool)
    }

    func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
    func decode<T: Decodable>(_ type: T.Type, _ string: String) throws -> T { try decoder.decode(type, from: Data(string.utf8)) }
    func list<T: Decodable>(_ type: T.Type, sql: String, args: StatementArguments = []) throws -> [T] {
        try pool.read { db in try String.fetchAll(db, sql: sql, arguments: args).map { try decode(type, $0) } }
    }

    public func roots() throws -> [LibraryRoot] { try list(LibraryRoot.self, sql: "SELECT data FROM root ORDER BY path") }
    public func saveRoot(_ root: LibraryRoot) throws {
        try pool.write { db in try db.execute(sql: "INSERT INTO root(id,path,data) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET path=excluded.path,data=excluded.data", arguments: [root.id, root.path, try json(root)]) }
    }
    /// Removes only the app's index. This method never accesses the music files.
    public func removeRoot(_ rootID: String) throws -> Set<String> {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM identityLink WHERE albumID IN (SELECT id FROM album WHERE rootID=?)", arguments: [rootID])
            let removedTracks = Set(try String.fetchAll(db, sql: "SELECT id FROM track WHERE rootID=?", arguments: [rootID]))
            // A user may have moved another root's album into this root's collection.
            let movedAlbums = try String.fetchAll(db, sql: "SELECT data FROM album WHERE rootID<>? AND sectionID IN (SELECT id FROM section WHERE rootID=?)", arguments: [rootID, rootID])
            for data in movedAlbums {
                var album = try decode(Album.self, data)
                let sectionID: String
                if let existing = try String.fetchOne(db, sql: "SELECT id FROM section WHERE rootID=? ORDER BY id LIMIT 1", arguments: [album.rootID]) {
                    sectionID = existing
                } else {
                    let rootData = try String.fetchOne(db, sql: "SELECT data FROM root WHERE id=?", arguments: [album.rootID])!
                    let root = try decode(LibraryRoot.self, rootData)
                    let section = LibrarySection(rootID: root.id, relativePath: "", name: URL(fileURLWithPath: root.path).lastPathComponent)
                    sectionID = section.id
                    try db.execute(sql: "INSERT INTO section(id,rootID,data) VALUES(?,?,?)", arguments: [section.id, root.id, try json(section)])
                }
                album.sectionID = sectionID
                try db.execute(sql: "UPDATE album SET sectionID=?,data=? WHERE id=?", arguments: [sectionID, try json(album), album.id])
                try db.execute(sql: "UPDATE assertion SET value=? WHERE entityID=? AND field='sectionID'", arguments: [sectionID, album.id])
                try db.execute(sql: "UPDATE searchContent SET sectionID=? WHERE albumID=?", arguments: [sectionID, album.id])
            }
            if let stored = try String.fetchOne(db, sql: "SELECT data FROM preference WHERE key='queue'") {
                let queue = try decode(QueueSnapshot.self, stored).removingTracks(removedTracks)
                try db.execute(sql: "UPDATE preference SET data=? WHERE key='queue'", arguments: [try json(queue)])
            }
            for table in ["assertion", "insight"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE entityID IN (SELECT id FROM album WHERE rootID=? UNION SELECT id FROM track WHERE rootID=?)", arguments: [rootID, rootID])
            }
            // Shared artist/work records and their user aliases are retained.
            try db.execute(sql: "DELETE FROM searchFTS WHERE rowid IN (SELECT id FROM searchContent WHERE kind IN ('album','track') AND albumID IN (SELECT id FROM album WHERE rootID=?))", arguments: [rootID])
            try db.execute(sql: "DELETE FROM searchContent WHERE kind IN ('album','track') AND albumID IN (SELECT id FROM album WHERE rootID=?)", arguments: [rootID])
            try db.execute(sql: "DELETE FROM credit WHERE trackID IN (SELECT id FROM track WHERE rootID=?)", arguments: [rootID])
            try db.execute(sql: "DELETE FROM recordingWork WHERE recordingID IN (SELECT r.id FROM recording r JOIN track t ON t.id=r.trackID WHERE t.rootID=?)", arguments: [rootID])
            try db.execute(sql: "DELETE FROM recording WHERE trackID IN (SELECT id FROM track WHERE rootID=?)", arguments: [rootID])
            try db.execute(sql: "DELETE FROM externalMatch WHERE albumID IN (SELECT id FROM album WHERE rootID=?)", arguments: [rootID])
            try db.execute(sql: "DELETE FROM track WHERE rootID=?", arguments: [rootID])
            try db.execute(sql: "DELETE FROM album WHERE rootID=?", arguments: [rootID])
            try db.execute(sql: "DELETE FROM section WHERE rootID=?", arguments: [rootID])
            try db.execute(sql: "DELETE FROM scanRun WHERE rootID=?", arguments: [rootID])
            try db.execute(sql: "DELETE FROM albumMergeArchive WHERE rootID=?", arguments: [rootID])
            try db.execute(sql: "DELETE FROM libraryRedirect WHERE rootID=?", arguments: [rootID])
            try db.execute(sql: "DELETE FROM root WHERE id=?", arguments: [rootID])
            // A shared work's search link may have pointed at the removed album.
            try db.execute(sql: """
                UPDATE searchContent SET albumID=(SELECT t.albumID FROM recordingWork rw JOIN recording r ON r.id=rw.recordingID JOIN track t ON t.id=r.trackID WHERE rw.workID=searchContent.entityID LIMIT 1), sectionID=NULL
                WHERE kind='work' AND NOT EXISTS (SELECT 1 FROM album WHERE id=searchContent.albumID)
                """)
            return removedTracks
        }
    }
    public func sections() throws -> [LibrarySection] { try list(LibrarySection.self, sql: "SELECT data FROM section WHERE present=1").sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    public func saveSection(_ value: LibrarySection) throws {
        try pool.write { db in try db.execute(sql: "INSERT INTO section(id,rootID,data) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data,present=1", arguments: [value.id, value.rootID, try json(value)]) }
    }
    public func albums(rootID: String? = nil, sectionID: String? = nil, rootIDs: [String]? = nil, sectionIDs: [String]? = nil, favorites: Bool = false, sort: String = "title", limit: Int = 120, offset: Int = 0) throws -> [Album] {
        let ordering = ["title": "title COLLATE NOCASE", "artist": "artist COLLATE NOCASE,title", "date": "date DESC,title"][sort] ?? "title"
        var conditions: [String] = []; var args: [DatabaseValue] = []
        for (column, ids) in [("rootID", rootID.map { [$0] } ?? rootIDs), ("sectionID", sectionID.map { [$0] } ?? sectionIDs)] {
            if let ids {
                guard !ids.isEmpty else { return [] }
                conditions.append("\(column) IN (\(Array(repeating: "?", count: ids.count).joined(separator: ",")))")
                args += ids.map(\.databaseValue)
            }
        }
        if favorites { conditions.append("favorite=1") }
        conditions.append("EXISTS (SELECT 1 FROM section s WHERE s.id=album.sectionID AND s.present=1)")
        args += [limit.databaseValue, offset.databaseValue]
        return try list(Album.self, sql: "SELECT data FROM album WHERE \(conditions.joined(separator: " AND ")) ORDER BY \(ordering),id LIMIT ? OFFSET ?", args: StatementArguments(args))
    }
    public func counts() throws -> (albums: Int, tracks: Int) {
        try pool.read { db in (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM album") ?? 0, try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track") ?? 0) }
    }
    public func album(_ id: String) throws -> Album? { try list(Album.self, sql: "SELECT data FROM album WHERE id=?", args: [resolvedLibraryID(id)]).first }
    public func albumIdentities(rootID: String) throws -> [String: String] {
        try pool.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT groupingKey,id FROM album WHERE rootID=? AND groupingKey IS NOT NULL", arguments: [rootID]).map { ($0["groupingKey"] as String, $0["id"] as String) })
        }
    }
    public func rawTrack(_ id: String) throws -> Track? { try list(Track.self, sql: "SELECT data FROM track WHERE id=?", args: [resolvedLibraryID(id)]).first }
    public func track(_ id: String) throws -> Track? { try displayTracks(list(Track.self, sql: "SELECT data FROM track WHERE id=?", args: [resolvedLibraryID(id)])).first }
    public func tracks(albumID: String) throws -> [Track] { try displayTracks(list(Track.self, sql: "SELECT data FROM track WHERE albumID=? ORDER BY disc,number,path", args: [resolvedLibraryID(albumID)])) }
    public func artist(_ id: String) throws -> Artist? { try list(Artist.self, sql: "SELECT data FROM artist WHERE id=?", args: [id]).first }
    public func work(_ id: String) throws -> Work? { try list(Work.self, sql: "SELECT data FROM work WHERE id=?", args: [id]).first }
    public func artists(role: String? = nil, limit: Int = 100) throws -> [Artist] {
        let values = try list(Artist.self, sql: "SELECT data FROM artist WHERE EXISTS (SELECT 1 FROM credit WHERE artistID=artist.id" + (role == nil ? "" : " AND role=?") + ") ORDER BY name", args: role.map { [$0] } ?? [])
        var seen = Set<String>(), result: [Artist] = []
        for value in values {
            let id = try canonicalID(value.id, kind: "artist")
            if seen.insert(id).inserted { result.append(try artist(id) ?? value) }
            if result.count >= limit { break }
        }
        return result
    }

    public func upsert(album incoming: Album, tracks: [Track], scanID: String, groupingKey: String? = nil) throws {
        try pool.write { db in
            var album = incoming
            if let old = try String.fetchOne(db, sql: "SELECT data FROM album WHERE id=?", arguments: [album.id]) { album.favorite = try decode(Album.self, old).favorite }
            let overrides = try Row.fetchAll(db, sql: "SELECT field,value FROM assertion WHERE entityID=? AND (source='user' OR (source='musicbrainz' AND field='artwork')) ORDER BY CASE source WHEN 'user' THEN 1 ELSE 0 END", arguments: [album.id])
            for row in overrides {
                let field: String = row["field"], value: String = row["value"]
                if field == "title" { album.title = value }; if field == "artist" { album.artist = value }; if field == "artwork" { album.artwork = value }
            }
            try db.execute(sql: "INSERT INTO album(id,rootID,sectionID,title,artist,date,favorite,data) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET sectionID=excluded.sectionID,title=excluded.title,artist=excluded.artist,date=excluded.date,favorite=excluded.favorite,data=excluded.data", arguments: [album.id, album.rootID, album.sectionID, album.title, album.artist, album.date, album.favorite, try json(album)])
            if let groupingKey { try db.execute(sql: "UPDATE album SET groupingKey=? WHERE id=?", arguments: [groupingKey, album.id]) }
            for var track in tracks {
                // Confirmed external credits are assertions, independent of scanner input.
                let remoteCredits = try Row.fetchAll(db, sql: "SELECT a.data,c.role,c.source FROM artist a JOIN credit c ON c.artistID=a.id WHERE c.trackID=? AND c.source != 'local'", arguments: [track.id])
                let oldCredits = try String.fetchOne(db, sql: "SELECT data FROM track WHERE id=?", arguments: [track.id]).map { try decode(Track.self, $0).credits } ?? []
                for row in remoteCredits {
                    let artist = try decode(Artist.self, row["data"])
                    track.credits.append(oldCredits.first { $0.artistID == artist.id && $0.role == (row["role"] as String) && $0.source == (row["source"] as String) } ?? Credit(artistID: artist.id, name: artist.name, role: row["role"], source: row["source"]))
                }
                track.credits = Array(Set(track.credits)).sorted { ($0.role, $0.name) < ($1.role, $1.name) }
                try db.execute(sql: "INSERT INTO track(id,rootID,albumID,path,disc,number,format,available,scanID,data) VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET path=excluded.path,albumID=excluded.albumID,disc=excluded.disc,number=excluded.number,format=excluded.format,available=excluded.available,scanID=excluded.scanID,data=excluded.data", arguments: [track.id, track.rootID, track.albumID, track.relativePath, track.disc, track.number, track.format, track.available, scanID, try json(track)])
                try db.execute(sql: "INSERT OR IGNORE INTO recording(id,trackID) VALUES(?,?)", arguments: [track.recordingID, track.id])
                try db.execute(sql: "DELETE FROM credit WHERE trackID=? AND source='local'", arguments: [track.id])
                for credit in track.credits {
                    var artist = Artist(id: credit.artistID, name: credit.name, role: credit.role, externalID: credit.artistID.hasPrefix("mb:") ? String(credit.artistID.dropFirst(3)) : nil)
                    try db.execute(sql: "INSERT OR IGNORE INTO artist(id,name,role,data) VALUES(?,?,?,?)", arguments: [artist.id, artist.name, artist.role, try json(artist)])
                    if let saved = try String.fetchOne(db, sql: "SELECT data FROM artist WHERE id=?", arguments: [artist.id]) { artist = try decode(Artist.self, saved) }
                    try db.execute(sql: "INSERT OR IGNORE INTO credit(trackID,artistID,role,source) VALUES(?,?,?,?)", arguments: [track.id, credit.artistID, credit.role, credit.source])
                    try Self.index(db, id: artist.id, kind: "artist", title: artist.name, subtitle: ([credit.roleLabel] + artist.aliases).joined(separator: " "), role: credit.role)
                }
                if let title = track.tags["WORK"]?.first, !title.isEmpty {
                    let workID = try String.fetchOne(db, sql: "SELECT w.id FROM work w JOIN recordingWork rw ON rw.workID=w.id WHERE rw.recordingID=? AND rw.source='local' AND w.title=? LIMIT 1", arguments: [track.recordingID, title]) ?? TextKey.id(album.id, "work", title)
                    let work = Work(id: workID, title: title)
                    try db.execute(sql: "INSERT OR REPLACE INTO work(id,title,data) VALUES(?,?,?)", arguments: [work.id, title, try json(work)])
                    try db.execute(sql: "INSERT OR IGNORE INTO recordingWork(recordingID,workID,source) VALUES(?,?,'local')", arguments: [track.recordingID, work.id])
                    try Self.index(db, id: work.id, kind: "work", title: title, subtitle: album.artist, albumID: album.id, sectionID: album.sectionID)
                }
            }
            try DiscoveryMigration.tagLinks(db, albumID: album.id)
            if try String.fetchOne(db, sql: "SELECT albumID FROM externalMatch WHERE albumID=?", arguments: [album.id]) != nil { try DiscoveryMigration.rebuild(db, albumID: album.id) }
            let stored = try String.fetchAll(db, sql: "SELECT data FROM track WHERE albumID=?", arguments: [album.id]).map { try decode(Track.self, $0) }
            album.trackCount = stored.count; album.duration = stored.reduce(0) { $0 + $1.duration }
            if !overrides.contains(where: { ($0["field"] as String) == "artist" }) { album.artist = AlbumGrouping.artist(tracks: stored, fallback: album.artist) }
            try db.execute(sql: "UPDATE album SET artist=?,data=? WHERE id=?", arguments: [album.artist, try json(album), album.id])
            for track in stored {
                try Self.index(db, id: track.id, kind: "track", title: track.title, subtitle: ([album.title, album.artist, album.label] + track.credits.map(\.name)).joined(separator: " · "), albumID: album.id, sectionID: album.sectionID, format: track.format)
            }
            try Self.index(db, id: album.id, kind: "album", title: album.title, subtitle: [album.artist, album.label, album.date].joined(separator: " · "), albumID: album.id, sectionID: album.sectionID)
        }
    }

    static func index(_ db: Database, id: String, kind: String, title: String, subtitle: String, albumID: String? = nil, sectionID: String? = nil, format: String? = nil, role: String? = nil) throws {
        let normalized = TextKey.normalize(title + " " + subtitle)
        if let row = try Row.fetchOne(db, sql: "SELECT * FROM searchContent WHERE entityID=? AND kind=?", arguments: [id, kind]), (row["normalized"] as String) == normalized, (row["sectionID"] as String?) == sectionID, (row["albumID"] as String?) == albumID, (row["format"] as String?) == format, (row["role"] as String?) == role { return }
        try db.execute(sql: "INSERT INTO searchContent(entityID,kind,title,subtitle,normalized,albumID,sectionID,format,role,titleKey) VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(entityID,kind) DO UPDATE SET title=excluded.title,subtitle=excluded.subtitle,normalized=excluded.normalized,albumID=excluded.albumID,sectionID=excluded.sectionID,format=excluded.format,role=excluded.role,titleKey=excluded.titleKey", arguments: [id, kind, title, subtitle, normalized, albumID, sectionID, format, role, TextKey.normalize(title)])
        let docID = try Int64.fetchOne(db, sql: "SELECT id FROM searchContent WHERE entityID=? AND kind=?", arguments: [id, kind])!
        try db.execute(sql: "DELETE FROM searchFTS WHERE rowid=?", arguments: [docID])
        try db.execute(sql: "INSERT INTO searchFTS(rowid,title,subtitle) VALUES(?,?,?)", arguments: [docID, title, subtitle])
        try db.execute(sql: "DELETE FROM searchGram WHERE docID=?", arguments: [docID])
        for gram in TextKey.grams(title + " " + subtitle) { try db.execute(sql: "INSERT INTO searchGram(gram,docID) VALUES(?,?)", arguments: [gram, docID]) }
    }

    public func search(_ text: String, rootID: String? = nil, sectionID: String? = nil, rootIDs: [String]? = nil, sectionIDs: [String]? = nil, role: String? = nil, format: String? = nil, limit: Int = 80) throws -> [SearchHit] {
        let normalized = TextKey.normalize(text), grams = TextKey.queryGrams(text)
        guard !grams.isEmpty else { return [] }
        return try pool.read { db in
            let anchor = String(normalized.suffix(min(3, normalized.count)))
            // Narrow candidates by one indexed gram, then verify the literal substring.
            var sql = "SELECT c.* FROM searchContent c WHERE (c.id IN (SELECT rowid FROM searchFTS WHERE searchFTS MATCH ?) OR (c.id IN (SELECT docID FROM searchGram WHERE gram=?) AND instr(c.normalized,?)>0))"
            var args: [DatabaseValue] = [TextKey.fts(text).databaseValue, anchor.databaseValue, normalized.databaseValue]
            sql += " AND (c.kind<>'artist' OR EXISTS(SELECT 1 FROM credit WHERE artistID=c.entityID)) AND (c.kind<>'work' OR EXISTS(SELECT 1 FROM recordingWork WHERE workID=c.entityID))"
            for (column, ids) in [("rootID", rootID.map { [$0] } ?? rootIDs), ("sectionID", sectionID.map { [$0] } ?? sectionIDs)] {
                if let ids {
                    guard !ids.isEmpty else { return [] }
                    let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
                    sql += """
                     AND ((c.kind IN ('album','track') AND EXISTS(SELECT 1 FROM album a WHERE a.id=c.albumID AND a.\(column) IN (\(placeholders))))
                       OR (c.kind='artist' AND EXISTS(SELECT 1 FROM credit cr JOIN track t ON t.id=cr.trackID JOIN album a ON a.id=t.albumID WHERE cr.artistID=c.entityID AND a.\(column) IN (\(placeholders))))
                       OR (c.kind='work' AND EXISTS(SELECT 1 FROM recordingWork rw JOIN recording r ON r.id=rw.recordingID JOIN track t ON t.id=r.trackID JOIN album a ON a.id=t.albumID WHERE rw.workID=c.entityID AND a.\(column) IN (\(placeholders)))))
                    """
                    for _ in 0..<3 { args += ids.map(\.databaseValue) }
                }
            }
            if let format { sql += " AND c.format=?"; args.append(format.databaseValue) }
            if let role { sql += " AND (c.role=? OR EXISTS (SELECT 1 FROM credit cr WHERE cr.role=? AND (cr.trackID=c.entityID OR cr.artistID=c.entityID)))"; args += [role.databaseValue, role.databaseValue] }
            sql += " ORDER BY CASE WHEN c.titleKey=? THEN 0 WHEN c.titleKey LIKE ? ESCAPE '\\' THEN 1 ELSE 2 END,c.kind,c.title LIMIT ?"
            args += [normalized.databaseValue, (normalized + "%").databaseValue, limit.databaseValue]
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map { SearchHit(kind: $0["kind"], entityID: $0["entityID"], title: $0["title"], subtitle: $0["subtitle"], albumID: $0["albumID"]) }
        }
    }

    public func reconcile(rootID: String, scanID: String) throws {
        try pool.write { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id,data FROM track WHERE rootID=? AND scanID<>?", arguments: [rootID, scanID])
            for row in rows {
                var track = try decode(Track.self, row["data"]); track.available = false
                try db.execute(sql: "UPDATE track SET available=0,data=? WHERE id=?", arguments: [try json(track), track.id])
            }
        }
    }
    public func markSeen(trackID: String, scanID: String, remoteModified: Double? = nil) throws {
        guard var track = try rawTrack(trackID) else { return }; track.available = true
        if let remoteModified {
            track.modified = remoteModified
            if track.metadataStatus == nil { track.metadataStatus = track.format == "FLAC" ? "inherited-local" : "deferred-format" }
        }
        try pool.write { db in try db.execute(sql: "UPDATE track SET scanID=?,available=1,data=? WHERE id=?", arguments: [scanID, try json(track), trackID]) }
    }
    public func scanHistory() throws -> [ScanProgress] { try list(ScanProgress.self, sql: "SELECT data FROM scanRun ORDER BY date DESC LIMIT 20") }
    public func saveScan(rootID: String, scanID: String, progress: ScanProgress) throws {
        try pool.write { db in try db.execute(sql: "INSERT OR REPLACE INTO scanRun(id,rootID,date,data) VALUES(?,?,?,?)", arguments: [scanID, rootID, Date().timeIntervalSince1970, try json(progress)]) }
    }
    public func setFavorite(_ id: String, value: Bool) throws {
        let id = try resolvedLibraryID(id)
        guard var album = try album(id) else { return }; album.favorite = value
        try pool.write { db in try db.execute(sql: "UPDATE album SET favorite=?,data=? WHERE id=?", arguments: [value, try json(album), id]) }
    }
    public func editAlbum(_ id: String, title: String, artist: String, artwork: String? = nil) throws {
        let id = try resolvedLibraryID(id)
        guard var album = try album(id) else { return }
        album.title = title; album.artist = artist
        if let artwork { album.artwork = artwork }
        try pool.write { db in
            var fields = ["title": title, "artist": artist]; if let artwork { fields["artwork"] = artwork }
            for (field, value) in fields { try db.execute(sql: "INSERT OR REPLACE INTO assertion(entityID,field,value,source) VALUES(?,?,?,'user')", arguments: [id, field, value]) }
            try db.execute(sql: "UPDATE album SET title=?,artist=?,data=? WHERE id=?", arguments: [title, artist, try json(album), id])
            try Self.index(db, id: id, kind: "album", title: title, subtitle: [artist, album.label, album.date].joined(separator: " · "), albumID: id, sectionID: album.sectionID)
        }
    }
    public func addAlias(artistID: String, alias: String) throws {
        guard var artist = try artist(artistID), !alias.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        artist.aliases = Array(Set(artist.aliases + [alias]))
        try pool.write { db in
            try db.execute(sql: "UPDATE artist SET data=? WHERE id=?", arguments: [try json(artist), artistID])
            try Self.index(db, id: artistID, kind: "artist", title: artist.name, subtitle: ([artist.role] + artist.aliases).joined(separator: " "), role: artist.role)
        }
    }
    public func preference<T: Decodable>(_ key: String, as type: T.Type) throws -> T? {
        try pool.read { db in try String.fetchOne(db, sql: "SELECT data FROM preference WHERE key=?", arguments: [key]).map { try decode(type, $0) } }
    }
    public func setPreference<T: Encodable>(_ key: String, value: T) throws {
        let data: String
        if key == "queue", var queue = value as? QueueSnapshot {
            for i in queue.entries.indices { queue.entries[i].trackID = try resolvedLibraryID(queue.entries[i].trackID) }
            data = try json(queue)
        } else { data = try json(value) }
        try pool.write { db in try db.execute(sql: "INSERT OR REPLACE INTO preference(key,data) VALUES(?,?)", arguments: [key, data]) }
    }
    public func backup(to path: String) throws { try pool.backup(to: DatabaseQueue(path: path)) }
    public func works(trackID: String) throws -> [Work] {
        try displayWorks(list(Work.self, sql: "SELECT w.data FROM work w JOIN recordingWork rw ON rw.workID=w.id JOIN recording r ON r.id=rw.recordingID WHERE r.trackID=?", args: [resolvedLibraryID(trackID)]))
    }
    // Check on the writer: pooled readers can retain stale FTS5 segment state after bulk deletion.
    public func integrityCheck() throws -> String { try pool.write { try String.fetchOne($0, sql: "PRAGMA integrity_check") ?? "unknown" } }

    public func saveDocument<T: Encodable>(_ table: String, id: String, value: T) throws {
        guard ["evidence", "externalMatch"].contains(table) else { throw AppError.message("허용하지 않는 저장 대상") }
        if table == "evidence" { try pool.write { try $0.execute(sql: "INSERT OR REPLACE INTO evidence(id,data) VALUES(?,?)", arguments: [id, try json(value)]) } }
    }
    public func saveInsight(_ value: Insight) throws {
        var value = value; value.entityID = try resolvedLibraryID(value.entityID)
        try pool.write { db in try db.execute(sql: "INSERT OR REPLACE INTO insight(id,entityID,language,created,data) VALUES(?,?,?,?,?)", arguments: [value.id, value.entityID, value.language, value.created.timeIntervalSince1970, try json(value)]) }
    }
    public func insight(entityID: String, language: String) throws -> Insight? { try list(Insight.self, sql: "SELECT data FROM insight WHERE entityID=? AND language=? ORDER BY created DESC LIMIT 1", args: [resolvedLibraryID(entityID), language]).first }

    public func confirmedMatch(_ albumID: String) throws -> ReleaseMatch? { try list(ReleaseMatch.self, sql: "SELECT data FROM externalMatch WHERE albumID=?", args: [resolvedLibraryID(albumID)]).first }
    public func confirmMatch(albumID: String, match: ReleaseMatch, approvedOrder: Bool = false) throws {
        let albumID = try resolvedLibraryID(albumID)
        let local = try list(Track.self, sql: "SELECT data FROM track WHERE albumID=? ORDER BY disc,number,path", args: [albumID])
        let positions = Set(local.map { "\($0.disc):\($0.number)" }), remotePositions = Set(match.tracks.map { "\($0.disc):\($0.number)" })
        guard !local.isEmpty, local.count == match.tracks.count, positions.count == local.count, remotePositions.count == match.tracks.count, positions == remotePositions else { throw AppError.message("디스크와 트랙 구조가 다릅니다. 이 판을 연결하지 않았습니다.") }
        for track in local {
            let remote = match.tracks.first { $0.disc == track.disc && $0.number == track.number }!
            guard approvedOrder || TextKey.normalize(track.title) == TextKey.normalize(remote.title) else { throw AppError.message("제목이 다른 트랙이 있습니다. 트랙별 대응을 검토하세요.") }
        }
        try pool.write { db in
            try db.execute(sql: "DELETE FROM credit WHERE source='musicbrainz' AND trackID IN (SELECT id FROM track WHERE albumID=?)", arguments: [albumID])
            try db.execute(sql: "DELETE FROM recordingWork WHERE source='musicbrainz' AND recordingID IN (SELECT r.id FROM recording r JOIN track t ON t.id=r.trackID WHERE t.albumID=?)", arguments: [albumID])
            try db.execute(sql: "DELETE FROM preference WHERE key=?", arguments: ["metadata-skip:" + albumID])
            try db.execute(sql: "INSERT OR REPLACE INTO externalMatch(albumID,releaseID,data,confirmedAt) VALUES(?,?,?,?)", arguments: [albumID, match.candidate.id, try json(match), Date().timeIntervalSince1970])
            for var track in local {
                let remote = match.tracks.first { $0.disc == track.disc && $0.number == track.number }!
                track.credits = track.credits.filter { $0.source != "musicbrainz" } + remote.credits
                try db.execute(sql: "UPDATE track SET data=? WHERE id=?", arguments: [try json(track), track.id])
                try db.execute(sql: "UPDATE recording SET mbid=? WHERE trackID=?", arguments: [remote.recordingID, track.id])
                for credit in remote.credits {
                    let artist = Artist(id: credit.artistID, name: credit.name, role: credit.role, externalID: credit.artistID.hasPrefix("mb:") ? String(credit.artistID.dropFirst(3)) : nil)
                    try db.execute(sql: "INSERT OR IGNORE INTO artist(id,name,role,data) VALUES(?,?,?,?)", arguments: [artist.id, artist.name, artist.role, try json(artist)])
                    try db.execute(sql: "INSERT OR IGNORE INTO credit(trackID,artistID,role,source) VALUES(?,?,?,'musicbrainz')", arguments: [track.id, artist.id, credit.role])
                    try Self.index(db, id: artist.id, kind: "artist", title: artist.name, subtitle: credit.roleLabel, role: credit.role)
                }
                for work in remote.works {
                    if let parentID = work.parentID, let title = work.parentTitle {
                        let parent = Work(id: parentID, title: title, source: "musicbrainz")
                        try db.execute(sql: "INSERT OR IGNORE INTO work(id,title,data) VALUES(?,?,?)", arguments: [parentID, title, try json(parent)])
                    }
                    try db.execute(sql: "INSERT OR REPLACE INTO work(id,title,data) VALUES(?,?,?)", arguments: [work.id, work.title, try json(work)])
                    try db.execute(sql: "INSERT OR IGNORE INTO recordingWork(recordingID,workID,source) VALUES(?,?,'musicbrainz')", arguments: [track.recordingID, work.id])
                    try Self.index(db, id: work.id, kind: "work", title: work.title, subtitle: "MusicBrainz · 작품", albumID: albumID)
                }
                if let album = try String.fetchOne(db, sql: "SELECT data FROM album WHERE id=?", arguments: [albumID]).map({ try decode(Album.self, $0) }) {
                    try Self.index(db, id: track.id, kind: "track", title: track.title, subtitle: ([album.title, album.artist, album.label] + track.credits.map(\.name)).joined(separator: " · "), albumID: albumID, sectionID: album.sectionID, format: track.format)
                }
            }
            try DiscoveryMigration.rebuild(db, albumID: albumID)
            try NamesakeLinks.rebuild(db)
        }
    }
    public func removeMatch(albumID: String) throws {
        let albumID = try resolvedLibraryID(albumID)
        let local = try list(Track.self, sql: "SELECT data FROM track WHERE albumID=? ORDER BY disc,number,path", args: [albumID])
        guard let album = try album(albumID) else { return }
        try pool.write { db in
            try db.execute(sql: "DELETE FROM identityLink WHERE albumID=? AND source='musicbrainz'", arguments: [albumID])
            try db.execute(sql: "INSERT OR REPLACE INTO preference(key,data) VALUES(?,'true')", arguments: ["metadata-skip:" + albumID])
            try db.execute(sql: "DELETE FROM externalMatch WHERE albumID=?", arguments: [albumID])
            for var track in local {
                track.credits.removeAll { $0.source == "musicbrainz" }
                try db.execute(sql: "UPDATE track SET data=? WHERE id=?", arguments: [try json(track), track.id])
                try db.execute(sql: "DELETE FROM credit WHERE trackID=? AND source='musicbrainz'", arguments: [track.id])
                try db.execute(sql: "DELETE FROM recordingWork WHERE recordingID=? AND source='musicbrainz'", arguments: [track.recordingID])
                try db.execute(sql: "UPDATE recording SET mbid=NULL WHERE trackID=?", arguments: [track.id])
                try Self.index(db, id: track.id, kind: "track", title: track.title, subtitle: ([album.title, album.artist, album.label] + track.credits.map(\.name)).joined(separator: " · "), albumID: album.id, sectionID: album.sectionID, format: track.format)
            }
            try NamesakeLinks.rebuild(db)
        }
    }
}
