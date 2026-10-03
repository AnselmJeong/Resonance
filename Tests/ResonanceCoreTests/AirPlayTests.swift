import Testing
import AVFoundation
import Network
import Darwin
@testable import ResonanceCore

/// Reads an uncompressed ALAC frame back into interleaved samples.
private func unpackALAC(_ data: Data) -> (header: UInt32, samples: [Int16], endTag: UInt32) {
    let bytes = [UInt8](data)
    var bit = 0
    func read(_ count: Int) -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<count { value = value << 1 | UInt32(bytes[bit / 8] >> (7 - bit % 8) & 1); bit += 1 }
        return value
    }
    let header = read(23)
    let samples = (0..<RAOP.framesPerPacket * 2).map { _ in Int16(bitPattern: UInt16(read(16))) }
    return (header, samples, read(3))
}

private func writeTone(_ url: URL, rate: Double, seconds: Double, channels: AVAudioChannelCount = 2) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
    let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
    let frames = AVAudioFrameCount(rate * seconds)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0..<Int(channels) { for i in 0..<Int(frames) { buffer.floatChannelData![channel][i] = Float(sin(Double(i) * 2 * .pi * 440 / rate) * 0.5) } }
    try file.write(from: buffer)
}

/// A minimal RAOP receiver on localhost: answers RTSP and records what arrives over UDP.
private final class FakeReceiver: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "fake.receiver")
    let lock = NSLock()
    private(set) var methods: [String] = []
    private(set) var bodies: [String: String] = [:]
    private(set) var audioPackets: [Data] = []
    private(set) var syncPackets = 0
    let audioSocket: Int32, controlSocket: Int32
    var port: UInt16 { listener.port!.rawValue }

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        audioSocket = FakeReceiver.udp(); controlSocket = FakeReceiver.udp()
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        for (fd, audio) in [(audioSocket, true), (controlSocket, false)] {
            Thread.detachNewThread { [weak self] in
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = recv(fd, &buffer, buffer.count, 0)
                    guard n > 0, let self else { return }
                    self.lock.withLock { if audio { self.audioPackets.append(Data(buffer[0..<n])) } else if buffer[1] == 0xD4 { self.syncPackets += 1 } }
                }
            }
        }
    }

    func snapshot() -> (methods: [String], audio: [Data], syncs: Int) { lock.withLock { (methods, audioPackets, syncPackets) } }
    func body(_ method: String) -> String? { lock.withLock { bodies[method] } }
    func stop() { listener.cancel(); shutdown(audioSocket, SHUT_RDWR); shutdown(controlSocket, SHUT_RDWR); close(audioSocket); close(controlSocket) }

    private func serve(_ connection: NWConnection) {
        var pending = Data()
        func next() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, complete, _ in
                if let data { pending.append(data) }
                while let end = pending.range(of: Data("\r\n\r\n".utf8)) {
                    let head = String(decoding: pending[pending.startIndex..<end.lowerBound], as: UTF8.self)
                    let lines = head.components(separatedBy: "\r\n")
                    let length = lines.first { $0.lowercased().hasPrefix("content-length:") }.flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                    guard pending.distance(from: end.upperBound, to: pending.endIndex) >= length else { break }
                    let body = String(decoding: pending[end.upperBound..<pending.index(end.upperBound, offsetBy: length)], as: UTF8.self)
                    pending = Data(pending[pending.index(end.upperBound, offsetBy: length)...])
                    let method = String(lines[0].split(separator: " ")[0])
                    let cseq = lines.first { $0.hasPrefix("CSeq:") }!.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    lock.withLock { methods.append(method); bodies[method] = body }
                    var reply = "RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\nServer: AirTunes/105.1\r\n"
                    if method == "SETUP" { reply += "Session: 1\r\nTransport: RTP/AVP/UDP;unicast;mode=record;server_port=\(Self.port(audioSocket));control_port=\(Self.port(controlSocket));timing_port=\(Self.port(controlSocket))\r\n" }
                    connection.send(content: Data((reply + "\r\n").utf8), completion: .idempotent)
                }
                if !complete { next() }
            }
        }
        connection.start(queue: queue); next()
    }

    private static func udp() -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        return fd
    }
    private static func port(_ fd: Int32) -> UInt16 {
        var address = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        return UInt16(bigEndian: address.sin_port)
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AirPlayStreamer.Event] = []
    func append(_ event: AirPlayStreamer.Event) { lock.withLock { events.append(event) } }
    var all: [AirPlayStreamer.Event] { lock.withLock { events } }
    func wait(seconds: Double, until done: ([AirPlayStreamer.Event]) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { if done(all) { return true }; try? await Task.sleep(nanoseconds: 50_000_000) }
        return done(all)
    }
}

