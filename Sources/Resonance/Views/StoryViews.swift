import SwiftUI
import ResonanceCore

/// A story card for an album, track, musician or work: saved text, live progress, or a one-click start.
struct StoryPanel: View {
    let model: AppModel
    let request: StoryRequest
    /// Write the story without being asked (albums, musicians, works). Tracks wait for a click.
    var auto = true
    /// Narrow column (Now Playing inspector): no card chrome, smaller type.
    var compact = false
    @State private var expanded = false
    @State private var editing = false
    @State private var reading = false
    private var state: StoryState { model.stories.state(request.entityID, settings: model.settings) }
    private var label: String { ["album": "앨범 이야기", "track": "이 곡 이야기", "artist": "음악가 이야기", "work": "작품 이야기"][request.kind] ?? "이야기" }
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 16) {
            HStack(spacing: 7) {
                Image(systemName: "text.book.closed").font(.caption.weight(.semibold)).foregroundStyle(.tint)
                Text(label).font(.caption.weight(.semibold)).tracking(0.4).foregroundStyle(.secondary)
                Spacer()
                if case .working = state.phase { Button("취소") { model.stories.cancel(request.entityID, settings: model.settings) }.buttonStyle(.borderless).font(.caption) }
                Menu {
                    Button(state.insight == nil ? "지금 찾아 쓰기" : "새로 찾아 다시 쓰기") { model.stories.start(request, settings: model.settings, regenerate: state.insight != nil) }.disabled(StoryStore.blocker(model.settings) != nil || isWorking)
                    Button("출처 직접 고르기…") { editing = true }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(.secondary).help("이야기 관리")
            }
            if case .working(let step) = state.phase { StoryProgress(step: step, compact: compact) }
            if let insight = state.insight {
                StoryContent(insight: insight, expanded: $expanded, compact: compact, open: compact ? { reading = true } : nil).opacity(isWorking ? 0.45 : 1)
            } else {
                switch state.phase {
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 10) {
                        Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack { Button("다시 시도") { model.stories.start(request, settings: model.settings) }; Button("출처 직접 고르기…") { editing = true }.buttonStyle(.borderless) }.controlSize(.small)
                    }
                case .off(let reason):
                    VStack(alignment: .leading, spacing: 8) { Text(reason).font(.callout).foregroundStyle(.secondary); SettingsLink { Text("설정 열기") }.controlSize(.small) }
                case .idle where auto && state.checked && StoryStore.blocker(model.settings) == nil:
                    StoryProgress(step: nil, compact: compact)
                case .idle:
                    VStack(alignment: .leading, spacing: 10) {
                        Text("백과사전·레이블·평론 같은 공개 자료를 찾아 출처와 함께 정리합니다.").font(.callout).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                        if let reason = StoryStore.blocker(model.settings) { Text(reason).font(.caption).foregroundStyle(.tertiary); SettingsLink { Text("설정 열기") }.controlSize(.small) }
                        else { Button { model.stories.start(request, settings: model.settings) } label: { Label("이야기 찾아 읽기", systemImage: "sparkle.magnifyingglass") }.buttonStyle(.borderedProminent).controlSize(compact ? .small : .regular) }
                    }
                case .working: EmptyView()
                }
            }
        }
        .padding(.horizontal, compact ? 0 : 34).padding(.vertical, compact ? 0 : 28)
        .frame(maxWidth: compact ? .infinity : 760, alignment: .leading)
        .background { if !compact { card } }
        .frame(maxWidth: .infinity)
        .task(id: "\(request.entityID)|\(model.settings.language)|\(model.settings.enabled)|\(model.settings.model)") {
            expanded = false
            await model.stories.prepare(request, settings: model.settings, auto: auto)
        }
        .sheet(isPresented: $editing, onDismiss: { Task { await model.stories.reload(request.entityID, settings: model.settings) } }) {
            InsightEditorView(model: model, request: request)
        }
        .sheet(isPresented: $reading) { if let insight = state.insight { StoryReader(label: label, title: request.title, insight: insight) } }
    }
    private var isWorking: Bool { if case .working = state.phase { return true }; return false }
    /// Quiet paper-like surface: a faint top light, hairline edge and soft lift.
    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return shape.fill(.background.secondary)
            .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.045), .clear], startPoint: .top, endPoint: .center)))
            .overlay(shape.strokeBorder(.separator.opacity(0.45), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 22, y: 10)
    }
}

/// Three quiet steps with placeholder lines while a story is being written.
struct StoryProgress: View {
    let step: StoryStep?
    var compact = false
    @State private var pulse = false
    private let steps: [(StoryStep, String)] = [(.searching, "자료 찾기"), (.reading, "원문 읽기"), (.writing, "정리하기")]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: compact ? 8 : 14) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, item in
                    let current = steps.firstIndex { $0.0 == step } ?? -1
                    HStack(spacing: 5) {
                        if index == current { ProgressView().controlSize(.mini) }
                        else { Image(systemName: index < current ? "checkmark.circle.fill" : "circle").font(.caption2).foregroundStyle(index < current ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary)) }
                        Text(item.1).font(.caption).foregroundStyle(index == current ? .primary : .secondary)
                    }
                }
            }.opacity(step == nil ? 0 : 1)
            VStack(alignment: .leading, spacing: 9) {
                ForEach([1.0, 0.94, 0.97, 0.6], id: \.self) { width in
                    GeometryReader { proxy in Capsule().fill(.quaternary).frame(width: proxy.size.width * width) }.frame(height: compact ? 8 : 10)
                }
            }.opacity(pulse ? 0.45 : 1).animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse).onAppear { pulse = true }
        }.accessibilityElement(children: .ignore).accessibilityLabel(step.map { s in "이야기 준비 중: \(steps.first { $0.0 == s }?.1 ?? "")" } ?? "이야기 준비 중")
    }
}

