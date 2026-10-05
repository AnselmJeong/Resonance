import Foundation
import AVFoundation
import MediaPlayer
import Observation
import ResonanceCore

@MainActor @Observable
final class PlaybackCoordinator {
    enum State: String { case idle = "대기", preparing = "준비 중", playing = "재생 중", paused = "일시 정지", buffering = "버퍼링", failed = "재생 오류" }
    let player = AVQueuePlayer()
    let output = OutputMonitor()
    private let db: LibraryDatabase
    private let files: AudioFileAccess
    private var currentFile: AudioFileLease?
    private var nextFile: AudioFileLease?
    private var preparationTask: Task<AudioFileLease, Error>?
    private var prefetchTask: Task<Void, Never>?
    var state = State.idle
    var entries: [QueueEntry] = []
    var index = 0
    var current: Track?
    var currentAlbum: Album?
    var position: Double = 0
    var volume: Double = 0.8 { didSet { player.volume = Float(volume); stream?.setVolume(volume) } }
    /// Where this app's music plays. An AirPlay receiver gets the app's own stream, so the Mac's
    /// system output (alerts, other apps) never moves to the Hi-Fi.
    enum OutputTarget: Equatable { case mac, airPlay(AirPlayReceiver) }
    private(set) var target = OutputTarget.mac
    let airPlay = AirPlayBrowser()
    private var stream: AirPlayStreamer?
    private var streamEnded = false
    private var preferredReceiverID: String?
    var error: String?
    private var generation = 0
    private var seekGeneration = 0
    private var upcomingGeneration = 0
    private var wantsPlaying = false
    private var timeObserver: Any?
    private var observations: [NSKeyValueObservation] = []
    private var itemObservation: NSKeyValueObservation?
    private var itemEntries: [ObjectIdentifier: String] = [:]
    private var lastSaved = Date.distantPast
    private var changingItems = false
    private var tokens: [NSObjectProtocol] = []

