import SwiftUI
import AppKit
import ResonanceCore

struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var tab = "library"
    @State private var tinyKey = ""
    @State private var llmKey = ""
    @State private var message: String?
    @State private var saving = false
    @State private var savedForClose = false
    @State private var tinyKeySaved = false
    @State private var llmKeySaved = false
    @State private var checkingTinyFish = false
    @State private var savingKey = false
    var body: some View {
        VStack(spacing: 0) {
            Picker("설정", selection: $tab) { Text("라이브러리").tag("library"); Text("통계").tag("statistics"); Text("음악 정보").tag("info"); Text("운영과 백업").tag("operations") }.pickerStyle(.segmented).padding(20)
            Form {
                if tab == "library" { librarySettings }
                if tab == "statistics" { LibraryStatisticsView(model: model) }
                if tab == "info" { infoSettings }
                if tab == "operations" { operationsSettings }
            }.formStyle(.grouped)
            HStack {
                ScanStatusView(model: model).frame(maxWidth: 180, alignment: .leading)
                if let message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                Spacer()
                Button(saving ? "저장 중…" : "설정 저장") { saveAndClose() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(saving || savingKey || model.removingRootID != nil)
            }.padding(20)
        }.frame(width: 720, height: 630)
            .onAppear { savedForClose = false }
            .task { await refreshKeyStatus() }
            .onDisappear { if !savedForClose { Task { await model.saveSettings() } } }
    }
    @ViewBuilder private var librarySettings: some View {
        Section("음악 폴더 · 원본 읽기 전용") {
            ForEach(model.roots) { root in RootSettingsRow(model: model, root: root) }
            HStack { Button("음악 폴더 추가…") { model.chooseRoot() }.disabled(model.removingRootID != nil); Spacer(); Button(model.scanning ? "스캔 중지" : "재스캔") { if model.scanning { model.cancelScan() } else { model.startScan() } }.disabled(model.roots.isEmpty || model.removingRootID != nil) }
        }
        SMBFallbackSettingsView(model: model)
        Section("출력") {
            Text("재생 바의 AirPlay 선택기는 앱의 AVQueuePlayer에 연결됩니다.").font(.callout)
            Text("음악은 앱의 AirPlay 선택기에서 연결합니다. Mac의 일반 소리와 알림은 macOS에서 별도로 관리하세요. 원본 음원 형식과 전송 형식은 다를 수 있습니다.").font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var infoSettings: some View {
        Section("온라인 정보") {
            Toggle("외부 음악 정보 사용", isOn: $model.settings.enabled)
            Text("현재 대상에서 직접 요청할 때만 조회합니다. 모든 음악을 일괄 요약하지 않습니다.").font(.caption).foregroundStyle(.secondary)
            Picker("설명 언어", selection: $model.settings.language) { Text("한국어").tag("ko"); Text("English").tag("en") }
            VStack(alignment: .leading, spacing: 8) {
                Text("TinyFish API 키")
                SecureField("새 TinyFish API 키를 입력하세요", text: $tinyKey)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("TinyFish API 키 입력")
                Text(tinyKeySaved ? "Keychain에 키가 저장되어 있습니다. 새 키를 입력하면 교체됩니다." : "저장된 키가 없습니다. 키를 입력하고 설정 저장을 누르세요.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("TinyFish 키 저장") { Task { if await saveKey(tinyKey, account: "tinyfish") { tinyKey = "" } } }.disabled(tinyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving || savingKey)
                    Button("키 삭제") { Task { if await saveKey("", account: "tinyfish") { tinyKey = "" } } }.disabled(!tinyKeySaved || saving || savingKey)
                    Button(checkingTinyFish ? "연결 확인 중…" : "TinyFish 연결 확인") { checkTinyFish() }.disabled(!tinyKeySaved || checkingTinyFish || saving || savingKey)
                }
            }.padding(.vertical, 4)
        }
        Section("설명 모델") {
            Picker("제공자", selection: $model.settings.provider) { Text("Ollama").tag("ollama"); Text("OpenAI 호환 API").tag("compatible") }
            TextField("Chat API URL", text: $model.settings.endpoint)
            TextField("모델 이름", text: $model.settings.model)
            VStack(alignment: .leading, spacing: 8) {
                Text("모델 API 키 (로컬은 선택)")
                SecureField("새 모델 API 키를 입력하세요", text: $llmKey)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("모델 API 키 입력")
                Text(llmKeySaved ? "Keychain에 키가 저장되어 있습니다." : "저장된 키가 없습니다.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("모델 키 저장") { Task { if await saveKey(llmKey, account: "llm") { llmKey = "" } } }.disabled(llmKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving || savingKey)
                    Button("키 삭제") { Task { if await saveKey("", account: "llm") { llmKey = "" } } }.disabled(!llmKeySaved || saving || savingKey)
                }
            }.padding(.vertical, 4)
            Text("키는 macOS Keychain에 저장됩니다. Ollama는 설치하고 실행한 모델 이름을 입력하세요. Ollama Cloud는 https://ollama.com/api/chat과 API 키를 사용하며, 생각(thinking)을 끌 수 있는 deepseek-v4.1-flash를 권장합니다. 호환 API는 Chat Completions와 JSON 응답을 지원해야 하며, …/v1까지만 입력해도 됩니다.").font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var operationsSettings: some View {
        Section("파생 커버 캐시") { TextField("디스크 캐시 상한 (MB)", value: $model.settings.cacheMegabytes, format: .number); Button("캐시 상한 적용") { Task { do { try await model.trimArtworkCache(); message = "파생 커버 캐시를 정리했습니다. 재스캔하면 필요한 커버가 복원됩니다." } catch { message = error.localizedDescription } } } }
        Section("데이터베이스") {
            Button("일관된 DB 백업 저장…") { model.backup() }
            Button("DB 무결성 검사") { Task { message = (try? await model.db.integrityCheck()) == "ok" ? "DB 무결성: 정상" : "DB 무결성을 확인하지 못했습니다." } }
            Button("저장 폴더 열기") { NSWorkspace.shared.open(AppPaths.support) }
            Text("음악 색인, 별칭, 수동 수정, 외부 매칭, 출처, 설명, 사용량을 백업합니다. 커버 캐시는 재생성할 수 있습니다.").font(.caption).foregroundStyle(.secondary)
        }
        if let scan = model.scan {
            Section("최근 스캔") { Text("발견 \(scan.discovered) · 처리 \(scan.processed) · 변경 없음 \(scan.reused)"); if scan.cancelled { Text("중단됨 · 재스캔 시 이미 처리한 파일을 재사용합니다") }; ForEach(Array(scan.errors.prefix(200).enumerated()), id: \.offset) { _, error in Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) } }
        }
        Section("버전") { Text("Resonance \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "개발 빌드") · macOS 14+"); Text("로컬 개발용 ad-hoc 서명. Developer ID 서명과 notarization은 포함하지 않습니다.").font(.caption).foregroundStyle(.secondary) }
    }
    private func refreshKeyStatus() async {
        do {
            let status = try await Task.detached { (try KeychainStore.contains("tinyfish"), try KeychainStore.contains("llm")) }.value
            tinyKeySaved = status.0; llmKeySaved = status.1
        }
        catch { message = error.localizedDescription }
    }
    private func saveKey(_ value: String, account: String) async -> Bool {
        savingKey = true
        defer { savingKey = false }
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await KeychainStore.saveAndVerify(key, account: account)
            if account == "tinyfish" { tinyKeySaved = !key.isEmpty } else { llmKeySaved = !key.isEmpty }
            message = key.isEmpty ? "Keychain 키를 삭제했습니다." : "Keychain에 키를 저장했습니다."
            return true
        } catch { message = error.localizedDescription; return false }
    }
    private func saveAndClose() {
        saving = true; message = nil
        Task {
            defer { saving = false }
            if !tinyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard await saveKey(tinyKey, account: "tinyfish") else { return }; tinyKey = ""
            }
            if !llmKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard await saveKey(llmKey, account: "llm") else { return }; llmKey = ""
            }
            guard await model.saveSettings() else { message = model.error ?? "설정을 저장하지 못했습니다."; return }
            savedForClose = true; dismiss()
        }
    }
    private func checkTinyFish() {
        checkingTinyFish = true; message = nil
        Task {
            defer { checkingTinyFish = false }
            do {
                let key = try await KeychainStore.readAsync("tinyfish")
                let results = try await model.tinyFish.search(query: "Claude Debussy official composer biography", key: key)
                message = "TinyFish 검색 연결 정상 · 검색 결과 \(results.count)개"
            } catch { message = "TinyFish 연결 확인 실패: \(error.localizedDescription)" }
        }
    }
}