@Suite(.serialized) struct AirPlayTests {
    @Test func receiverCapabilitiesComeFromBonjour() {
        let x100 = AirPlayReceiver(serviceName: "83D8052413DC@X100-00432f-USB", txt: ["et": "0,1", "cn": "0,1", "ss": "16", "sr": "44100", "ch": "2", "tp": "TCP,UDP", "pw": "false"])
        #expect(x100.name == "X100-00432f-USB")
        #expect(x100.supportsDirectStreaming)
        #expect(!AirPlayReceiver(serviceName: "A@Locked", txt: ["et": "1"]).supportsDirectStreaming)
        #expect(!AirPlayReceiver(serviceName: "A@Password", txt: ["pw": "true"]).supportsDirectStreaming)
        #expect(!AirPlayReceiver(serviceName: "A@HiRes", txt: ["sr": "96000"]).supportsDirectStreaming)
    }

    @Test func alacFramesCarryPCMUnchanged() {
        let samples = (0..<RAOP.framesPerPacket * 2).map { Int16(truncatingIfNeeded: $0 * 977 - 30_000) }
        let frame = samples.withUnsafeBufferPointer { RAOP.alacFrame($0) }
        #expect(frame.count == 1412)
        let decoded = unpackALAC(frame)
        #expect(decoded.header == 0b001_0000_000000000000_0_00_1)
        #expect(decoded.samples == samples)
        #expect(decoded.endTag == 7)
    }

    @Test func packetsFollowAirPlayLayout() {
        let audio = RAOP.audioPacket(sequence: 0x1234, timestamp: 0xA0B0C0D0, ssrc: 7, marker: true, payload: Data([9]))
        #expect([UInt8](audio) == [0x80, 0xE0, 0x12, 0x34, 0xA0, 0xB0, 0xC0, 0xD0, 0, 0, 0, 7, 9])
        let time = RAOP.NTPTime(seconds: 1, fraction: 2)
        let sync = [UInt8](RAOP.syncPacket(first: true, head: 100_000, time: time))
        #expect(sync.count == 20 && sync[0] == 0x90 && sync[1] == 0xD4)
        #expect(Array(sync[4..<8]) == UInt32(100_000 - RAOP.syncLatency).bigEndianBytes && Array(sync[16..<20]) == UInt32(100_000).bigEndianBytes)
        var request = [UInt8](repeating: 0, count: 32); request[0] = 0x80; request[1] = 0xD2
        for i in 24..<32 { request[i] = UInt8(i) }
        let reply = [UInt8](RAOP.timingReply(to: Data(request), received: time, sent: time)!)
        #expect(reply[1] == 0xD3 && Array(reply[8..<16]) == Array(request[24..<32]))
        #expect(RAOP.retransmitRequest(Data([0x80, 0xD5, 0, 1, 0x12, 0x34, 0, 3]))! == (0x1234, 3))
        #expect([UInt8](RAOP.resentPacket(audio).prefix(4)) == [0x80, 0xD6, 0x12, 0x34])
        #expect(RAOP.transportParameters("RTP/AVP/UDP;unicast;control_port=6001;server_port=6003")["server_port"] == "6003")
        #expect(RAOP.volumeDB(1) == 0 && RAOP.volumeDB(0) == -144 && RAOP.volumeDB(0.5) == -15)
    }

