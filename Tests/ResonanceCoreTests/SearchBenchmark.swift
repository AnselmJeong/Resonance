import Testing
import AVFoundation
import GRDB
@testable import ResonanceCore

@Suite struct SearchBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RESONANCE_BENCHMARK"] == "1"))
    func hundredThousandDocuments() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ResonanceBenchmark-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try LibraryDatabase(path: directory.appendingPathComponent("benchmark.sqlite").path)
        let fixture = try DatabaseQueue(path: db.path)
        let names = ["Mémoire", "Impromptu", "Debussy", "드뷔시 전주곡", "バッハ 無伴奏", "Jazz Quartet", "Piano Sonata", "ECM Session", "Boulanger", "Beethoven Symphony"]
        let start = Date()
        try await fixture.write { sql in
            let content = try sql.makeStatement(sql: "INSERT INTO searchContent(id,entityID,kind,title,subtitle,normalized,titleKey) VALUES(?,?,'track',?,'Synthetic music document',?,?)")
            let fts = try sql.makeStatement(sql: "INSERT INTO searchFTS(rowid,title,subtitle) VALUES(?,?,'Synthetic music document')")
            let gramStatement = try sql.makeStatement(sql: "INSERT INTO searchGram(gram,docID) VALUES(?,?)")
            for i in 1...100_000 {
                let title = "\(names[i % names.count]) \(i)", normalized = TextKey.normalize(title)
                try content.execute(arguments: [i, String(i), title, normalized, normalized])
                try fts.execute(arguments: [i, title])
                for gram in TextKey.grams(title) { try gramStatement.execute(arguments: [gram, i]) }
            }
        }
        print("BENCHMARK: built 100000 synthetic music search documents in \(Date().timeIntervalSince(start))s")
        let queries = ["Memoire", "Impromptu", "드뷔시", "バッハ", "伴奏", "Piano 123", "Beethoven", "구노", "\\\" NEAR *", "Memoire 10000"]
        var measurements: [Double] = []
        for _ in 0..<3 { for query in queries { _ = try await db.search(query) } }
        for _ in 0..<10 {
            for query in queries { let begin = Date(); _ = try await db.search(query); measurements.append(Date().timeIntervalSince(begin) * 1000) }
        }
        let sorted = measurements.sorted(), p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        print("BENCHMARK: warm search p95=\(String(format: "%.2f", p95))ms; max=\(String(format: "%.2f", sorted.last!))ms; 100 mixed queries, limit80; metadata index only, not external-volume I/O")
        #expect(p95 <= 250)
    }
}
