import SwiftUI
import Observation
import ResonanceCore

struct MetadataState {
    var snapshot: MetadataSnapshot?
    var busy = false
    var error: String?
}
@MainActor @Observable
final class DiscoveryStore {
    var states: [String: MetadataState] = [:]
    var revision = 0
    @ObservationIgnored let service: MetadataDiscovery
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    init(service: MetadataDiscovery) { self.service = service }
    func prepare(_ album: Album, enabled: Bool, force: Bool = false) async {
        guard enabled, tasks[album.id] == nil else { return }
        if !force, states[album.id]?.snapshot != nil || states[album.id]?.error != nil { return }
        if !force { try? await Task.sleep(for: .milliseconds(800)); guard !Task.isCancelled else { return } }
        guard tasks[album.id] == nil else { return }
        states[album.id, default: MetadataState()].busy = true; states[album.id]?.error = nil
        tasks[album.id] = Task {
            defer { states[album.id]?.busy = false; tasks[album.id] = nil }
            do { states[album.id]?.snapshot = try await service.discover(album: album, force: force); revision += 1 }
            catch { states[album.id]?.error = error.localizedDescription }
        }
    }
    func changed(_ albumID: String? = nil) { if let albumID { states[albumID] = nil }; revision += 1 }
}

struct BookletSelection: Identifiable {
    let album: Album
    let path: String
    var page = 1
    var id: String { album.id + path + String(page) }
}
struct DetailState {
    var scroll: String?
    var role = "all"
    var instrument = "all"
    var collaborator = "all"
    var collectionOnly = false
}
extension AppModel {
    func refreshBooklets(_ album: Album) async -> Album {
        if let source = roots.first(where: { $0.id == album.rootID })?.smb {
            guard album.artwork.map({ FileManager.default.fileExists(atPath: $0) }) != true else { return album }
            do {
                let tracks = try await db.tracks(albumID: album.id)
                guard let track = tracks.first else { return album }
                let transport = try await smbSessions.session(source)
                if let path = try await SMBArtwork.load(source: source, track: track, transport: transport, cache: AppPaths.cache) {
                    return try await db.saveSourceArtwork(albumID: album.id, path: path)
                }
            } catch { /* A missing cover never prevents album browsing or playback. */ }
            return album
        }
        let paths = await booklets.attachments(for: album)
        return (try? await db.updateAttachments(albumID: album.id, paths: paths)) ?? album
    }
    func openBooklet(_ album: Album, path: String, page: Int = 1) {
        do { _ = try BookletSource.validatedURL(path: path, album: album, roots: roots); booklet = BookletSelection(album: album, path: path, page: page) }
        catch { self.error = error.localizedDescription }
    }
    func openStoryURL(_ url: URL) -> OpenURLAction.Result {
        if let target = DiscoveryLink.entity(url) {
            Task {
                switch target.kind {
                case "album": if (try? await db.album(target.id)) != nil { go(.album(target.id)) }
                case "track": if (try? await db.track(target.id)) != nil { go(.track(target.id)) }
                case "artist": if (try? await db.artist(target.id)) != nil { go(.artist(target.id)) }
                case "work": if (try? await db.work(target.id)) != nil { go(.work(target.id)) }
                default: break
                }
            }; return .handled
        }
        if let ref = BookletSource.reference(url) {
            Task {
                if let album = try? await db.album(ref.albumID), let path = album.attachments.first(where: { TextKey.hash($0) == ref.fileID }) { openBooklet(album, path: path, page: ref.page) }
            }; return .handled
        }
        return SafeLink.url(url.absoluteString) == nil ? .discarded : .systemAction
    }
    func reveal(_ track: Track) {
        detailStates["album:" + track.albumID, default: DetailState()].scroll = track.id
        highlightedTrack = track.id; go(.album(track.albumID))
    }
}
