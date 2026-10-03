import Foundation

/// A classic AirPlay (RAOP) receiver found over Bonjour, e.g. "83D8052413DC@X100-00432f-USB".
public struct AirPlayReceiver: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var txt: [String: String]

    public init(serviceName: String, txt: [String: String] = [:]) {
        id = serviceName; self.txt = txt
        name = serviceName.split(separator: "@", maxSplits: 1).last.map(String.init) ?? serviceName
    }

    /// The sender streams unencrypted ALAC over UDP at 44.1 kHz / 16-bit stereo without a password.
    public var supportsDirectStreaming: Bool {
        func list(_ key: String) -> [String]? { txt[key].map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } } }
        guard list("et")?.contains("0") ?? true, list("cn")?.contains("1") ?? true, txt["pw"]?.lowercased() != "true" else { return false }
        if let transports = list("tp"), !transports.contains("UDP") { return false }
        return (txt["sr"] ?? "44100") == "44100" && (txt["ss"] ?? "16") == "16" && (txt["ch"] ?? "2") == "2"
    }
}

/// Wire formats of AirPlay 1. macOS routes these receivers only for the whole system, so the app
/// sends its own stream: the same ALAC/44.1 kHz/16-bit format and 2 s latency macOS uses.
public enum RAOP {
    public static let sampleRate = 44_100
    public static let framesPerPacket = 352
    /// Latency announced in sync packets; the receiver adds its own 11025 frames (2 s total, as macOS).
    public static let syncLatency = 77_175
    public static let totalLatency = 88_200

    public struct NTPTime: Equatable, Sendable {
        public var seconds: UInt32, fraction: UInt32
        public init(seconds: UInt32, fraction: UInt32) { self.seconds = seconds; self.fraction = fraction }
        public init(unix: TimeInterval) {
            let t = unix + 2_208_988_800, whole = t.rounded(.down)
            self.init(seconds: UInt32(truncatingIfNeeded: Int64(whole)), fraction: UInt32(min((t - whole) * 4_294_967_296, 4_294_967_295)))
        }
        var bytes: [UInt8] { seconds.bigEndianBytes + fraction.bigEndianBytes }
    }

    /// AirPlay's slider range is -30…0 dB; -144 mutes. Full app volume passes audio unattenuated.
    public static func volumeDB(_ level: Double) -> Double {
        level <= 0 ? -144 : 30 * (min(level, 1) - 1)
    }

    public static func announce(sessionID: String, localIP: String, remoteIP: String) -> String {
        "v=0\r\no=iTunes \(sessionID) 0 IN IP4 \(localIP)\r\ns=iTunes\r\nc=IN IP4 \(remoteIP)\r\nt=0 0\r\n"
            + "m=audio 0 RTP/AVP 96\r\na=rtpmap:96 AppleLossless\r\na=fmtp:96 \(framesPerPacket) 0 16 40 10 14 2 255 0 0 \(sampleRate)\r\n"
    }

    public static func transportParameters(_ header: String) -> [String: String] {
        var result: [String: String] = [:]
        for part in header.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { result[String(pair[0])] = String(pair[1]) }
        }
        return result
    }

    /// Stores interleaved 16-bit stereo frames losslessly in an uncompressed (escape) ALAC frame.
    public static func alacFrame(_ samples: UnsafeBufferPointer<Int16>) -> Data {
        var writer = BitWriter(capacity: samples.count * 2 + 4)
        writer.write(1, 3)   // stereo channel pair element
        writer.write(0, 4); writer.write(0, 12)
        writer.write(0, 1)   // full-length frame, no sample count
        writer.write(0, 2); writer.write(1, 1)   // no shift, not compressed
        for sample in samples { writer.write(UInt32(UInt16(bitPattern: sample)), 16) }
        writer.write(7, 3)   // end tag
        return writer.finish()
    }

    public static func audioPacket(sequence: UInt16, timestamp: UInt32, ssrc: UInt32, marker: Bool, payload: Data) -> Data {
        var packet = Data([0x80, marker ? 0xE0 : 0x60] + sequence.bigEndianBytes + timestamp.bigEndianBytes + ssrc.bigEndianBytes)
        packet.append(payload)
        return packet
    }

    /// `head` is the RTP time being sent now; `head - syncLatency` is what the receiver should play now.
    public static func syncPacket(first: Bool, head: UInt32, time: NTPTime) -> Data {
        Data([first ? 0x90 : 0x80, 0xD4, 0x00, 0x07] + (head &- UInt32(syncLatency)).bigEndianBytes + time.bytes + head.bigEndianBytes)
    }

    public static func timingReply(to request: Data, received: NTPTime, sent: NTPTime) -> Data? {
        let bytes = [UInt8](request)
        guard bytes.count >= 32, bytes[1] & 0x7F == 0x52 else { return nil }
        return Data([0x80, 0xD3, 0x00, 0x07, 0, 0, 0, 0] + bytes[24..<32] + received.bytes + sent.bytes)
    }

    public static func retransmitRequest(_ data: Data) -> (first: UInt16, count: UInt16)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes[1] & 0x7F == 0x55 else { return nil }
        return (UInt16(bytes[4]) << 8 | UInt16(bytes[5]), UInt16(bytes[6]) << 8 | UInt16(bytes[7]))
    }

    public static func resentPacket(_ original: Data) -> Data {
        var packet = Data([0x80, 0xD6, original[original.startIndex + 2], original[original.startIndex + 3]])
        packet.append(original)
        return packet
    }
}

struct BitWriter {
    private var data: Data
    private var accumulator: UInt64 = 0
    private var count = 0
    init(capacity: Int) { data = Data(capacity: capacity) }
    mutating func write(_ value: UInt32, _ bits: Int) {
        accumulator = accumulator << UInt64(bits) | UInt64(value) & (1 << UInt64(bits) - 1)
        count += bits
        while count >= 8 { count -= 8; data.append(UInt8(truncatingIfNeeded: accumulator >> UInt64(count))) }
    }
    mutating func finish() -> Data {
        if count > 0 { data.append(UInt8(truncatingIfNeeded: accumulator << UInt64(8 - count))); count = 0 }
        return data
    }
}

extension FixedWidthInteger {
    var bigEndianBytes: [UInt8] { withUnsafeBytes(of: bigEndian) { Array($0) } }
}
