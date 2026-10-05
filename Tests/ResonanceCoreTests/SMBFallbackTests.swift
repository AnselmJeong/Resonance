import Testing
import AVFoundation
@testable import ResonanceCore

@Suite struct SMBFallbackTests {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SMBTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func audio() -> Data {
        var stream = Data(repeating: 0, count: 34)
        let packed = UInt64(8000) << 44 | UInt64(15) << 36 | UInt64(8000)
        for i in 0..<8 { stream[10 + i] = UInt8((packed >> UInt64((7 - i) * 8)) & 255) }
        return Data("fLaC".utf8) + Data([128, 0, 0, 34]) + stream
    }
    private actor Counter {
        var count = 0
        func increment() { count += 1 }
    }
    @Test func localFilesNeverUseSMBAndMissingUnconfiguredFilesRemainErrors() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let calls = Counter(), data = audio(), source = dir.appendingPathComponent("song.flac")
        try data.write(to: source)
        let access = AudioFileAccess(directory: dir.appendingPathComponent("cache"), capacity: 1000, password: { _ in "fixture" }) { _, _, _, _ in await calls.increment() }
        let lease = try await access.resolve(source, size: 0, modified: 0)
        #expect(lease.url == source)
        await #expect(throws: (any Error).self) { try await access.resolve(dir.appendingPathComponent("missing.flac"), size: 42, modified: 1) }
        #expect(await calls.count == 0)
    }
    @Test func completeDownloadIsReusedAndModificationInvalidatesCache() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let data = audio(), calls = Counter(), source = dir.appendingPathComponent("Mélodie.flac")
        let access = AudioFileAccess(directory: dir.appendingPathComponent("cache"), capacity: 1000, password: { _ in "fixture" }) { _, path, _, target in
            #expect(path == "Mélodie.flac"); await calls.increment(); try data.write(to: target)
        }
        await access.configure([SMBConnection(mountPath: dir.path, server: "test.local", share: "Music", username: "user", enabled: true)])
        let first = try await access.resolve(source, size: Int64(data.count), modified: 1)
        let second = try await access.resolve(source, size: Int64(data.count), modified: 1)
        #expect(first.url == second.url); #expect(try Data(contentsOf: first.url) == data)
        #expect(await calls.count == 1)
        let changed = try await access.resolve(source, size: Int64(data.count), modified: 2)
        #expect(changed.url != first.url); #expect(await calls.count == 2)
    }
    @Test func partialAndInvalidAudioNeverEnterCacheOrBlockOtherFiles() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let data = audio(), calls = Counter(), cache = dir.appendingPathComponent("cache")
        let access = AudioFileAccess(directory: cache, capacity: 1000, password: { _ in "fixture" }) { _, path, _, target in
            await calls.increment()
            try (path == "short.flac" ? data.prefix(8) : path == "invalid.flac" ? Data(repeating: 0, count: data.count) : data).write(to: target)
        }
        await access.configure([SMBConnection(mountPath: dir.path, server: "test.local", share: "Music", username: "user", enabled: true)])
        for name in ["short.flac", "invalid.flac"] {
            await #expect(throws: (any Error).self) { try await access.resolve(dir.appendingPathComponent(name), size: Int64(data.count), modified: 1) }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)
        let valid = try await access.resolve(dir.appendingPathComponent("valid.flac"), size: Int64(data.count), modified: 1)
        #expect(try MetadataReader.flac(valid.url).duration == 1)
        #expect(await calls.count == 3)
    }
    @Test func cancellationCleansUp() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let data = audio()
        let cancelCache = dir.appendingPathComponent("cancel-cache"), started = Counter()
        let cancellable = AudioFileAccess(directory: cancelCache, capacity: 1000, password: { _ in "fixture" }) { _, _, _, target in
            try data.prefix(4).write(to: target); await started.increment(); try await Task.sleep(for: .seconds(30))
        }
        await cancellable.configure([SMBConnection(mountPath: dir.path, server: "test.local", share: "Music", username: "user", enabled: true)])
        let task = Task { try await cancellable.resolve(dir.appendingPathComponent("cancel.flac"), size: Int64(data.count), modified: 1) }
        while await started.count == 0 { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") } catch { #expect(error is CancellationError) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(try FileManager.default.contentsOfDirectory(atPath: cancelCache.path).isEmpty)
    }
    @Test func simultaneousReadsShareOneDownloadAndLeasePreventsEviction() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let data = audio(), calls = Counter(), source = dir.appendingPathComponent("same.flac")
        let access = AudioFileAccess(directory: dir.appendingPathComponent("cache"), capacity: Int64(data.count), password: { _ in "fixture" }) { _, _, _, target in
            await calls.increment(); try await Task.sleep(for: .milliseconds(50)); try data.write(to: target)
        }
        await access.configure([SMBConnection(mountPath: dir.path, server: "test.local", share: "Music", username: "user", enabled: true)])
        async let a = access.resolve(source, size: Int64(data.count), modified: 1)
        async let b = access.resolve(source, size: Int64(data.count), modified: 1)
        let (first, second) = try await (a, b)
        #expect(first.url == second.url); #expect(await calls.count == 1)
        await #expect(throws: (any Error).self) { try await access.resolve(dir.appendingPathComponent("next.flac"), size: Int64(data.count), modified: 1) }
        #expect(FileManager.default.fileExists(atPath: first.url.path))
        first.release(); second.release()
        // Releases cross back onto the actor asynchronously.
        try await Task.sleep(for: .milliseconds(20))
        let next = try await access.resolve(dir.appendingPathComponent("next.flac"), size: Int64(data.count), modified: 1)
        #expect(next.url != first.url); #expect(!FileManager.default.fileExists(atPath: first.url.path))
    }
    @Test func id3WrappedPlaybackCachePreservesNativeBytesAndSurvivesRestart() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let payloadCount = 2 * 1024 * 1024 + 71
        let payload = Data((0..<payloadCount).map { UInt8($0 % 251) })
        let native = audio() + payload
        let wrapped = Data("ID3".utf8) + Data([3, 0, 0, 0, 0, 0, 17]) + Data(repeating: 0, count: 17)
            + native + Data("TAG".utf8) + Data(repeating: 0, count: 125)
        let cache = dir.appendingPathComponent("cache"), source = dir.appendingPathComponent("wrapped.flac")
        let connections = [SMBConnection(mountPath: dir.path, server: "test.local", share: "Music", username: "user", enabled: true)]
        let access = AudioFileAccess(directory: cache, capacity: 8 * 1024 * 1024, password: { _ in "fixture" }) { _, _, _, target in try wrapped.write(to: target) }
        await access.configure(connections)
        let lease = try await access.resolve(source, size: Int64(wrapped.count), modified: 1)
        #expect(try Data(contentsOf: lease.url) == native)
        let reopened = AudioFileAccess(directory: cache, capacity: 8 * 1024 * 1024, password: { _ in throw CancellationError() }) { _, _, _, _ in Issue.record("Normalized cache downloaded again") }
        await reopened.configure(connections)
        let again = try await reopened.resolve(source, size: Int64(wrapped.count), modified: 1)
        #expect(again.url == lease.url)
        var tampered = native; tampered[tampered.count - 1] ^= 1
        try tampered.write(to: lease.url)
        await #expect(throws: (any Error).self) { try await reopened.resolve(source, size: Int64(wrapped.count), modified: 1) }
        let withoutTrailer = dir.appendingPathComponent("prefix-only.flac")
        try wrapped.dropLast(128).write(to: withoutTrailer)
        try FLACPlaybackCache.prepare(withoutTrailer, originalSize: Int64(wrapped.count - 128))
        #expect(try Data(contentsOf: withoutTrailer) == native)
        let unwrapped = dir.appendingPathComponent("native.flac")
        let nativeWithTAGBytes = native + Data("TAG".utf8) + Data(repeating: 0, count: 125)
        try nativeWithTAGBytes.write(to: unwrapped)
        try FLACPlaybackCache.prepare(unwrapped, originalSize: Int64(nativeWithTAGBytes.count))
        #expect(try Data(contentsOf: unwrapped) == nativeWithTAGBytes)
    }
    @Test func commandAndMappingValidationRejectsInjectionAndTraversal() throws {
        for path in ["../a", "a/../b", "/a", "a//b", "a\\b", "a\0b"] { #expect(throws: (any Error).self) { try SMBSource.validatePath(path) } }
        for path in ["Mélodie #2 (Op. 34).flac", "a;b.flac", "a\"b.flac", "a\nb.flac"] { try SMBSource.validatePath(path) }
        let connection = SMBConnection(mountPath: "/Volumes/Music2", server: "192.168.0.11", share: "Music2", username: "aurender")
        #expect(try connection.remotePath(for: URL(fileURLWithPath: "/Volumes/Music2/Artist/Album/01.flac")) == "Artist/Album/01.flac")
        for path in ["/Volumes/Music2-other/01.flac", "/Volumes/Music2/../other/01.flac"] {
            #expect(throws: (any Error).self) { try connection.remotePath(for: URL(fileURLWithPath: path)) }
        }
        #expect(!AudioFileAccess.isMissingFile(NSError(domain: NSPOSIXErrorDomain, code: 13)))
    }
    @Test func cancellingOneWaiterDoesNotCancelAnother() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let data = audio(), calls = Counter(), source = dir.appendingPathComponent("shared.flac")
        let access = AudioFileAccess(directory: dir.appendingPathComponent("cache"), capacity: 1000, password: { _ in "fixture" }) { _, _, _, target in
            await calls.increment(); try await Task.sleep(for: .milliseconds(150)); try data.write(to: target)
        }
        await access.configure([SMBConnection(mountPath: dir.path, server: "test.local", share: "Music", username: "user", enabled: true)])
        let first = Task { try await access.resolve(source, size: Int64(data.count), modified: 1) }
        while await calls.count == 0 { await Task.yield() }
        let second = Task { try await access.resolve(source, size: Int64(data.count), modified: 1) }
        try await Task.sleep(for: .milliseconds(40)); first.cancel()
        do { _ = try await first.value; Issue.record("Expected cancellation") } catch { #expect(error is CancellationError) }
        let lease = try await second.value
        #expect(try Data(contentsOf: lease.url) == data); #expect(await calls.count == 1)
    }
    @Test func restartRemovesPartialAndReusesVerifiedCache() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let data = audio(), cache = dir.appendingPathComponent("cache"), source = dir.appendingPathComponent("song.flac")
        let connections = [SMBConnection(mountPath: dir.path, server: "test.local", share: "Music", username: "user", enabled: true)]
        let first = AudioFileAccess(directory: cache, capacity: 1000, password: { _ in "fixture" }) { _, _, _, target in try data.write(to: target) }
        await first.configure(connections)
        let original = try await first.resolve(source, size: Int64(data.count), modified: 1)
        let stale = cache.appendingPathComponent("stale.partial")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        let reopened = AudioFileAccess(directory: cache, capacity: 1000, password: { _ in throw CancellationError() }) { _, _, _, _ in Issue.record("Cache hit downloaded") }
        await reopened.configure(connections)
        let reused = try await reopened.resolve(source, size: Int64(data.count), modified: 1)
        #expect(reused.url == original.url); #expect(!FileManager.default.fileExists(atPath: stale.path))
        try Data(repeating: 1, count: data.count).write(to: original.url)
        await #expect(throws: (any Error).self) { try await reopened.resolve(source, size: Int64(data.count), modified: 1) }
    }
}
