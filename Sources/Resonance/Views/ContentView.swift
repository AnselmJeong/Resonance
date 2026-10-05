import SwiftUI
import ResonanceCore

struct ContentView: View {
    @Bindable var model: AppModel
    @FocusState private var searchFocused: Bool
    var body: some View {
        NavigationSplitView {
            SidebarView(model: model).navigationSplitViewColumnWidth(min: 175, ideal: 205, max: 255)
        } detail: {
            Group {
                switch model.destination {
                case .library: LibraryView(model: model)
                case .track(let id): TrackDetailView(model: model, trackID: id).id(id)
                case .album(let id): AlbumDetailView(model: model, albumID: id).id(id)
                case .artist(let id): EntityDetailView(model: model, entityID: id, kind: "artist").id(id)
                case .work(let id): EntityDetailView(model: model, entityID: id, kind: "work").id(id)
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button { model.back() } label: { Image(systemName: "chevron.left") }.disabled(model.history.isEmpty).help("이전 화면")
                    Button { model.forward() } label: { Image(systemName: "chevron.right") }.disabled(model.future.isEmpty).help("다음 화면")
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("앨범, 트랙, 음악가, 작품 검색", text: $model.query).textFieldStyle(.plain).focused($searchFocused)
                        if !model.query.isEmpty { Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                    }.padding(7).frame(width: 300).background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                }
                ToolbarItemGroup {
                    Button { searchFocused = true } label: { Image(systemName: "magnifyingglass") }.keyboardShortcut("f").help("라이브러리 검색")
                    Button { model.chooseRoot() } label: { Image(systemName: "folder.badge.plus") }.help("음악 폴더 추가")
                    Button { model.inspector.toggle() } label: { Image(systemName: "sidebar.right") }.help("감상 정보 표시")
                    SettingsLink { Label("설정", systemImage: "gearshape") }
                        .labelStyle(.titleAndIcon)
                        .help("설정 열기")
                        .accessibilityLabel("설정 열기")
                }
            }
        }
        .inspector(isPresented: $model.inspector) { NowPlayingInspector(model: model).inspectorColumnWidth(min: 260, ideal: 300, max: 380) }
        .safeAreaInset(edge: .bottom, spacing: 0) { PlaybackBar(model: model) }
        .frame(minWidth: 1000, minHeight: 650)
        .onChange(of: model.query) { _, _ in model.scheduleSearch() }
        .environment(\.openURL, OpenURLAction { model.openStoryURL($0) })
        .sheet(item: $model.booklet) { BookletView(model: model, selection: $0) }
        .sheet(isPresented: $model.queueVisible) { QueueView(model: model) }
        .alert("알림", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("확인") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}

struct SidebarView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.circle.fill").font(.system(size: 29)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) { Text("Resonance").font(.headline); Text("음악을 듣고, 알아가는 시간").font(.caption2).foregroundStyle(.secondary) }
                Spacer()
            }.padding(.horizontal, 16).padding(.vertical, 18)
            List(selection: $model.selection) {
                Section("라이브러리") {
                    Label("모든 앨범", systemImage: "square.grid.2x2").tag("all")
                    Label("즐겨찾기", systemImage: "heart").tag("favorites")
                    Label("음악가", systemImage: "person.2").tag("artists")
                }
                if !model.roots.isEmpty {
                    Section("음악 폴더") {
                        ForEach(model.rootGroups) { root in
                            Label(root.name, systemImage: root.connected ? "folder" : "externaldrive.badge.exclamationmark")
                                .tag(root.id)
                                .help(root.help)
                        }
                    }
                }
                if let root = model.collectionRoot, !model.visibleSections.isEmpty {
                    Section("\(root.name) 컬렉션") {
                        ForEach(model.visibleSections) { section in Label(section.name, systemImage: "music.note.list").tag(section.id) }
                    }
                }
            }.listStyle(.sidebar)
            .onChange(of: model.selection) { _, value in model.selectSection(value) }
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                Text("\(model.counts.albums.formatted()) 앨범 · \(model.counts.tracks.formatted()) 트랙").font(.caption).foregroundStyle(.secondary)
                ScanStatusView(model: model)
                if !model.connected { Label("음악 볼륨을 다시 연결하세요", systemImage: "externaldrive.badge.exclamationmark").font(.caption).foregroundStyle(.orange) }
                if !model.scanning {
                    HStack { Button { model.startScan() } label: { Label("재스캔", systemImage: "arrow.clockwise") }.disabled(model.roots.isEmpty); Spacer() }.buttonStyle(.borderless).font(.caption)
                }
            }.padding(16)
        }
    }
}
