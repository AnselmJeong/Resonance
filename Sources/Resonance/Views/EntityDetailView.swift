import SwiftUI
import ResonanceCore

struct EntityDetailView: View {
    let model: AppModel
    let entityID: String
    let kind: String
    @State private var artist: Artist?
    @State private var work: Work?
    @State private var children: [Work] = []
    @State private var tracks: [Track] = []
    @State private var albums: [String: Album] = [:]
    @State private var recordingDates: [String: String] = [:]
    @State private var namesakes: [IdentityCandidate] = []
    @State private var alias = ""
    @State private var linking = false
    @State private var loaded = false
    @State private var width: CGFloat = 0
    /// Room for the story beside the name instead of under it.
    private var wide: Bool { width >= 980 }
    private var key: String { kind + ":" + entityID }
    private var state: DetailState { model.detailStates[key] ?? DetailState() }
    private var title: String { artist?.name ?? work?.title ?? "" }
    private var subjectID: String { artist?.id ?? work?.id ?? entityID }
    private func binding<T>(_ path: WritableKeyPath<DetailState, T>) -> Binding<T> {
        Binding(get: { state[keyPath: path] }, set: { model.detailStates[key, default: DetailState()][keyPath: path] = $0 })
    }
    private var roles: [String] { Array(Set(tracks.flatMap(\.credits).filter { $0.artistID == subjectID }.map(\.role))).sorted() }
    private var instruments: [String] { Array(Set(tracks.flatMap(\.credits).filter { $0.artistID == subjectID }.flatMap { $0.attributes ?? [] })).sorted() }
    private var collaborators: [Credit] {
        var seen = Set<String>()
        return tracks.flatMap(\.credits).filter { $0.artistID != subjectID && seen.insert($0.artistID).inserted }.sorted { $0.name < $1.name }
    }
    private var filtered: [Track] {
        tracks.filter { track in
            (!state.collectionOnly || model.sectionIDs == nil || model.sectionIDs?.contains(albums[track.albumID]?.sectionID ?? "") == true)
            && (state.role == "all" || track.credits.contains { $0.artistID == subjectID && $0.role == state.role })
            && (state.instrument == "all" || track.credits.contains { $0.artistID == subjectID && ($0.attributes ?? []).contains(state.instrument) })
            && (state.collaborator == "all" || track.credits.contains { $0.artistID == state.collaborator })
        }
    }
    private var visibleAlbums: [Album] { Set(filtered.map(\.albumID)).compactMap { albums[$0] }.sorted { ($0.date, $0.title) < ($1.date, $1.title) } }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                header.id("header")
                if let work, let parent = work.parentID {
                    Button { model.go(.work(parent)) } label: { Label(work.parentTitle ?? "상위 작품 보기", systemImage: "arrow.turn.up.left") }.buttonStyle(.borderless)
                }
                if !children.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("작품의 악장과 부분").font(.headline)
                        ForEach(children) { child in Button(child.title) { model.go(.work(child.id)) }.buttonStyle(.borderless) }
                    }.id("movements")
                }
                if let artist {
                    HStack {
                        TextField("검색에 사용할 확인된 별칭", text: $alias)
                        Button("별칭 추가") { Task { do { try await model.db.addAlias(artistID: artist.id, alias: alias); alias = ""; model.discovery.changed(); await load() } catch { model.error = error.localizedDescription } } }.disabled(alias.trimmingCharacters(in: .whitespaces).isEmpty)
                    }.id("alias")
                    if !artist.aliases.isEmpty { Text(artist.aliases.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                }
                filters.id("filters")
                if loaded && visibleAlbums.isEmpty && children.isEmpty {
                    ContentUnavailableView("조건에 맞는 연주가 없습니다", systemImage: "music.note", description: Text("필터를 해제하거나 다른 앨범의 동일 인물·작품을 연결해 보세요."))
                }
                ForEach(visibleAlbums) { album in
                    performance(album).id(album.id)
                }
                if !namesakes.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("같은 이름으로 등록된 다른 항목").font(.headline)
                        Text("아직 동일한 대상인지 확인되지 않았습니다. 참여 음반을 살펴보고 연결 관리에서 합칠 수 있습니다.").font(.caption).foregroundStyle(.secondary)
                        ForEach(namesakes) { candidate in
                            Button { model.go(kind == "artist" ? .artist(candidate.id) : .work(candidate.id)) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(candidate.name).font(.callout)
                                    Text(candidate.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.borderless)
                        }
                    }.id("namesakes")
                }
            }.padding(28).scrollTargetLayout()
        }.scrollPosition(id: binding(\.scroll))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .task(id: entityID + String(model.discovery.revision)) { await load() }
            .sheet(isPresented: $linking) { IdentityLinkView(model: model, entityID: entityID, kind: kind, name: title) }
    }
    /// Name and counts with the story beside them, like the album page's lead text; stacked when the window is narrow.
    /// One layout for both so the story keeps its state while the window is resized.
    private var header: some View {
        let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 36)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 24))
        return layout {
            identity.frame(width: wide ? 380 : nil, alignment: .leading).frame(maxWidth: wide ? nil : .infinity, alignment: .leading)
            if let story { StoryPanel(model: model, request: story, leading: wide) }
        }
    }
    private var identity: some View {
        HStack(alignment: .top, spacing: 20) {
            Image(systemName: kind == "artist" ? "person.crop.circle" : "music.quarternote.3").font(.system(size: 52, weight: .ultraLight)).foregroundStyle(.tint).frame(width: 90, height: 90).background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 10) {
                Text(kind == "artist" ? "음악가 · 참여 음반" : "작품 · 연주 비교").font(.caption).foregroundStyle(.secondary)
                Text(title).font(.largeTitle.weight(.semibold)).textSelection(.enabled)
                Text("내 라이브러리의 \(Set(tracks.map(\.albumID)).count) 앨범 · \(tracks.count) 트랙").foregroundStyle(.secondary)
                if !subjectID.hasPrefix("mb:") { Text("로컬 태그의 대상입니다. 같은 이름의 다른 항목은 확인 후 연결할 수 있습니다.").font(.caption).foregroundStyle(.secondary) }
                Button("동일 \(kind == "artist" ? "음악가" : "작품") 연결 관리…") { linking = true }.buttonStyle(.borderless)
            }.fixedSize(horizontal: false, vertical: true)
        }
    }
    private var filters: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(kind == "artist" ? "참여 음반 둘러보기" : "같은 작품, 다른 연주").font(.title3.weight(.semibold))
                Spacer()
                Toggle("현재 컬렉션만", isOn: binding(\.collectionOnly)).disabled(model.sectionIDs == nil).toggleStyle(.checkbox).font(.caption)
            }
            HStack {
                if kind == "artist" {
                    Picker("역할", selection: binding(\.role)) { Text("모든 역할").tag("all"); ForEach(roles, id: \.self) { role in Text(Credit(artistID: "", name: "", role: role).roleLabel).tag(role) } }
                    if !instruments.isEmpty { Picker("악기", selection: binding(\.instrument)) { Text("모든 악기").tag("all"); ForEach(instruments, id: \.self) { Text($0).tag($0) } } }
                }
                Picker("함께한 음악가", selection: binding(\.collaborator)) { Text("모두").tag("all"); ForEach(collaborators, id: \.artistID) { Text($0.name).tag($0.artistID) } }
                Button("초기화") { model.detailStates[key] = DetailState() }.buttonStyle(.borderless)
            }.controlSize(.small)
            if kind == "work" { Text("같은 작품 ID로 연결된 보유 연주입니다. 녹음일이 없는 경우 발매 연도를 표시하며, 반복·편집에 따라 길이가 다를 수 있습니다.").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func performance(_ album: Album) -> some View {
        let performance = filtered.filter { $0.albumID == album.id }.sorted { ($0.disc, $0.number) < ($1.disc, $1.number) }
        let performers = Array(Set(performance.flatMap(\.credits).filter { ["performer", "conductor", "ensemble"].contains($0.role) }.map(\.name))).sorted()
        let dates = Array(Set(performance.compactMap { recordingDates[$0.id] })).sorted()
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                Button { model.go(.album(album.id)) } label: { ArtworkView(path: album.artwork, size: 78) }.buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 6) {
                    Button(album.title) { model.go(.album(album.id)) }.buttonStyle(.plain).font(.headline)
                    Text(performers.isEmpty ? album.artist : performers.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
                    Text([dates.isEmpty ? (album.year.isEmpty ? "녹음일 미상" : "발매 " + album.year) : "녹음 " + dates.joined(separator: ", "), "\(performance.count)곡", clockText(performance.reduce(0) { $0 + $1.duration })].joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button { Task { await model.playback.play(performance) } } label: { Label(kind == "work" ? "이 연주 듣기" : "참여곡 재생", systemImage: "play.fill") }.buttonStyle(.borderedProminent)
                        Button("다음에 재생") { Task { await model.playback.append(performance, next: true) } }
                    }.controlSize(.small)
                }
                Spacer()
            }
            ForEach(performance) { track in TrackRow(model: model, track: track, play: { Task { await model.playback.play(performance, start: performance.firstIndex { $0.id == track.id } ?? 0) } }) }
        }.padding(18).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
    }
    private var story: StoryRequest? {
        guard loaded else { return nil }
        let titles = albums.values.sorted { $0.title < $1.title }.map(\.title)
        if let artist { return .artist(artist, albums: titles) }
        if let work { return .work(work, composers: Array(Set(tracks.flatMap(\.credits).filter { $0.role == "composer" }.map(\.name))).sorted(), albums: titles) }
        return nil
    }
    private func load() async {
        do {
            let canonical = try await model.db.canonicalID(entityID, kind: kind)
            if kind == "artist" { artist = try await model.db.artist(canonical); tracks = try await model.db.artistTracks(canonical) }
            else { work = try await model.db.work(canonical); tracks = try await model.db.workTracks(canonical); children = try await model.db.childWorks(canonical) }
            var found: [String: Album] = [:]
            for id in Set(tracks.map(\.albumID)) { found[id] = try await model.db.album(id) }
            albums = found; recordingDates = [:]
            if kind == "work" { for track in tracks { recordingDates[track.id] = try await model.db.recordingDetails(trackID: track.id)?.recordingDate } }
            let candidates = try await model.db.identityCandidates(canonical, kind: kind, query: title)
            guard !Task.isCancelled else { return }
            namesakes = Array(candidates.filter { TextKey.normalize($0.name) == TextKey.normalize(title) }.prefix(8))
            loaded = true
        } catch { model.error = error.localizedDescription }
    }
}
