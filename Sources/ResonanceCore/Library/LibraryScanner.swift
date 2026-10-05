import Foundation

public actor LibraryScanner {
    private let db: LibraryDatabase
    private let cache: URL
    private let remote: SMBSessionPool?
    public init(database: LibraryDatabase, cache: URL, remote: SMBSessionPool? = nil) { self.db = database; self.cache = cache; self.remote = remote }
    private let formats: Set<String> = ["flac", "mp3", "m4a", "aac", "wav", "aiff", "aif", "ape", "cue"]

    public func scan(root: LibraryRoot, relativeFolder: String? = nil, progress: @escaping @Sendable (ScanProgress) async -> Void) async throws -> ScanProgress {
        let rootURL = URL(fileURLWithPath: root.path, isDirectory: true), fm = FileManager.default
        var state = ScanProgress(), scanID = UUID().uuidString
        if let relativeFolder { try SMBSource.validatePath(relativeFolder); guard root.smb != nil else { throw AppError.message("폴더 범위 스캔은 직접 SMB 소스에서 지원합니다.") } }
        state.issues = []; state.phase = "음악 파일을 찾고 있습니다"
        await progress(state)
        var lastProgress = Date.distantPast
        var isDirectory: ObjCBool = false
        guard root.smb != nil || (fm.fileExists(atPath: root.path, isDirectory: &isDirectory) && isDirectory.boolValue) else { throw AppError.message("라이브러리가 연결되어 있지 않습니다. 이전 색인은 유지됩니다.") }
        let volume = root.smb == nil ? try rootURL.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString : nil
        if let expected = root.volumeID, let volume, expected != volume { throw AppError.message("등록한 볼륨과 다릅니다. 이전 색인을 유지합니다.") }
        var walkErrors: [String] = [], walkIssues: [ScanIssue] = [], coverage = ScanCoverage()
        let resolvedRoot = root.smb == nil ? rootURL.resolvingSymlinksInPath().path : root.path
        func relativeFailurePath(_ url: URL) -> String {
            for base in [root.path, resolvedRoot] where url.path.hasPrefix(base + "/") { return String(url.path.dropFirst(base.count + 1)) }
            return "" // Unknown coverage protects the whole root.
        }
        let enumerator = root.smb == nil ? fm.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles], errorHandler: { url, error in walkErrors.append("읽기 실패: \(url.lastPathComponent)"); walkIssues.append(ScanIssue(path: url.path, reason: error.localizedDescription)); coverage.protectedPaths.insert(relativeFailurePath(url)); return true }) : nil
        var transport: (any SMBTransport)?
        var remoteEntries: [(String, SMBFileInfo)] = []
        var ambiguousPaths: [String] = []
        func noteAmbiguities(_ entries: [SMBFileInfo], parent: String) {
            for siblings in Dictionary(grouping: entries, by: \.name).values where siblings.count > 1 {
                for entry in siblings { ambiguousPaths.append(parent.isEmpty ? entry.name : parent + "/" + entry.name) }
            }
        }
        if let source = root.smb {
            try source.validate()
            guard let remote else { throw AppError.message("SMB 연결 설정이 없습니다.") }
            await remote.reset() // A new scan is an explicit retry after a disconnected session.
            transport = try await remote.session(source)
            let scope = relativeFolder ?? ""
            let entries = try await transport!.list(source.path(scope))
            noteAmbiguities(entries, parent: scope)
            remoteEntries = entries.map { (scope.isEmpty ? $0.name : scope + "/" + $0.name, $0) }.reversed()
            // A user-requested album refresh adds/updates only. It cannot prove absence outside its scope.
            if relativeFolder != nil { coverage.protectedPaths.insert("") }
        } else if enumerator == nil { throw AppError.message("폴더를 읽을 수 없습니다.") }
        let existingSections = try await db.sections()
        var sections = Dictionary(uniqueKeysWithValues: existingSections.filter { $0.rootID == root.id }.map { (Data($0.relativePath.utf8), $0) })
        var folderAssets: [String: (URL?, [String])] = [:]
        var pending: [String: (Album, [Track])] = [:]
        var identities = try await db.albumIdentities(rootID: root.id)
        let existingTracks = try await db.scanTracks(rootID: root.id)
        // Canonical equality is used only to locate a unique legacy identity. Remote I/O always
        // uses the exact enumerated bytes, and any ambiguous ancestor forbids this migration.
        let legacyPaths = Dictionary(grouping: existingTracks.values.filter { $0.metadataStatus == nil }, by: \.relativePath)
        let legacyAlbums = Dictionary(grouping: existingTracks.values.filter { $0.metadataStatus == nil }, by: { MountedAlbumIdentity(path: $0.relativePath, tags: $0.tags) }).mapValues { Set($0.map(\.albumID)) }
        var groupingKeys: [String: String] = [:]
        do {
            while true {
                try Task.checkCancellation()
                let url: URL, relative: String
                var values = ScanFileValues()
                if let (path, entry) = remoteEntries.popLast(), root.smb != nil {
                    relative = path; url = rootURL.appendingPathComponent(path)
                    if entry.name.hasPrefix(".") { coverage.protectedPaths.insert(relative); continue }
                    values.isDirectory = entry.isDirectory; values.isSymbolicLink = entry.isSymbolicLink
                    values.fileSize = Int(entry.size); values.contentModificationDate = Date(timeIntervalSince1970: entry.modified)
                } else if root.smb == nil, let localURL = enumerator?.nextObject() as? URL {
                    url = localURL
                    relative = url.pathComponents.suffix(enumerator!.level).joined(separator: "/")
                    do { values = ScanFileValues(try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])) }
                    catch { coverage.protectedPaths.insert(relative); state.errors.append("\(relative): \(error.localizedDescription)"); state.issues?.append(ScanIssue(path: url.path, reason: error.localizedDescription)); continue }
                } else { break }
                if Date().timeIntervalSince(lastProgress) >= 0.3 {
                    state.current = url.lastPathComponent
                    await progress(state); lastProgress = Date()
                }
                if values.isSymbolicLink == true { coverage.protectedPaths.insert(relative); if values.isDirectory == true { enumerator?.skipDescendants() }; continue }
                if values.isDirectory == true {
                    coverage.folders.insert(relative)
                    if root.exclusions.contains(where: { $0.caseInsensitiveCompare(url.lastPathComponent) == .orderedSame }) { coverage.protectedPaths.insert(relative); enumerator?.skipDescendants(); continue }
                    if let transport, let source = root.smb {
                        do {
                            let children = try await transport.list(source.path(relative))
                            noteAmbiguities(children, parent: relative)
                            remoteEntries += children.reversed().map { (relative + "/" + $0.name, $0) }
                        } catch is CancellationError { throw CancellationError() }
                        catch { coverage.protectedPaths.insert(relative); walkErrors.append("\(relative): \(error.localizedDescription)"); walkIssues.append(ScanIssue(path: relative, reason: error.localizedDescription)) }
                    }
                    continue
                }
                coverage.files.insert(relative)
                guard formats.contains(url.pathExtension.lowercased()), !url.lastPathComponent.hasPrefix("._") else { continue }
                state.discovered += 1; state.current = url.lastPathComponent; state.phase = "음악 정보를 확인하고 있습니다"
                let sectionPath = LibrarySection.folderPath(for: relative)
                coverage.collections.insert(sectionPath)
                if sections[Data(sectionPath.utf8)] == nil {
                    let name = LibrarySection.folderName(rootPath: root.path, relativePath: sectionPath)
                    let section = LibrarySection(rootID: root.id, relativePath: sectionPath, name: name)
                    try await db.saveSection(section); sections[Data(sectionPath.utf8)] = section
                }
                var existingTrack = existingTracks[Data(relative.utf8)]
                if root.smb != nil, relativeFolder == nil, existingTrack == nil,
                   let candidates = legacyPaths[relative], candidates.count == 1,
                   !ambiguousPaths.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }),
                   let legacy = candidates.first,
                   identities[AlbumGrouping.key(root: root, relativePath: relative, tags: legacy.tags)].map({ $0 == legacy.albumID }) ?? true {
                    existingTrack = try await db.adoptSMBPath(track: legacy, path: relative,
                        folder: Self.albumFolder(url.deletingLastPathComponent()).path,
                        sectionID: sections[Data(sectionPath.utf8)]!.id,
                        groupingKey: AlbumGrouping.key(root: root, relativePath: relative, tags: legacy.tags))
                    identities[AlbumGrouping.key(root: root, relativePath: relative, tags: legacy.tags)] = legacy.albumID
                }
                // IDs survive moves; a path hash could collide when a file moves back to an earlier path.
                let trackID = existingTrack?.id ?? UUID().uuidString
                if let old = existingTrack,
                   (root.smb != nil ? SMBFileVersion.matches(size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0, track: old) : old.size == Int64(values.fileSize ?? 0) && old.modified == values.contentModificationDate?.timeIntervalSince1970),
                   let oldAlbum = try await db.album(old.albumID),
                   (root.smb != nil || (oldAlbum.artwork.map({ fm.fileExists(atPath: $0) }) ?? true)) {
                    try await db.markSeen(trackID: trackID, scanID: scanID, remoteModified: root.smb != nil ? values.contentModificationDate?.timeIntervalSince1970 : nil); state.reused += 1; state.processed += 1
                    if !old.supported {
                        state.errors.append("미지원 형식: \(relative)")
                        state.issues?.append(ScanIssue(path: url.path, reason: "미지원 형식: \(old.format)"))
                    }
                } else {
                    do {
                        let metadata: AudioMetadata
                        if let transport, let source = root.smb {
                            if url.pathExtension.lowercased() == "flac" {
                                let path = try source.path(relative)
                                let (read, metrics) = try await FLACRangeReader.read(SMBRangeReader(size: Int64(values.fileSize ?? 0), path: path, transport: transport))
                                let after = try await transport.stat(path)
                                guard after.size == Int64(values.fileSize ?? 0), after.modified == values.contentModificationDate?.timeIntervalSince1970 else { throw AppError.message("태그를 읽는 동안 원본이 변경되었습니다.") }
                                metadata = read
                                try await db.saveSMBRead(rootID: root.id, path: relative, metrics: metrics)
                            } else {
                                // Retain any known local tags. Unsupported containers are NEVER downloaded for scanning.
                                var basic = AudioMetadata()
                                if let old = existingTrack { basic.tags = old.tags; basic.duration = old.duration; basic.sampleRate = old.sampleRate; basic.bitDepth = old.bitDepth; basic.channels = old.channels }
                                metadata = basic
                                var metrics = MetadataReadMetrics(); metrics.status = "deferred-format"
                                try await db.saveSMBRead(rootID: root.id, path: relative, metrics: metrics)
                                state.issues?.append(ScanIssue(path: relative, reason: "직접 SMB 태그 읽기는 FLAC부터 지원합니다. 이 형식은 태그 읽기를 보류했습니다."))
                            }
                        } else { metadata = try await MetadataReader.read(url) }
                        let folder = url.deletingLastPathComponent()
                        let groupedFolder = Self.albumFolder(folder)
                        let albumTitle = metadata.value("ALBUM").isEmpty ? groupedFolder.lastPathComponent : metadata.value("ALBUM")
                        let albumArtist = metadata.value("ALBUMARTIST", "ALBUM ARTIST", "ARTIST").isEmpty ? groupedFolder.deletingLastPathComponent().lastPathComponent : metadata.value("ALBUMARTIST", "ALBUM ARTIST", "ARTIST")
                        let groupingKey = AlbumGrouping.key(root: root, relativePath: relative, tags: metadata.tags)
                        var inheritedAlbumID: String?
                        if root.smb != nil, relativeFolder == nil,
                           !ambiguousPaths.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }),
                           let matches = legacyAlbums[MountedAlbumIdentity(path: relative, tags: metadata.tags)], matches.count == 1 {
                            inheritedAlbumID = matches.first
                        }
                        let albumID = (root.smb != nil ? existingTrack?.albumID : nil) ?? inheritedAlbumID ?? identities[groupingKey] ?? UUID().uuidString
                        identities[groupingKey] = albumID; groupingKeys[albumID] = groupingKey
                        if folderAssets[groupedFolder.path] == nil { folderAssets[groupedFolder.path] = root.smb == nil ? Self.assets(groupedFolder) : (nil, []) }
                        let assets = folderAssets[groupedFolder.path]!
                        let imageURL = assets.0 ?? (root.smb == nil ? Self.assets(folder).0 : nil)
                        let imageVersion = imageURL.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970 } ?? values.contentModificationDate?.timeIntervalSince1970 ?? 0
                        let preferredImage = imageURL?.deletingPathExtension().lastPathComponent.lowercased() == "thumbnail" && metadata.picture != nil ? nil : imageURL
                        var artwork = try ArtworkCache.thumbnail(source: preferredImage, embedded: metadata.picture, key: (preferredImage?.path ?? trackID) + ":\(imageVersion)", directory: cache)
                        if root.smb != nil, artwork == nil { artwork = try await db.album(albumID)?.artwork }
                        var album = Album(id: albumID, rootID: root.id, sectionID: sections[Data(sectionPath.utf8)]!.id, folder: groupedFolder.path, title: albumTitle, artist: albumArtist, date: metadata.value("DATE", "YEAR", "ORIGINALDATE"), label: metadata.value("LABEL", "ORGANIZATION"), barcode: metadata.value("BARCODE", "UPC"), musicBrainzID: metadata.value("MUSICBRAINZ_ALBUMID"), artwork: artwork, attachments: Array(Set(assets.1 + (root.smb == nil ? Self.assets(folder).1 : []))).sorted())
                        if root.smb != nil { album.attachments = try await db.album(albumID)?.attachments ?? [] }
                        let title = metadata.value("TITLE").isEmpty ? url.deletingPathExtension().lastPathComponent : metadata.value("TITLE")
                        let disc = Self.number(metadata.value("DISCNUMBER", "DISC")) ?? Self.discNumber(folder.lastPathComponent) ?? 1
                        let number = Self.number(metadata.value("TRACKNUMBER", "TRACK")) ?? Self.number(url.lastPathComponent) ?? state.processed + 1
                        var credits: [Credit] = []
                        let roleTags = [("COMPOSER", "composer"), ("ARTIST", "performer"), ("PERFORMER", "performer"), ("CONDUCTOR", "conductor"), ("ENSEMBLE", "ensemble"), ("ARRANGER", "arranger"), ("LYRICIST", "lyricist")]
                        for (tag, role) in roleTags {
                            for name in metadata.tags[tag] ?? [] where !name.isEmpty {
                                // Provisional identities stay album-scoped; names alone never merge people across albums.
                                let artistID = existingTrack?.credits.first { $0.source == "local" && $0.role == role && $0.name == name }?.artistID ?? TextKey.id(albumID, role, name)
                                credits.append(Credit(artistID: artistID, name: name, role: role))
                            }
                        }
                        if !credits.contains(where: { $0.role == "performer" }) { credits.append(Credit(artistID: TextKey.id(albumID, "performer", albumArtist), name: albumArtist, role: "performer")) }
                        var track = Track(id: trackID, rootID: root.id, albumID: albumID, relativePath: relative, title: title, number: number, disc: disc, duration: metadata.duration, format: url.pathExtension.uppercased(), sampleRate: metadata.sampleRate, bitDepth: metadata.bitDepth, channels: metadata.channels, isrc: metadata.value("ISRC"), size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0, tags: metadata.tags, credits: Array(Set(credits)))
                        if root.smb != nil { track.metadataStatus = track.format == "FLAC" ? "complete" : "deferred-format" }
                        if var group = pending[albumID] { group.1.append(track); if group.0.artwork == nil { group.0.artwork = artwork }; group.0.attachments = Array(Set(group.0.attachments + album.attachments)).sorted(); pending[albumID] = group } else { pending[albumID] = (album, [track]) }
                        state.processed += 1
                        if ["APE", "CUE"].contains(track.format) { state.errors.append("미지원 형식: \(relative)"); state.issues?.append(ScanIssue(path: url.path, reason: "미지원 형식: \(track.format)")) }
                    } catch is CancellationError { throw CancellationError() }
                    catch { coverage.protectedPaths.insert(relative); state.errors.append("\(relative): \(error.localizedDescription)"); state.issues?.append(ScanIssue(path: url.path, reason: error.localizedDescription)) }
                }
                if state.discovered % 25 == 0 {
                    for (album, tracks) in pending.values { try await db.upsert(album: album, tracks: tracks, scanID: scanID, groupingKey: groupingKeys[album.id]) }; pending.removeAll()
                    state.albums = try await db.counts().albums; await progress(state); lastProgress = Date(); await Task.yield()
                }
            }
            for (album, tracks) in pending.values { try await db.upsert(album: album, tracks: tracks, scanID: scanID, groupingKey: groupingKeys[album.id]) }
            try Task.checkCancellation()
            // A disconnected/replaced volume cannot prove that any file disappeared.
            if let transport, let source = root.smb {
                _ = try await transport.stat(source.path(""))
                // With any remote walk failure, keep the entire root's previous availability.
                if !walkErrors.isEmpty { coverage.protectedPaths.insert("") }
            } else {
                let finalVolume = try rootURL.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
                guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue, volume == finalVolume else { throw AppError.message("스캔 중 라이브러리 연결이 변경되었습니다. 이전 색인은 유지합니다.") }
            }
            state.phase = "라이브러리를 정리하고 있습니다"; await progress(state)
            try Task.checkCancellation()
            if relativeFolder == nil { try await db.finishScan(root: root, scanID: scanID, coverage: coverage) }
            // Completion describes coverage, not the absence of individual file errors.
            // A fully traversed root replaces old failure history with this run's current issues.
            state.finished = root.smb == nil || walkErrors.isEmpty
        } catch is CancellationError {
            for (album, tracks) in pending.values { try await db.upsert(album: album, tracks: tracks, scanID: scanID, groupingKey: groupingKeys[album.id]) }
            state.cancelled = true
        }
        state.errors += walkErrors; state.issues? += walkIssues
        state.albums = try await db.counts().albums
        if relativeFolder == nil { try await db.saveScan(rootID: root.id, scanID: scanID, progress: state) }
        await progress(state); return state
    }

    public static func number(_ text: String) -> Int? { Int(text.prefix(while: \.isNumber)) }
    public static func discNumber(_ name: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: "(?i)^(?:CD|Disc|Disk)\\s*[-_]?\\s*(\\d+)(?:\\s.*)?$"), let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)), let range = Range(match.range(at: 1), in: name) else { return nil }
        return Int(name[range])
    }
    public static func albumFolder(_ folder: URL) -> URL { discNumber(folder.lastPathComponent) == nil ? folder : folder.deletingLastPathComponent() }
    private static func assets(_ folder: URL) -> (URL?, [String]) {
        let fm = FileManager.default
        let direct = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey])) ?? []
        let coversFolder = direct.first { $0.lastPathComponent.lowercased() == "covers" && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true }
        let nested = coversFolder.flatMap { try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey]) } ?? []
        let candidates = (direct + nested).filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true }
        func priority(_ url: URL) -> Int { let name = url.deletingPathExtension().lastPathComponent.lowercased(); return ["cover": 0, "folder": 1, "front": 2, "thumbnail": 4][name] ?? (name.contains("front") ? 3 : 9) }
        let image = candidates.filter { priority($0) < 9 }.sorted {
            if priority($0) != priority($1) { return priority($0) < priority($1) }
            return ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }.first
        return (image, direct.filter { $0.pathExtension.lowercased() == "pdf" && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true }.map(\.path).sorted())
    }
}

private struct ScanFileValues {
    var isDirectory: Bool?; var isSymbolicLink: Bool?; var fileSize: Int?; var contentModificationDate: Date?
    init() {}
    init(_ values: URLResourceValues) { isDirectory = values.isDirectory; isSymbolicLink = values.isSymbolicLink; fileSize = values.fileSize; contentModificationDate = values.contentModificationDate }
}

/// Canonical spelling is only an identity hint after the server listing ruled out ambiguous names.
private struct MountedAlbumIdentity: Hashable {
    let folder: String, title: String, barcode: String
    init(path: String, tags: [String: [String]]) {
        let parent = (path as NSString).deletingLastPathComponent
        folder = LibraryScanner.discNumber((parent as NSString).lastPathComponent) == nil ? parent : (parent as NSString).deletingLastPathComponent
        let album = AlbumGrouping.value(tags, "ALBUM")
        title = album.isEmpty ? (folder as NSString).lastPathComponent : album
        barcode = AlbumGrouping.value(tags, "BARCODE", "UPC")
    }
}
