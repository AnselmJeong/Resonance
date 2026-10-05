import SwiftUI
import AppKit
import ResonanceCore

struct AlbumDetailView: View {
    let model: AppModel
    let albumID: String
    @State private var album: Album?
    @State private var tracks: [Track] = []
    @State private var matchVisible = false
    @State private var editVisible = false
    var body: some View {
        Group {
            if let album {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 26) {
                        HStack(alignment: .top, spacing: 26) {
                            ArtworkView(path: album.artwork, size: 205).shadow(color: .black.opacity(0.12), radius: 12, y: 5)
                            VStack(alignment: .leading, spacing: 12) {
                                Text("ALBUM").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                                Text(album.title).font(.system(size: 30, weight: .semibold)).textSelection(.enabled)
                                if let performer = tracks.flatMap(\.credits).first(where: { $0.role == "performer" && $0.name == album.artist }) {
                                    Button(album.artist) { model.go(.artist(performer.artistID)) }.buttonStyle(.plain).foregroundStyle(.tint).font(.title3)
                                } else { Text(album.artist).font(.title3).foregroundStyle(.secondary) }
                                Text([album.year, album.label, "\(tracks.count)곡", clockText(album.duration)].filter { !$0.isEmpty }.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
                                if let first = tracks.first { Text("원본 음원  \(first.sourceFormat)").font(.caption).foregroundStyle(.secondary) }
                                HStack {
                                    Button { model.playAlbum(album) } label: { Label("앨범 재생", systemImage: "play.fill") }.buttonStyle(.borderedProminent)
                                    Menu { Button("다음에 재생") { model.enqueue(album, next: true) }; Button("큐에 추가") { model.enqueue(album) } } label: { Image(systemName: "text.badge.plus") }.menuStyle(.borderlessButton).frame(width: 28)
                                    Button { model.favorite(album); self.album?.favorite.toggle() } label: { Image(systemName: album.favorite ? "heart.fill" : "heart") }.buttonStyle(.borderless).help("즐겨찾기")
                                }.padding(.top, 8)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        HStack(spacing: 16) {
                            Button { matchVisible = true } label: { Label("크레디트 검토", systemImage: "person.text.rectangle") }
                            Menu {
                                Button("앨범 표시 정보 수정…") { editVisible = true }
                                Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: album.folder)]) }.disabled(model.roots.first(where: { $0.id == album.rootID })?.smb != nil)
                            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 22)
                            if !album.attachments.isEmpty {
                                Menu("부클릿", systemImage: "doc.richtext") { ForEach(album.attachments, id: \.self) { path in Button(URL(fileURLWithPath: path).lastPathComponent) { model.openBooklet(album, path: path) } } }
                            }
                            Spacer()
                        }.buttonStyle(.borderless).font(.callout)
                        MetadataStatusView(model: model, album: album) { matchVisible = true }.id("metadata")
                        if !album.attachments.isEmpty { BookletLinks(model: model, album: album).id("booklet") }
                        StoryPanel(model: model, request: .album(album, tracks: tracks)).id("story")
                        LazyVStack(spacing: 0) {
                            ForEach(Array(Set(tracks.map(\.disc))).sorted(), id: \.self) { disc in
                                if Set(tracks.map(\.disc)).count > 1 { Text("DISC \(disc)").font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 14) }
                                ForEach(tracks.filter { $0.disc == disc }) { track in
                                    TrackRow(model: model, track: track, play: { model.playAlbum(album, start: tracks.firstIndex(where: { $0.id == track.id }) ?? 0) }).id(track.id)
                                        .background(model.highlightedTrack == track.id ? Color.accentColor.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                                    Divider().opacity(0.45)
                                }
                            }
                        }.scrollTargetLayout()
                        if !album.barcode.isEmpty { Text("판 UPC  \(album.barcode)").font(.caption).foregroundStyle(.tertiary).textSelection(.enabled) }
                    }.padding(28).scrollTargetLayout()
                }.scrollPosition(id: Binding(get: { model.detailStates["album:" + albumID]?.scroll }, set: { model.detailStates["album:" + albumID, default: DetailState()].scroll = $0 }))
                .sheet(isPresented: $matchVisible, onDismiss: { Task { await load() } }) { MatchReviewView(model: model, album: album, local: tracks) }
                .sheet(isPresented: $editVisible, onDismiss: { Task { await load(); await model.reload() } }) { AlbumEditView(model: model, album: album) }
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.task(id: albumID + String(model.discovery.revision)) { await load() }
    }
    private func load() async { do { let loadedTracks = try await model.db.tracks(albumID: albumID), loaded = try await model.db.album(albumID); tracks = loadedTracks; if let loaded { album = loaded; album = await model.refreshBooklets(loaded) } else { album = nil } } catch { model.error = error.localizedDescription } }
}

