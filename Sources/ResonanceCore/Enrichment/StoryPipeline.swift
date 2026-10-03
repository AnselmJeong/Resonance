import Foundation

/// What a story is about, plus the names a useful source must mention.
public struct StoryRequest: Sendable, Hashable {
    public var entityID: String
    public var kind: String
    public var title: String
    public var context: String
    public var queries: [String]
    /// Every group must match at least one of its names (album title, performer, …).
    public var required: [[String]]
    /// Names that raise a source's rank when present.
    public var related: [String]
    public init(entityID: String, kind: String, title: String, context: String, queries: [String], required: [[String]], related: [String] = []) {
        self.entityID = entityID; self.kind = kind; self.title = title; self.context = context
        self.queries = queries.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }.filter { !$0.isEmpty }
        self.required = required.map { $0.filter { !TextKey.normalize($0).isEmpty } }.filter { !$0.isEmpty }
        self.related = related.filter { !TextKey.normalize($0).isEmpty }
    }
}

/// Picks readable, citable pages and drops social, video and storefront pages.
public enum SourcePolicy {
    static let blockedHosts = ["youtu.be", "x.com", "music.apple.com", "itunes.apple.com", "podcasts.apple.com", "open.spotify.com", "muso.ai", "fb.watch", "threads.net"]
    static let blockedLabels: Set<String> = ["youtube", "instagram", "facebook", "tiktok", "twitter", "pinterest", "linkedin", "reddit", "tumblr", "spotify", "deezer", "tidal", "soundcloud", "shazam", "amazon", "ebay", "vk", "weibo", "douyin", "bilibili", "snapchat"]
    static let preferred: [String: Int] = [
        "wikipedia.org": 30, "britannica.com": 25, "culture.pl": 25, "imslp.org": 15,
        "gramophone.co.uk": 25, "allmusic.com": 25, "bachtrack.com": 20, "prestomusic.com": 20, "classicfm.com": 15, "musicweb-international.com": 20,
        "theguardian.com": 20, "nytimes.com": 20, "npr.org": 20, "bbc.co.uk": 20, "pitchfork.com": 20, "theartsdesk.com": 15, "jazztimes.com": 20, "downbeat.com": 20,
        "deutschegrammophon.com": 25, "warnerclassics.com": 25, "deccaclassics.com": 25, "decca.com": 20, "sonyclassical.com": 25, "harmoniamundi.com": 25,
        "hyperion-records.co.uk": 25, "chandos.net": 25, "bis.se": 25, "naxos.com": 25, "ecmrecords.com": 25, "pentatonemusic.com": 25, "alpha-classics.com": 25,
        "outhere-music.com": 20, "nonesuch.com": 25, "bluenote.com": 20, "linnrecords.com": 20, "ondine.net": 20,
        "qobuz.com": 10, "bandcamp.com": 10, "discogs.com": 10, "musicbrainz.org": 5, "last.fm": -5, "genius.com": -5,
    ]
    public static func isBlocked(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host?.lowercased() else { return true }
        if blockedHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
        return host.split(separator: ".").dropLast().contains { blockedLabels.contains(String($0)) }
    }
    static func matches(_ name: String, in haystack: String) -> Bool {
        let phrase = TextKey.normalize(name)
        guard !phrase.isEmpty else { return false }
        if " \(haystack) ".contains(" \(phrase) ") { return true }
        let words = Set<Substring>(haystack.split(separator: " "))
        let tokens: [Substring] = phrase.split(separator: " ").filter { $0.count >= 3 || $0.allSatisfy(\.isNumber) }
        guard tokens.count >= 2 else { return false }
        return Double(tokens.filter { words.contains($0) }.count) / Double(tokens.count) >= 0.6
    }
    static func domainScore(_ host: String) -> Int {
        preferred.first { host == $0.key || host.hasSuffix("." + $0.key) }?.value ?? 0
    }
    /// Relevant, non-blocked candidates, best first.
    public static func rank(_ candidates: [SourceCandidate], for request: StoryRequest) -> [SourceCandidate] {
        var seen = Set<String>()
        let scored = candidates.enumerated().compactMap { index, source -> (SourceCandidate, Int)? in
            guard seen.insert(source.id).inserted, PublicWebURL.validate(source.url) != nil, !isBlocked(source.url), let url = URL(string: source.url), let host = url.host?.lowercased() else { return nil }
            let haystack = TextKey.normalize([source.title, source.snippet ?? "", host.replacingOccurrences(of: ".", with: " "), url.path.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")].joined(separator: " "))
            guard request.required.allSatisfy({ group in group.contains { matches($0, in: haystack) } }) else { return nil }
            var score = domainScore(host) + 10 * request.related.filter { matches($0, in: haystack) }.count - index
            // A subject's own site (e.g. aleksanderdebicz.com) usually carries the best biography.
            let compactHost = TextKey.normalize(host).replacingOccurrences(of: " ", with: "")
            if request.required.flatMap({ $0 }).flatMap({ TextKey.normalize($0).split(separator: " ") }).contains(where: { $0.count >= 5 && compactHost.contains($0) }) { score += 20 }
            return (source, score)
        }
        return scored.sorted { $0.1 > $1.1 }.map(\.0)
    }
    /// Up to `count` sources, preferring one page per site.
    public static func pick(_ ranked: [SourceCandidate], count: Int = 3) -> [SourceCandidate] {
        var hosts = Set<String>(), first: [SourceCandidate] = [], rest: [SourceCandidate] = []
        for source in ranked { if hosts.insert(URL(string: source.url)?.host?.lowercased() ?? source.url).inserted { first.append(source) } else { rest.append(source) } }
        return Array((first + rest).prefix(count))
    }
}

public enum StoryStep: Sendable, Equatable {
    case searching, reading, writing
}

/// Search → read the best pages → write a cited story, without asking the listener to pick sources.
public struct StoryPipeline: Sendable {
    let tinyFish: TinyFishClient
    let insights: InsightService
    public init(tinyFish: TinyFishClient, insights: InsightService) { self.tinyFish = tinyFish; self.insights = insights }
    public func run(_ request: StoryRequest, settings: InfoSettings, searchKey: String, llmKey: String, regenerate: Bool = false, progress: @Sendable (StoryStep) async -> Void = { _ in }) async throws -> Insight {
        try InsightService.preflight(settings: settings, key: llmKey)
        guard !searchKey.isEmpty else { throw AppError.message("설정에서 TinyFish API 키를 저장하세요.") }
        await progress(.searching)
        var found: [SourceCandidate] = [], ranked: [SourceCandidate] = []
        for query in request.queries {
            try Task.checkCancellation()
            found += try await tinyFish.search(query: query, key: searchKey)
            ranked = SourcePolicy.rank(found, for: request)
            if ranked.count >= 3 { break }
        }
        guard !ranked.isEmpty else { throw AppError.message("믿을 만한 출처를 찾지 못했습니다. 소셜·동영상·스트리밍 페이지는 제외합니다.") }
        await progress(.reading)
        var evidence: [Evidence] = [], remaining = ranked
        // At most two reads: the best three pages, then a top-up if most of them failed.
        for _ in 0..<2 where evidence.count < 2 && !remaining.isEmpty {
            try Task.checkCancellation()
            let batch = SourcePolicy.pick(remaining, count: 3 - evidence.count)
            remaining.removeAll { source in batch.contains { $0.id == source.id } }
            if let read = try? await tinyFish.fetch(sources: batch, key: searchKey) { evidence += read }
        }
        guard !evidence.isEmpty else { throw AppError.message("출처 원문을 읽지 못했습니다. 잠시 후 다시 시도하세요.") }
        await progress(.writing)
        return try await insights.generate(entityID: request.entityID, kind: request.kind, context: request.context, evidence: evidence, settings: settings, key: llmKey, regenerate: regenerate)
    }
}
