import SwiftUI
import Observation
import ResonanceCore

struct StoryState {
    enum Phase: Equatable { case idle, working(StoryStep), failed(String), off(String) }
    var insight: Insight?
    var phase = Phase.idle
    var checked = false
}

/// Saved and in-flight stories, owned by the app so a story keeps writing after its view closes.
@MainActor @Observable
final class StoryStore {
    private(set) var states: [String: StoryState] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let db: LibraryDatabase
    @ObservationIgnored private let pipeline: StoryPipeline
    init(db: LibraryDatabase, pipeline: StoryPipeline) { self.db = db; self.pipeline = pipeline }
    private func key(_ entityID: String, _ settings: InfoSettings) -> String { entityID + "|" + settings.language }
    func state(_ entityID: String, settings: InfoSettings) -> StoryState { states[key(entityID, settings)] ?? StoryState() }
    static func blocker(_ settings: InfoSettings) -> String? {
        if !settings.enabled { return "설정에서 외부 음악 정보를 켜면 이야기가 자동으로 나타납니다." }
        if settings.model.isEmpty { return "설정에서 설명 모델을 지정하면 이야기가 자동으로 나타납니다." }
        return nil
    }
    /// Shows a saved story; with `auto`, writes one when none exists yet.
    func prepare(_ request: StoryRequest, settings: InfoSettings, auto: Bool) async {
        let id = key(request.entityID, settings)
        if case .off = states[id]?.phase { states[id]?.phase = .idle }
        if states[id]?.checked != true {
            let saved = try? await db.insight(entityID: request.entityID, language: settings.language)
            states[id, default: StoryState()].insight = states[id]?.insight ?? saved
            states[id]?.checked = true
        }
        guard states[id]?.insight == nil, states[id]?.phase == .idle else { return }
        if let reason = Self.blocker(settings) { if auto { states[id]?.phase = .off(reason) }; return }
        guard auto else { return }
        // Paging quickly through albums should not spend a search on each one.
        try? await Task.sleep(for: .seconds(1.2))
        guard !Task.isCancelled else { return }
        start(request, settings: settings)
    }
    func start(_ request: StoryRequest, settings: InfoSettings, regenerate: Bool = false) {
        let id = key(request.entityID, settings)
        guard tasks[id] == nil else { return }
        states[id, default: StoryState()].phase = .working(.searching)
        let pipeline = pipeline
        let progress: @Sendable (StoryStep) async -> Void = { [weak self] step in await self?.advance(id, to: step) }
        tasks[id] = Task { [weak self] in
            defer { self?.tasks[id] = nil }
            do {
                let searchKey = try await KeychainStore.readAsync("tinyfish"), llmKey = try await KeychainStore.readAsync("llm")
                let insight = try await pipeline.run(request, settings: settings, searchKey: searchKey, llmKey: llmKey, regenerate: regenerate, progress: progress)
                self?.states[id]?.insight = insight; self?.states[id]?.phase = .idle
            } catch is CancellationError { self?.states[id]?.phase = .idle }
            catch { self?.states[id]?.phase = .failed(error.localizedDescription) }
        }
    }
    func cancel(_ entityID: String, settings: InfoSettings) { tasks[key(entityID, settings)]?.cancel() }
    func cancelAndWait(_ entityID: String, settings: InfoSettings) async {
        let task = tasks[key(entityID, settings)]
        task?.cancel()
        await task?.value
    }
    /// Picks up a story saved from the manual source editor.
    func reload(_ entityID: String, settings: InfoSettings) async {
        let id = key(entityID, settings)
        if let saved = try? await db.insight(entityID: entityID, language: settings.language) { states[id, default: StoryState()].insight = saved; states[id]?.checked = true; if case .failed = states[id]?.phase { states[id]?.phase = .idle } }
    }
    private func advance(_ id: String, to step: StoryStep) { if case .working = states[id]?.phase { states[id]?.phase = .working(step) } }
}

