import SwiftUI
import ResonanceCore

struct MetadataStatusView: View {
    let model: AppModel
    let album: Album
    let review: () -> Void
    var state: MetadataState { model.discovery.states[album.id] ?? MetadataState() }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if state.busy { ProgressView().controlSize(.small) }
            else { Image(systemName: state.snapshot?.confirmed == true ? "checkmark.seal" : "point.3.connected.trianglepath.dotted").foregroundStyle(.tint) }
            VStack(alignment: .leading, spacing: 5) {
                Text(state.busy ? "앨범 정보와 연결을 준비하고 있습니다" : "음악 정보").font(.callout.weight(.semibold))
                Text(state.error ?? state.snapshot?.message ?? (model.settings.enabled ? "MusicBrainz에서 크레디트·작품·커버를 확인합니다." : "로컬 태그와 부클릿으로 탐색할 수 있습니다. 온라인 보완은 설정에서 켤 수 있습니다."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let checked = state.snapshot?.checked { Text("MusicBrainz · \(checked.formatted(date: .abbreviated, time: .shortened)) 확인").font(.caption2).foregroundStyle(.tertiary) }
            }
            Spacer()
            Button("검토", action: review).disabled(state.busy)
            if model.settings.enabled {
                Button(state.error == nil ? "새로 확인" : "다시 시도") { Task { await model.discovery.prepare(album, enabled: true, force: true) } }.disabled(state.busy)
            } else { SettingsLink { Text("설정") } }
        }.padding(14).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            .task(id: album.id + String(model.settings.enabled) + String(model.discovery.revision)) { await model.discovery.prepare(album, enabled: model.settings.enabled) }
    }
}

struct RelatedAlbumsView: View {
    let model: AppModel
    let trackID: String
    var compact = false
    @State private var related: [RelatedAlbum] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("이어서 발견하기").font(compact ? .subheadline.weight(.semibold) : .title3.weight(.semibold))
            if related.isEmpty {
                Text("같은 작품이나 참여자가 연결된 다른 음반이 아직 없습니다. 앨범의 크레디트를 연결하면 여기에 모입니다.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(related.prefix(compact ? 3 : 6)) { item in
                HStack(spacing: 12) {
                    Button { model.go(.album(item.album.id)) } label: { ArtworkView(path: item.album.artwork, size: compact ? 46 : 64) }.buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.reason).font(.caption2).foregroundStyle(.tint).lineLimit(2)
                        Button(item.album.title) { model.go(.album(item.album.id)) }.buttonStyle(.plain).font(.callout.weight(.medium)).lineLimit(2)
                        Text(item.album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Button("연결된 곡 보기") { model.go(.track(item.trackID)) }.buttonStyle(.borderless).font(.caption)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if !compact { Button { model.playAlbum(item.album) } label: { Image(systemName: "play.fill") }.buttonStyle(.borderless).help("이 앨범 재생") }
                }
            }
        }.task(id: trackID + String(model.discovery.revision)) { related = (try? await model.db.relatedAlbums(trackID: trackID)) ?? [] }
    }
}

struct TrackDetailView: View {
    let model: AppModel
    let trackID: String
    @State private var track: Track?
    @State private var album: Album?
    @State private var works: [Work] = []
    @State private var matchVisible = false
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if let track, let album {
                    HStack(alignment: .top, spacing: 24) {
                        ArtworkView(path: album.artwork, size: 155)
                        VStack(alignment: .leading, spacing: 12) {
                            Text("TRACK · \(track.disc).\(track.number)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(track.title).font(.title.weight(.semibold)).textSelection(.enabled)
                            Button(album.title) { model.reveal(track) }.buttonStyle(.plain).foregroundStyle(.tint)
                            Text("\(clockText(track.duration)) · \(track.sourceFormat)").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button { Task { await model.playback.play([track]) } } label: { Label("이 곡 재생", systemImage: "play.fill") }.buttonStyle(.borderedProminent).disabled(!track.available || !track.supported)
                                Button("다음에 재생") { Task { await model.playback.append([track], next: true) } }
                            }
                        }
                    }.id("header")
                    MetadataStatusView(model: model, album: album) { matchVisible = true }.id("metadata")
                    VStack(alignment: .leading, spacing: 12) {
                        Text("작품과 참여 음악가").font(.title3.weight(.semibold))
                        ForEach(works) { work in
                            Button { model.go(.work(work.id)) } label: { Label(work.title + " · 다른 연주 비교", systemImage: "music.quarternote.3") }.buttonStyle(.borderless)
                        }
                        if works.isEmpty { Text("작품이 아직 식별되지 않았습니다. 크레디트 검토 또는 부클릿에서 확인하세요.").font(.caption).foregroundStyle(.secondary) }
                        ForEach(track.credits) { credit in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(credit.roleLabel).font(.caption).foregroundStyle(.secondary).frame(width: 45, alignment: .leading)
                                Button(credit.name) { model.go(.artist(credit.artistID)) }.buttonStyle(.borderless)
                                Text((credit.attributes ?? []).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.id("credits")
                    RelatedAlbumsView(model: model, trackID: track.id).id("related")
                    if !album.attachments.isEmpty { BookletLinks(model: model, album: album).id("booklet") }
                    StoryPanel(model: model, request: .track(track, album: album), auto: false).id("story")
                } else { ProgressView().frame(maxWidth: .infinity).padding(40) }
            }.padding(28).scrollTargetLayout()
        }.scrollPosition(id: Binding(get: { model.detailStates["track:" + trackID]?.scroll }, set: { model.detailStates["track:" + trackID, default: DetailState()].scroll = $0 }))
            .task(id: trackID + String(model.discovery.revision)) {
                do { track = try await model.db.track(trackID); if let track { if let loaded = try await model.db.album(track.albumID) { album = await model.refreshBooklets(loaded) }; works = try await model.db.works(trackID: trackID) } }
                catch { model.error = error.localizedDescription }
            }
            .sheet(isPresented: $matchVisible) { if let album { MatchReviewLoader(model: model, album: album) } }
    }
}