struct RootSettingsRow: View {
    let model: AppModel
    let root: LibraryRoot
    @State private var exclusions = ""
    @State private var confirmingRemoval = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(root.path).font(.callout).textSelection(.enabled); Spacer()
                Text(root.status).font(.caption).foregroundStyle(.secondary)
                Button(model.removingRootID == root.id ? "제거 중…" : "연결 제거", role: .destructive) { confirmingRemoval = true }
                    .disabled(model.removingRootID != nil)
                    .accessibilityLabel("\(URL(fileURLWithPath: root.path).lastPathComponent) 폴더 연결 제거")
            }
            HStack { TextField("제외 폴더 (쉼표로 구분)", text: $exclusions); Button("적용") { var updated = root; updated.exclusions = exclusions.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }; Task { await model.saveRoot(updated) } }.disabled(model.scanning) }
        }.onAppear { exclusions = root.exclusions.joined(separator: ", ") }
            .alert("음악 폴더 연결을 제거할까요?", isPresented: $confirmingRemoval) {
                Button("취소", role: .cancel) {}
                Button("연결 제거", role: .destructive) { Task { await model.removeRoot(root) } }
            } message: {
                Text("\(root.path)\n\n이 폴더의 앨범·트랙 색인, 앨범 수정 정보와 저장된 설명을 앱에서 제거합니다. 원본 음원은 삭제하지 않습니다. 다시 연결하면 재스캔할 수 있습니다.")
            }
    }
}