extension StoryRequest {
    private static func unique(_ names: [String]) -> [String] { var seen = Set<String>(); return names.filter { !$0.isEmpty && seen.insert(TextKey.normalize($0)).inserted } }
    private static func isVarious(_ name: String) -> Bool { ["various artists", "various", "va", "verschiedene interpreten"].contains(TextKey.normalize(name)) }
    static func album(_ album: Album, tracks: [Track]) -> StoryRequest {
        let composers = Array(unique(tracks.flatMap(\.credits).filter { $0.role == "composer" }.map(\.name)).prefix(4))
        let artist = isVarious(album.artist) ? "" : album.artist
        return StoryRequest(entityID: album.id, kind: "album", title: album.title,
            context: "Album: \(album.title); album artist: \(album.artist); date: \(album.date); label: \(album.label); UPC: \(album.barcode); composers in local tags: \(composers.joined(separator: ", "))",
            queries: ["\(album.title) \(artist) album", "\(album.title) \(artist) \(album.label) review", "\(album.title) \(composers.first ?? "")"],
            required: [[album.title], artist.isEmpty ? [] : [artist] + composers], related: [album.label] + composers)
    }
    /// A track is told as the piece it plays, not as an album slot: search and filter by the piece and its composer only.
    static func track(_ track: Track, album: Album?) -> StoryRequest {
        let composers = Array(unique(track.credits.filter { $0.role == "composer" }.map(\.name)).prefix(3))
        let (piece, work, movement) = pieceNames(track.title)
        let names = unique([piece, work, movement ?? ""])
        let composer = composers.first ?? ""
        return StoryRequest(entityID: track.id, kind: "track", title: track.title,
            context: "Piece: \(piece); part of: \(work); composer: \(composers.isEmpty ? "unknown" : composers.joined(separator: ", ")). The listener hears one recording of it, but the story is about the piece itself, not this album, performer or track order.",
            queries: unique(["\(movement ?? piece) \(composer)", "\(work) \(composer)", "\(movement ?? piece) \(composer) history character".replacingOccurrences(of: "Kk.", with: "K.")]),
            required: [names, composers], related: names + composers)
    }
    /// "Deuxième livre…, Suite en mi: V. Le rappel des oiseaux (Arr. X)" → (cleaned title, "Deuxième livre…, Suite en mi", "Le rappel des oiseaux").
    /// A movement is kept on its own only when it is a real name, not a bare tempo such as "II. Andante".
    static func pieceNames(_ title: String) -> (piece: String, work: String, movement: String?) {
        let piece = title.replacingOccurrences(of: #"\s*\((arr|transcr|after|orch|version|live|remaster)[^)]*\)"#, with: "", options: [.regularExpression, .caseInsensitive]).trimmingCharacters(in: .whitespaces)
        guard let colon = piece.firstIndex(of: ":") else { return (piece, piece, nil) }
        let work = String(piece[..<colon]).trimmingCharacters(in: .whitespaces)
        let movement = String(piece[piece.index(after: colon)...]).replacingOccurrences(of: #"^\s*(([IVXLC]+|\d+)[.)]\s*)?(No\.?\s*\d+[,.]?\s*)?"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return (piece, work, movement.split(separator: " ").count >= 3 ? movement : nil)
    }
    static func artist(_ artist: Artist, albums: [String]) -> StoryRequest {
        let role = ["composer": "composer", "conductor": "conductor"][artist.role] ?? "musician"
        return StoryRequest(entityID: artist.id, kind: "artist", title: artist.name,
            context: "Artist: \(artist.name); aliases: \(artist.aliases.joined(separator: ", ")); role in local tags: \(artist.role); albums in this library: \(albums.prefix(6).joined(separator: "; ")). Several people can share a name; describe only the one matching these albums.",
            queries: ["\(artist.name) \(role) biography", "\(artist.name) \(albums.first ?? "")"],
            required: [[artist.name] + artist.aliases], related: Array(albums.prefix(6)))
    }
    static func work(_ work: Work, composers: [String], albums: [String]) -> StoryRequest {
        StoryRequest(entityID: work.id, kind: "work", title: work.title,
            context: "Work: \(work.title); composers in local tags: \(composers.joined(separator: ", ")); recordings in this library: \(albums.prefix(4).joined(separator: "; ")).",
            queries: ["\(work.title) \(composers.first ?? "") composition", "\(work.title) \(composers.first ?? "")"],
            required: [[work.title]], related: composers)
    }
}
