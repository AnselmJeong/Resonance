import Foundation

public actor HTTPClient {
    private let session: URLSession
    private var nextRequest = Date.distantPast
    private let interval: Double
    public init(interval: Double = 0, session: URLSession = .shared) { self.interval = interval; self.session = session }
    public func send(_ request: URLRequest, retries: Int = 2) async throws -> Data {
        for attempt in 0...retries {
            try Task.checkCancellation()
            let delay = max(0, nextRequest.timeIntervalSinceNow)
            nextRequest = Date().addingTimeInterval(delay + interval)
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AppError.message("올바르지 않은 서버 응답") }
            if [429, 503].contains(http.statusCode), attempt < retries {
                let retry = min(15, max(1, Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? pow(2, Double(attempt + 1))))
                try await Task.sleep(nanoseconds: UInt64((retry + Double.random(in: 0...0.3)) * 1_000_000_000)); continue
            }
            guard (200..<300).contains(http.statusCode) else {
                let reason = [401: "API 키를 확인하세요.", 402: "계정 접근 권한 또는 결제 설정을 확인하세요.", 403: "접근이 허용되지 않습니다.", 429: "요청 한도를 초과했습니다.", 503: "서비스를 잠시 사용할 수 없습니다."][http.statusCode] ?? "요청에 실패했습니다."
                throw AppError.message("HTTP \(http.statusCode) · \(reason)")
            }
            guard data.count <= 8 * 1024 * 1024 else { throw AppError.message("서버 응답 크기 상한 초과") }
            return data
        }
        throw AppError.message("요청 재시도 실패")
    }
}

public enum PublicWebURL {
    public static func validate(_ value: String) -> URL? {
        guard let url = SafeLink.url(value), let host = url.host?.lowercased(), !host.hasSuffix(".local"), !host.hasSuffix(".localhost"), !["localhost", "127.0.0.1", "::1", "0.0.0.0"].contains(host), !host.contains(":") else { return nil }
        let first = host.split(separator: ".").first.flatMap { Int($0) }
        if let first, [0, 10, 127, 169, 172, 192].contains(first) { return nil }
        return url
    }
}
