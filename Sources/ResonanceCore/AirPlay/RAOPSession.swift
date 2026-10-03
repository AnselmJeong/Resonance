import Foundation
import Network
import Darwin

/// One RTSP/RTP session with a classic AirPlay receiver. RTSP runs on its own queue; audio and
/// sync packets may be sent from the streamer's queue once `connect` has returned.
public final class RAOPSession: @unchecked Sendable {
    private struct Response { var status: Int; var headers: [String: String] }
    private struct Packet { var sequence: UInt16; var data: Data }

    public let receiver: AirPlayReceiver
    private let endpoint: NWEndpoint
    private let queue = DispatchQueue(label: "local.Resonance.airplay.session")
    private var connection: NWConnection?
    private var buffer = Data()
    private var waiting: [Int: CheckedContinuation<Response, Error>] = [:]
    private var cseq = 0
    private var rtspSession: String?
    private var url = ""
    private let clientID = String(format: "%016llX", UInt64.random(in: 0...UInt64.max))
    private let activeRemote = String(UInt32.random(in: 0...UInt32.max))
    private let sessionID = String(UInt32.random(in: 0...UInt32.max))
    private var audioSocket: Int32 = -1, controlSocket: Int32 = -1, timingSocket: Int32 = -1
    private var serverAddress = sockaddr_in(), controlAddress = sockaddr_in()
    private var sources: [DispatchSourceRead] = []
    private let historyLock = NSLock()
    private var history = [Packet?](repeating: nil, count: 1024)
    private let unixBase = Date().timeIntervalSince1970
    private let uptimeBase = DispatchTime.now().uptimeNanoseconds
    private let closedLock = NSLock()
    private var closedFlag = false
    /// Called once on the session queue when the receiver or network ends the session.
    public var onClose: (@Sendable () -> Void)?

    public var isClosed: Bool { closedLock.withLock { closedFlag } }

    /// `endpoint` overrides Bonjour resolution (used for tests and explicit hosts).
    public init(receiver: AirPlayReceiver, endpoint: NWEndpoint? = nil) {
        self.receiver = receiver
        self.endpoint = endpoint ?? .service(name: receiver.id, type: "_raop._tcp", domain: "local.", interface: nil)
    }

    public func connect(volumeDB: Double, sequence: UInt16, timestamp: UInt32) async throws {
        let (local, remote) = try await open()
        try openSockets(remote: remote)
        queue.sync { url = "rtsp://\(local)/\(sessionID)" }
        try expectOK(try await request("OPTIONS", uri: "*"), "OPTIONS")
        let sdp = RAOP.announce(sessionID: sessionID, localIP: local, remoteIP: remote)
        try expectOK(try await request("ANNOUNCE", headers: ["Content-Type": "application/sdp"], body: Data(sdp.utf8)), "ANNOUNCE")
        let setup = try await request("SETUP", headers: ["Transport": "RTP/AVP/UDP;unicast;interleaved=0-1;mode=record;control_port=\(Self.port(controlSocket));timing_port=\(Self.port(timingSocket))"])
        try expectOK(setup, "SETUP")
        let transport = RAOP.transportParameters(setup.headers["transport"] ?? "")
        guard let server = transport["server_port"].flatMap(UInt16.init), let control = transport["control_port"].flatMap(UInt16.init) else {
            throw AppError.message("\(receiver.name)이 오디오 포트를 알려주지 않았습니다.")
        }
        queue.sync {
            rtspSession = setup.headers["session"]?.split(separator: ";").first.map(String.init)
            serverAddress = Self.address(remote, server); controlAddress = Self.address(remote, control)
        }
        try expectOK(try await request("RECORD", headers: ["Range": "npt=0-", "RTP-Info": "seq=\(sequence);rtptime=\(timestamp)"]), "RECORD")
        try await setVolume(volumeDB)
    }

    public func setVolume(_ db: Double) async throws {
        try expectOK(try await request("SET_PARAMETER", headers: ["Content-Type": "text/parameters"], body: Data(String(format: "volume: %.6f\r\n", db).utf8)), "SET_PARAMETER")
    }

    /// Drops audio the receiver has buffered before `timestamp`, the next packet to be sent.
    public func flush(sequence: UInt16, timestamp: UInt32) async throws {
        try expectOK(try await request("FLUSH", headers: ["Range": "npt=0-", "RTP-Info": "seq=\(sequence);rtptime=\(timestamp)"]), "FLUSH")
    }