    @Test func decoderResamplesAndSeeksExactly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AirPlayTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func count(_ url: URL, from offset: Double = 0) throws -> Int {
            let decoder = try PCMDecoder(url: url, offset: offset)
            var buffer = [Int16](repeating: 0, count: 4096 * 2), total = 0
            while true { let n = buffer.withUnsafeMutableBufferPointer { decoder.read(into: $0.baseAddress!, frames: 4096) }; total += n; if n < 4096 { break } }
            return total
        }
        let hiRes = directory.appendingPathComponent("96k.caf"), cd = directory.appendingPathComponent("44k.caf"), mono = directory.appendingPathComponent("mono.caf")
        try writeTone(hiRes, rate: 96_000, seconds: 1); try writeTone(cd, rate: 44_100, seconds: 0.5); try writeTone(mono, rate: 44_100, seconds: 0.2, channels: 1)
        #expect(abs(try count(hiRes) - 44_100) <= 2)
        #expect(try count(cd) == 22_050)
        #expect(try count(cd, from: 0.25) == 11_025)
        #expect(try count(mono) == 8_820)
    }

    @Test func streamerPlaysQueueGaplesslyOnReceiver() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AirPlayTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.caf"), second = directory.appendingPathComponent("second.caf")
        try writeTone(first, rate: 44_100, seconds: 0.4); try writeTone(second, rate: 48_000, seconds: 0.3)

        let receiver = try FakeReceiver()
        defer { receiver.stop() }
        let streamer = AirPlayStreamer(receiver: AirPlayReceiver(serviceName: "TEST@Fake"), volume: 1, endpoint: NWEndpointOverride(host: "127.0.0.1", port: receiver.port))
        let log = EventLog()
        streamer.onEvent = { log.append($0) }
        streamer.load(.init(id: "a", url: first), at: 0, autoplay: true)
        streamer.setNext(.init(id: "b", url: second))

        #expect(await log.wait(seconds: 8) { $0.contains(.finished) }, "events: \(log.all)")
        let events = log.all.filter { if case .progress = $0 { return false }; return true }
        #expect(events == [.connecting, .playing, .advanced(id: "b"), .finished])
        let state = receiver.snapshot()
        #expect(state.methods.starts(with: ["OPTIONS", "ANNOUNCE", "SETUP", "RECORD", "SET_PARAMETER"]))
        #expect(receiver.body("ANNOUNCE")?.contains("AppleLossless") == true)
        #expect(receiver.body("SET_PARAMETER") == "volume: 0.000000\r\n")
        #expect(state.syncs >= 2)
        // 0.4 s + 0.3 s of music back to back, then silence until the 2 s latency has played out.
        let musicPackets = Int((0.7 * 44_100 / 352).rounded(.up))
        #expect(state.audio.count >= musicPackets + RAOP.totalLatency / 352 - 2)
        let audible = state.audio.prefix(musicPackets - 1).map { unpackALAC($0.dropFirst(12)).samples.contains { $0 != 0 } }
        #expect(audible.allSatisfy { $0 }, "a silent packet inside the music means a gap")
        #expect(state.audio.first.map { $0[1] } == 0xE0)
        streamer.stop()
        #expect(await log.wait(seconds: 3) { _ in receiver.snapshot().methods.last == "TEARDOWN" })
    }

    @Test func pauseFlushesReceiverAndResumesWhereListenerWas() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AirPlayTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let track = directory.appendingPathComponent("long.caf")
        try writeTone(track, rate: 44_100, seconds: 5)
        let receiver = try FakeReceiver()
        defer { receiver.stop() }
        let streamer = AirPlayStreamer(receiver: AirPlayReceiver(serviceName: "TEST@Fake"), volume: 0.5, endpoint: NWEndpointOverride(host: "127.0.0.1", port: receiver.port))
        let log = EventLog()
        streamer.onEvent = { log.append($0) }
        streamer.load(.init(id: "a", url: track), at: 1, autoplay: true)
        #expect(await log.wait(seconds: 5) { $0.contains(.playing) })
        try await Task.sleep(nanoseconds: 500_000_000)
        streamer.pause()
        #expect(await log.wait(seconds: 3) { _ in receiver.snapshot().methods.contains("FLUSH") })
        // Nothing has sounded yet within the 2 s latency, so the listener is still at the start offset.
        guard case .progress(_, let paused)? = log.all.last(where: { if case .progress = $0 { return true }; return false }) else { Issue.record("no position"); return }
        #expect(abs(paused - 1) < 0.05)
        #expect(receiver.body("SET_PARAMETER") == "volume: -15.000000\r\n")
        streamer.stop()
    }
}
