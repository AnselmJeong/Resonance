import SwiftUI
import AppKit
import ResonanceCore

struct PlaybackBar: View {
    @Bindable var model: AppModel
    @State private var scrub: Double = 0
    @State private var scrubbing = false
    var playback: PlaybackCoordinator { model.playback }
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            if let error = playback.error {
                HStack { Image(systemName: "exclamationmark.circle"); Text(error).lineLimit(2); Spacer(); Button("닫기") { playback.error = nil } }.font(.caption).foregroundStyle(.orange).padding(.horizontal, 18).padding(.top, 8)
            }
            HStack(spacing: 22) {
                HStack(spacing: 11) {
                    Button {
                        if let albumID = playback.current?.albumID { model.go(.album(albumID)) }
                    } label: { ArtworkView(path: playback.currentAlbum?.artwork, size: 54) }
                    .buttonStyle(.plain).disabled(playback.current == nil)
                    .help("앨범 상세 보기").accessibilityLabel("재생 중인 앨범 상세 보기")
                    .accessibilityIdentifier("player-album-detail")
                    VStack(alignment: .leading, spacing: 4) {
                        Button { if let track = playback.current { model.go(.track(track.id)) } } label: { Text(playback.current?.title ?? "오늘은 어떤 음악을 들을까요?").font(.system(size: 12, weight: .medium)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
                        Text(playback.currentAlbum?.artist ?? "앨범을 선택해 감상을 시작하세요").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.frame(width: 260)
                VStack(spacing: 6) {
                    HStack(spacing: 22) {
                        Button { Task { await playback.previous() } } label: { Image(systemName: "backward.end.fill") }.help("이전 트랙")
                        Button { playback.toggle() } label: { Image(systemName: playback.state == .playing || playback.state == .buffering ? "pause.fill" : "play.fill").font(.system(size: 19)).frame(width: 34, height: 28) }.help("재생 / 일시 정지")
                        Button { Task { await playback.next() } } label: { Image(systemName: "forward.end.fill") }.help("다음 트랙")
                        if playback.state == .preparing || playback.state == .buffering { ProgressView().controlSize(.mini) }
                    }.buttonStyle(.plain).disabled(playback.current == nil)
                    HStack(spacing: 9) {
                        Text(clockText(scrubbing ? scrub : playback.position)).frame(width: 44, alignment: .trailing)
                        Slider(value: $scrub, in: 0...max(1, playback.current?.duration ?? 1), onEditingChanged: { editing in scrubbing = editing; if !editing { playback.seek(scrub) } }).disabled(playback.current == nil).accessibilityLabel("재생 위치")
                        Text(clockText(playback.current?.duration ?? 0)).frame(width: 44, alignment: .leading)
                    }.font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity)
                HStack(spacing: 12) {
                    Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
                    Slider(value: Bindable(playback).volume, in: 0...1).frame(width: 80).accessibilityLabel("음량")
                    OutputMenu(playback: playback)
                    Button { model.queueVisible = true } label: { Image(systemName: "list.bullet") }.buttonStyle(.plain).help("재생 큐")
                }
            }.padding(.horizontal, 20).padding(.vertical, 13)
        }.background(.bar)
        .onChange(of: playback.position) { _, value in if !scrubbing { scrub = value } }
    }
}

/// Chooses where this app's music plays. AirPlay receivers get the app's own stream;
/// the Mac's system output and other apps stay where they are.
struct OutputMenu: View {
    let playback: PlaybackCoordinator
    var body: some View {
        Menu {
            Section("음악 출력") {
                choice(.mac, "이 Mac · \(playback.output.name)")
                ForEach(playback.airPlay.receivers) { receiver in choice(.airPlay(receiver), receiver.name) }
                if playback.airPlay.receivers.isEmpty { Text("AirPlay 수신기를 찾는 중…") }
            }
            Section {
                if case .airPlay = playback.target {
                    Text("전송: ALAC 16-bit / 44.1 kHz (AirPlay)")
                    Text("앱 음량 100% = 감쇠 없음. 음량은 앰프에서 조절하세요")
                    Text("Mac의 시스템 소리는 이 Mac에 남습니다")
                } else if let rate = playback.output.nominalRate {
                    Text("기기 설정: \(String(format: "%g", rate / 1000)) kHz")
                }
                Text("원본 음질과 전송 음질은 다를 수 있습니다")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: playback.target == .mac ? "hifispeaker" : "airplayaudio")
                Text(playback.outputName).font(.caption).lineLimit(1).frame(maxWidth: 110, alignment: .leading)
            }
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("음악을 재생할 기기 선택")
    }

    private func choice(_ target: PlaybackCoordinator.OutputTarget, _ title: String) -> some View {
        Toggle(title, isOn: Binding(get: { playback.target == target }, set: { if $0 { Task { await playback.selectOutput(target) } } }))
    }
}

struct QueueView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack { VStack(alignment: .leading, spacing: 4) { Text("재생 큐").font(.title2.weight(.semibold)); Text("\(model.playback.entries.count) 트랙 · 탐색 중에도 재생은 이어집니다").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(22)
            if model.playback.entries.isEmpty { ContentUnavailableView("재생 큐가 비어 있습니다", systemImage: "music.note.list") }
            else {
                List(model.playback.entries) { entry in QueueRow(model: model, entry: entry) }
            }
            HStack { Button("큐 비우기") { model.playback.stop() }.disabled(model.playback.entries.isEmpty); Spacer(); Text("큐와 마지막 위치를 저장합니다. 재시작 시 자동으로 재생하지 않습니다.").font(.caption).foregroundStyle(.secondary) }.padding(18)
        }.frame(width: 670, height: 530)
    }
}

struct QueueRow: View {
    let model: AppModel
    let entry: QueueEntry
    @State private var track: Track?
    var body: some View {
        HStack {
            Image(systemName: model.playback.current?.id == entry.trackID && model.playback.entries.indices.contains(model.playback.index) && model.playback.entries[model.playback.index].id == entry.id ? "waveform" : "music.note").foregroundStyle(.secondary).frame(width: 25)
            Button { Task { await model.playback.select(entry.id) } } label: { Text(track?.title ?? "트랙을 읽는 중…").frame(maxWidth: .infinity, alignment: .leading).lineLimit(2) }.buttonStyle(.plain)
            Button { Task { await model.playback.move(entry.id, delta: -1) } } label: { Image(systemName: "arrow.up") }.help("위로 이동")
            Button { Task { await model.playback.move(entry.id, delta: 1) } } label: { Image(systemName: "arrow.down") }.help("아래로 이동")
            Button { Task { await model.playback.remove(entry.id) } } label: { Image(systemName: "minus.circle") }.help("큐에서 제거")
        }.buttonStyle(.borderless).padding(.vertical, 6).task { track = try? await model.db.track(entry.trackID) }
    }
}
