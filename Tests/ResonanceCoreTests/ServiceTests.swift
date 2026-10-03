import Testing
import AVFoundation
@testable import ResonanceCore

private final class FixtureProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data, [String: String]))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body, headers) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private actor FixtureProvider: LLMProvider {
    var calls = 0
    let payload: InsightPayload
    init(_ payload: InsightPayload) { self.payload = payload }
    func summarize(prompt: String, settings: InfoSettings, key: String) async throws -> (InsightPayload, Int, Int) { calls += 1; try await Task.sleep(nanoseconds: 30_000_000); return (payload, 100, 20) }
}

@Suite(.serialized) struct ServiceTests {
    private func http() -> HTTPClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
        return HTTPClient(session: URLSession(configuration: config))
    }
    private func data(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    @Test func statusErrorsDoNotRetryCredentials() async throws {
        for status in [401, 402, 403] {
            var calls = 0
            FixtureProtocol.handler = { _ in calls += 1; return (status, Data("secret-server-body".utf8), [:]) }
            do { _ = try await http().send(URLRequest(url: URL(string: "https://example.com")!)); Issue.record("Credential error accepted") }
            catch { #expect(error.localizedDescription.contains("HTTP \(status)")); #expect(!error.localizedDescription.contains("secret-server-body")) }
            #expect(calls == 1)
        }
    }
    @Test func transientFailureIsBoundedAndRetried() async throws {
        var calls = 0
        FixtureProtocol.handler = { _ in calls += 1; return calls == 1 ? (429, Data(), ["Retry-After": "1"]) : (200, Data("ok".utf8), [:]) }
        let result = try await http().send(URLRequest(url: URL(string: "https://example.com")!), retries: 1)
        #expect(result == Data("ok".utf8)); #expect(calls == 2)
    }
    @Test func tinyFishReadsBodiesAndHandlesPartialFailure() async throws {
        let searchResponse = try data(["results": [["title": "Official album", "url": "https://label.example/album", "snippet": "Not sufficient evidence"], ["title": "Private", "url": "http://127.0.0.1/secret"]]])
        let fetchResponse = try data(["results": [["url": "https://label.example/album", "final_url": "https://label.example/album", "title": "Album", "text": String(repeating: "Verified public source content. ", count: 8)]], "errors": [["url": "https://artist.example/album", "error": "bot_blocked"]]])
        FixtureProtocol.handler = { request in
            #expect(request.value(forHTTPHeaderField: "X-API-Key") == "fixture-key")
            #expect(request.url?.query?.contains("fixture-key") != true)
            return (200, request.httpMethod == "POST" ? fetchResponse : searchResponse, [:])
        }
        let client = TinyFishClient(search: http(), fetch: http()), sources = try await client.search(query: "Mémoire Tharaud", key: "fixture-key")
        #expect(sources.count == 1)
        let evidence = try await client.fetch(sources: sources + [SourceCandidate(title: "Artist", url: "https://artist.example/album")], key: "fixture-key")
        #expect(evidence.count == 1); #expect(evidence[0].text.count > 100)
        FixtureProtocol.handler = { _ in (200, Data("{\"results\":[],\"errors\":[{}]}".utf8), [:]) }
        do { _ = try await client.fetch(sources: sources, key: "fixture-key"); Issue.record("Empty fetch accepted") } catch {}
        FixtureProtocol.handler = { _ in (200, Data("not-json".utf8), [:]) }
        do { _ = try await client.search(query: "query", key: "fixture-key"); Issue.record("Malformed response accepted") } catch {}
    }
    @Test func matchingDistinguishesDifferentEditionBarcode() async throws {
        let response = try data(["releases": [["id": UUID().uuidString, "title": "Mémoire", "barcode": "1200214263720", "date": "2026-09-25", "artist-credit": [["name": "Alexandre Tharaud"]], "media": [["track-count": 27]]]]])
        FixtureProtocol.handler = { request in #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("Resonance") == true); return (200, response, [:]) }
        let client = MusicBrainzClient(http: http())
        let album = Album(id: "a", rootID: "r", sectionID: "s", folder: "/", title: "Mémoire", artist: "Alexandre Tharaud", barcode: "1200214264086", trackCount: 27)
        let candidates = try await client.search(album: album)
        #expect(candidates.count == 1); #expect(candidates[0].reasons.contains("⚠ UPC가 다른 판")); #expect(candidates[0].score < 60)
    }
    @Test func insightCacheHitHasNoNewRequestOrCost() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: dir) }
        let db = try LibraryDatabase(path: dir.appendingPathComponent("test.sqlite").path)
        let source = Evidence(title: "Official", url: "https://example.com", text: "This recording features a solo piano performance.")
        let payload = InsightPayload(sections: [.init(title: "녹음", text: "피아노 녹음", source_ids: [source.id])], claims: [.init(text: "피아노", source_id: source.id, quote: "a solo piano performance")], uncertainties: [])
        let provider = FixtureProvider(payload), service = InsightService(database: db, provider: provider)
        var defaults = InfoSettings(); defaults.enabled = true
        #expect(defaults.usesOllamaAPI); #expect(defaults.chatURL?.absoluteString == "https://ollama.com/api/chat"); #expect(!defaults.model.isEmpty)
        var settings = defaults; settings.endpoint = "http://localhost:11434/api/chat"; settings.model = "fixture"
        #expect(settings.isLocalEndpoint); try InsightService.preflight(settings: settings, key: "")
        var cloud = settings; cloud.provider = "compatible"; cloud.endpoint = "https://ollama.com/v1"
        #expect(!cloud.isLocalEndpoint); #expect(cloud.usesOllamaAPI); #expect(cloud.chatURL?.absoluteString == "https://ollama.com/api/chat")
        #expect(throws: (any Error).self) { try InsightService.preflight(settings: cloud, key: "") }
        try InsightService.preflight(settings: cloud, key: "api-key")
        cloud.endpoint = "https://api.example.com/v1"; #expect(!cloud.usesOllamaAPI); #expect(cloud.chatURL?.absoluteString == "https://api.example.com/v1/chat/completions")
        #expect(settings.chatURL?.absoluteString == "http://localhost:11434/api/chat")
        let first = try await service.generate(entityID: "target", kind: "album", context: "Piano", evidence: [source], settings: settings, key: "")
        let second = try await service.generate(entityID: "target", kind: "album", context: "Piano", evidence: [source], settings: settings, key: "")
        #expect(first.id == second.id); let calls = await provider.calls; #expect(calls == 1)
        settings.endpoint = "https://cloud.example/v1/chat/completions"
        do { _ = try await service.generate(entityID: "new", kind: "album", context: "Piano", evidence: [source], settings: settings, key: ""); Issue.record("Keyless remote request accepted") } catch {}
        let unchanged = await provider.calls; #expect(unchanged == 1)
    }
    @Test func storyPipelineReadsOnlyUsefulSourcesWithoutPicking() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: dir) }
        let db = try LibraryDatabase(path: dir.appendingPathComponent("test.sqlite").path)
        let page = "https://label.example/mem", text = String(repeating: "Mémoire is a solo piano album by Alexandre Tharaud. ", count: 4)
        let source = Evidence(title: "Mémoire", url: page, text: text)
        let payload = InsightPayload(sections: [.init(title: "개요", text: "피아노 독주 앨범", source_ids: [source.id])], claims: [.init(text: "독주", source_id: source.id, quote: "a solo piano album")], uncertainties: [])
        let searchResponse = try data(["results": [["title": "Mémoire Tharaud", "url": "https://www.youtube.com/watch?v=1", "snippet": "Alexandre Tharaud"], ["title": "Mémoire — Alexandre Tharaud", "url": page, "snippet": "Erato"]]])
        let fetchResponse = try data(["results": [["url": page, "final_url": page, "title": "Mémoire", "text": text]]])
        var fetched: [String] = []
        FixtureProtocol.handler = { request in
            if request.httpMethod == "POST", let body = request.httpBodyStream.map({ stream -> Data in stream.open(); defer { stream.close() }; var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096); while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }; return data }) ?? request.httpBody, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] { fetched += json["urls"] as? [String] ?? [] }
            return (200, request.httpMethod == "POST" ? fetchResponse : searchResponse, [:])
        }
        let provider = FixtureProvider(payload)
        let pipeline = StoryPipeline(tinyFish: TinyFishClient(search: http(), fetch: http()), insights: InsightService(database: db, provider: provider))
        var settings = InfoSettings(); settings.enabled = true; settings.endpoint = "http://localhost:11434/api/chat"; settings.model = "fixture"
        let request = StoryRequest(entityID: "album", kind: "album", title: "Mémoire", context: "Album: Mémoire", queries: ["Mémoire Tharaud album"], required: [["Mémoire"], ["Alexandre Tharaud"]])
        let insight = try await pipeline.run(request, settings: settings, searchKey: "fixture-key", llmKey: "")
        #expect(fetched == [page]); #expect(insight.evidence.map(\.url) == [page])
        var off = settings; off.model = ""
        do { _ = try await pipeline.run(request, settings: off, searchKey: "fixture-key", llmKey: ""); Issue.record("Unconfigured model searched") } catch {}
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RESONANCE_LLM_SMOKE"] == "1"))
    func actualLocalProviderSmoke() async throws {
        var settings = InfoSettings(); settings.endpoint = "http://localhost:11434/api/chat"; settings.model = ProcessInfo.processInfo.environment["RESONANCE_LLM_MODEL"] ?? ""
        let source = Evidence(title: "Synthetic test source", url: "https://example.com/fixture", text: "This is a synthetic music test. The album title is Fixture Piano. The performer is Test Artist. The recording features solo piano. Its recording venue and date are not provided.")
        let prompt = "Write a short Korean JSON music note with sections, claims and uncertainties. Source ID: \(source.id). Source text: \(source.text)"
        let (payload, input, output) = try await ChatLLMProvider().summarize(prompt: prompt, settings: settings, key: "")
        try payload.validate(evidence: [source]); #expect(input > 0); #expect(output > 0)
        print("LOCAL LLM SMOKE: structured cited response validated; \(input) input / \(output) output tokens; synthetic evidence only")
    }
}
