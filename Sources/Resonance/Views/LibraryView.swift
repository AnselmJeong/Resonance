import SwiftUI
import AppKit
import ResonanceCore

private enum ArtworkMemory { static let cache: NSCache<NSString, NSImage> = { let cache = NSCache<NSString, NSImage>(); cache.countLimit = 100; cache.totalCostLimit = 48 * 1024 * 1024; return cache }() }

struct ArtworkView: View {
    let path: String?
    var size: CGFloat = 180
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { Image(systemName: "music.note").font(.system(size: size / 4, weight: .light)).foregroundStyle(.tertiary) }
        }
        .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 5))
        .task(id: path) {
            image = nil; guard let path else { return }
            if let cached = ArtworkMemory.cache.object(forKey: path as NSString) { image = cached; return }
            let data = await Task.detached(priority: .utility) { try? Data(contentsOf: URL(fileURLWithPath: path)) }.value
            guard !Task.isCancelled, let data, let loaded = NSImage(data: data) else { return }
            ArtworkMemory.cache.setObject(loaded, forKey: path as NSString, cost: 480 * 480 * 4); image = loaded
        }
        .accessibilityLabel("앨범 커버")
    }
}

struct LibraryView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.query.isEmpty ? model.header : "검색 결과").font(.system(size: 28, weight: .semibold))
                    Text(model.query.isEmpty ? model.librarySubtitle : model.searchSection && model.hasSearchScope ? "\(model.header)에서 찾은 음악" : "전체 라이브러리에서 찾은 음악")
                        .foregroundStyle(.secondary).font(.callout).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if model.query.isEmpty && model.selection != "artists" {
                    Picker("정렬", selection: $model.sort) { Text("앨범명").tag("title"); Text("아티스트").tag("artist"); Text("최신 발매").tag("date") }.frame(width: 135).labelsHidden()
                }
            }.padding(26)
            if !model.query.isEmpty {
                HStack {
                    Toggle(model.searchScopeLabel, isOn: $model.searchSection).toggleStyle(.checkbox).disabled(!model.hasSearchScope)
                    Picker("역할", selection: $model.roleFilter) { Text("모든 역할").tag("all"); Text("작곡").tag("composer"); Text("연주").tag("performer"); Text("지휘").tag("conductor") }.frame(width: 140)
                    Picker("형식", selection: $model.formatFilter) { Text("모든 형식").tag("all"); Text("FLAC").tag("FLAC"); Text("MP3").tag("MP3") }.frame(width: 140)
                    Spacer()
                }.padding(.horizontal, 26).padding(.bottom, 15)
                SearchResultsView(model: model)
            } else if model.roots.isEmpty {
                ContentUnavailableView {
                    Label("음악 컬렉션을 만나보세요", systemImage: "opticaldisc")
                } description: { Text("음악 폴더를 선택하면 앨범 커버와 트랙이 나타납니다.\n원본 음악은 그대로 두고, 인터넷 없이도 감상할 수 있습니다.") } actions: { Button("음악 폴더 선택…") { model.chooseRoot() }.buttonStyle(.borderedProminent) }
            } else if model.selection == "artists" {
                List(model.people) { artist in Button { model.go(.artist(artist.id)) } label: { HStack { Image(systemName: "person.crop.circle").font(.title2).foregroundStyle(.secondary); VStack(alignment: .leading) { Text(artist.name); Text(artist.role == "composer" ? "작곡가" : "음악가 · 로컬 태그").font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary) }.padding(.vertical, 6) }.buttonStyle(.plain) }
            } else if model.albums.isEmpty {
                ContentUnavailableView(model.scanning ? "음악을 찾고 있습니다" : "아직 앨범이 없습니다", systemImage: model.scanning ? "waveform" : "square.grid.2x2", description: Text(model.selection == "favorites" ? "앨범의 하트를 눌러 여기에 모아두세요." : "라이브러리를 재스캔하거나 다른 음악 폴더를 추가하세요."))
            } else {
                ScrollView {
                  LazyVStack(spacing: 0) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 174, maximum: 205), spacing: 22)], alignment: .leading, spacing: 26) {
                        ForEach(model.albums) { album in
                            AlbumCard(model: model, album: album)
                                .task { await model.loadMoreAlbums(after: album.id) }
                        }
                    }.scrollTargetLayout().padding(.horizontal, 26).padding(.bottom, 24)
                    HStack {
                        Text("\(model.albums.count.formatted())개 앨범 표시").font(.caption).foregroundStyle(.secondary)
                        if model.canLoadMore {
                            Button("더 보기") { Task { await model.refreshGrid(more: true) } }.disabled(model.loading)
                        }
                        if model.loading { ProgressView().controlSize(.small) }
                    }.padding(.bottom, 24)
                  }
                }.scrollPosition(id: Binding(get: { model.scrollPositions[model.selection] }, set: { model.scrollPositions[model.selection] = $0 }))
            }
        }
        .onChange(of: model.sort) { _, _ in Task { await model.refreshGrid() } }
        .onChange(of: model.searchSection) { _, _ in model.scheduleSearch() }
        .onChange(of: model.roleFilter) { _, _ in model.scheduleSearch() }
        .onChange(of: model.formatFilter) { _, _ in model.scheduleSearch() }
    }
}

