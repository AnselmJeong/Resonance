import SwiftUI
import ResonanceCore

struct SMBFallbackSettingsView: View {
    let model: AppModel
    @State private var selected = ""
    @State private var server = ""
    @State private var share = ""
    @State private var subpath = ""
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var message: String?
    @State private var allShareRoots = true
    var body: some View {
        Section("직접 SMB 라이브러리") {
            Text("Finder 마운트 없이 서버에서 읽습니다. FLAC 스캔은 태그 구간만 읽고, 재생할 곡과 다음 곡만 로컬 캐시에 받습니다 (최대 4 GiB). 다른 형식의 태그 읽기는 보류됩니다.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("연결할 라이브러리", selection: $selected) {
                Text("새 SMB 폴더 추가").tag("")
                ForEach(model.roots) { root in Text((root.smb == nil ? "" : "SMB · ") + root.path).tag(root.id) }
            }.accessibilityIdentifier("smb-root-picker")
            TextField("서버 주소 또는 IP", text: $server).accessibilityIdentifier("smb-server")
            TextField("공유 이름", text: $share).accessibilityIdentifier("smb-share")
            TextField("공유 내부 폴더 (전체 공유는 비워 두세요)", text: $subpath).accessibilityIdentifier("smb-subpath")
            TextField("사용자 이름", text: $username).accessibilityIdentifier("smb-username")
            SecureField("SMB 비밀번호 (저장된 계정은 비워 두세요)", text: $password).accessibilityIdentifier("smb-password")
            Text("비밀번호는 이 Mac의 Keychain에 저장됩니다. 기존 라이브러리를 선택하면 곡·즐겨찾기·큐를 유지합니다.")
                .font(.caption).foregroundStyle(.secondary)
            if selectedRoot?.path.hasPrefix("/Volumes/" + share + "/") == true {
                Toggle("이 공유의 기존 라이브러리 폴더를 함께 전환", isOn: $allShareRoots)
            }
            HStack {
                Button(busy ? "연결 확인 중…" : "연결 확인 후 저장") { save() }.accessibilityIdentifier("smb-save")
                if selectedRoot?.smb != nil {
                    Button("마운트 폴더로 되돌리기") {
                        busy = true
                        Task { defer { busy = false }; do { try await model.setSMBSource(nil, rootID: selected); message = "기존 폴더 접근으로 되돌렸습니다. 색인은 유지됩니다." } catch { message = error.localizedDescription } }
                    }
                }
            }.disabled(busy)
            if let message { Text(message).font(.caption).textSelection(.enabled).accessibilityIdentifier("smb-status") }
        }.disabled(busy)
            .task(id: selected) { await loadSelection() }
    }
    private var selectedRoot: LibraryRoot? { model.roots.first { $0.id == selected } }
    private func loadSelection() async {
        password = ""; message = nil
        guard let root = selectedRoot else { return }
        if let source = root.smb { server = source.server; share = source.share; subpath = source.subpath; username = source.username; return }
        let connection = await Task.detached { SMBConnection.mounted(at: root.path) }.value
        guard selected == root.id else { return }
        if let connection {
            server = connection.server; share = connection.share; username = connection.username
            subpath = (try? connection.remotePath(for: URL(fileURLWithPath: root.path))) ?? ""
        }
    }
    private func save() {
        busy = true; message = nil
        let source = SMBSource(server: server.trimmingCharacters(in: .whitespaces), share: share, subpath: subpath, username: username)
        let entered = password, rootID = selected
        Task {
            defer { busy = false }
            do {
                try source.validate()
                let secret = entered.isEmpty ? try await KeychainStore.readAsync(source.credentialAccount) : entered
                let client = try await SMBClient.connect(source.connection, password: secret)
                let info = try await client.stat(source.path(""))
                guard info.isDirectory, !info.isSymbolicLink else { throw AppError.message("공유 내부 경로가 폴더가 아닙니다.") }
                if !entered.isEmpty { try await KeychainStore.saveAndVerify(secret, account: source.credentialAccount) }
                if rootID.isEmpty { try await model.addSMBSource(source) }
                else {
                    var sources = [rootID: source]
                    let prefix = "/Volumes/" + source.share + "/"
                    if allShareRoots, selectedRoot?.path.hasPrefix(prefix) == true {
                        for root in model.roots where root.id != rootID && root.path.hasPrefix(prefix) {
                            var sibling = source; sibling.subpath = String(root.path.dropFirst(prefix.count))
                            let info = try await client.stat(sibling.path(""))
                            guard info.isDirectory, !info.isSymbolicLink else { throw AppError.message("SMB 라이브러리 경로를 확인하세요.") }
                            sources[root.id] = sibling
                        }
                    }
                    try await model.setSMBSources(sources)
                }
                password = ""; message = "직접 SMB 연결을 저장했습니다. 재스캔하면 태그 구간만 읽습니다."
            } catch { message = error.localizedDescription }
        }
    }
}
