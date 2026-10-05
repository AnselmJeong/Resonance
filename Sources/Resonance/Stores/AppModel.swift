import SwiftUI
import AppKit
import Observation
import ResonanceCore

enum Destination: Hashable { case library, album(String), artist(String), work(String), track(String) }

@MainActor @Observable
final class AppModel {
    let db: LibraryDatabase
    let scanner: LibraryScanner
    let smbSessions: SMBSessionPool
    let audioFiles: AudioFileAccess
    let artworkLoader: SMBArtworkLoader
    var smbConnections: [SMBConnection] = []
    let playback: PlaybackCoordinator
    let musicBrainz = MusicBrainzClient()
    let tinyFish = TinyFishClient()
    let insights: InsightService
    let stories: StoryStore
    let discovery: DiscoveryStore
    let booklets = BookletReader()
    var booklet: BookletSelection?
    var detailStates: [String: DetailState] = [:]
    var highlightedTrack: String?
    var roots: [LibraryRoot] = []
    var sections: [LibrarySection] = []
    var albums: [Album] = []
    var searchHits: [SearchHit] = []
    var people: [Artist] = []
    var counts = (albums: 0, tracks: 0)
    var selection = "all"
    var query = ""
    var searchSection = false
    var roleFilter = "all"
    var formatFilter = "all"
    var sort = "title"
    var destination = Destination.library
    var history: [Destination] = []
    var future: [Destination] = []
    var scan: ScanProgress?
    var scanning = false
    var scanRootPath = ""
    var scanRootIndex = 0
    var scanRootCount = 0
    var scanSummary = ScanSummary()
    var scanCancelling = false
    var scanNotice: ScanNotice?
    private var noticeTask: Task<Void, Never>?
    private var lastScanReload = Date.distantPast
    var scanProcessed: Int { scanSummary.processed + (scan?.processed ?? 0) }
    var removingRootID: String?
    var error: String?
    var settings = InfoSettings()
    var inspector = true
    var queueVisible = false
    var canLoadMore = false
    var artworkCollecting = false
    var artworkProcessed = 0
    var artworkTotal = 0
    var artworkRestored = 0
    private var artworkTask: Task<Void, Never>?
    private var artworkRescanRequested = false
    var loading = false
    var restored = false
    var scrollPositions: [String: String] = [:]
    private var scanTask: Task<Void, Never>?
    private var queryTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var scopedURLs: [String: URL] = [:]
    private var watcher: LibraryWatcher?
    private var watchTask: Task<Void, Never>?
    private var rescanRequested = false
    private var notifications: [NSObjectProtocol] = []
    var rootGroups: [LibraryRootGroup] { LibraryRootGroup.grouping(roots) }
    var collectionGroups: [LibraryCollectionGroup] { rootGroups.flatMap { $0.collections(from: sections) } }
    var selectedCollection: LibraryCollectionGroup? {
        guard selection.hasPrefix("collection-group:") else { return nil }
        return collectionGroups.first { $0.id == selection }
    }
    var selectedRoot: LibraryRootGroup? {
        guard selection.hasPrefix("root-group:") else { return nil }
        return rootGroups.first { $0.id == selection }
    }
    var rootIDs: [String]? { collectionRoot?.rootIDs }
    var sectionIDs: [String]? { selectedCollection?.sectionIDs }
    var collectionRoot: LibraryRootGroup? {
        if let selectedRoot { return selectedRoot }
        guard let collection = selectedCollection else { return nil }
        return rootGroups.first { $0.id == collection.rootGroupID }
    }
    var visibleSections: [LibraryCollectionGroup] { collectionRoot?.collections(from: sections) ?? [] }
    var hasSearchScope: Bool { rootIDs != nil }
    var searchScopeLabel: String { selectedRoot != nil ? "현재 폴더만" : "현재 컬렉션만" }
    var header: String { selection == "favorites" ? "즐겨찾기" : selection == "artists" ? "음악가" : selectedRoot?.name ?? selectedCollection?.name ?? "모든 앨범" }
    var librarySubtitle: String {
        if let root = collectionRoot {
            if selectedCollection != nil { return "\(root.name) · 하위 컬렉션" }
            return root.roots.count == 1 ? root.roots[0].path : "\(root.roots.count)개의 음악 폴더를 함께 표시합니다"
        }
        return "커버에서 시작하는 나만의 음악 컬렉션"
    }
    var connected: Bool { roots.allSatisfy { $0.smb != nil || $0.status == "연결됨" } }

