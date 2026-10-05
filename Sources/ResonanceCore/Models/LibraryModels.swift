import Foundation

public struct LibraryRoot: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID().uuidString
    public var path: String
    public var bookmark: Data?
    public var volumeID: String?
    public var smb: SMBSource?
    public var exclusions = ["__backup__", "lost+found", "Covers", "@eaDir", "$RECYCLE.BIN"]
    public var status = "연결됨"
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
    public var navigationID: String { "root:" + id }
    public init(path: String, bookmark: Data? = nil, volumeID: String? = nil) { self.path = path; self.bookmark = bookmark; self.volumeID = volumeID }
}

public struct LibrarySection: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var rootID: String
    public var relativePath: String
    public var name: String
    public var hidden = false
    public var order = 0
    public init(rootID: String, relativePath: String, name: String) {
        self.id = TextKey.id(rootID, relativePath); self.rootID = rootID; self.relativePath = relativePath; self.name = name
    }
    static func folderPath(for musicPath: String) -> String {
        let parts = musicPath.split(separator: "/")
        return parts.count > 1 ? String(parts[0]) : ""
    }
    static func folderName(rootPath: String, relativePath: String) -> String {
        relativePath.isEmpty ? URL(fileURLWithPath: rootPath).lastPathComponent : relativePath
    }
}

public struct Album: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var rootID: String
    public var sectionID: String
    public var folder: String
    public var title: String
    public var artist: String
    public var date: String
    public var label: String
    public var barcode: String
    public var musicBrainzID: String
    public var artwork: String?
    public var attachments: [String]
    public var trackCount: Int
    public var duration: Double
    public var favorite = false
    public var year: String { String(date.prefix(4)) }
    public init(id: String, rootID: String, sectionID: String, folder: String, title: String, artist: String, date: String = "", label: String = "", barcode: String = "", musicBrainzID: String = "", artwork: String? = nil, attachments: [String] = [], trackCount: Int = 0, duration: Double = 0) {
        self.id = id; self.rootID = rootID; self.sectionID = sectionID; self.folder = folder; self.title = title; self.artist = artist; self.date = date; self.label = label; self.barcode = barcode; self.musicBrainzID = musicBrainzID; self.artwork = artwork; self.attachments = attachments; self.trackCount = trackCount; self.duration = duration
    }
}

public struct Track: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var rootID: String
    public var albumID: String
    public var relativePath: String
    public var title: String
    public var number: Int
    public var disc: Int
    public var duration: Double
    public var format: String
    public var sampleRate: Int
    public var bitDepth: Int
    public var channels: Int
    public var isrc: String
    public var size: Int64
    public var modified: Double
    public var metadataStatus: String?
    public var available: Bool
    public var tags: [String: [String]]
    public var credits: [Credit]
    public var recordingID: String { "recording:" + id }
    public var sourceFormat: String {
        if metadataStatus == "deferred-format" { return format + " · 태그 읽기 보류" }
        if sampleRate > 0 { return "\(format) · \(bitDepth > 0 ? "\(bitDepth)-bit / " : "")\(String(format: "%g", Double(sampleRate) / 1000)) kHz" }
        return format
    }
    public var supported: Bool { ["FLAC", "MP3", "M4A", "AAC", "WAV", "AIFF", "AIF"].contains(format) }
    public init(id: String, rootID: String, albumID: String, relativePath: String, title: String, number: Int = 0, disc: Int = 1, duration: Double = 0, format: String = "FLAC", sampleRate: Int = 0, bitDepth: Int = 0, channels: Int = 0, isrc: String = "", size: Int64 = 0, modified: Double = 0, available: Bool = true, tags: [String: [String]] = [:], credits: [Credit] = []) {
        self.id = id; self.rootID = rootID; self.albumID = albumID; self.relativePath = relativePath; self.title = title; self.number = number; self.disc = disc; self.duration = duration; self.format = format; self.sampleRate = sampleRate; self.bitDepth = bitDepth; self.channels = channels; self.isrc = isrc; self.size = size; self.modified = modified; self.available = available; self.tags = tags; self.credits = credits
    }
}

public struct Credit: Codable, Hashable, Identifiable, Sendable {
    public var id: String { TextKey.id(artistID, role, source) }
    public var artistID: String
    public var name: String
    public var role: String
    public var source: String
    public var attributes: [String]?
    public init(artistID: String, name: String, role: String, source: String = "local", attributes: [String]? = nil) { self.artistID = artistID; self.name = name; self.role = role; self.source = source; self.attributes = attributes }
    public var roleLabel: String {
        ["composer": "작곡", "performer": "연주", "conductor": "지휘", "ensemble": "앙상블", "arranger": "편곡", "lyricist": "작사"][role] ?? role
    }
}

public struct Artist: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var role: String
    public var aliases: [String]
    public var externalID: String?
    public init(id: String, name: String, role: String, aliases: [String] = [], externalID: String? = nil) { self.id = id; self.name = name; self.role = role; self.aliases = aliases; self.externalID = externalID }
}

public struct Work: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var parentID: String?
    public var parentTitle: String?
    public var source: String
    public init(id: String, title: String, parentID: String? = nil, source: String = "local", parentTitle: String? = nil) { self.id = id; self.title = title; self.parentID = parentID; self.source = source; self.parentTitle = parentTitle }
}

public struct SearchHit: Identifiable, Sendable {
    public var id: String { kind + ":" + entityID }
    public var kind: String
    public var entityID: String
    public var title: String
    public var subtitle: String
    public var albumID: String?
}

public struct ScanProgress: Codable, Sendable {
    public var discovered = 0
    public var processed = 0
    public var reused = 0
    public var albums = 0
    public var errors: [String] = []
    public var current = ""
    public var finished = false
    public var cancelled = false
    // Optional fields keep scan history written by older app versions readable.
    public var issues: [ScanIssue]? = nil
    public var phase: String? = nil
    public init() {}
}

public struct QueueEntry: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID().uuidString
    public var trackID: String
    public init(trackID: String) { self.trackID = trackID }
}

public struct QueueSnapshot: Codable, Sendable {
    public var entries: [QueueEntry]
    public var index: Int
    public var position: Double
    public init(entries: [QueueEntry] = [], index: Int = 0, position: Double = 0) { self.entries = entries; self.index = index; self.position = position }

    public func removingTracks(_ trackIDs: Set<String>) -> QueueSnapshot {
        let kept = entries.filter { !trackIDs.contains($0.trackID) }
        guard !kept.isEmpty else { return QueueSnapshot() }
        if entries.indices.contains(index), let newIndex = kept.firstIndex(where: { $0.id == entries[index].id }) {
            return QueueSnapshot(entries: kept, index: newIndex, position: position)
        }
        let preceding = entries.prefix(max(0, min(index, entries.count))).filter { !trackIDs.contains($0.trackID) }.count
        return QueueSnapshot(entries: kept, index: min(preceding, kept.count - 1), position: 0)
    }
}
