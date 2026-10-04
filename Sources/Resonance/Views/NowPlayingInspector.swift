import SwiftUI
import ResonanceCore

struct NowPlayingInspector: View {
    let model: AppModel
    @State private var works: [Work] = []
    @State private var resolvedTrack: Track?
    @State private var resolvedAlbum: Album?
    var track: Track? { resolvedTrack?.id == model.playback.current?.id ? resolvedTrack : model.playback.current }
    var album: Album? { resolvedAlbum?.id == track?.albumID ? resolvedAlbum : model.playback.currentAlbum }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack { Text("감상 노트").font(.headline); Spacer(); Image(systemName: "text.book.closed").foregroundStyle(.secondary) }
                if let track {
                    ArtworkView(path: album?.artwork, size: 230)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("NOW PLAYING").font(.caption2.weight(.semibold)).tracking(1.5).foregroundStyle(.secondary)
                        Button { model.go(.track(track.id)) } label: { Text(track.title).font(.title3.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
                        if let album { Button(album.title) { model.reveal(track) }.buttonStyle(.borderless).font(.callout) }
                    }
                    Divider()
                    if !works.isEmpty {
                        Text("연결된 작품").font(.subheadline.weight(.semibold))
                        ForEach(works) { work in Button(work.title) { model.go(.work(work.id)) }.buttonStyle(.plain).foregroundStyle(.tint).font(.callout) }
                        Divider()
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("크레디트").font(.subheadline.weight(.semibold))
                        ForEach(track.credits) { credit in
                            HStack(alignment: .top) { Text(credit.roleLabel).font(.caption).foregroundStyle(.secondary).frame(width: 34, alignment: .leading); Button(credit.name) { model.go(.artist(credit.artistID)) }.buttonStyle(.plain).foregroundStyle(.tint).font(.callout); Spacer() }
                        }
                        if !track.credits.contains(where: { $0.role == "composer" }) { Text("작곡자 정보가 없는 태그입니다. 크레디트 검토에서 출처를 확인할 수 있습니다.").font(.caption).foregroundStyle(.secondary) }
                    }
                    Divider()
                    RelatedAlbumsView(model: model, trackID: track.id, compact: true)
                    if let album, !album.attachments.isEmpty { BookletLinks(model: model, album: album) }
                    Divider()
                    StoryPanel(model: model, request: .track(track, album: model.playback.currentAlbum), auto: false, compact: true)
                    if let album = model.playback.currentAlbum {
                        Divider()
                        StoryPanel(model: model, request: .album(album, tracks: [track]), compact: true)
                    }
                    Divider()
                    Text("원본 음원\n\(track.sourceFormat) · \(track.channels) channels").font(.caption2).foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        Image(systemName: "waveform").font(.system(size: 44, weight: .ultraLight)).foregroundStyle(.tertiary).padding(.top, 35)
                        Text("지금 흐르는 음악의 이야기").font(.title3.weight(.medium))
                        Text("재생을 시작하면 곡의 크레디트와 저장된 설명이 이곳에 나타납니다.").font(.callout).foregroundStyle(.secondary).lineSpacing(4)
                    }
                    Spacer(minLength: 50)
                    Text("내 음악은 로컬에 그대로.\n더 깊은 감상은 출처와 함께.").font(.caption).foregroundStyle(.tertiary).lineSpacing(5)
                }
            }.padding(22)
        }
        .task(id: (model.playback.current?.id ?? "") + model.settings.language + String(model.discovery.revision) + String(model.settings.enabled)) {
            works = []; guard let id = model.playback.current?.id else { resolvedTrack = nil; resolvedAlbum = nil; return }
            let foundTrack = try? await model.db.track(id)
            var foundAlbum: Album?
            if let foundTrack, let loaded = try? await model.db.album(foundTrack.albumID) { foundAlbum = await model.refreshBooklets(loaded) }
            let related = (try? await model.db.works(trackID: id)) ?? []
            guard !Task.isCancelled, model.playback.current?.id == id else { return }
            resolvedTrack = foundTrack; resolvedAlbum = foundAlbum; works = related
            if let album = resolvedAlbum { await model.discovery.prepare(album, enabled: model.settings.enabled) }
        }
    }
}