    init() throws {
        try AppPaths.prepare()
        db = try LibraryDatabase(path: AppPaths.support.appendingPathComponent("Library.sqlite").path)
        audioFiles = AudioFileAccess(directory: AppPaths.support.appendingPathComponent("SMBAudioCache", isDirectory: true)) { connection in
            try await KeychainStore.readAsync(connection.credentialAccount)
        }
        smbSessions = SMBSessionPool { try await KeychainStore.readAsync($0.credentialAccount) }
        artworkLoader = SMBArtworkLoader(database: db, cache: AppPaths.cache, sessions: SMBSessionPool { try await KeychainStore.readAsync($0.credentialAccount) })
        scanner = LibraryScanner(database: db, cache: AppPaths.cache, remote: smbSessions)
        playback = PlaybackCoordinator(database: db, files: audioFiles); insights = InsightService(database: db)
        discovery = DiscoveryStore(service: MetadataDiscovery(database: db, client: musicBrainz, artworkDirectory: AppPaths.cache))
        stories = StoryStore(db: db, pipeline: StoryPipeline(tinyFish: tinyFish, insights: insights))
    }
    func bootstrap() async {
        guard !restored else { return }; restored = true
        do {
            if let stored = try await db.preference("infoSettings", as: InfoSettings.self) { settings = stored }
            smbConnections = try await db.preference("smbConnections", as: [SMBConnection].self) ?? []
            await audioFiles.configure(smbConnections)
            roots = try await db.roots()
            for i in roots.indices {
                if roots[i].smb != nil { roots[i].status = "연결 확인 필요"; continue }
                if let bookmark = roots[i].bookmark {
                    var stale = false
                    if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) {
                        if url.startAccessingSecurityScopedResource() { scopedURLs[roots[i].id] = url }
                        if stale { roots[i].bookmark = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) }
                        roots[i].path = url.path
                    }
                }
                roots[i].status = FileManager.default.fileExists(atPath: roots[i].path) ? "연결됨" : "연결 안 됨"
                try await db.saveRoot(roots[i])
            }
            await reload(); await playback.restore(); configureWatcher()
            notifications.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in await self?.refreshConnections(rescan: true) } })
            notifications.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in await self?.refreshConnections(rescan: false) } })
            if let i = CommandLine.arguments.firstIndex(of: "--import"), CommandLine.arguments.indices.contains(i + 1) { await addRoot(URL(fileURLWithPath: CommandLine.arguments[i + 1])) }
            else {
                #if DEBUG
                if let i = CommandLine.arguments.firstIndex(of: "--smb-verify-album"), CommandLine.arguments.indices.contains(i + 1) {
                    await SMBFallbackDiagnostic.run(folder: URL(fileURLWithPath: CommandLine.arguments[i + 1]), roots: roots)
                } else if let i = CommandLine.arguments.firstIndex(of: "--smb-rescan-root"), CommandLine.arguments.indices.contains(i + 1), let root = roots.first(where: { $0.id == CommandLine.arguments[i + 1] }) {
                    _ = try await scanner.scan(root: root) { _ in }; await reload()
                } else if CommandLine.arguments.contains("--smb-rescan-album") {
                    for i in CommandLine.arguments.indices where CommandLine.arguments[i] == "--smb-rescan-album" && CommandLine.arguments.indices.contains(i + 1) {
                        let folder = CommandLine.arguments[i + 1]
                        if let root = roots.first(where: { $0.smb != nil && folder.hasPrefix($0.path + "/") }) {
                            _ = try await scanner.scan(root: root, relativeFolder: String(folder.dropFirst(root.path.count + 1))) { _ in }
                        }
                    }
                    await reload()
                } else if !CommandLine.arguments.contains("--no-auto-scan") { startScan() }
                #else
                startScan()
                #endif
            }
            if !CommandLine.arguments.contains("--smb-verify-album") && !CommandLine.arguments.contains("--diagnostics") { startArtworkBackfill() }
            if CommandLine.arguments.contains("--diagnostics") { await diagnostics() }
        } catch { self.error = error.localizedDescription }
    }
    func chooseRoot() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "원본 음악 폴더를 읽기 전용으로 색인합니다."; panel.prompt = "라이브러리 추가"
        if panel.runModal() == .OK, let url = panel.url { Task { await addRoot(url) } }
    }
    func addRoot(_ url: URL) async {
        guard removingRootID == nil else { return }
        do {
            let path = url.standardizedFileURL.path
            if roots.contains(where: { URL(fileURLWithPath: $0.path).standardizedFileURL.path == path }) { startScan(); return }
            let bookmark = (try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)) ?? (try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil))
            let volume = try url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
            let root = LibraryRoot(path: path, bookmark: bookmark, volumeID: volume)
            if url.startAccessingSecurityScopedResource() { scopedURLs[root.id] = url }
            try await db.saveRoot(root); roots.append(root); configureWatcher(); startScan()
        } catch { showScanNotice(title: "폴더를 추가하지 못했습니다", detail: error.localizedDescription, warning: true) }
    }
    func startScan() {
        guard removingRootID == nil, !roots.isEmpty else { return }
        if scanning { rescanRequested = true; return }
        rescanRequested = false; scanning = true; scan = ScanProgress(); scanSummary = ScanSummary()
        scanCancelling = false; scanNotice = nil; noticeTask?.cancel(); lastScanReload = .distantPast
        let scanRoots = roots
        scanRootCount = scanRoots.count; scanRootIndex = 1; scanRootPath = scanRoots[0].path
        AppLog.library.info("Scan started; rootCount=\(self.roots.count, privacy: .public)")
        scanTask = Task(priority: .utility) {
            for (index, root) in scanRoots.enumerated() {
                if Task.isCancelled { scanSummary.cancelled = true; break }
                scanRootIndex = index + 1; scanRootPath = root.path; scan = ScanProgress()
                do {
                    let final = try await scanner.scan(root: root) { [weak self] update in
                        await self?.acceptProgress(update)
                    }
                    scanSummary.include(final, root: root); scan = nil
                    startArtworkBackfill()
                    if let i = roots.firstIndex(where: { $0.id == root.id }), root.smb != nil { roots[i].status = final.finished ? "연결됨" : "부분 스캔"; try await db.saveRoot(roots[i]) }
                    if final.cancelled { break }
                } catch is CancellationError { scanSummary.cancelled = true; break }
                catch {
                    var failed = scan ?? ScanProgress()
                    failed.errors.append(error.localizedDescription)
                    failed.issues = (failed.issues ?? []) + [ScanIssue(path: root.path, reason: error.localizedDescription)]
                    scanSummary.include(failed, root: root); scan = nil
                    try? await db.saveScan(rootID: root.id, scanID: UUID().uuidString, progress: failed)
                }
            }
            scanSummary.cancelled = scanSummary.cancelled || Task.isCancelled
            discovery.changed(); await playback.refreshLibraryReferences(); await reload(reportError: false)
            AppLog.library.info("Scan ended; albumCount=\(self.counts.albums, privacy: .public); trackCount=\(self.counts.tracks, privacy: .public); issues=\(self.scanSummary.errors.count, privacy: .public)")
            // Artwork collection maintains its own cache after metadata scanning finishes.
            let shouldRescan = rescanRequested && !Task.isCancelled
            rescanRequested = false; scanning = false; scanTask = nil; scanCancelling = false
            var result = ScanProgress()
            result.discovered = scanSummary.discovered; result.albums = counts.albums
            result.processed = scanSummary.processed; result.reused = scanSummary.reused
            result.errors = scanSummary.errors; result.cancelled = scanSummary.cancelled
            result.finished = !result.cancelled && scanSummary.completedRoots == scanRoots.count
            scan = result
            showScanNotice(title: scanSummary.title, detail: scanSummary.detail, warning: !scanSummary.errors.isEmpty)
            if shouldRescan { startScan() }
        }
    }
    private func acceptProgress(_ update: ScanProgress) async {
        scan = update
        if Date().timeIntervalSince(lastScanReload) >= 1 || update.finished || update.cancelled {
            lastScanReload = Date(); await reload(reportError: false)
        }
    }
    func showScanNotice(title: String, detail: String, warning: Bool = false) {
        noticeTask?.cancel()
        let notice = ScanNotice(title: title, detail: detail, warning: warning)
        scanNotice = notice
        if !warning {
            noticeTask = Task {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, scanNotice?.id == notice.id else { return }
                scanNotice = nil
            }
        }
    }
    func cancelScan() {
        rescanRequested = false; watchTask?.cancel(); scanCancelling = scanning; scanTask?.cancel()
    }
    func removeRoot(_ root: LibraryRoot) async {
        guard removingRootID == nil, roots.contains(where: { $0.id == root.id }) else { return }
        removingRootID = root.id
        let resumeScan = scanning
        watchTask?.cancel(); watcher = nil
        rescanRequested = false; scanTask?.cancel()
        await scanTask?.value
        do {
            let trackIDs = try await db.removeRoot(root.id)
            let previousGroupID = collectionRoot?.id
            roots.removeAll { $0.id == root.id }
            await playback.removeTracks(trackIDs)
            scopedURLs.removeValue(forKey: root.id)?.stopAccessingSecurityScopedResource()
            if let previousGroupID {
                if !rootGroups.contains(where: { $0.id == previousGroupID }) { selection = "all" }
                else if selectedRoot == nil && selectedCollection == nil { selection = previousGroupID }
            }
            destination = .library; history.removeAll(); future.removeAll()
            await reload()
        } catch { self.error = error.localizedDescription }
        removingRootID = nil
        configureWatcher()
        if resumeScan { startScan() }
    }
    func reload(reportError: Bool = true) async {
        do {
            let previousCollection = selectedCollection
            sections = try await db.sections(); counts = try await db.counts()
            if let previousCollection, !collectionGroups.contains(where: { $0.id == selection }) {
                selection = rootGroups.first { $0.id == previousCollection.rootGroupID }?.id ?? "all"
                query = ""; searchSection = hasSearchScope
            }
            await refreshGrid(reportError: reportError, preserveLoadedAlbums: !reportError)
        } catch { if reportError { self.error = error.localizedDescription } else { scanSummary.errors.append(error.localizedDescription) } }
    }
    func refreshGrid(more: Bool = false, reportError: Bool = true, preserveLoadedAlbums: Bool = false) async {
        if more && (loading || !canLoadMore) { return }
        if preserveLoadedAlbums && loading { return }
        refreshGeneration += 1; let token = refreshGeneration; loading = true
        defer { if token == refreshGeneration { loading = false } }
        do {
            if !query.isEmpty {
                let hits = try await db.search(query, rootIDs: searchSection ? rootIDs : nil, sectionIDs: searchSection ? sectionIDs : nil, role: roleFilter == "all" ? nil : roleFilter, format: formatFilter == "all" ? nil : formatFilter)
                guard token == refreshGeneration else { return }; searchHits = hits; return
            }
            if selection == "artists" { let result = try await db.artists(limit: 500); guard token == refreshGeneration else { return }; people = result; return }
            let pageSize = preserveLoadedAlbums ? max(120, albums.count) : 120
            let page = try await db.albums(rootIDs: rootIDs, sectionIDs: sectionIDs, favorites: selection == "favorites", sort: sort, limit: pageSize + 1, offset: more ? albums.count : 0)
            guard token == refreshGeneration else { return }
            let visible = Array(page.prefix(pageSize))
            albums = more ? albums + visible : visible; canLoadMore = page.count > pageSize
        } catch { if token == refreshGeneration { if reportError { self.error = error.localizedDescription } else { scanSummary.errors.append(error.localizedDescription) } } }
    }
    func trimArtworkCache() async throws {
        let paths = Set(try await db.albums(limit: Int.max).compactMap(\.artwork))
        let limit = settings.cacheMegabytes
        try await Task.detached(priority: .utility) {
            try ArtworkCache.trim(directory: AppPaths.cache, megabytes: limit, preserving: paths)
        }.value
    }
    func startArtworkBackfill() {
        guard artworkTask == nil else { artworkRescanRequested = true; return }
        artworkCollecting = true; artworkProcessed = 0; artworkRestored = 0; artworkTotal = 0
        artworkTask = Task {
            do {
                let rootIDs = roots.filter { $0.smb != nil }.map(\.id)
                let candidates = try await db.albums(rootIDs: rootIDs, limit: Int.max)
                let missing = await Task.detached(priority: .utility) {
                    candidates.filter { $0.artwork.map { FileManager.default.fileExists(atPath: $0) } != true }
                }.value
                artworkTotal = missing.count
                await withTaskGroup(of: Bool.self) { group in
                    var iterator = missing.makeIterator()
                    func enqueue(_ album: Album) {
                        group.addTask { [weak self] in
                            guard !Task.isCancelled, let self else { return false }
                            let path = await self.loadArtwork(album)
                            return path.map { FileManager.default.fileExists(atPath: $0) } == true
                        }
                    }
                    for _ in 0..<2 { if let album = iterator.next() { enqueue(album) } }
                    for await restored in group {
                        artworkProcessed += 1
                        if restored { artworkRestored += 1 }
                        if !Task.isCancelled, let album = iterator.next() { enqueue(album) }
                    }
                }
                try? await db.setPreference("artworkBackfill", value: ["total": artworkTotal, "restored": artworkRestored, "unavailable": artworkTotal - artworkRestored])
                if !scanning { try? await trimArtworkCache() }
            } catch { AppLog.library.error("Artwork collection failed: \(error.localizedDescription, privacy: .private)") }
            artworkCollecting = false; artworkTask = nil
            if artworkRescanRequested { artworkRescanRequested = false; startArtworkBackfill() }
        }
    }
    func loadMoreAlbums(after albumID: String) async {
        guard query.isEmpty, selection != "artists", canLoadMore, !loading,
              let index = albums.firstIndex(where: { $0.id == albumID }), index >= albums.count - 14 else { return }
        await refreshGrid(more: true)
    }
    func loadArtwork(_ album: Album) async -> String? {
        guard let source = roots.first(where: { $0.id == album.rootID })?.smb else { return album.artwork }
        do {
            let path = try await artworkLoader.load(album: album, source: source)
            if let path {
                if let index = albums.firstIndex(where: { $0.id == album.id }) { albums[index].artwork = path }
                if playback.currentAlbum?.id == album.id { playback.currentAlbum?.artwork = path }
            }
            return path ?? album.artwork
        } catch { return album.artwork }
    }
    func scheduleSearch() {
        queryTask?.cancel(); queryTask = Task { try? await Task.sleep(nanoseconds: 180_000_000); guard !Task.isCancelled else { return }; destination = .library; await refreshGrid() }
    }
    func selectSection(_ id: String) { selection = id; query = ""; searchSection = hasSearchScope; go(.library); Task { await refreshGrid() } }
    func go(_ next: Destination) { if destination != next { history.append(destination); future.removeAll(); destination = next } }
    func back() { guard let next = history.popLast() else { return }; future.append(destination); destination = next }
    func forward() { guard let next = future.popLast() else { return }; history.append(destination); destination = next }
    func playAlbum(_ album: Album, start: Int = 0) { Task { do { await playback.play(try await db.tracks(albumID: album.id), start: start) } catch { self.error = error.localizedDescription } } }
    func enqueue(_ album: Album, next: Bool = false) { Task { do { await playback.append(try await db.tracks(albumID: album.id), next: next) } catch { self.error = error.localizedDescription } } }
    func favorite(_ album: Album) { Task { do { try await db.setFavorite(album.id, value: !album.favorite); await reload() } catch { self.error = error.localizedDescription } } }
    @discardableResult func saveSettings() async -> Bool {
        do { try await db.setPreference("infoSettings", value: settings); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func saveRoot(_ root: LibraryRoot) async {
        guard removingRootID == nil, roots.contains(where: { $0.id == root.id }) else { return }
        do { try await db.saveRoot(root); roots = try await db.roots() } catch { self.error = error.localizedDescription }
    }
    func setSMBSource(_ source: SMBSource?, rootID: String) async throws {
        scanTask?.cancel()
        if let scanTask { await scanTask.value }
        try await db.setSMBSource(rootID: rootID, source: source)
        roots = try await db.roots(); await smbSessions.reset(); await audioFiles.configure(smbConnections)
        configureWatcher()
    }
    func setSMBSources(_ sources: [String: SMBSource]) async throws {
        cancelScan(); if let scanTask { await scanTask.value }
        try await db.setSMBSources(sources)
        roots = try await db.roots(); await smbSessions.reset(); await audioFiles.configure(smbConnections); configureWatcher()
    }
    func addSMBSource(_ source: SMBSource) async throws {
        try source.validate()
        guard !roots.contains(where: { $0.smb == source }) else { throw AppError.message("이미 등록된 SMB 폴더입니다.") }
        var root = LibraryRoot(path: "/SMB/" + source.server + "/" + source.share + (source.subpath.isEmpty ? "" : "/" + source.subpath))
        root.smb = source
        try await db.saveRoot(root); roots = try await db.roots(); configureWatcher()
    }
    func backup() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Resonance-\(Date().formatted(.iso8601.year().month().day())) .sqlite".replacingOccurrences(of: " ", with: "")
        panel.allowedContentTypes = [.database]
        if panel.runModal() == .OK, let url = panel.url { Task { do { try await db.backup(to: url.path) } catch { self.error = error.localizedDescription } } }
    }
    private func configureWatcher() {
        watchTask?.cancel()
        watcher = LibraryWatcher(paths: roots.filter { $0.smb == nil }.map(\.path)) { [weak self] in
            Task { @MainActor in
                self?.watchTask?.cancel()
                self?.watchTask = Task { try? await Task.sleep(nanoseconds: 3_000_000_000); guard !Task.isCancelled else { return }; self?.startScan() }
            }
        }
    }
    private func refreshConnections(rescan: Bool) async {
        guard removingRootID == nil else { return }
        for var root in roots where root.smb == nil {
            guard removingRootID == nil, let i = roots.firstIndex(where: { $0.id == root.id }) else { return }
            root.status = FileManager.default.fileExists(atPath: root.path) ? "연결됨" : "연결 안 됨"
            roots[i] = root; try? await db.saveRoot(root)
        }
        guard removingRootID == nil else { return }
        if let rootID = playback.current?.rootID, let playingRoot = roots.first(where: { $0.id == rootID }), playingRoot.smb == nil, playingRoot.status != "연결됨" { playback.pause(); playback.error = "음악 볼륨이 연결 해제되었습니다." }
        configureWatcher(); if rescan { startScan() }
    }
    private func diagnostics() async {
        let account = "diagnostic-" + UUID().uuidString
        let sentinel = UUID().uuidString
        var keychainPassed = false
        do {
            try KeychainStore.save(sentinel, account: account)
            keychainPassed = try KeychainStore.read(account) == sentinel
            try KeychainStore.save("", account: account)
            keychainPassed = try keychainPassed && KeychainStore.read(account).isEmpty
            let replacement = UUID().uuidString
            try await KeychainStore.saveAndVerify(replacement, account: account)
            keychainPassed = try keychainPassed && KeychainStore.contains(account)
            try await KeychainStore.saveAndVerify("", account: account)
            keychainPassed = try keychainPassed && !KeychainStore.contains(account)
        } catch { try? KeychainStore.save("", account: account) }
        let report: [String: Any] = ["keychainRoundTrip": keychainPassed, "databaseIntegrity": (try? await db.integrityCheck()) ?? "failed", "albums": counts.albums, "tracks": counts.tracks, "restoredQueueEntries": playback.entries.count, "restoredPosition": playback.position, "playbackState": playback.state.rawValue, "systemOutput": playback.output.name, "nominalSampleRate": playback.output.nominalRate ?? 0, "onlineEnabled": settings.enabled]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: AppPaths.support.appendingPathComponent("Diagnostics.json"), options: .atomic) }
    }
}
