import SwiftUI
import AppKit
import Observation
import ResonanceCore

enum Destination: Hashable { case library, album(String), artist(String), work(String) }

@MainActor @Observable
final class AppModel {
    let db: LibraryDatabase
    let scanner: LibraryScanner
    let playback: PlaybackCoordinator
    let musicBrainz = MusicBrainzClient()
    let tinyFish = TinyFishClient()
    let insights: InsightService
    let stories: StoryStore
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
    var removingRootID: String?
    var error: String?
    var settings = InfoSettings()
    var inspector = true
    var queueVisible = false
    var canLoadMore = false
    var loading = false
    var restored = false
    var scrollPositions: [String: String] = [:]
    private var scanTask: Task<Void, Never>?
    private var queryTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var scopedURLs: [String: URL] = [:]
    private var watcher: LibraryWatcher?
    private var watchTask: Task<Void, Never>?
    private var notifications: [NSObjectProtocol] = []
    var sectionID: String? { sections.contains { $0.id == selection } ? selection : nil }
    var header: String { selection == "favorites" ? "즐겨찾기" : selection == "artists" ? "음악가" : sections.first { $0.id == selection }?.name ?? "모든 앨범" }
    var connected: Bool { roots.allSatisfy { $0.status == "연결됨" } }

    init() throws {
        try AppPaths.prepare()
        db = try LibraryDatabase(path: AppPaths.support.appendingPathComponent("Library.sqlite").path)
        scanner = LibraryScanner(database: db, cache: AppPaths.cache)
        playback = PlaybackCoordinator(database: db); insights = InsightService(database: db)
        stories = StoryStore(db: db, pipeline: StoryPipeline(tinyFish: tinyFish, insights: insights))
    }
    func bootstrap() async {
        guard !restored else { return }; restored = true
        do {
            if let stored = try await db.preference("infoSettings", as: InfoSettings.self) { settings = stored }
            roots = try await db.roots()
            for i in roots.indices {
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
        } catch { self.error = error.localizedDescription }
    }
    func startScan() {
        guard !scanning, removingRootID == nil, !roots.isEmpty else { return }
        scanning = true; scan = ScanProgress()
        let scanRoots = roots
        AppLog.library.info("Scan started; rootCount=\(self.roots.count, privacy: .public)")
        scanTask = Task(priority: .utility) {
            for root in scanRoots {
                if Task.isCancelled { break }
                do {
                    let final = try await scanner.scan(root: root) { [weak self] update in
                        await self?.acceptProgress(update)
                    }
                    scan = final
                    if final.cancelled { break }
                } catch is CancellationError { break }
                catch { self.error = error.localizedDescription }
            }
            scanning = false; await reload()
            AppLog.library.info("Scan completed; albumCount=\(self.counts.albums, privacy: .public); trackCount=\(self.counts.tracks, privacy: .public)")
            try? ArtworkCache.trim(directory: AppPaths.cache, megabytes: settings.cacheMegabytes)
        }
    }
    private func acceptProgress(_ update: ScanProgress) async { scan = update; await reload() }
    func cancelScan() { scanTask?.cancel() }
    func removeRoot(_ root: LibraryRoot) async {
        guard removingRootID == nil, roots.contains(where: { $0.id == root.id }) else { return }
        removingRootID = root.id
        let resumeScan = scanning
        watchTask?.cancel(); watcher = nil
        scanTask?.cancel()
        await scanTask?.value
        do {
            let trackIDs = try await db.removeRoot(root.id)
            roots.removeAll { $0.id == root.id }
            await playback.removeTracks(trackIDs)
            scopedURLs.removeValue(forKey: root.id)?.stopAccessingSecurityScopedResource()
            if sections.contains(where: { $0.rootID == root.id && $0.id == selection }) { selection = "all" }
            destination = .library; history.removeAll(); future.removeAll()
            await reload()
        } catch { self.error = error.localizedDescription }
        removingRootID = nil
        configureWatcher()
        if resumeScan { startScan() }
    }
    func reload() async {
        do {
            sections = try await db.sections(); counts = try await db.counts()
            await refreshGrid()
        } catch { self.error = error.localizedDescription }
    }
    func refreshGrid(more: Bool = false) async {
        refreshGeneration += 1; let token = refreshGeneration; loading = true
        defer { if token == refreshGeneration { loading = false } }
        do {
            if !query.isEmpty {
                let hits = try await db.search(query, sectionID: searchSection ? sectionID : nil, role: roleFilter == "all" ? nil : roleFilter, format: formatFilter == "all" ? nil : formatFilter)
                guard token == refreshGeneration else { return }; searchHits = hits; return
            }
            if selection == "artists" { let result = try await db.artists(limit: 500); guard token == refreshGeneration else { return }; people = result; return }
            let page = try await db.albums(sectionID: sectionID, favorites: selection == "favorites", sort: sort, offset: more ? albums.count : 0)
            guard token == refreshGeneration else { return }
            albums = more ? albums + page : page; canLoadMore = page.count == 120
        } catch { if token == refreshGeneration { self.error = error.localizedDescription } }
    }
    func scheduleSearch() {
        queryTask?.cancel(); queryTask = Task { try? await Task.sleep(nanoseconds: 180_000_000); guard !Task.isCancelled else { return }; destination = .library; await refreshGrid() }
    }
    func selectSection(_ id: String) { selection = id; query = ""; go(.library); Task { await refreshGrid() } }
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
    func saveSection(_ section: LibrarySection) async { do { try await db.saveSection(section); await reload() } catch { self.error = error.localizedDescription } }
    func saveRoot(_ root: LibraryRoot) async {
        guard removingRootID == nil, roots.contains(where: { $0.id == root.id }) else { return }
        do { try await db.saveRoot(root); roots = try await db.roots() } catch { self.error = error.localizedDescription }
    }
    func backup() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Resonance-\(Date().formatted(.iso8601.year().month().day())) .sqlite".replacingOccurrences(of: " ", with: "")
        panel.allowedContentTypes = [.database]
        if panel.runModal() == .OK, let url = panel.url { Task { do { try await db.backup(to: url.path) } catch { self.error = error.localizedDescription } } }
    }
    private func configureWatcher() {
        watchTask?.cancel()
        watcher = LibraryWatcher(paths: roots.map(\.path)) { [weak self] in
            Task { @MainActor in
                self?.watchTask?.cancel()
                self?.watchTask = Task { try? await Task.sleep(nanoseconds: 3_000_000_000); guard !Task.isCancelled else { return }; self?.startScan() }
            }
        }
    }
    private func refreshConnections(rescan: Bool) async {
        guard removingRootID == nil else { return }
        for var root in roots {
            guard removingRootID == nil, let i = roots.firstIndex(where: { $0.id == root.id }) else { return }
            root.status = FileManager.default.fileExists(atPath: root.path) ? "연결됨" : "연결 안 됨"
            roots[i] = root; try? await db.saveRoot(root)
        }
        guard removingRootID == nil else { return }
        if let rootID = playback.current?.rootID, roots.first(where: { $0.id == rootID })?.status != "연결됨" { playback.pause(); playback.error = "음악 볼륨이 연결 해제되었습니다." }
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
