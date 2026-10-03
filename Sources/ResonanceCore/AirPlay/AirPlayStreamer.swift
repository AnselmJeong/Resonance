import Foundation
import AVFoundation
import Network

/// Plays queue items on one AirPlay 1 receiver. Files are decoded to 44.1 kHz / 16-bit stereo,
/// paced by the Mac's clock and sent as one continuous RTP stream, so track changes are gapless.
/// The receiver plays everything `RAOP.totalLatency` frames after it is due to be sent.
public final class AirPlayStreamer: @unchecked Sendable {
    public struct Item: Sendable, Equatable {
        public var id: String
        public var url: URL
        public init(id: String, url: URL) { self.id = id; self.url = url }
    }

    public enum Event: Sendable, Equatable {
        case connecting
        case playing
        case progress(id: String, seconds: Double)
        /// The next item started sounding on the receiver.
        case advanced(id: String)
        /// The last item finished sounding.
        case finished
        case failed(String)
    }

    private struct Segment { var frame: Int64; var item: Item; var offset: Double }

    public let receiver: AirPlayReceiver
    /// Delivered on the main queue.
    public var onEvent: (@Sendable (Event) -> Void)?

    private let endpoint: NWEndpointOverride?
    private let queue = DispatchQueue(label: "local.Resonance.airplay.stream", qos: .userInteractive)
    private let rate = Double(RAOP.sampleRate)
    private let leadFrames = Int64(RAOP.sampleRate / 4)
    private var session: RAOPSession?
    private var connecting = false
    private var generation = 0
    private var volume: Double
    private var decoder: PCMDecoder?
    private var decodingItem: Item?
    private var upcoming: Item?
    private var segments: [Segment] = []
    private var endFrame: Int64?
    private var sentFrame: Int64 = 0
    private var sequence = UInt16.random(in: .min ... .max)
    private let baseTimestamp = UInt32.random(in: .min ... .max)
    private let ssrc = UInt32.random(in: .min ... .max)
    private var anchorFrame: Int64 = 0
    private var anchorTime: UInt64 = 0
    private var needsAnchor = true
    private var marker = true
    private var firstSync = true
    private var wantsPlay = false
    private var streaming = false
    private var timer: DispatchSourceTimer?
    private var nextSync: UInt64 = 0
    private var nextProgress: UInt64 = 0
    private var frames = [Int16](repeating: 0, count: RAOP.framesPerPacket * 2)

    public init(receiver: AirPlayReceiver, volume: Double, endpoint: NWEndpointOverride? = nil) {
        self.receiver = receiver; self.volume = volume; self.endpoint = endpoint
    }

    /// Prepares `item` at `offset` seconds. Audio buffered on the receiver for the previous item is dropped.
    public func load(_ item: Item, at offset: Double, autoplay: Bool) {
        queue.async { [self] in
            if streaming { flushReceiver() }
            stopStreaming()
            upcoming = nil; endFrame = nil
            guard open(item, at: offset) else { return }
            segments = [Segment(frame: sentFrame, item: item, offset: offset)]
            if autoplay { startPlaying() }
        }
    }

    public func setNext(_ item: Item?) {
        queue.async { [self] in
            if decoder == nil, endFrame != nil, let item {
                // The current item already ran out; start the next one right away.
                guard open(item, at: 0) else { return }
                segments.append(Segment(frame: sentFrame, item: item, offset: 0)); endFrame = nil
            } else if segments.count <= 1 || decodingItem == segments.first?.item {
                upcoming = item
            }
        }
    }

    public func play() { queue.async { [self] in if decoder != nil || endFrame != nil { startPlaying() } } }

    public func pause() {
        queue.async { [self] in
            wantsPlay = false
            guard streaming else { return }
            let position = audiblePosition()
            stopStreaming(); flushReceiver(); rewind(to: position)
            emit(.progress(id: position.item.id, seconds: position.seconds))
        }
    }

    public func seek(to seconds: Double) {
        queue.async { [self] in
            guard !segments.isEmpty else { return }
            let item = audiblePosition().item
            if streaming { flushReceiver(); needsAnchor = true }
            rewind(to: (item, max(0, seconds)))
        }
    }

    public func setVolume(_ level: Double) {
        queue.async { [self] in
            volume = level
            guard let session, !session.isClosed else { return }
            Task { try? await session.setVolume(RAOP.volumeDB(level)) }
        }
    }

    /// Ends the session and releases the receiver for other senders.
    public func stop() {
        queue.async { [self] in
            generation += 1; connecting = false; wantsPlay = false
            stopStreaming()
            decoder = nil; decodingItem = nil; upcoming = nil; segments = []; endFrame = nil
            if let session { self.session = nil; Task { await session.teardown() } }
        }
    }

    // MARK: Session

