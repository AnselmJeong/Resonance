import Foundation
import GRDB

public struct RootStatistics: Identifiable, Sendable {
    public var id: String { root.id }
    public var root: LibraryRoot
    public var albums: Int
    public var songs: Int
}

public struct IndexingFailure: Identifiable, Sendable {
    public var id: String { TextKey.id(root.id, path, reason) }
    public var root: LibraryRoot
    public var path: String
    public var reason: String
    public var date: Date
}

public struct LibraryStatistics: Sendable {
    public var roots: [RootStatistics]
    public var failures: [IndexingFailure]
    public var albums: Int { roots.reduce(0) { $0 + $1.albums } }
    public var songs: Int { roots.reduce(0) { $0 + $1.songs } }

    /// RFC 4180 quoting, UTF-8 BOM for Excel, and formula-injection protection for file/tag text.
    public func failureCSV() -> Data {
        func cell(_ value: String) -> String {
            let leading = value.trimmingCharacters(in: .whitespacesAndNewlines).first
            let safe = leading.map { "=+-@".contains($0) } == true ? "'" + value : value
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let formatter = ISO8601DateFormatter()
        let rows = [["음악 폴더", "연결 경로", "실패 경로", "실패 이유", "스캔 일시 (UTC)"]] + failures.map {
            [$0.root.name, $0.root.path, $0.path, $0.reason, formatter.string(from: $0.date)]
        }
        return Data(("\u{FEFF}" + rows.map { $0.map(cell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n").utf8)
    }
}

extension LibraryDatabase {
    public func statistics() throws -> LibraryStatistics {
        try pool.read { db in
            let decoder = JSONDecoder()
            let roots = try Row.fetchAll(db, sql: """
                SELECT r.data,
                  (SELECT COUNT(*) FROM album a JOIN section s ON s.id=a.sectionID WHERE a.rootID=r.id AND s.present=1) AS albums,
                  (SELECT COUNT(*) FROM track t JOIN album a ON a.id=t.albumID JOIN section s ON s.id=a.sectionID WHERE t.rootID=r.id AND s.present=1) AS songs
                FROM root r ORDER BY r.rowid
                """).map { row in
                    RootStatistics(root: try decoder.decode(LibraryRoot.self, from: Data((row["data"] as String).utf8)), albums: row["albums"], songs: row["songs"])
                }
            var failures: [IndexingFailure] = []
            for item in roots {
                var seen = Set<String>()
                // A partial/cancelled run cannot clear failures from the last complete traversal.
                let runs = try Row.fetchAll(db, sql: "SELECT date,data FROM scanRun WHERE rootID=? ORDER BY date DESC,rowid DESC", arguments: [item.id])
                for run in runs {
                    let progress = try decoder.decode(ScanProgress.self, from: Data((run["data"] as String).utf8))
                    let issues = progress.issues ?? progress.errors.map { legacyIssue($0, root: item.root) }
                    for issue in issues {
                        let key = TextKey.id(issue.path, issue.reason)
                        if seen.insert(key).inserted {
                            failures.append(IndexingFailure(root: item.root, path: issue.path, reason: issue.reason, date: Date(timeIntervalSince1970: run["date"])))
                        }
                    }
                    if progress.finished { break }
                }
            }
            return LibraryStatistics(roots: roots, failures: failures.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending })
        }
    }
}

private func legacyIssue(_ message: String, root: LibraryRoot) -> ScanIssue {
    if message.hasPrefix("미지원 형식: ") {
        return ScanIssue(path: URL(fileURLWithPath: root.path).appendingPathComponent(String(message.dropFirst("미지원 형식: ".count))).path, reason: "미지원 형식")
    }
    if let separator = message.range(of: ": "), !message.hasPrefix("읽기 실패: ") {
        let path = String(message[..<separator.lowerBound])
        return ScanIssue(path: URL(fileURLWithPath: root.path).appendingPathComponent(path).path, reason: String(message[separator.upperBound...]))
    }
    return ScanIssue(path: root.path, reason: message + " (이전 기록: 정확한 경로는 재스캔 후 확인)")
}