struct TrackRow: View {
    let model: AppModel
    let track: Track
    let play: () -> Void
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: play) { if model.playback.current?.id == track.id { Image(systemName: "waveform").foregroundStyle(.tint) } else { Text(String(format: "%02d", track.number)).monospacedDigit().foregroundStyle(.secondary) } }.buttonStyle(.plain).frame(width: 30).help("이 트랙부터 재생")
            VStack(alignment: .leading, spacing: 5) {
                Button { model.go(.track(track.id)) } label: { Text(track.title).font(.system(size: 13, weight: model.playback.current?.id == track.id ? .semibold : .regular)).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain).help("곡 상세 · 작품과 관련 음반")
                let composers = track.credits.filter { $0.role == "composer" }
                if composers.isEmpty { Text("작곡자 미확정").font(.caption2).foregroundStyle(.tertiary) }
                else { CreditLinks(model: model, credits: composers) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if !track.available || !track.supported { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).help(track.supported ? "연결되지 않은 음원" : "미지원 형식") }
            Text(clockText(track.duration)).font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 45, alignment: .trailing)
            Menu {
                Button("곡 상세와 관련 음반") { model.go(.track(track.id)) }
                Button("앨범에서 보기") { model.reveal(track) }
                Button("재생", action: play)
                Button("다음에 재생") { Task { await model.playback.append([track], next: true) } }
                Button("큐에 추가") { Task { await model.playback.append([track]) } }
                Section("크레디트") { ForEach(track.credits) { credit in Button("\(credit.roleLabel) · \(credit.name)") { model.go(.artist(credit.artistID)) } } }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 25)
        }.padding(.vertical, 12).contentShape(Rectangle()).onTapGesture(count: 2, perform: play)
    }
}

struct CreditLinks: View {
    let model: AppModel
    let credits: [Credit]
    var body: some View {
        HStack(spacing: 7) {
            ForEach(Array(credits.prefix(3))) { credit in Button(credit.name) { model.go(.artist(credit.artistID)) }.buttonStyle(.plain).foregroundStyle(.tint).font(.caption).lineLimit(1).help("\(credit.roleLabel) · \(credit.source == "local" ? "로컬 태그" : "MusicBrainz")") }
        }
    }
}

struct AlbumEditView: View {
    let model: AppModel
    let album: Album
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var artist = ""
    @State private var artwork: String?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("앨범 표시 정보").font(.title2)
            Text("수정값은 앱에 저장되며 원본 태그와 파일은 보존됩니다.").font(.callout).foregroundStyle(.secondary)
            Form { TextField("앨범명", text: $title); TextField("아티스트", text: $artist); Button("커버 이미지 선택…") { selectArtwork() } }
            if let error { Text(error).foregroundStyle(.red) }
            HStack { Spacer(); Button("취소") { dismiss() }; Button("저장") { Task { do { try await model.db.editAlbum(album.id, title: title, artist: artist, artwork: artwork); dismiss() } catch { self.error = error.localizedDescription } } }.buttonStyle(.borderedProminent).disabled(title.isEmpty || artist.isEmpty) }
        }.padding(26).frame(width: 480).onAppear { title = album.title; artist = album.artist }
    }
    private func selectArtwork() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.jpeg, .png]; panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            Task { do { artwork = try await Task.detached { try ArtworkCache.thumbnail(source: url, embedded: nil, key: UUID().uuidString, directory: AppPaths.cache) }.value } catch { self.error = error.localizedDescription } }
        }
    }
}
