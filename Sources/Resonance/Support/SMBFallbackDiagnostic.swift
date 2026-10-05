#if DEBUG
import AVFoundation
import ResonanceCore

/// Opt-in verification from the packaged app, with an isolated database and a nonexistent local root.
enum SMBFallbackDiagnostic {
    static func run(folder: URL, roots: [LibraryRoot]) async {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("ResonanceSMBVerification-" + UUID().uuidString)
        var report: [String: Any] = ["folder": folder.path, "passed": false, "workspace": workspace.path]
        let reportURL = AppPaths.support.appendingPathComponent("SMBDiagnostics.json")
        func save() { if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: reportURL, options: .atomic) } }
        save()
        do {
            guard let original = roots.filter({ $0.smb != nil && folder.path.hasPrefix($0.path + "/") }).max(by: { $0.path.count < $1.path.count }), var source = original.smb else { throw AppError.message("먼저 설정에서 해당 공유를 직접 SMB로 연결하세요.") }
            source.subpath = try source.path(String(folder.path.dropFirst(original.path.count + 1)))
            let pool = SMBSessionPool { try await KeychainStore.readAsync($0.credentialAccount) }
            let transport = try await pool.session(source)
            let rootListing = try await transport.list(original.smb!.path(""))
            report["sourceRootListing"] = rootListing.map { ["name": $0.name, "directory": $0.isDirectory, "symbolicLink": $0.isSymbolicLink] as [String: Any] }
            let listing = try await transport.list(source.path(""))
            report["listedFLAC"] = listing.filter { $0.name.lowercased().hasSuffix(".flac") }.map { ["name": $0.name, "utf8": Data($0.name.utf8).base64EncodedString(), "size": $0.size] as [String: Any] }
            save()
            let db = try LibraryDatabase(path: workspace.appendingPathComponent("test.sqlite").path)
            var root = LibraryRoot(path: workspace.appendingPathComponent("never-mounted").path); root.smb = source
            try await db.saveRoot(root)
            let scanner = LibraryScanner(database: db, cache: workspace.appendingPathComponent("artwork"), remote: pool)
            let result = try await scanner.scan(root: root) { _ in }
            let albums = try await db.albums(rootID: root.id)
            var tracks: [Track] = []
            for album in albums { tracks += try await db.tracks(albumID: album.id) }
            let metrics = try await db.smbReadMetrics(rootID: root.id)
            report["logicalMetadataBytes"] = metrics.reduce(0) { $0 + $1.bytes }
            report["rangeRequests"] = metrics.reduce(0) { $0 + $1.requests }
            report["finished"] = result.finished; report["tracks"] = tracks.count; report["errors"] = result.errors
            report["localRootExists"] = FileManager.default.fileExists(atPath: root.path)
            var headers: [[String: Any]] = []
            for entry in listing where !entry.isDirectory && result.errors.contains(where: { $0.hasPrefix(entry.name + ": ") }) {
                let data = try await transport.read(source.path(entry.name), offset: 0, count: Int(min(32, entry.size)))
                headers.append(["name": entry.name, "firstBytesHex": data.map { String(format: "%02x", $0) }.joined(), "size": entry.size])
            }
            report["failedHeaders"] = headers
            save()
            let second = try await scanner.scan(root: root) { _ in }
            report["secondScanReused"] = second.reused
            let files = AudioFileAccess(directory: workspace.appendingPathComponent("audio-cache")) { try await KeychainStore.readAsync($0.credentialAccount) }
            var decoded: [[String: Any]] = []
            for track in tracks where !CommandLine.arguments.contains("--smb-tags-only") {
                let file = try await files.resolve(root: root, track: track)
                let audio = try AVAudioFile(forReading: file.url)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 16384) else { throw AppError.message("PCM buffer allocation failed") }
                var frames: Int64 = 0
                while audio.framePosition < audio.length { try audio.read(into: buffer, frameCount: AVAudioFrameCount(min(16384, audio.length - audio.framePosition))); if buffer.frameLength == 0 { break }; frames += Int64(buffer.frameLength) }
                guard frames > 0, frames == audio.length,
                      track.duration <= 0 || abs(Double(frames) / audio.fileFormat.sampleRate - track.duration) <= 1 / audio.fileFormat.sampleRate else {
                    throw AppError.message("Decoded audio does not match the declared sample count")
                }
                let reused = try await files.resolve(root: root, track: track)
                guard reused.url == file.url else { throw AppError.message("Cache reuse failed") }
                var item: [String: Any] = ["path": track.relativePath, "size": track.size, "decodedFrames": frames, "cacheReused": true]
                if let local = try? MetadataReader.flac(folder.appendingPathComponent(track.relativePath)) {
                    item["matchesLocalTags"] = local.tags == track.tags && local.sampleRate == track.sampleRate && local.bitDepth == track.bitDepth && local.channels == track.channels && abs(local.duration - track.duration) < 0.001
                }
                decoded.append(item); file.release(); reused.release()
                report["decoded"] = decoded; save()
            }
            report["databaseIntegrity"] = try await db.integrityCheck()
            report["passed"] = result.finished && result.errors.isEmpty && !tracks.isEmpty && second.reused == tracks.count && !FileManager.default.fileExists(atPath: root.path)
        } catch { report["error"] = error.localizedDescription }
        save()
    }
}
#endif