    init(database: LibraryDatabase, files: AudioFileAccess) {
        db = database; self.files = files; player.volume = Float(volume); player.allowsExternalPlayback = true
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self, self.stream == nil, self.current != nil, self.state != .failed else { return }
                switch player.timeControlStatus {
                case .playing: self.state = .playing
                case .waitingToPlayAtSpecifiedRate: self.state = .buffering
                case .paused: if self.state != .preparing { self.state = .paused }
                @unknown default: break
                }
                AppLog.playback.info("Playback state=\(self.state.rawValue, privacy: .public); wantsPlaying=\(self.wantsPlaying, privacy: .public); airPlay=\(self.output.isAirPlay, privacy: .public)")
                self.updateNowPlaying()
            }
        })
        observations.append(player.observe(\.currentItem, options: [.new]) { [weak self] player, _ in
            let identity = player.currentItem.map(ObjectIdentifier.init)
            Task { @MainActor in await self?.itemChanged(identity) }
        })
        // Local playback follows the Mac's default device. macOS cannot route one player to an
        // AirPlay 1 receiver, so those receivers are played through `stream` instead.
        player.audioOutputDeviceUniqueID = nil
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                guard self.state != .preparing else { return }
                self.position = time.seconds.isFinite ? time.seconds : 0
                if Date().timeIntervalSince(self.lastSaved) > 5 { self.persist(); self.updateNowPlaying(); self.output.refresh(); self.lastSaved = Date() }
            }
        }
        tokens.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor in
                guard let self, let item = notification.object as? AVPlayerItem, item === self.player.currentItem else { return }
                self.fail("음원 재생에 실패했습니다. 파일과 출력 연결을 확인하세요.")
            }
        })
        tokens.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor in
                guard let self, let item = notification.object as? AVPlayerItem, let endedID = self.itemEntries[ObjectIdentifier(item)] else { return }
                if endedID == self.entries.last?.id {
                    self.wantsPlaying = false; self.state = .paused; self.position = self.current?.duration ?? 0; self.persist(); self.updateNowPlaying()
                } else if (self.player.currentItem == nil || (self.player.currentItem === item && self.player.items().count == 1)), self.entries.indices.contains(self.index), endedID == self.entries[self.index].id {
                    await self.prepare(at: self.index + 1, autoplay: self.wantsPlaying)
                }
            }
        })
        configureRemoteCommands()
        output.onChange = { [weak self] previous, current, previousAlive in
            guard let self else { return }
            AppLog.playback.info("Audio route changed; available=\(current.available, privacy: .public); airPlay=\(current.isAirPlay, privacy: .public); rate=\(current.nominalRate ?? 0, privacy: .public); device=\(current.name, privacy: .private)")
            guard self.stream == nil, self.wantsPlaying, AudioOutputRoute.shouldPause(after: previous, current: current, previousStillAvailable: previousAlive, userIsSelecting: false) else { return }
            self.pause(); self.error = "출력 연결이 해제되어 재생을 멈췄습니다. 출력 기기를 선택한 뒤 다시 재생하세요."
        }
        airPlay.onChange = { [weak self] in self?.restorePreferredReceiver() }
        airPlay.start()
    }

    var outputName: String { if case .airPlay(let receiver) = target { receiver.name } else { output.name } }

    /// Moves this app's playback, keeping the queue position and play/pause state.
    func selectOutput(_ newTarget: OutputTarget) async {
        guard newTarget != target else { return }
        let resume = wantsPlaying, at = position
        generation += 1; preparationTask?.cancel(); prefetchTask?.cancel(); upcomingGeneration += 1
        player.pause(); player.removeAllItems(); itemEntries.removeAll()
        stream?.stop(); stream = nil; streamEnded = false; error = nil
        target = newTarget; preferredReceiverID = nil
        var receiverID = ""
        if case .airPlay(let receiver) = newTarget {
            receiverID = receiver.id
            let stream = AirPlayStreamer(receiver: receiver, volume: volume)
            stream.onEvent = { [weak self, weak stream] event in
                MainActor.assumeIsolated { if let self, let stream, stream === self.stream { self.handle(event) } }
            }
            self.stream = stream
        }
        AppLog.playback.info("Output target: \(receiverID.isEmpty ? "Mac" : "AirPlay", privacy: .public)")
        Task { try? await db.setPreference("airPlayReceiver", value: receiverID) }
        if current != nil, entries.indices.contains(index) { await prepare(at: index, autoplay: resume, position: at) }
    }

    /// Re-selects the last AirPlay receiver once it is found, without starting playback.
    private func restorePreferredReceiver() {
        guard target == .mac, !wantsPlaying, let id = preferredReceiverID, let receiver = airPlay.receivers.first(where: { $0.id == id }) else { return }
        preferredReceiverID = nil
        Task { await selectOutput(.airPlay(receiver)) }
    }

    private func handle(_ event: AirPlayStreamer.Event) {
        switch event {
        case .connecting: if wantsPlaying { state = .buffering }
        case .playing: state = .playing; error = nil; updateNowPlaying()
        case .progress(let id, let seconds):
            guard entries.indices.contains(index), entries[index].id == id else { return }
            position = seconds
            if Date().timeIntervalSince(lastSaved) > 5 { persist(); updateNowPlaying(); lastSaved = Date() }
        case .advanced(let id): Task { await advance(to: id) }
        case .finished:
            wantsPlaying = false; streamEnded = true; state = .paused; position = current?.duration ?? 0; persist(); updateNowPlaying()
        case .failed(let message): fail(message)
        }
    }

    func restore() async {
        preferredReceiverID = try? await db.preference("airPlayReceiver", as: String.self).flatMap { $0.isEmpty ? nil : $0 }
        defer { restorePreferredReceiver() }
        do {
            if let snapshot = try await db.preference("queue", as: QueueSnapshot.self), !snapshot.entries.isEmpty {
                entries = snapshot.entries; index = min(max(0, snapshot.index), entries.count - 1)
                await prepare(at: index, autoplay: false, position: snapshot.position)
            }
        } catch { self.error = error.localizedDescription }
    }
    func play(_ tracks: [Track], start: Int = 0) async {
        guard !tracks.isEmpty else { return }
        entries = tracks.map { QueueEntry(trackID: $0.id) }; index = min(max(0, start), tracks.count - 1)
        await prepare(at: index, autoplay: true)
    }
    func append(_ tracks: [Track], next: Bool = false) async {
        let added = tracks.map { QueueEntry(trackID: $0.id) }
        if entries.isEmpty { entries = added; if !added.isEmpty { await prepare(at: 0, autoplay: false) } }
        else if next { entries.insert(contentsOf: added, at: min(index + 1, entries.count)) }
        else { entries += added }
        scheduleNext(); persist()
    }
    func toggle() {
        if wantsPlaying || state == .playing { pause() }
        else if current != nil {
            if state == .failed || streamEnded { let at = stream != nil && !streamEnded ? position : 0; Task { await prepare(at: index, autoplay: true, position: at) }; return }
            error = nil; wantsPlaying = true
            if let stream { stream.play() } else { player.play() }
            updateNowPlaying()
        }
    }
    func pause() { wantsPlaying = false; player.pause(); stream?.pause(); if current != nil && state != .failed { state = .paused }; persist(); updateNowPlaying() }
    func next() async { if index + 1 < entries.count { await prepare(at: index + 1, autoplay: wantsPlaying) } }
    func previous() async { if position > 3 { seek(0) } else if index > 0 { await prepare(at: index - 1, autoplay: wantsPlaying) } }
    func select(_ entryID: String) async { if let i = entries.firstIndex(where: { $0.id == entryID }) { await prepare(at: i, autoplay: true) } }
    func seek(_ seconds: Double) {
        seekGeneration += 1; let token = generation, seekToken = seekGeneration
        Task { _ = await performSeek(seconds, token: token, seekToken: seekToken) }
    }
    private func performSeek(_ seconds: Double, token: Int, seekToken: Int) async -> Bool {
        guard token == generation, seekToken == seekGeneration, let current else { return false }
        let target = min(max(0, seconds), current.duration)
        if let stream { stream.seek(to: target); streamEnded = false; position = target; persist(); updateNowPlaying(); return true }
        let success = await withCheckedContinuation { continuation in
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { continuation.resume(returning: $0) }
        }
        guard token == generation, seekToken == seekGeneration, success else { return false }
        position = target; persist(); updateNowPlaying(); return true
    }
    func remove(_ id: String) async {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        let wasCurrent = i == index, playing = wantsPlaying
        entries.remove(at: i)
        if entries.isEmpty { stop(); return }
        if i < index { index -= 1 }
        if wasCurrent { await prepare(at: min(index, entries.count - 1), autoplay: playing) } else { scheduleNext(); persist() }
    }
    func move(_ id: String, delta: Int) async {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries.indices.contains(i + delta) else { return }
        let currentID = entries.indices.contains(index) ? entries[index].id : nil
        entries.swapAt(i, i + delta); if let currentID { index = entries.firstIndex(where: { $0.id == currentID }) ?? index }
        scheduleNext(); persist()
    }
    func removeTracks(_ trackIDs: Set<String>) async {
        let old = QueueSnapshot(entries: entries, index: index, position: position)
        let updated = old.removingTracks(trackIDs)
        guard updated.entries != entries else { return }
        let retainedCurrent = entries.indices.contains(index) && !trackIDs.contains(entries[index].trackID) && current != nil
        entries = updated.entries; index = updated.index
        if entries.isEmpty { stop() }
        else if retainedCurrent { scheduleNext(); persist() }
        else { await prepare(at: index, autoplay: false) }
    }
    func stop() { preparationTask?.cancel(); preparationTask = nil; prefetchTask?.cancel(); prefetchTask = nil; upcomingGeneration += 1; generation += 1; wantsPlaying = false; player.pause(); stream?.stop(); streamEnded = false; player.removeAllItems(); entries.removeAll(); itemEntries.removeAll(); current = nil; currentAlbum = nil; currentFile = nil; nextFile = nil; position = 0; index = 0; state = .idle; persist(); MPNowPlayingInfoCenter.default().nowPlayingInfo = nil }
    func persist() {
        let snapshot = QueueSnapshot(entries: entries, index: index, position: position)
        Task { try? await db.setPreference("queue", value: snapshot) }
    }
    /// Refresh paths/redirects after a scan without restarting the current audio stream.
    func refreshLibraryReferences() async {
        var redirects: [String: String] = [:]
        for id in Set(entries.map(\.trackID)) { redirects[id] = try? await db.resolvedLibraryID(id) }
        for i in entries.indices { entries[i].trackID = redirects[entries[i].trackID] ?? entries[i].trackID }
        if let id = current?.id, let refreshed = try? await db.track(id), current?.id == id {
            current = refreshed
            let album = try? await db.album(refreshed.albumID)
            if current?.id == refreshed.id { currentAlbum = album }
        }
        scheduleNext(); persist(); updateNowPlaying()
    }
    private func fail(_ message: String) { player.pause(); stream?.pause(); wantsPlaying = false; state = .failed; error = message; AppLog.playback.error("Playback failed: \(message, privacy: .private)"); persist(); updateNowPlaying() }
    private func fileURL(_ track: Track) async throws -> AudioFileLease {
        guard track.supported else { throw AppError.message("\(track.format)은 아직 재생을 지원하지 않습니다.") }
        guard let root = try await db.roots().first(where: { $0.id == track.rootID }) else { throw AppError.message("음원의 라이브러리를 찾을 수 없습니다.") }
        if root.smb != nil { return try await files.resolve(root: root, track: track) }
        let rootURL = URL(fileURLWithPath: root.path, isDirectory: true)
        let volume = try? rootURL.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        if let expected = root.volumeID, let volume, volume != expected { throw AppError.message("등록한 볼륨과 다른 볼륨입니다.") }
        let url = rootURL.appendingPathComponent(track.relativePath)
        return try await files.resolve(url, size: track.size, modified: track.modified)
    }
    private func prepare(at newIndex: Int, autoplay: Bool, position: Double = 0) async {
        guard entries.indices.contains(newIndex) else { return }
        preparationTask?.cancel(); prefetchTask?.cancel(); upcomingGeneration += 1
        generation += 1; let token = generation; wantsPlaying = autoplay; state = .preparing; error = nil
        player.pause(); index = newIndex; changingItems = true; player.removeAllItems(); itemEntries.removeAll(); itemObservation = nil
        do {
            guard let track = try await db.track(entries[newIndex].trackID) else { throw AppError.message("색인에서 트랙을 찾을 수 없습니다.") }
            guard token == generation else { return }
            let preparation = Task { try await fileURL(track) }; preparationTask = preparation
            let file = try await preparation.value, album = try await db.album(track.albumID)
            guard token == generation else { return }
            preparationTask = nil
            currentFile = file; nextFile = nil
            let url = file.url
            current = track; currentAlbum = album; self.position = position
            AppLog.playback.info("Prepared track \(track.id.prefix(12), privacy: .public)")
            if let stream {
                streamEnded = false
                stream.load(.init(id: entries[newIndex].id, url: url), at: position, autoplay: wantsPlaying)
                changingItems = false
                scheduleNext()
                guard token == generation else { return }
                if !wantsPlaying { state = .paused }
                persist(); updateNowPlaying(); return
            }
            let item = playerItem(file: url, track: track); itemEntries[ObjectIdentifier(item)] = entries[newIndex].id
            player.insert(item, after: nil); observeItem(item); changingItems = false
            guard token == generation else { return }
            if position > 0 {
                seekGeneration += 1
                _ = await performSeek(position, token: token, seekToken: seekGeneration)
            }
            guard token == generation else { return }
            if wantsPlaying { player.play() } else { state = .paused }
            scheduleNext()
            persist(); updateNowPlaying()
        } catch { guard token == generation else { return }; changingItems = false; fail(error.localizedDescription) }
    }
    private func scheduleNext() {
        prefetchTask?.cancel(); upcomingGeneration += 1
        let upcomingToken = upcomingGeneration, token = generation
        prefetchTask = Task { [weak self] in await self?.prepareNext(token: token, upcomingToken: upcomingToken) }
    }
    private func prepareNext(token: Int, upcomingToken: Int) async {
        guard !Task.isCancelled, token == generation, upcomingToken == upcomingGeneration else { return }
        nextFile = nil
        if let stream {
            stream.setNext(nil)
            guard entries.indices.contains(index + 1) else { return }
            let entry = entries[index + 1]
            guard let track = try? await db.track(entry.trackID), let file = try? await fileURL(track), !Task.isCancelled, token == generation, upcomingToken == upcomingGeneration,
                  stream === self.stream, entries.indices.contains(index + 1), entries[index + 1].id == entry.id else { return }
            nextFile = file
            stream.setNext(.init(id: entry.id, url: file.url))
            return
        }
        guard let currentItem = player.currentItem else { return }
        for item in player.items() where item !== currentItem { player.remove(item); itemEntries.removeValue(forKey: ObjectIdentifier(item)) }
        guard entries.indices.contains(index + 1) else { return }
        let entry = entries[index + 1]
        guard let track = try? await db.track(entry.trackID), let file = try? await fileURL(track), !Task.isCancelled, token == generation, upcomingToken == upcomingGeneration, player.currentItem === currentItem, entries.indices.contains(index + 1), entries[index + 1].id == entry.id else { return }
        nextFile = file
        let item = playerItem(file: file.url, track: track); itemEntries[ObjectIdentifier(item)] = entry.id
        if player.canInsert(item, after: currentItem) { player.insert(item, after: currentItem) }
    }
    private func playerItem(file: URL, track: Track) -> AVPlayerItem {
        let item = AVPlayerItem(url: file)
        // Native FLAC playback can run beyond EOF after seeking without posting an end event.
        // STREAMINFO's sample count gives the exact boundary for queue advancement.
        if track.format == "FLAC", track.duration.isFinite, track.duration > 0, track.sampleRate > 0 {
            item.forwardPlaybackEndTime = CMTime(seconds: track.duration, preferredTimescale: Int32(track.sampleRate))
        }
        return item
    }
    private func itemChanged(_ identity: ObjectIdentifier?) async {
        guard !changingItems, let identity, let id = itemEntries[identity] else { return }
        await advance(to: id)
    }
    /// The queue moved on by itself: the next item started playing gaplessly.
    private func advance(to id: String) async {
        guard let newIndex = entries.firstIndex(where: { $0.id == id }), newIndex != index else { return }
        generation += 1; let token = generation; index = newIndex; position = 0
        currentFile = nextFile; nextFile = nil
        do {
            let track = try await db.track(entries[index].trackID)
            let album: Album?
            if let track { album = try await db.album(track.albumID) } else { album = nil }
            guard token == generation else { return }
            current = track; currentAlbum = album
            if stream == nil, let item = player.currentItem { observeItem(item) }
            scheduleNext(); persist(); updateNowPlaying()
        } catch { fail(error.localizedDescription) }
    }
    private func observeItem(_ item: AVPlayerItem) {
        itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, item === self.player.currentItem else { return }
                if item.status == .failed { self.fail("오디오 디코딩 또는 출력 준비에 실패했습니다.") }
            }
        }
    }
    private func updateNowPlaying() {
        guard let current else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: current.title, MPMediaItemPropertyArtist: currentAlbum?.artist ?? "", MPMediaItemPropertyAlbumTitle: currentAlbum?.title ?? "", MPMediaItemPropertyPlaybackDuration: current.duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: position, MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? 1.0 : 0.0]
        MPNowPlayingInfoCenter.default().playbackState = state == .playing ? .playing : .paused
    }
    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in Task { @MainActor in if self?.state != .playing { self?.toggle() } }; return .success }
        center.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in await self?.next() }; return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in await self?.previous() }; return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(event.positionTime) }; return .success
        }
    }
}
