import Foundation

public struct SourceCandidate: Codable, Identifiable, Hashable, Sendable {
    public var id: String { TextKey.hash(url) }
    public var title: String
    public var url: String
    public var snippet: String?
    public init(title: String, url: String, snippet: String? = nil) { self.title = title; self.url = url; self.snippet = snippet }
}
public struct Evidence: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var url: String
    public var text: String
    public var fetched: Date
    public var hash: String
    public init(title: String, url: String, text: String, fetched: Date = Date()) { self.id = TextKey.hash(url + text); self.title = title; self.url = url; self.text = text; self.fetched = fetched; self.hash = TextKey.hash(text) }
}
public struct InsightSection: Codable, Hashable, Sendable {
    public var title: String
    public var text: String
    public var source_ids: [String]
    public init(title: String, text: String, source_ids: [String]) { self.title = title; self.text = text; self.source_ids = source_ids }
}
public struct InsightClaim: Codable, Hashable, Sendable {
    public var text: String
    public var source_id: String
    public var quote: String
    public init(text: String, source_id: String, quote: String) { self.text = text; self.source_id = source_id; self.quote = quote }
}
public struct InsightPayload: Codable, Sendable {
    public var sections: [InsightSection]
    public var claims: [InsightClaim]
    public var uncertainties: [String]
    public init(sections: [InsightSection], claims: [InsightClaim], uncertainties: [String]) { self.sections = sections; self.claims = claims; self.uncertainties = uncertainties }
    public func validate(evidence: [Evidence]) throws {
        let sources = Dictionary(uniqueKeysWithValues: evidence.map { ($0.id, $0) })
        guard !sections.isEmpty, sections.count <= 6, !claims.isEmpty, claims.count <= 30 else { throw AppError.message("설명 응답의 구조가 올바르지 않습니다.") }
        for section in sections {
            guard !section.text.isEmpty, section.text.count <= 3000, !section.source_ids.isEmpty, section.source_ids.allSatisfy({ sources[$0] != nil }) else { throw AppError.message("확보한 출처에 연결되지 않은 설명을 거절했습니다.") }
        }
        guard claims.contains(where: { Self.supports($0, sources) }) else { throw AppError.message("원문 근거를 확인할 수 없는 주장입니다. 설명을 저장하지 않았습니다.") }
    }
    /// The payload keeping only claims whose quote is found in its source; one stray quote no longer sinks a well-grounded story.
    public func verified(evidence: [Evidence]) throws -> InsightPayload {
        try validate(evidence: evidence)
        let sources = Dictionary(uniqueKeysWithValues: evidence.map { ($0.id, $0) })
        return InsightPayload(sections: sections, claims: claims.filter { Self.supports($0, sources) }, uncertainties: uncertainties)
    }
    /// Verbatim up to typography: case, accents, curly quotes, dashes and line breaks may differ, and "…" may join exact fragments in order.
    static func supports(_ claim: InsightClaim, _ sources: [String: Evidence]) -> Bool {
        guard let source = sources[claim.source_id], claim.quote.count >= 8, claim.quote.count <= 500 else { return false }
        let text = quoteKey(source.text)
        let parts = quoteKey(claim.quote).components(separatedBy: "...").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard parts.joined().count >= 8 else { return false }
        var rest = text[...]
        for part in parts { guard let found = rest.range(of: part) else { return false }; rest = rest[found.upperBound...] }
        return true
    }
    static func quoteKey(_ text: String) -> String {
        var folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        for (from, to) in [("\u{2018}", "'"), ("\u{2019}", "'"), ("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{00AB}", "\""), ("\u{00BB}", "\""), ("\u{201E}", "\""), ("\u{2013}", "-"), ("\u{2014}", "-"), ("\u{2011}", "-"), ("\u{2026}", "..."), ("\u{00AD}", "")] { folded = folded.replacingOccurrences(of: from, with: to) }
        return folded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
public struct Insight: Codable, Identifiable, Sendable {
    public static let currentVersion = "prompt3-schema1"
    public var id: String
    public var entityID: String
    public var kind: String
    public var language: String
    public var payload: InsightPayload
    public var evidence: [Evidence]
    public var created: Date
    public var model: String
    public var version: String
    public var provider: String?
    public var contextHash: String?
    public init(entityID: String, kind: String, language: String, payload: InsightPayload, evidence: [Evidence], model: String, provider: String = "", context: String = "") {
        self.entityID = entityID; self.kind = kind; self.language = language; self.payload = payload; self.evidence = evidence; self.model = model; self.version = Self.currentVersion; self.provider = provider; self.contextHash = TextKey.hash(context)
        self.id = TextKey.id(kind, entityID, language, evidence.map(\.hash).sorted().joined(), model, provider, contextHash!, version); self.created = Date()
    }
}
public struct InfoSettings: Codable, Sendable {
    public var enabled = false
    public var language = "ko"
    public var provider = "ollama"
    // Ollama Cloud with a model that can turn thinking off and keeps quotes verbatim.
    public var endpoint = "https://ollama.com/api/chat"
    public var model = "deepseek-v4.1-flash"
    public var cacheMegabytes = 2048
    /// A model server on this Mac (Ollama, LM Studio…) needs no API key; it handles any cloud sign-in itself.
    public var isLocalEndpoint: Bool { ["localhost", "127.0.0.1", "::1"].contains(URL(string: endpoint)?.host ?? "") }
    /// Ollama Cloud also speaks the native Ollama API, which can turn off thinking and enforce the JSON schema.
    public var isOllamaCloud: Bool { ["ollama.com", "www.ollama.com"].contains(URL(string: endpoint)?.host?.lowercased() ?? "") }
    public var usesOllamaAPI: Bool { provider == "ollama" || isOllamaCloud }
    /// The chat endpoint actually called; a bare `/v1` (OpenAI style) or empty Ollama path is completed.
    public var chatURL: URL? {
        guard let url = SafeLink.url(endpoint.trimmingCharacters(in: .whitespacesAndNewlines)), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = parts.path.hasSuffix("/") ? String(parts.path.dropLast()) : parts.path
        if isOllamaCloud { parts.path = "/api/chat" }
        else if provider == "ollama" { parts.path = path.isEmpty ? "/api/chat" : path }
        else { parts.path = path.hasSuffix("/v1") || path.hasSuffix("/api") ? path + "/chat/completions" : path }
        return parts.url
    }
    public init() {}
}
public struct ReleaseCandidate: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var artist: String
    public var date: String
    public var barcode: String
    public var trackCount: Int
    public var score: Int
    public var reasons: [String]
    public var country: String
    public var disambiguation: String
}
public struct MatchedTrack: Codable, Sendable {
    public var disc: Int
    public var number: Int
    public var title: String
    public var recordingID: String
    public var credits: [Credit]
    public var works: [Work]
    public var duration: Double? = nil
    public var recordingDate: String? = nil
}
public struct ReleaseMatch: Codable, Sendable {
    public var candidate: ReleaseCandidate
    public var tracks: [MatchedTrack]
}
