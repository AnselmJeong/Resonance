import SwiftUI
import ResonanceCore

private struct MatchCache: Codable { var date: Date; var candidates: [ReleaseCandidate] }

struct MatchReviewView: View {
    let model: AppModel
    let album: Album
    let local: [Track]
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [ReleaseCandidate] = []
    @State private var preview: ReleaseMatch?
    @State private var confirmed: ReleaseMatch?
    @State private var orderReviewed = false
    @State private var busy = false
    @State private var error: String?
    @State private var job: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { VStack(alignment: .leading, spacing: 5) { Text("판과 크레디트 검토").font(.title2.weight(.semibold)); Text("\(album.title) · \(local.count) 트랙 · UPC \(album.barcode.isEmpty ? "없음" : album.barcode)").foregroundStyle(.secondary).font(.callout) }; Spacer(); Button("닫기") { job?.cancel(); dismiss() }.keyboardShortcut(.cancelAction) }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let confirmed {
                        Label("연결된 판: \(confirmed.candidate.title)", systemImage: "checkmark.seal").foregroundStyle(.tint)
                        Button("외부 매칭 해제") { run { try await model.db.removeMatch(albumID: album.id); self.confirmed = nil; preview = nil; model.discovery.changed(album.id) } }
                    }
                    Text("후보 점수는 일치 근거의 합계이며 정확도 확률이 아닙니다. 다른 CD·디지털 판을 구분하고 트랙별 대응을 확인하세요.").font(.callout).foregroundStyle(.secondary).lineSpacing(3)
                    HStack { Button("MusicBrainz 후보 찾기") { search(force: false) }.disabled(busy || !model.settings.enabled); Button("다시 조회") { search(force: true) }.disabled(busy || !model.settings.enabled); if !model.settings.enabled { SettingsLink { Text("온라인 정보 활성화…") } } }
                    ForEach(candidates) { candidate in candidateCard(candidate) }
                    if let preview { previewContent(preview) }
                    if busy { HStack { ProgressView().controlSize(.small); Text("MusicBrainz 자료를 읽고 있습니다. 요청 간격을 유지합니다.").font(.caption); Spacer(); Button("취소") { job?.cancel() } } }
                    if let error { Text(error).foregroundStyle(.orange).font(.callout) }
                    Link("MusicBrainz 제공 · 데이터와 라이선스", destination: URL(string: "https://musicbrainz.org/doc/About/Data_License")!).font(.caption)
                }.padding(24)
            }
        }.frame(width: 780, height: 670).task { confirmed = try? await model.db.confirmedMatch(album.id); candidates = model.discovery.states[album.id]?.snapshot?.candidates ?? [] }.onDisappear { job?.cancel() }
    }
    private func candidateCard(_ candidate: ReleaseCandidate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(candidate.title).font(.headline); Spacer(); Text("근거 점수 \(candidate.score)").font(.caption).foregroundStyle(.secondary) }
            Text([candidate.artist, candidate.date, candidate.country, candidate.disambiguation].filter { !$0.isEmpty }.joined(separator: " · ")).font(.callout)
            Text("UPC \(candidate.barcode.isEmpty ? "없음" : candidate.barcode) · \(candidate.trackCount) 트랙").font(.caption).foregroundStyle(.secondary)
            Text(candidate.reasons.joined(separator: " · ")).font(.caption).foregroundStyle(candidate.reasons.contains(where: { $0.hasPrefix("⚠") }) ? Color.orange : Color.secondary)
            HStack {
                Link("MusicBrainz에서 보기", destination: URL(string: "https://musicbrainz.org/release/\(candidate.id)")!)
                Spacer()
                Button("트랙 대응과 관계 읽기") { run { preview = try await model.musicBrainz.detail(candidate: candidate); orderReviewed = false } }.disabled(busy)
            }
        }.padding(16).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
    private func previewContent(_ match: ReleaseMatch) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider(); Text("트랙별 대응 확인").font(.headline)
            ForEach(local) { track in correspondence(track, match: match) }
            Toggle("디스크·트랙 순서와 제목을 검토했으며 이 판으로 연결합니다", isOn: $orderReviewed)
            Button("이 판으로 연결") {
                run { try await model.db.confirmMatch(albumID: album.id, match: match, approvedOrder: orderReviewed); confirmed = match; model.discovery.changed(album.id); await model.reload() }
            }.buttonStyle(.borderedProminent).disabled(busy || !orderReviewed || match.tracks.count != local.count)
        }
    }
    private func correspondence(_ track: Track, match: ReleaseMatch) -> some View {
        let remote = match.tracks.first { $0.disc == track.disc && $0.number == track.number }
        let agrees = remote.map { TextKey.normalize($0.title) == TextKey.normalize(track.title) } == true
        return VStack(alignment: .leading, spacing: 5) {
            Text("\(track.disc).\(track.number)  \(track.title)").font(.callout)
            Text("→ \(remote?.title ?? "대응 없음")").font(.caption).foregroundStyle(agrees ? Color.secondary : Color.orange)
            Text(remote?.credits.map { "\($0.roleLabel): \($0.name)" }.joined(separator: " · ") ?? "크레디트 없음").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func run(_ operation: @escaping () async throws -> Void) { busy = true; error = nil; job = Task { defer { busy = false }; do { try await operation() } catch is CancellationError { self.error = "검토 자료 읽기를 취소했습니다." } catch { self.error = error.localizedDescription } } }
    private func search(force: Bool) {
        run {
            let cacheKey = "mb-candidates:" + TextKey.id(album.id, album.barcode, album.title, String(local.count))
            if !force, let cached = try await model.db.preference(cacheKey, as: MatchCache.self), Date().timeIntervalSince(cached.date) < 86400 { candidates = cached.candidates }
            else { candidates = try await model.musicBrainz.search(album: album); try await model.db.setPreference(cacheKey, value: MatchCache(date: Date(), candidates: candidates)) }
            if candidates.isEmpty { error = "해당 판의 후보가 없습니다. 다른 판에 자동 연결하지 않았습니다. 신규 발매는 나중에 다시 조회하세요." }
        }
    }
}
