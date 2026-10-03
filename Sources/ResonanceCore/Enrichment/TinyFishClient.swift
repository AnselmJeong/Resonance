import Foundation

public actor TinyFishClient {
    private let searchHTTP: HTTPClient
    private let fetchHTTP: HTTPClient
    public init(search: HTTPClient = HTTPClient(interval: 2.1), fetch: HTTPClient = HTTPClient(interval: 0.5)) { searchHTTP = search; fetchHTTP = fetch }
    public func search(query: String, key: String) async throws -> [SourceCandidate] {
        guard !key.isEmpty else { throw AppError.message("설정에서 TinyFish API 키를 저장하세요.") }
        var url = URLComponents(string: "https://api.search.tinyfish.ai")!
        url.queryItems = [.init(name: "query", value: query), .init(name: "language", value: "en"), .init(name: "purpose", value: "Find official album, artist and composition information for a private music player.")]
        var req = URLRequest(url: url.url!); req.timeoutInterval = 40; req.setValue(key, forHTTPHeaderField: "X-API-Key")
        struct Response: Decodable { var results: [SourceCandidate] }
        let response = try JSONDecoder().decode(Response.self, from: await searchHTTP.send(req))
        return response.results.filter { PublicWebURL.validate($0.url) != nil }
    }
    public func fetch(sources: [SourceCandidate], key: String) async throws -> [Evidence] {
        guard !key.isEmpty else { throw AppError.message("설정에서 TinyFish API 키를 저장하세요.") }
        let selected = Array(sources.prefix(3)).filter { PublicWebURL.validate($0.url) != nil }
        guard !selected.isEmpty else { throw AppError.message("읽을 공개 출처를 선택하세요.") }
        var req = URLRequest(url: URL(string: "https://api.fetch.tinyfish.ai/")!); req.httpMethod = "POST"; req.timeoutInterval = 75
        req.setValue(key, forHTTPHeaderField: "X-API-Key"); req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["urls": selected.map(\.url), "format": "markdown", "purpose": "Read verifiable music facts for a cited summary", "per_url_timeout_ms": 45000])
        struct Result: Decodable { var url: String; var final_url: String?; var title: String?; var text: String }
        struct Response: Decodable { var results: [Result] }
        let response = try JSONDecoder().decode(Response.self, from: await fetchHTTP.send(req))
        let evidence = response.results.compactMap { result -> Evidence? in
            guard selected.contains(where: { $0.url == result.url }), PublicWebURL.validate(result.final_url ?? result.url) != nil, result.text.count > 100 else { return nil }
            return Evidence(title: result.title ?? selected.first { $0.url == result.url }!.title, url: result.final_url ?? result.url, text: String(result.text.prefix(6500)))
        }
        guard !evidence.isEmpty else { throw AppError.message("출처 본문을 확보하지 못했습니다. 검색 요약만으로 설명을 만들지 않습니다.") }
        return evidence
    }
}