struct MatchReviewLoader: View {
    let model: AppModel
    let album: Album
    @State private var tracks: [Track]?
    var body: some View {
        Group { if let tracks { MatchReviewView(model: model, album: album, local: tracks) } else { ProgressView().padding(40) } }
            .task { tracks = try? await model.db.tracks(albumID: album.id) }
    }
}

struct BookletLinks: View {
    let model: AppModel
    let album: Album
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("음반 속 이야기 · 부클릿").font(.headline)
            Text("해설과 크레디트를 원문 페이지에서 확인하세요.").font(.caption).foregroundStyle(.secondary)
            ForEach(album.attachments.filter { URL(fileURLWithPath: $0).pathExtension.lowercased() == "pdf" }, id: \.self) { path in
                Button { model.openBooklet(album, path: path) } label: { Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "book.pages") }.buttonStyle(.borderless)
            }
        }
    }
}

struct IdentityLinkView: View {
    let model: AppModel
    let entityID: String
    let kind: String
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var candidates: [IdentityCandidate] = []
    @State private var selected: Set<String> = []
    @State private var revision = 0
    @State private var message: String?
    private var namesakes: [String] { candidates.filter { TextKey.normalize($0.name) == TextKey.normalize(name) }.map(\.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("동일한 \(kind == "artist" ? "음악가" : "작품") 연결").font(.title2); Spacer(); Button("닫기") { dismiss() } }
            Text(kind == "artist" ? "이름이 같은 음악가는 자동으로 묶입니다. 표기가 다른 같은 사람은 골라서 한 번에 연결하고, 다른 사람이 섞였다면 연결을 모두 푼 뒤 다시 고르세요. 원본 태그는 유지됩니다." : "\(name)과 같은 대상인지 참여 음반을 확인한 뒤 골라서 한 번에 연결하세요. 원본 태그는 유지됩니다.").font(.callout).foregroundStyle(.secondary)
            TextField("이름 또는 작품명 검색", text: $query).textFieldStyle(.roundedBorder)
            List(candidates) { candidate in
                Toggle(isOn: Binding(get: { selected.contains(candidate.id) }, set: { if $0 { selected.insert(candidate.id) } else { selected.remove(candidate.id) } })) {
                    VStack(alignment: .leading, spacing: 5) { Text(candidate.name); Text(candidate.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                        .padding(.leading, 6).frame(maxWidth: .infinity, alignment: .leading)
                }.toggleStyle(.checkbox).padding(.vertical, 8)
            }.overlay { if candidates.isEmpty { ContentUnavailableView("연결할 다른 항목이 없습니다", systemImage: "person.crop.circle.badge.questionmark", description: Text("이름이나 작품명을 바꿔 검색해 보세요.")) } }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button(kind == "artist" ? "연결 모두 풀기" : "이 대상의 수동 연결 해제") { Task { do { try await model.db.unlinkIdentity(entityID, kind: kind); model.discovery.changed(); dismiss() } catch { message = error.localizedDescription } } }
                Spacer()
                if !namesakes.isEmpty {
                    Button(Set(namesakes).isSubset(of: selected) ? "선택 해제" : "같은 이름 \(namesakes.count)개 모두 선택") {
                        if Set(namesakes).isSubset(of: selected) { selected.removeAll() } else { selected.formUnion(namesakes) }
                    }
                }
                Button("선택한 \(selected.count)개 연결") { link() }.buttonStyle(.borderedProminent).disabled(selected.isEmpty)
            }
        }.padding(24).frame(width: 650, height: 510)
            .onAppear { query = name }
            .task(id: "\(query)|\(revision)") {
                try? await Task.sleep(for: .milliseconds(250)); guard !Task.isCancelled else { return }
                let found = (try? await model.db.identityCandidates(entityID, kind: kind, query: query)) ?? []
                guard !Task.isCancelled else { return }; candidates = found; selected.formIntersection(found.map(\.id))
            }
    }
    /// Stays open on the refreshed list so further matches can be joined without reopening.
    private func link() {
        let targets = candidates.map(\.id).filter(selected.contains)
        Task {
            do {
                try await model.db.linkIdentities(entityID, to: targets, kind: kind)
                selected = []; message = "\(targets.count)개 항목을 연결했습니다."; revision += 1; model.discovery.changed()
            } catch { message = error.localizedDescription }
        }
    }
}
