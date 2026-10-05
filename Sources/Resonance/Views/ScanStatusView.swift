import SwiftUI

struct ScanNotice: Identifiable {
    let id = UUID()
    var title: String
    var detail: String
    var warning: Bool
}

/// A quiet sidebar status; changing file names and counts stay in the tooltip.
struct ScanStatusView: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var folderProgress: Double {
        Double(model.scanSummary.completedRoots) / Double(max(1, model.scanRootCount))
    }
    private var scanDetails: String {
        "완료한 폴더 \(model.scanSummary.completedRoots)/\(model.scanRootCount) · \(model.scanProcessed.formatted())곡 처리\n\(model.scanRootPath)\n\(model.scan?.current ?? "")"
    }

    var body: some View {
        if model.scanning || model.scanNotice != nil || model.artworkCollecting {
            VStack(alignment: .leading, spacing: 5) {
                if model.scanning {
                    HStack(spacing: 6) {
                        Text(model.scanCancelling ? "스캔 중지 중…" : "스캔 중")
                        Spacer(minLength: 4)
                        Button { model.cancelScan() } label: {
                            Image(systemName: "stop.fill").font(.system(size: 8)).padding(4)
                        }
                        .buttonStyle(.plain).disabled(model.scanCancelling)
                        .help("스캔 중지").accessibilityLabel("스캔 중지")
                    }
                    ProgressView(value: folderProgress)
                        .progressViewStyle(.linear).controlSize(.mini).tint(.secondary)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 1.2), value: folderProgress)
                        .accessibilityLabel("완료한 음악 폴더")
                        .accessibilityValue("\(model.scanSummary.completedRoots)/\(model.scanRootCount)")
                } else if let notice = model.scanNotice {
                    HStack(spacing: 6) {
                        Image(systemName: notice.warning ? "exclamationmark.triangle" : "checkmark.circle")
                        Text(notice.warning ? "스캔 확인 필요" : model.scanSummary.cancelled ? "스캔 중지됨" : "스캔 완료")
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Button { model.scanNotice = nil } label: { Image(systemName: "xmark").padding(4) }
                            .buttonStyle(.plain).accessibilityLabel("스캔 메시지 닫기")
                    }
                }
                if model.artworkCollecting {
                    Text("커버 저장 중 \(model.artworkProcessed.formatted()) / \(model.artworkTotal.formatted())")
                        .lineLimit(1)
                    ProgressView(value: Double(model.artworkProcessed), total: Double(max(1, model.artworkTotal)))
                        .progressViewStyle(.linear).controlSize(.mini).tint(.secondary)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: 220, alignment: .leading)
            .help(model.scanning ? scanDetails : [model.scanNotice?.title, model.scanNotice?.detail].compactMap { $0 }.joined(separator: "\n"))
        }
    }
}