struct AlbumCard: View {
    let model: AppModel
    let album: Album
    @State private var hovering = false
    @State private var loadedArtwork: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .bottomTrailing) {
                Button { model.go(.album(album.id)) } label: { ArtworkView(path: loadedArtwork ?? album.artwork) }.buttonStyle(.plain)
                if hovering {
                    Button { model.playAlbum(album) } label: { Image(systemName: "play.fill").font(.title3).padding(13).background(.regularMaterial, in: Circle()) }.buttonStyle(.plain).padding(10).help("앨범 재생")
                }
            }
            Text(album.title).font(.system(size: 13, weight: .semibold)).lineLimit(2).frame(maxWidth: 180, alignment: .leading)
            Text(album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack { Text(album.year.isEmpty ? "\(album.trackCount) 트랙" : "\(album.year) · \(album.trackCount) 트랙").font(.caption2).foregroundStyle(.tertiary); if album.favorite { Image(systemName: "heart.fill").font(.caption2).foregroundStyle(.tint) } }
        }.frame(maxWidth: .infinity, alignment: .leading).onHover { hovering = $0 }
        .task(id: album.artwork) { loadedArtwork = await model.loadArtwork(album) }
        .contextMenu {
            Button("앨범 재생", systemImage: "play") { model.playAlbum(album) }
            Button("다음에 재생") { model.enqueue(album, next: true) }
            Button("큐에 추가") { model.enqueue(album) }
            Button(album.favorite ? "즐겨찾기 해제" : "즐겨찾기에 추가") { model.favorite(album) }
            Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: album.folder)]) }
        }
    }
}

struct SearchResultsView: View {
    let model: AppModel
    var body: some View {
        if model.searchHits.isEmpty { ContentUnavailableView.search(text: model.query) }
        else {
            List {
                ForEach([("album", "앨범"), ("track", "트랙"), ("artist", "음악가"), ("work", "작품")], id: \.0) { kind, title in
                    let hits = model.searchHits.filter { $0.kind == kind }
                    if !hits.isEmpty {
                        Section(title) {
                            ForEach(hits) { hit in
                                HStack {
                                    Button { navigate(hit) } label: { VStack(alignment: .leading, spacing: 4) { Text(hit.title).lineLimit(2); Text(hit.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5) }.buttonStyle(.plain)
                                    if kind == "track" { Button { Task { if let track = try? await model.db.track(hit.entityID) { await model.playback.play([track]) } } } label: { Image(systemName: "play.circle") }.buttonStyle(.borderless).help("트랙 재생") }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    private func navigate(_ hit: SearchHit) {
        switch hit.kind {
        case "album": model.go(.album(hit.entityID))
        case "track": model.go(.track(hit.entityID))
        case "artist": model.go(.artist(hit.entityID))
        case "work": model.go(.work(hit.entityID))
        default: break
        }
    }
}
