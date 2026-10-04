import SwiftUI
import ResonanceCore

struct InsightEditorView: View {
    let model: AppModel
    let request: StoryRequest
    private var entityID: String { request.entityID }
    private var kind: String { request.kind }
    private var title: String { request.title }
    private var context: String { request.context }
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [SourceCandidate] = []
    @State private var selected: Set<String> = []
    @State private var evidence: [Evidence] = []
    @State private var insight: Insight?
    @State private var reviewed = false
    @State private var busy = false
    @State private var phase = ""
    @State private var error: String?
    @State private var manualURL = ""
    @State private var job: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { VStack(alignment: .leading, spacing: 5) { Text("출처 직접 고르기").font(.title2.weight(.semibold)); Text(title).foregroundStyle(.secondary).lineLimit(2) }; Spacer(); Button("닫기") { job?.cancel(); dismiss() }.keyboardShortcut(.cancelAction) }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let insight { StoryContent(model: model, insight: insight, expanded: .constant(true)); Divider() }
                    if !model.settings.enabled {
                        Label("설정에서 온라인 음악 정보를 활성화하세요.", systemImage: "network.slash").foregroundStyle(.secondary)
                        SettingsLink { Text("설정 열기") }
                    }
                    Text("1. 출처 찾기").font(.headline)
                    HStack { Text("소셜·동영상·스트리밍 페이지는 제외하고 관련도 순으로 보여 줍니다.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("TinyFish로 검색") { search() }.disabled(busy || !model.settings.enabled) }
                    HStack { TextField("확인할 공개 원문 URL", text: $manualURL); Button("추가") { if let url = PublicWebURL.validate(manualURL) { let source = SourceCandidate(title: url.host ?? title, url: url.absoluteString); if !candidates.contains(where: { $0.id == source.id }) { candidates.append(source) }; manualURL = "" } else { error = "공개 http/https URL을 입력하세요." } }.disabled(busy) }
                    ForEach(candidates) { source in
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle(isOn: Binding(get: { selected.contains(source.id) }, set: { value in
                                evidence = []; reviewed = false
                                if value && selected.count < 3 { selected.insert(source.id) } else { selected.remove(source.id) }
                            })) { Text(source.title).font(.callout) }
                            if let url = SafeLink.url(source.url) { Link(url.host ?? source.url, destination: url).font(.caption).padding(.leading, 20) }
                            if let snippet = source.snippet { Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(3).padding(.leading, 20) }
                        }
                    }
                    if !candidates.isEmpty { Button("선택한 출처 원문 읽기 (최대 3개)") { fetch() }.disabled(busy || selected.isEmpty || !model.settings.enabled) }
                    if !evidence.isEmpty {
                        Divider(); Text("2. 대상과 근거 확인").font(.headline)
                        ForEach(evidence) { source in DisclosureGroup(source.title) { Text(source.text).font(.caption).textSelection(.enabled).lineSpacing(3).padding(.vertical, 8) } }
                        Text("읽은 본문 \(evidence.count)개. 일부 URL이 실패한 경우 확보한 자료만 사용합니다.").font(.caption).foregroundStyle(.secondary)
                        Toggle("본문이 이 앨범·음악가·곡에 관한 자료임을 확인했습니다", isOn: $reviewed)
                        Text("3. 출처가 연결된 설명 만들기").font(.headline)
                        Text("설정한 모델로 요약합니다.").font(.caption).foregroundStyle(.secondary)
                        Button(insight == nil ? "설명 생성" : "설명 다시 생성") { generate() }.buttonStyle(.borderedProminent).disabled(busy || !reviewed || !model.settings.enabled)
                    }
                    if busy { HStack { ProgressView().controlSize(.small); Text(phase).font(.callout); Spacer(); Button("취소") { job?.cancel() } } }
                    if let error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                    Text("설명은 정규 메타데이터를 수정하지 않습니다. 음원과 부클릿은 전송하지 않습니다.").font(.caption).foregroundStyle(.tertiary)
                }.padding(24)
            }
        }.frame(width: 700, height: 650).task { insight = try? await model.db.insight(entityID: entityID, language: model.settings.language) }.onDisappear { job?.cancel() }
    }
    private func run(_ phase: String, operation: @escaping () async throws -> Void) {
        busy = true; self.phase = phase; error = nil
        job = Task { defer { busy = false }; do { try await operation() } catch is CancellationError { self.error = "작업을 취소했습니다." } catch { self.error = error.localizedDescription } }
    }
    private func search() { run("자료 후보를 찾고 있습니다…") { let key = try await KeychainStore.readAsync("tinyfish"); let found = try await model.tinyFish.search(query: request.queries.first ?? title, key: key); let ranked = SourcePolicy.rank(found, for: request); candidates = ranked.isEmpty ? found.filter { !SourcePolicy.isBlocked($0.url) } : ranked; selected = []; evidence = []; reviewed = false; if candidates.isEmpty { error = "검색 결과가 없습니다. 확인한 공식 URL을 직접 추가할 수 있습니다." } } }
    private func fetch() { run("선택한 원문을 읽고 있습니다…") { let key = try await KeychainStore.readAsync("tinyfish"); evidence = try await model.tinyFish.fetch(sources: candidates.filter { selected.contains($0.id) }, key: key); reviewed = false } }
    private func generate() {
        let settings = model.settings
        run("출처를 바탕으로 설명을 만들고 있습니다…") {
            let key = try await KeychainStore.readAsync("llm")
            insight = try await model.insights.generate(entityID: entityID, kind: kind, context: context, evidence: evidence, settings: settings, key: key, regenerate: insight != nil)
        }
    }
}
