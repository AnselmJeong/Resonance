import Foundation

public struct ScanSummary: Sendable {
    public var discovered = 0
    public var processed = 0
    public var reused = 0
    public var completedRoots = 0
    public var errors: [String] = []
    public var cancelled = false
    public init() {}
    public mutating func include(_ progress: ScanProgress, root: LibraryRoot) {
        discovered += progress.discovered
        processed += progress.processed
        reused += progress.reused
        if progress.finished { completedRoots += 1 }
        cancelled = cancelled || progress.cancelled
        errors += progress.errors.map { root.path + ": " + $0 }
    }
    public var title: String {
        if cancelled { return "스캔을 중지했습니다" }
        if !errors.isEmpty { return completedRoots == 0 ? "스캔을 완료하지 못했습니다" : "스캔 완료 · 확인이 필요합니다" }
        return "스캔이 완료되었습니다"
    }
    public var detail: String {
        "\(completedRoots)개 폴더 완료 · \(processed.formatted())곡 처리" + (errors.isEmpty ? "" : " · \(errors.count)건 확인 필요 · 설정의 통계에서 확인하세요")
    }
}

public struct ScanIssue: Codable, Hashable, Sendable {
    public var path: String
    public var reason: String
    public init(path: String, reason: String) { self.path = path; self.reason = reason }
}
