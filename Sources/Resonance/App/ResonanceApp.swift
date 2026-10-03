import SwiftUI
import AppKit
import ResonanceCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task { @MainActor in
            model.cancelScan(); model.playback.pause()
            let queue = QueueSnapshot(entries: model.playback.entries, index: model.playback.index, position: model.playback.position)
            try? await model.db.setPreference("queue", value: queue)
            await model.saveSettings(); sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main @MainActor
struct ResonanceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let launch: Result<AppModel, Error> = Result { try AppModel() }
    var body: some Scene {
        WindowGroup("Resonance", id: "library") {
            switch launch {
            case .success(let model): ContentView(model: model).task { delegate.model = model; await model.bootstrap() }
            case .failure(let error): ContentUnavailableView("라이브러리를 열 수 없습니다", systemImage: "externaldrive.badge.exclamationmark", description: Text(error.localizedDescription + "\nDB를 보존했습니다. 백업과 저장 위치를 확인하세요.")).frame(minWidth: 600, minHeight: 400)
            }
        }
        .defaultSize(width: 1280, height: 830)
        .commands {
            if case .success(let model) = launch {
                CommandGroup(after: .newItem) {
                    Button("음악 폴더 추가…") { model.chooseRoot() }.keyboardShortcut("o", modifiers: [.command, .shift])
                    Button("라이브러리 재스캔") { model.startScan() }.keyboardShortcut("r").disabled(model.scanning)
                }
                CommandMenu("재생") {
                    Button("재생 / 일시 정지") { model.playback.toggle() }.keyboardShortcut("p")
                    Button("다음 트랙") { Task { await model.playback.next() } }.keyboardShortcut(.rightArrow, modifiers: .command)
                    Button("이전 트랙") { Task { await model.playback.previous() } }.keyboardShortcut(.leftArrow, modifiers: .command)
                    Divider()
                    Button("재생 목록") { model.queueVisible.toggle() }.keyboardShortcut("q", modifiers: [.command, .shift])
                    Button("감상 정보") { model.inspector.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
                }
            }
        }
        Settings { if case .success(let model) = launch { SettingsView(model: model) } }
    }
}