    public func teardown() async {
        if !isClosed { _ = try? await request("TEARDOWN") }
        close()
    }

    public func close() { queue.async { self.shutdown(notify: false) } }

    public func sendAudio(sequence: UInt16, timestamp: UInt32, ssrc: UInt32, marker: Bool, payload: Data) {
        let packet = RAOP.audioPacket(sequence: sequence, timestamp: timestamp, ssrc: ssrc, marker: marker, payload: payload)
        historyLock.withLock { history[Int(sequence) % history.count] = Packet(sequence: sequence, data: packet) }
        send(packet, from: audioSocket, to: serverAddress)
    }

    public func sendSync(first: Bool, head: UInt32) {
        send(RAOP.syncPacket(first: first, head: head, time: now()), from: controlSocket, to: controlAddress)
    }

    // MARK: Connection

    private func open() async throws -> (local: String, remote: String) {
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: endpoint, using: parameters)
        queue.sync { self.connection = connection }
        let name = receiver.name
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Both handlers run on `queue`, so the once-only state needs no lock.
            final class Attempt: @unchecked Sendable { var resumed = false; var waitingReason: String? }
            let attempt = Attempt()
            let finish: @Sendable (Result<Void, Error>) -> Void = { result in
                if !attempt.resumed { attempt.resumed = true; continuation.resume(with: result) }
            }
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: finish(.success(()))
                case .waiting(let error): attempt.waitingReason = error.localizedDescription
                case .failed(let error): finish(.failure(AppError.message("\(name)에 연결하지 못했습니다: \(error.localizedDescription)"))); self?.shutdown(notify: true)
                case .cancelled: finish(.failure(AppError.message("\(name) 연결이 취소되었습니다.")))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 8) {
                guard !attempt.resumed else { return }
                connection.cancel()
                let reason = attempt.waitingReason.map { " (\($0)) 시스템 설정 > 개인정보 보호 및 보안 > 로컬 네트워크에서 Resonance 허용 여부를 확인하세요." } ?? " 네트워크와 수신기 전원을 확인하세요."
                finish(.failure(AppError.message("\(name)이 응답하지 않습니다." + reason)))
            }
        }
        return try queue.sync {
            guard case .hostPort(let localHost, _)? = connection.currentPath?.localEndpoint, case .hostPort(let remoteHost, _)? = connection.currentPath?.remoteEndpoint,
                  let local = Self.ipv4(localHost), let remote = Self.ipv4(remoteHost) else { throw AppError.message("\(name)의 IPv4 주소를 확인하지 못했습니다.") }
            receive(on: connection)
            return (local, remote)
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { buffer.append(data); parseResponses() }
            if complete || error != nil { shutdown(notify: true) } else { receive(on: connection) }
        }
    }

    private func parseResponses() {
        while let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
            let lines = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let length = Int(headers["content-length"] ?? "") ?? 0
            guard buffer.distance(from: end.upperBound, to: buffer.endIndex) >= length else { return }
            buffer = Data(buffer[buffer.index(end.upperBound, offsetBy: length)...])
            let parts = lines.first?.split(separator: " ") ?? []
            guard parts.count >= 2, let status = Int(parts[1]), let sequence = Int(headers["cseq"] ?? "") else { continue }
            waiting.removeValue(forKey: sequence)?.resume(returning: Response(status: status, headers: headers))
        }
    }

    private func request(_ method: String, uri: String? = nil, headers: [String: String] = [:], body: Data = Data()) async throws -> Response {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard let connection, !isClosed else { continuation.resume(throwing: AppError.message("\(receiver.name) 연결이 끊어졌습니다.")); return }
                cseq += 1
                let sequence = cseq
                var lines = ["\(method) \(uri ?? url) RTSP/1.0", "CSeq: \(sequence)", "User-Agent: Resonance/0.1 (Macintosh)",
                             "DACP-ID: \(clientID)", "Active-Remote: \(activeRemote)", "Client-Instance: \(clientID)"]
                if let rtspSession { lines.append("Session: \(rtspSession)") }
                lines += headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
                if !body.isEmpty { lines.append("Content-Length: \(body.count)") }
                var message = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
                message.append(body)
                waiting[sequence] = continuation
                connection.send(content: message, completion: .contentProcessed { [weak self] error in
                    guard let self, let error else { return }
                    queue.async { self.waiting.removeValue(forKey: sequence)?.resume(throwing: error) }
                })
                queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self else { return }
                    waiting.removeValue(forKey: sequence)?.resume(throwing: AppError.message("\(receiver.name)이 \(method) 요청에 응답하지 않습니다."))
                }
            }
        }
    }

    private func expectOK(_ response: Response, _ method: String) throws {
        switch response.status {
        case 200: return
        case 453: throw AppError.message("\(receiver.name)을 다른 기기(Apple Music, 시스템 AirPlay 등)가 사용 중입니다. 그쪽 연결을 해제한 뒤 다시 재생하세요.")
        default: throw AppError.message("\(receiver.name)이 \(method) 요청을 거부했습니다 (RTSP \(response.status)).")
        }
    }

    private func shutdown(notify: Bool) {
        let wasClosed = closedLock.withLock { () -> Bool in defer { closedFlag = true }; return closedFlag }
        guard !wasClosed else { return }
        for continuation in waiting.values { continuation.resume(throwing: AppError.message("\(receiver.name) 연결이 끊어졌습니다.")) }
        waiting.removeAll()
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        sources.forEach { $0.cancel() }; sources.removeAll()
        if notify { onClose?() }
    }

    // Descriptors stay open until deinit so a late packet from the streamer never reaches a reused fd.
    deinit { for fd in [audioSocket, controlSocket, timingSocket] where fd >= 0 { Darwin.close(fd) } }

    // MARK: UDP

    private func openSockets(remote: String) throws {
        audioSocket = try Self.udpSocket(bound: false)
        controlSocket = try Self.udpSocket(bound: true)
        timingSocket = try Self.udpSocket(bound: true)
        let timing = DispatchSource.makeReadSource(fileDescriptor: timingSocket, queue: queue)
        timing.setEventHandler { [weak self] in self?.answerTiming() }
        let control = DispatchSource.makeReadSource(fileDescriptor: controlSocket, queue: queue)
        control.setEventHandler { [weak self] in self?.answerRetransmit() }
        queue.sync { sources = [timing, control] }
        timing.resume(); control.resume()
    }

    private func answerTiming() {
        var bytes = [UInt8](repeating: 0, count: 128), from = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(timingSocket, &bytes, bytes.count, 0, $0, &length) } }
        let received = now()
        guard count > 0, let reply = RAOP.timingReply(to: Data(bytes[0..<count]), received: received, sent: now()) else { return }
        send(reply, from: timingSocket, to: from)
    }

    private func answerRetransmit() {
        var bytes = [UInt8](repeating: 0, count: 64)
        let count = recv(controlSocket, &bytes, bytes.count, 0)
        guard count > 0, let request = RAOP.retransmitRequest(Data(bytes[0..<count])) else { return }
        for offset in 0..<min(request.count, 256) {
            let sequence = request.first &+ UInt16(offset)
            let packet = historyLock.withLock { history[Int(sequence) % history.count].flatMap { $0.sequence == sequence ? $0.data : nil } }
            if let packet { send(RAOP.resentPacket(packet), from: controlSocket, to: controlAddress) }
        }
    }

    private func send(_ data: Data, from socket: Int32, to address: sockaddr_in) {
        guard socket >= 0, !isClosed else { return }
        var target = address
        _ = data.withUnsafeBytes { buffer in
            withUnsafePointer(to: &target) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(socket, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
    }

    /// A monotonic NTP-format clock; the receiver only needs timing replies and sync packets to agree.
    private func now() -> RAOP.NTPTime {
        RAOP.NTPTime(unix: unixBase + Double(DispatchTime.now().uptimeNanoseconds - uptimeBase) / 1e9)
    }

    private static func udpSocket(bound: Bool) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw AppError.message("AirPlay UDP 소켓을 만들 수 없습니다.") }
        if bound {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
            let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard result == 0 else { Darwin.close(fd); throw AppError.message("AirPlay UDP 포트를 열 수 없습니다.") }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        return fd
    }

    private static func port(_ fd: Int32) -> UInt16 {
        var address = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        return UInt16(bigEndian: address.sin_port)
    }

    private static func address(_ ip: String, _ port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian
        inet_pton(AF_INET, ip, &address.sin_addr)
        return address
    }

    private static func ipv4(_ host: NWEndpoint.Host) -> String? {
        guard case .ipv4(let address) = host else { return nil }
        return address.rawValue.map(String.init).joined(separator: ".")
    }
}
