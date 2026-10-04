import Foundation

public actor LibraryScanner {
    private let db: LibraryDatabase
    private let cache: URL
    public init(database: LibraryDatabase, cache: URL) { self.db = database; self.cache = cache }
    private let formats: Set<String> = ["flac", "mp3", "m4a", "aac", "wav", "aiff", "aif", "ape", "cue"]

    public func scan(root: LibraryRoot, progress: @escaping @Sendable (ScanProgress) async -> Void) async throws -> ScanProgress {
        let rootURL = URL(fileURLWithPath: root.path, isDirectory: true), fm = FileManager.default
        var state = ScanProgress(), scanID = UUID().uuidString
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw AppError.message("라이브러리가 연결되어 있지 않습니다. 이전 색인은 유지됩니다.") }
        let volume = try rootURL.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        if let expected = root.volumeID, let volume, expected != volume { throw AppError.message("등록한 볼륨과 다릅니다. 이전 색인을 유지합니다.") }
        var walkErrors: [String] = [], coverage = ScanCoverage()
        let resolvedRoot = rootURL.resolvingSymlinksInPath().path
        func relativeFailurePath(_ url: URL) -> String {
            for base in [root.path, resolvedRoot] where url.path.hasPrefix(base + "/") { return String(url.path.dropFirst(base.count + 1)) }
            return "" // Unknown coverage protects the whole root.
        }
        guard let enumerator = fm.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles], errorHandler: { url, _ in walkErrors.append("읽기 실패: \(url.lastPathComponent)"); coverage.protectedPaths.insert(relativeFailurePath(url)); return true }) else { throw AppError.message("폴더를 읽을 수 없습니다.") }
        let existingSections = try await db.sections()
        var sections = Dictionary(uniqueKeysWithValues: existingSections.filter { $0.rootID == root.id }.map { ($0.relativePath, $0) })
        var folderAssets: [String: (URL?, [String])] = [:]
        var pending: [String: (Album, [Track])] = [:]
        var identities = try await db.albumIdentities(rootID: root.id)
        let existingTracks = try await db.scanTracks(rootID: root.id)
        var groupingKeys: [String: String] = [:]
        do {
            while let url = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                // Foundation may enumerate /var as /private/var; use traversal depth for relative paths.
                let relative = url.pathComponents.suffix(enumerator.level).joined(separator: "/"), parts = relative.split(separator: "/")
                let values: URLResourceValues
                do { values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]) }
                catch { coverage.protectedPaths.insert(relative); state.errors.append("\(relative): \(error.localizedDescription)"); continue }
                if values.isSymbolicLink == true { coverage.protectedPaths.insert(relative); if values.isDirectory == true { enumerator.skipDescendants() }; continue }
                if values.isDirectory == true {
                    coverage.folders.insert(relative)
                    if root.exclusions.contains(where: { $0.caseInsensitiveCompare(url.lastPathComponent) == .orderedSame }) { coverage.protectedPaths.insert(relative); enumerator.skipDescendants() }
                    continue
                }
                coverage.files.insert(relative)
                guard formats.contains(url.pathExtension.lowercased()), !url.lastPathComponent.hasPrefix("._") else { continue }
                state.discovered += 1; state.current = url.lastPathComponent
                let sectionPath = parts.count > 1 ? String(parts[0]) : ""
                if sections[sectionPath] == nil {
                    let name = sectionPath.isEmpty ? rootURL.lastPathComponent : sectionPath.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    let section = LibrarySection(rootID: root.id, relativePath: sectionPath, name: name)
                    try await db.saveSection(section); sections[sectionPath] = section
                }
                let existingTrack = existingTracks[relative]
                // IDs survive moves; a path hash could collide when a file moves back to an earlier path.
                let trackID = existingTrack?.id ?? UUID().uuidString
                if let old = existingTrack, old.size == Int64(values.fileSize ?? 0), old.modified == values.contentModificationDate?.timeIntervalSince1970,
                   let oldAlbum = try await db.album(old.albumID), oldAlbum.artwork.map({ fm.fileExists(atPath: $0) }) ?? true {
                    try await db.markSeen(trackID: trackID, scanID: scanID); state.reused += 1; state.processed += 1
                } else {
                    do {
                        let metadata = try await MetadataReader.read(url), folder = url.deletingLastPathComponent()
                        let groupedFolder = Self.albumFolder(folder)
                        let albumTitle = metadata.value("ALBUM").isEmpty ? groupedFolder.lastPathComponent : metadata.value("ALBUM")
                        let albumArtist = metadata.value("ALBUMARTIST", "ALBUM ARTIST", "ARTIST").isEmpty ? groupedFolder.deletingLastPathComponent().lastPathComponent : metadata.value("ALBUMARTIST", "ALBUM ARTIST", "ARTIST")
                        let groupingKey = AlbumGrouping.key(root: root, relativePath: relative, tags: metadata.tags)
                        let albumID = identities[groupingKey] ?? UUID().uuidString
                        identities[groupingKey] = albumID; groupingKeys[albumID] = groupingKey
                        if folderAssets[groupedFolder.path] == nil { folderAssets[groupedFolder.path] = Self.assets(groupedFolder) }
                        let assets = folderAssets[groupedFolder.path]!
                        let imageURL = assets.0 ?? Self.assets(folder).0
                        let imageVersion = imageURL.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970 } ?? values.contentModificationDate?.timeIntervalSince1970 ?? 0
                        let preferredImage = imageURL?.deletingPathExtension().lastPathComponent.lowercased() == "thumbnail" && metadata.picture != nil ? nil : imageURL
                        let artwork = try ArtworkCache.thumbnail(source: preferredImage, embedded: metadata.picture, key: (preferredImage?.path ?? trackID) + ":\(imageVersion)", directory: cache)
                        let album = Album(id: albumID, rootID: root.id, sectionID: sections[sectionPath]!.id, folder: groupedFolder.path, title: albumTitle, artist: albumArtist, date: metadata.value("DATE", "YEAR", "ORIGINALDATE"), label: metadata.value("LABEL", "ORGANIZATION"), barcode: metadata.value("BARCODE", "UPC"), musicBrainzID: metadata.value("MUSICBRAINZ_ALBUMID"), artwork: artwork, attachments: Array(Set(assets.1 + Self.assets(folder).1)).sorted())
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
                        let track = Track(id: trackID, rootID: root.id, albumID: albumID, relativePath: relative, title: title, number: number, disc: disc, duration: metadata.duration, format: url.pathExtension.uppercased(), sampleRate: metadata.sampleRate, bitDepth: metadata.bitDepth, channels: metadata.channels, isrc: metadata.value("ISRC"), size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0, tags: metadata.tags, credits: Array(Set(credits)))
                        if var group = pending[albumID] { group.1.append(track); if group.0.artwork == nil { group.0.artwork = artwork }; group.0.attachments = Array(Set(group.0.attachments + album.attachments)).sorted(); pending[albumID] = group } else { pending[albumID] = (album, [track]) }
                        state.processed += 1
                        if ["APE", "CUE"].contains(track.format) { state.errors.append("미지원 형식: \(relative)") }
                    } catch is CancellationError { throw CancellationError() }
                    catch { coverage.protectedPaths.insert(relative); state.errors.append("\(relative): \(error.localizedDescription)") }
                }
                if state.discovered % 25 == 0 {
                    for (album, tracks) in pending.values { try await db.upsert(album: album, tracks: tracks, scanID: scanID, groupingKey: groupingKeys[album.id]) }; pending.removeAll()
                    state.albums = try await db.counts().albums; await progress(state); await Task.yield()
                }
            }
            for (album, tracks) in pending.values { try await db.upsert(album: album, tracks: tracks, scanID: scanID, groupingKey: groupingKeys[album.id]) }
            try Task.checkCancellation()
            // A disconnected/replaced volume cannot prove that any file disappeared.
            let finalVolume = try rootURL.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
            guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  volume == finalVolume else { throw AppError.message("스캔 중 라이브러리 연결이 변경되었습니다. 이전 색인은 유지합니다.") }
            try await db.finishScan(root: root, scanID: scanID, coverage: coverage)
            state.errors += walkErrors; state.finished = true
        } catch is CancellationError {
            for (album, tracks) in pending.values { try await db.upsert(album: album, tracks: tracks, scanID: scanID, groupingKey: groupingKeys[album.id]) }
            state.cancelled = true
        }
        state.albums = try await db.counts().albums
        try await db.saveScan(rootID: root.id, scanID: scanID, progress: state)
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