/// The whole story at reading width, opened from the narrow inspector — like Roon keeping long text in the main view, not the side pane.
struct StoryReader: View {
    let label: String
    let title: String
    let insight: Insight
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(label, systemImage: "text.book.closed").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(title).font(.title3.weight(.semibold)).lineLimit(2).textSelection(.enabled)
                }
                Spacer()
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 32).padding(.vertical, 18)
            Divider()
            ScrollView {
                StoryContent(insight: insight, expanded: .constant(true), collapsible: false)
                    .padding(.horizontal, 44).padding(.vertical, 34).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
        }.frame(width: 740, height: 700)
    }
}

/// Reading layout: serif lead, topic sections with citation marks, a quiet uncertainty note and numbered sources.
struct StoryContent: View {
    let insight: Insight
    @Binding var expanded: Bool
    var compact = false
    /// When set (narrow inspector), the footer opens the full reader instead of expanding in place.
    var open: (() -> Void)? = nil
    /// The reader shows everything with no fold control.
    var collapsible = true
    private var numbers: [String: Int] { Dictionary(uniqueKeysWithValues: insight.evidence.enumerated().map { ($1.id, $0 + 1) }) }
    var body: some View {
        let sections = insight.payload.sections
        VStack(alignment: .leading, spacing: compact ? 14 : 22) {
            if let lead = sections.first {
                cited(lead).font(.system(size: compact ? 14 : 19, design: .serif)).lineSpacing(compact ? 4 : 8)
                    .lineLimit(expanded || !compact ? nil : 5).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if expanded {
                if sections.count > 1 { Divider().opacity(0.5) }
                ForEach(Array(sections.dropFirst().enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: compact ? 6 : 9) {
                        HStack(spacing: 8) {
                            Capsule().fill(.tint).frame(width: 3, height: compact ? 11 : 13)
                            Text(section.title).font(.system(size: compact ? 12 : 13, weight: .semibold))
                        }
                        cited(section).font(.system(size: compact ? 13 : 15.5, design: .serif)).lineSpacing(compact ? 4 : 7).foregroundStyle(.primary.opacity(0.88))
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !insight.payload.uncertainties.isEmpty { uncertaintyNote }
                sourceList
            }
            footer(sections)
        }
    }
    private var uncertaintyNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("확인되지 않은 부분", systemImage: "questionmark.circle").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(insight.payload.uncertainties.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Circle().fill(.tertiary).frame(width: 3.5, height: 3.5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                    Text(line).font(.caption).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, compact ? 12 : 16).padding(.vertical, compact ? 10 : 14).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.top, compact ? 0 : 4)
    }
    private var sourceList: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 11) {
            Text("출처 \(insight.evidence.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(insight.evidence.enumerated()), id: \.offset) { index, source in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(index + 1)").font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundStyle(.tint)
                        .frame(width: 18, height: 18).background(Circle().fill(.tint.opacity(0.14)))
                    let title = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    VStack(alignment: .leading, spacing: 2) {
                        if let url = SafeLink.url(source.url) { Link(title, destination: url).font(compact ? .caption : .callout).lineLimit(2) } else { Text(title).font(compact ? .caption : .callout) }
                        Text("\(host(source.url)) · \(source.fetched.formatted(date: .abbreviated, time: .omitted)) 조회").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }.padding(.top, 4)
    }
    private func footer(_ sections: [InsightSection]) -> some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            if expanded { Divider().opacity(0.5) }
            HStack(spacing: 10) {
                if expanded { Text("AI가 위 출처만으로 정리 · \(insight.created.formatted(date: .abbreviated, time: .omitted)) · \(insight.model)").font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                if let open, !expanded {
                    Button(action: open) { Label("전체 읽기", systemImage: "arrow.up.left.and.arrow.down.right") }.buttonStyle(.borderless).font(.caption.weight(.medium))
                } else if collapsible, sections.count > 1 || !expanded {
                    if expanded { Spacer(minLength: 8) }
                    Button { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } } label: {
                        Label(expanded ? "접기" : (sections.count > 1 ? "계속 읽기 · 주제 \(sections.count - 1)개" : "출처 보기"), systemImage: expanded ? "chevron.up" : "chevron.down")
                    }.buttonStyle(.borderless).font(.caption.weight(.medium))
                }
                if !expanded { Text(insight.evidence.map { host($0.url) }.filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail) }
                if !expanded { Spacer(minLength: 0) }
            }
        }
    }
    private func host(_ url: String) -> String { URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? "" }
    private func cited(_ section: InsightSection) -> Text {
        let marks = section.source_ids.compactMap { numbers[$0] }.sorted().map(String.init).joined(separator: ",")
        return marks.isEmpty ? Text(section.text) : Text(section.text) + Text(" \(marks)").font(.system(size: compact ? 8 : 9, weight: .semibold)).baselineOffset(compact ? 5 : 7).foregroundColor(.accentColor)
    }
}
