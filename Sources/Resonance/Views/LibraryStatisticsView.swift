import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ResonanceCore

struct LibraryStatisticsView: View {
    let model: AppModel
    @State private var statistics: LibraryStatistics?
    @State private var message: String?
    @State private var exporting = false

    private struct RefreshID: Hashable {
        var roots: [LibraryRoot]
        var albums: Int
        var songs: Int
        var scanning: Bool
    }

    var body: some View {
        Group {
            Section("전체 라이브러리") {
                if let statistics {
                    countRow("전체", albums: statistics.albums, songs: statistics.songs)
                    Text(model.scanning ? "스캔 중입니다. 색인된 수가 계속 갱신됩니다." : "현재 라이브러리에 표시되는 앨범과 곡 수입니다. 연결 해제된 디스크의 보관된 색인도 포함합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                } else { ProgressView("통계를 불러오는 중…") }
                HStack {
                    Button("통계 새로고침") { Task { await refresh() } }
                    Spacer()
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }
            }
            if let statistics {
                Section("음악 폴더별") {
                    if statistics.roots.isEmpty { Text("연결된 음악 폴더가 없습니다.").foregroundStyle(.secondary) }
                    ForEach(LibraryRootGroup.grouping(statistics.roots.map(\.root))) { group in
                        let rows = statistics.roots.filter { group.rootIDs.contains($0.id) }
                        if rows.count > 1 {
                            DisclosureGroup {
                                ForEach(rows) { row in physicalRoot(row) }
                            } label: {
                                countRow(group.name, albums: rows.reduce(0) { $0 + $1.albums }, songs: rows.reduce(0) { $0 + $1.songs })
                            }
                        } else if let row = rows.first { physicalRoot(row) }
                    }
                }
                Section("색인 실패 · 확인 필요") {
                    HStack {
                        Text("\(statistics.failures.count.formatted())건").font(.headline)
                        Spacer()
                        Button(exporting ? "내보내는 중…" : "실패 목록 CSV 내보내기…") { export(statistics) }
                            .disabled(exporting || statistics.failures.isEmpty)
                    }
                    Text("폴더별 최근 완료된 스캔과 이후 중단된 스캔에서 확인한 파일·폴더의 읽기 오류 및 미지원 형식입니다. 재스캔이 완료되면 목록을 갱신합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    if statistics.failures.isEmpty {
                        Label("기록된 색인 오류가 없습니다.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    }
                    ForEach(statistics.failures.prefix(50)) { failure in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(failure.path).font(.callout).textSelection(.enabled)
                            Text(failure.reason).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    if statistics.failures.count > 50 { Text("화면에는 50건을 표시합니다. CSV에는 전체 목록이 포함됩니다.").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .task(id: RefreshID(roots: model.roots, albums: model.counts.albums, songs: model.counts.tracks, scanning: model.scanning)) { await refresh() }
    }

    private func countRow(_ name: String, albums: Int, songs: Int) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text("\(albums.formatted()) 앨범 · \(songs.formatted())곡").monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func physicalRoot(_ row: RootStatistics) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            countRow(row.root.name, albums: row.albums, songs: row.songs)
            Text(row.root.path + " · " + row.root.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private func refresh() async {
        do {
            let result = try await model.db.statistics()
            guard !Task.isCancelled else { return }
            statistics = result
        } catch { message = "통계를 불러오지 못했습니다: " + error.localizedDescription }
    }

    private func export(_ snapshot: LibraryStatistics) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = .autoupdatingCurrent
        dateFormatter.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "Resonance-indexing-failures-\(dateFormatter.string(from: Date())).csv"
        panel.canCreateDirectories = true
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            exporting = true
            Task { @MainActor in
                defer { exporting = false }
                do {
                    try await Task.detached(priority: .utility) { try snapshot.failureCSV().write(to: url, options: .atomic) }.value
                    message = "\(snapshot.failures.count)건을 CSV로 저장했습니다."
                } catch { message = "CSV 저장 실패: " + error.localizedDescription }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
}
