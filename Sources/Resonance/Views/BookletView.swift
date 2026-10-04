import SwiftUI
import PDFKit
import ResonanceCore

struct BookletView: View {
    let model: AppModel
    let selection: BookletSelection
    @Environment(\.dismiss) private var dismiss
    @State private var contents: BookletText?
    @State private var page = 1
    @State private var query = ""
    @State private var selected = Set<Int>()
    @State private var busy = false
    @State private var message: String?
    @State private var job: Task<Void, Never>?
    private var visiblePages: [BookletPage] {
        let pages = contents?.pages ?? []
        return query.isEmpty ? pages : pages.filter { $0.text.localizedStandardContains(query) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selection.album.title).font(.headline).lineLimit(1)
                    Text(URL(fileURLWithPath: selection.path).lastPathComponent).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { page = max(1, page - 1) } label: { Image(systemName: "chevron.left") }.disabled(page <= 1)
                Text("\(page) / \(contents?.pageCount ?? 0)쪽").monospacedDigit().font(.callout)
                Button { page = min(contents?.pageCount ?? 1, page + 1) } label: { Image(systemName: "chevron.right") }.disabled(page >= contents?.pageCount ?? 1)
                Button("외부 앱에서 열기") { NSWorkspace.shared.open(URL(fileURLWithPath: selection.path)) }.disabled(!FileManager.default.fileExists(atPath: selection.path))
                Button("닫기") { job?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(18)
            Divider()
            if let contents {
                HSplitView {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("부클릿에서 검색", text: $query).textFieldStyle(.roundedBorder)
                        if !contents.hasText { Text("텍스트가 없는 스캔본입니다. 페이지를 직접 읽을 수 있습니다.").font(.callout).foregroundStyle(.secondary) }
                        Text(query.isEmpty ? "페이지를 누르면 열립니다. 설명에 쓸 페이지는 체크하세요." : "\(visiblePages.count)개 페이지에서 발견").font(.caption).foregroundStyle(.secondary)
                        List(visiblePages) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Toggle("\(item.number)쪽 선택", isOn: Binding(get: { selected.contains(item.number) }, set: { on in if on { selected.insert(item.number) } else { selected.remove(item.number) } }))
                                    .labelsHidden().disabled(item.text.isEmpty || (!selected.contains(item.number) && selected.count >= 6) || busy)
                                Button { page = item.number } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("\(item.number)쪽").font(.callout.weight(page == item.number ? .bold : .regular))
                                        Text(excerpt(item.text)).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain)
                            }.padding(.vertical, 4)
                        }.listStyle(.inset)
                        if contents.hasText {
                            Button(busy ? "부클릿을 정리하고 있습니다…" : "선택한 \(selected.count)쪽으로 이야기 만들기") { generate() }
                                .buttonStyle(.borderedProminent).disabled(selected.isEmpty || busy || StoryStore.blocker(model.settings) != nil)
                            Text("선택한 페이지 텍스트(최대 6쪽)를 설정된 모델에 전달합니다. PDF 파일은 전송하지 않습니다.").font(.caption2).foregroundStyle(.secondary)
                            if let reason = StoryStore.blocker(model.settings) { Text(reason).font(.caption).foregroundStyle(.secondary) }
                        }
                        if let message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    }.padding(16).frame(minWidth: 230, idealWidth: 280, maxWidth: 340)
                    PDFCanvas(url: URL(fileURLWithPath: selection.path), page: $page).frame(minWidth: 460)
                }
            } else {
                VStack(spacing: 14) { if let message { Text(message) } else { ProgressView("부클릿 읽는 중…") } }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(minWidth: 850, idealWidth: 1050, minHeight: 650, idealHeight: 760)
            .task {
                do {
                    let url = try BookletSource.validatedURL(path: selection.path, album: selection.album, roots: model.roots)
                    contents = try await model.booklets.read(url); page = min(max(1, selection.page), contents?.pageCount ?? 1)
                } catch { message = error.localizedDescription }
            }.onDisappear { job?.cancel() }
    }
    private func excerpt(_ text: String) -> String {
        if !query.isEmpty, let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            let start = text.index(range.lowerBound, offsetBy: -45, limitedBy: text.startIndex) ?? text.startIndex
            return String(text[start...].prefix(180)).replacingOccurrences(of: "\n", with: " ")
        }
        return text.isEmpty ? "이미지 페이지" : String(text.prefix(180)).replacingOccurrences(of: "\n", with: " ")
    }
    private func generate() {
        guard let contents else { return }
        let evidence = BookletReader.evidence(album: selection.album, path: selection.path, pages: contents.pages.filter { selected.contains($0.number) })
        busy = true; message = nil
        job = Task {
            defer { busy = false }
            do {
                await model.stories.cancelAndWait(selection.album.id, settings: model.settings)
                try Task.checkCancellation()
                let key = try await KeychainStore.readAsync("llm")
                try InsightService.preflight(settings: model.settings, key: key)
                let tracks = try await model.db.tracks(albumID: selection.album.id)
                let request = StoryRequest.album(selection.album, tracks: tracks)
                _ = try await model.insights.generate(entityID: selection.album.id, kind: "album", context: request.context + "; Source: listener-selected pages of this album's local booklet. Describe only what these pages support.", evidence: evidence, settings: model.settings, key: key, regenerate: true)
                await model.stories.reload(selection.album.id, settings: model.settings)
                message = "앨범의 음악 이야기에 저장했습니다. 출처를 누르면 해당 페이지를 다시 엽니다."
            } catch is CancellationError { message = "작업을 취소했습니다." }
            catch { message = error.localizedDescription }
        }
    }
}

/// SwiftUI owns the selected page; PDFKit owns rendering, text selection and native scrolling.
private struct PDFCanvas: NSViewRepresentable {
    let url: URL
    @Binding var page: Int
    func makeCoordinator() -> Coordinator { Coordinator(page: $page) }
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView(); view.document = PDFDocument(url: url); view.autoScales = true; view.displayMode = .singlePageContinuous
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak view, weak coordinator = context.coordinator] _ in
            guard let view, let current = view.currentPage, let document = view.document else { return }
            let number = document.index(for: current) + 1
            DispatchQueue.main.async { coordinator?.page.wrappedValue = number }
        }
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.page = $page
        if let target = view.document?.page(at: page - 1), view.currentPage != target { view.go(to: target) }
    }
    final class Coordinator {
        var page: Binding<Int>
        var observer: NSObjectProtocol?
        init(page: Binding<Int>) { self.page = page }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}