    private func startPlaying() {
        wantsPlay = true
        if let session, !session.isClosed { beginStreaming(); return }
        guard !connecting else { return }
        connecting = true
        emit(.connecting)
        let session = RAOPSession(receiver: receiver, endpoint: endpoint?.endpoint)
        session.onClose = { [weak self, weak session] in self?.queue.async { self?.closed(session) } }
        let token = generation, volume = volume, sequence = sequence, timestamp = timestamp(sentFrame)
        Task { [weak self] in
            do {
                try await session.connect(volumeDB: RAOP.volumeDB(volume), sequence: sequence, timestamp: timestamp)
                self?.queue.async { self?.connected(session, token: token) }
            } catch {
                session.close()
                self?.queue.async { self?.connectFailed(error, token: token) }
            }
        }
    }

    private func connected(_ session: RAOPSession, token: Int) {
        guard token == generation else { Task { await session.teardown() }; return }
        connecting = false
        self.session = session
        if wantsPlay { beginStreaming() }
    }

    private func connectFailed(_ error: Error, token: Int) {
        guard token == generation else { return }
        connecting = false
        if wantsPlay { wantsPlay = false; emit(.failed(error.localizedDescription)) }
    }

    private func closed(_ closedSession: RAOPSession?) {
        guard let closedSession, closedSession === session else { return }
        session = nil
        guard streaming || wantsPlay else { return }   // An idle receiver may end the session; reconnect on play.
        let position = audiblePosition()
        wantsPlay = false; stopStreaming(); rewind(to: position)
        emit(.failed("\(receiver.name) 연결이 끊어졌습니다. 수신기 상태를 확인한 뒤 다시 재생하세요."))
    }

    private func flushReceiver() {
        guard let session, !session.isClosed else { return }
        let sequence = sequence, timestamp = timestamp(sentFrame)
        Task { try? await session.flush(sequence: sequence, timestamp: timestamp) }
    }

    // MARK: Streaming

    private func beginStreaming() {
        guard !streaming else { return }
        streaming = true; needsAnchor = true
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.pump() }
        self.timer = timer
        timer.resume()
        emit(.playing)
    }

    private func stopStreaming() {
        streaming = false; needsAnchor = true
        timer?.cancel(); timer = nil
    }

    private func pump() {
        guard streaming, let session, !session.isClosed else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        if needsAnchor {
            needsAnchor = false; marker = true; firstSync = true
            anchorFrame = sentFrame; anchorTime = now; nextSync = now
        }
        let head = anchorFrame + Int64(Double(now - anchorTime) / 1e9 * rate)
        if now >= nextSync {
            session.sendSync(first: firstSync, head: timestamp(head))
            firstSync = false; nextSync = now + 1_000_000_000
        }
        while sentFrame < head + leadFrames {
            guard sendPacket(session) else { return }
        }
        let playing = head - Int64(RAOP.totalLatency)
        while segments.count > 1, segments[1].frame <= playing {
            segments.removeFirst()
            emit(.advanced(id: segments[0].item.id))
        }
        if let endFrame, playing >= endFrame {
            wantsPlay = false; stopStreaming()
            self.endFrame = nil; segments = []
            emit(.finished)
            return
        }
        if now >= nextProgress {
            nextProgress = now + 250_000_000
            let position = audiblePosition(playing: playing)
            emit(.progress(id: position.item.id, seconds: position.seconds))
        }
    }

    /// Sends one packet of the decoded stream, crossing into the next item without a gap.
    private func sendPacket(_ session: RAOPSession) -> Bool {
        let wanted = RAOP.framesPerPacket
        var filled = 0
        while filled < wanted, let decoder {
            filled += frames.withUnsafeMutableBufferPointer { decoder.read(into: $0.baseAddress! + filled * 2, frames: wanted - filled) }
            guard filled < wanted else { break }
            if let error = decoder.error {
                let position = audiblePosition()
                wantsPlay = false; stopStreaming(); flushReceiver(); rewind(to: position)
                emit(.failed("오디오를 디코딩하지 못했습니다: \(error.localizedDescription)"))
                return false
            }
            self.decoder = nil; decodingItem = nil
            if let next = upcoming {
                upcoming = nil
                if open(next, at: 0) { segments.append(Segment(frame: sentFrame + Int64(filled), item: next, offset: 0)); continue }
            }
            endFrame = sentFrame + Int64(filled)
        }
        if filled < wanted { for i in (filled * 2)..<(wanted * 2) { frames[i] = 0 } }
        let payload = frames.withUnsafeBufferPointer { RAOP.alacFrame($0) }
        session.sendAudio(sequence: sequence, timestamp: timestamp(sentFrame), ssrc: ssrc, marker: marker, payload: payload)
        marker = false; sequence &+= 1; sentFrame += Int64(wanted)
        return true
    }

    // MARK: Position

    private func audiblePosition(playing: Int64? = nil) -> (item: Item, seconds: Double) {
        guard let first = segments.first else { return (decodingItem ?? Item(id: "", url: URL(fileURLWithPath: "/")), 0) }
        let frame: Int64
        if let playing { frame = playing }
        else if streaming && !needsAnchor {
            frame = anchorFrame + Int64(Double(DispatchTime.now().uptimeNanoseconds - anchorTime) / 1e9 * rate) - Int64(RAOP.totalLatency)
        } else { frame = first.frame }
        let segment = segments.last { $0.frame <= frame } ?? first
        return (segment.item, segment.offset + Double(max(0, frame - segment.frame)) / rate)
    }

    /// Restarts decoding where the listener is. Audio the receiver had buffered must already be flushed.
    private func rewind(to position: (item: Item, seconds: Double)) {
        let pending = decodingItem
        guard !position.item.id.isEmpty, open(position.item, at: position.seconds) else { return }
        if let pending, pending.id != position.item.id { upcoming = pending }
        segments = [Segment(frame: sentFrame, item: position.item, offset: position.seconds)]
        endFrame = nil
    }

    private func open(_ item: Item, at offset: Double) -> Bool {
        do {
            decoder = try PCMDecoder(url: item.url, offset: offset); decodingItem = item; return true
        } catch {
            decoder = nil; decodingItem = nil
            wantsPlay = false; stopStreaming()
            emit(.failed("음원을 열 수 없습니다: \(error.localizedDescription)"))
            return false
        }
    }

    private func timestamp(_ frame: Int64) -> UInt32 { baseTimestamp &+ UInt32(truncatingIfNeeded: frame) }

    private func emit(_ event: Event) {
        let handler = onEvent
        DispatchQueue.main.async { handler?(event) }
    }
}

