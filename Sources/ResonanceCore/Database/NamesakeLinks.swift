import Foundation
import GRDB

/// Musicians with the same name are one person unless MusicBrainz names two different people or the listener split them.
/// The edges are derived data: rebuilt as a whole after scans and matches, never edited by hand.
enum NamesakeLinks {
    static let splitKey = "identity-name-split"
    static let generic: Set<String> = ["various artists", "various", "va", "verschiedene interpreten", "anonymous", "anon", "traditional", "trad", "unknown", "unknown artist"]

    static func rebuild(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM identityLink WHERE kind='artist' AND source='name'")
        let split = Set(try String.fetchOne(db, sql: "SELECT data FROM preference WHERE key=?", arguments: [splitKey]).map { try JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? [])
        let artists = try Row.fetchAll(db, sql: "SELECT id, name FROM artist").map { (id: $0["id"] as String, name: TextKey.normalize($0["name"])) }
        let links = try Row.fetchAll(db, sql: "SELECT localID, canonicalID FROM identityLink WHERE kind='artist'").map { ($0["localID"] as String, $0["canonicalID"] as String) }
        // Union-find over the links that already exist, so one name group never joins two MusicBrainz people.
        var parent: [String: String] = [:], people: [String: Set<String>] = [:]
        for id in artists.map(\.id) + links.flatMap({ [$0.0, $0.1] }) where id.hasPrefix("mb:") { people[id] = [id] }
        func find(_ id: String) -> String {
            var root = id
            while let next = parent[root] { root = next }
            var node = id
            while let next = parent[node], next != root { parent[node] = root; node = next }
            return root
        }
        func union(_ a: String, _ b: String) {
            let ra = find(a), rb = find(b)
            guard ra != rb else { return }
            parent[ra] = rb; people[rb, default: []].formUnion(people.removeValue(forKey: ra) ?? [])
        }
        for (a, b) in links { union(a, b) }
        let groups = Dictionary(grouping: artists, by: \.name)
        for name in groups.keys.sorted() where !name.isEmpty && !generic.contains(name) && !split.contains(name) {
            let ids = groups[name]!.map(\.id).sorted()
            guard ids.count > 1, Set(ids.flatMap { people[find($0)] ?? [] }).count <= 1 else { continue }
            let anchor = ids.first { $0.hasPrefix("mb:") } ?? ids[0]
            for id in ids where find(id) != find(anchor) {
                try db.execute(sql: "INSERT OR IGNORE INTO identityLink(kind,localID,canonicalID,source,albumID) VALUES('artist',?,?,'name','')", arguments: [id, anchor])
                union(id, anchor)
            }
        }
    }
}

extension LibraryDatabase {
    public func linkNamesakes() throws { try pool.write { db in try NamesakeLinks.rebuild(db) } }
}
