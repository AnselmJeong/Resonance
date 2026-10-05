import SwiftUI
import ResonanceCore

/// The input order is the displayed order, including album/disc grouping.
struct TrackSelectionBar: View {
    let model: AppModel
    let tracks: [Track]
    @Binding var selectedIDs: Set<String>
    var isInline = false
    @State private var adding = false
    @State private var message: String?

    private var eligible: [Track] { tracks.filter { $0.available && $0.supported } }
    private var eligibleIDs: Set<String> { Set(eligible.map(\.id)) }
    private var selected: [Track] { eligible.filter { selectedIDs.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("\(selected.count)곡 선택").font(.callout).monospacedDigit()
                Spacer(minLength: 8)
                Button("전체 선택") { selectedIDs = eligibleIDs; message = nil }
                    .disabled(eligibleIDs.isEmpty || eligibleIDs.isSubset(of: selectedIDs))
                Button("전체 해제") { selectedIDs.removeAll(); message = nil }
                    .disabled(selectedIDs.isEmpty)
                Button(action: enqueueSelection) {
                    Label(adding ? "추가 중…" : "선택 곡 큐에 추가", systemImage: "text.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty || adding)
            }.controlSize(.small)
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            } else if eligible.count < tracks.count {
                Text("연결되지 않았거나 지원하지 않는 \(tracks.count - eligible.count)곡은 선택에서 제외됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, isInline ? 0 : 28).padding(.vertical, 10)
        .background {
            if !isInline { Rectangle().fill(.bar) }
        }
        .overlay(alignment: .bottom) { Divider() }
        .onChange(of: eligibleIDs) { _, ids in selectedIDs.formIntersection(ids) }
        .task(id: message) {
            guard message != nil else { return }
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            message = nil
        }
    }

    private func enqueueSelection() {
        let queued = selected
        guard !adding, !queued.isEmpty else { return }
        adding = true
        Task { @MainActor in
            await model.playback.append(queued)
            selectedIDs.subtract(queued.map(\.id))
            message = "\(queued.count)곡을 큐에 추가했습니다."
            adding = false
        }
    }
}