/// Lets tests point the streamer at a local receiver instead of a Bonjour service.
public struct NWEndpointOverride: Sendable {
    let endpoint: NWEndpoint
    public init(host: String, port: UInt16) { endpoint = .hostPort(host: .init(host), port: .init(rawValue: port)!) }
}

/// Decodes a file to interleaved 44.1 kHz / 16-bit stereo. Sources that already are 16-bit
/// 44.1 kHz pass through unchanged; others are resampled and dithered.
final class PCMDecoder {
    static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(RAOP.sampleRate), channels: 2, interleaved: true)!
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer
    private var outputRead = 0
    private var inputDone = false
    private(set) var done = false
    private(set) var error: Error?

    init(url: URL, offset: Double) throws {
        file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        guard let converter = AVAudioConverter(from: source, to: Self.format),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 8192),
              let output = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: 4096) else {
            throw AppError.message("\(url.lastPathComponent)을 AirPlay 형식으로 변환할 수 없습니다.")
        }
        if source.channelCount == 1 { converter.channelMap = [0, 0] } else if source.channelCount > 2 { converter.downmix = true }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.dither = source.sampleRate != Self.format.sampleRate || Self.sourceBits(file) != 16
        self.converter = converter; self.input = input; self.output = output
        file.framePosition = min(AVAudioFramePosition((max(0, offset) * source.sampleRate).rounded()), file.length)
    }

    /// Returns fewer frames than requested only at the end of the file or on `error`.
    func read(into buffer: UnsafeMutablePointer<Int16>, frames: Int) -> Int {
        var produced = 0
        while produced < frames && !done {
            if outputRead >= Int(output.frameLength) { refill(); continue }
            let count = min(frames - produced, Int(output.frameLength) - outputRead)
            (buffer + produced * 2).update(from: output.int16ChannelData![0] + outputRead * 2, count: count * 2)
            outputRead += count; produced += count
        }
        return produced
    }

    private func refill() {
        output.frameLength = 0; outputRead = 0
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { [unowned self] count, status in
            // AVAudioFile throws rather than returning zero frames when asked to read at the end.
            if inputDone || file.framePosition >= file.length { inputDone = true; status.pointee = .endOfStream; return nil }
            do { try file.read(into: input, frameCount: min(count, input.frameCapacity)) }
            catch { self.error = error; inputDone = true; status.pointee = .endOfStream; return nil }
            if input.frameLength == 0 { inputDone = true; status.pointee = .endOfStream; return nil }
            status.pointee = .haveData
            return input
        }
        if status == .error { error = conversionError ?? AppError.message("오디오 변환 오류") }
        if status == .error || output.frameLength == 0 { done = true }
    }

    private static func sourceBits(_ file: AVAudioFile) -> Int? {
        let description = file.fileFormat.streamDescription.pointee
        if description.mBitsPerChannel > 0 { return Int(description.mBitsPerChannel) }
        // FLAC and ALAC record the source depth in the format flags.
        return [1: 16, 2: 20, 3: 24, 4: 32][description.mFormatFlags]
    }
}
