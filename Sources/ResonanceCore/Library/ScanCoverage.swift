import Foundation

/// Only a completed traversal can prove absence. Failed or intentionally skipped paths remain unknown.
struct ScanCoverage: Sendable {
    var files: ExactPathSet = []
    var folders: ExactPathSet = [""]
    var collections: ExactPathSet = []
    var protectedPaths: ExactPathSet = []

    func isProtected(_ path: String) -> Bool {
        protectedPaths.contains { path.isEmpty || $0.isEmpty || Data(path.utf8) == Data($0.utf8) || Data(path.utf8).starts(with: Data(($0 + "/").utf8)) || Data($0.utf8).starts(with: Data((path + "/").utf8)) }
    }
    func isMissing(_ path: String) -> Bool { !files.contains(path) && !isProtected(path) }
    func folderIsMissing(_ path: String) -> Bool { !folders.contains(path) && !isProtected(path) }
}

enum RelocationFingerprint {
    private struct Metadata: Encodable {
        let title: String
        let disc: Int
        let number: Int
        let duration: Double
        let format: String
        let sampleRate: Int
        let bitDepth: Int
        let channels: Int
        let size: Int64
        let tags: [String: [String]]
    }
    static func track(_ track: Track) throws -> String? {
        // Empty tags/unsupported placeholders are not enough evidence to move a recording.
        guard track.supported, track.size > 0, track.duration > 0, track.duration.isFinite,
              !(track.tags["ALBUM"]?.first ?? "").isEmpty else { return nil }
        let metadata = Metadata(title: track.title, disc: track.disc, number: track.number, duration: track.duration,
                                format: track.format, sampleRate: track.sampleRate, bitDepth: track.bitDepth,
                                channels: track.channels, size: track.size, tags: track.tags)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return TextKey.hash(String(decoding: try encoder.encode(metadata), as: UTF8.self))
    }
    static func album(_ tracks: [Track]) throws -> String? {
        let keys = try tracks.compactMap { try track($0) }
        guard !keys.isEmpty, keys.count == tracks.count, Set(keys).count == keys.count else { return nil }
        return TextKey.hash(keys.sorted().joined(separator: ":"))
    }
}
