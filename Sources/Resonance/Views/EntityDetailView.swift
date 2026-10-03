import SwiftUI
import ResonanceCore

struct EntityDetailView: View {
    let model: AppModel
    let entityID: String
    let kind: String
    @State private var artist: Artist?
    @State private var work: Work?
    @State private var tracks: [Track] = []
    @State private var albums: [String: Album] = [:]
    @State private var narrowed = false
    @State private var alias = ""
    @State private var loaded = false
    var title: String { artist?.name ?? work?.title ?? "" }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 20) {
                    Image(systemName: kind == "artist" ? "person.crop.circle" : "music.quarternote.3").font(.system(size: 65, weight: .ultraLight)).foregroundStyle(.secondary).frame(width: 90, height: 90).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 10) {
                        Text(kind == "artist" ? "음악가" : "작품").font(.caption).foregroundStyle(.secondary)
                        Text(title).font(.largeTitle.weight(.semibold)).textSelection(.enabled)
                        Text("내 라이브러리의 \(Set(tracks.map(\.albumID)).count) 앨범 · \(tracks.count) 트랙").foregroundStyle(.secondary)
                        if let artist, artist.externalID == nil { Text("로컬 태그의 임시 인물 · 앨범 간 동명이인을 자동 병합하지 않습니다.").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if let story { StoryPanel(model: model, request: story) }
                HStack { Spacer(); Toggle("현재 컬렉션만", isOn: $narrowed).disabled(model.sectionID == nil) }
                if let artist {
                    HStack { TextField("검색에 사용할 확인된 별칭", text: $alias); Button("별칭 추가") { Task { do { try await model.db.addAlias(artistID: artist.id, alias: alias); alias = ""; await load() } catch { model.error = error.localizedDescription } } }.disabled(alias.isEmpty) }
                    if !artist.aliases.isEmpty { Text(artist.aliases.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                }
                ForEach(Set(tracks.map(\.albumID)).sorted(), id: \.self) { albumID in
                    if let album = albums[albumID] {
                        HStack { ArtworkView(path: album.artwork, size: 55); Button { model.go(.album(album.id)) } label: { VStack(alignment: .leading) { Text(album.title).font(.headline); Text(album.artist).foregroundStyle(.secondary).font(.caption) } }.buttonStyle(.plain); Spacer() }
                        ForEach(tracks.filter { $0.albumID == albumID }) { track in TrackRow(model: model, track: track, play: { Task { await model.playback.play([track]) } }) }
                        Divider()
                    }
                }
            }.padding(28)
        }.task { await load() }.onChange(of: narrowed) { _, _ in Task { await load() } }
    }
    /// Built once the library context (albums, composers) is known, so searches can tell namesakes apart.
    private var story: StoryRequest? {
        guard loaded else { return nil }
        let albumTitles = Set(tracks.map(\.albumID)).sorted().compactMap { albums[$0]?.title }
        if let artist { return .artist(artist, albums: albumTitles) }
        if let work { return .work(work, composers: Array(Set(tracks.flatMap(\.credits).filter { $0.role == "composer" }.map(\.name))).sorted(), albums: albumTitles) }
        return nil
    }
    private func load() async {
        do {
            if kind == "artist" { artist = try await model.db.artist(entityID); tracks = try await model.db.artistTracks(entityID, sectionID: narrowed ? model.sectionID : nil) }
            else { work = try await model.db.work(entityID); tracks = try await model.db.workTracks(entityID) }
            for id in Set(tracks.map(\.albumID)) { albums[id] = try await model.db.album(id) }
            loaded = true
        } catch { model.error = error.localizedDescription }
    }
}
