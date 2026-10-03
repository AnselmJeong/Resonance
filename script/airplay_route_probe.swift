// Isolated routing experiment: no library database, credentials or global output writes.
import AppKit
import AVKit
import CoreAudio
import Network

func property(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    .init(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}
func number(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
    var address = property(object, selector), result: UInt32 = 0, size: UInt32 = 4
    _ = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result)
    return result
}
func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    var address = property(object, selector), result: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr, let result else { return "unavailable" }
    return result.takeRetainedValue() as String
}
func devices() -> [AudioDeviceID] {
    var address = property(1, kAudioHardwarePropertyDevices), size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(1, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
    var values = [AudioDeviceID](repeating: 0, count: Int(size) / 4)
    let status = values.withUnsafeMutableBytes { AudioObjectGetPropertyData(1, &address, 0, nil, &size, $0.baseAddress!) }
    return status == noErr ? values : []
}

@main @MainActor final class RouteProbe: NSObject, NSApplicationDelegate {
    let player = AVPlayer()
    let status = NSTextField(wrappingLabelWithString: "")
    let label = NSTextField(labelWithString: "")
    var window: NSWindow!
    var timer: Timer?
    var source = URL(fileURLWithPath: "/tmp/no-source")
    var aac = URL(fileURLWithPath: "/tmp/no-aac")
    var lastLog = ""
    var ticks = 0
    var connection: NWConnection?
    var networkResult = "Not tested"
    var directProcess: Process?
    static func main() {
        let app = NSApplication.shared, delegate = RouteProbe()
        app.delegate = delegate; app.setActivationPolicy(.regular); app.run()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        guard args.count >= 3 else { NSApp.terminate(nil); return }
        source = URL(fileURLWithPath: args[1]); aac = URL(fileURLWithPath: args[2])
        player.volume = 0.12; player.allowsExternalPlayback = true
        window = NSWindow(contentRect: .init(x: 300, y: 250, width: 640, height: 470), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "AirPlay Route Probe"
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)])
        stack.addArrangedSubview(NSTextField(labelWithString: "Isolated AirPlay routing comparison — volume 12%"))
        let formats = NSStackView(views: [button("Load original FLAC", #selector(loadFLAC)), button("Load derived AAC", #selector(loadAAC)), button("Play / Pause", #selector(toggle))]); formats.spacing = 12; stack.addArrangedSubview(formats)
        stack.addArrangedSubview(label)
        let picker = AVRoutePickerView(); picker.player = player; picker.isRoutePickerButtonBordered = true
        picker.widthAnchor.constraint(equalToConstant: 48).isActive = true; picker.heightAnchor.constraint(equalToConstant: 36).isActive = true
        stack.addArrangedSubview(picker)
        stack.addArrangedSubview(button("Pin active X100 Core Audio UID", #selector(pinReceiver)))
        stack.addArrangedSubview(button("Use system device / native picker", #selector(useDefault)))
        stack.addArrangedSubview(button("Check X100 RTSP connection", #selector(checkNetwork)))
        stack.addArrangedSubview(button("Direct RAOP test — maximum 12 seconds", #selector(directRAOP)))
        stack.addArrangedSubview(status)
        loadFLAC(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }
    func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    func load(_ url: URL) { player.pause(); player.replaceCurrentItem(with: AVPlayerItem(url: url)); label.stringValue = "Source: " + url.lastPathComponent; refresh() }
    @objc func loadFLAC() { load(source) }
    @objc func loadAAC() { load(aac) }
    @objc func toggle() { if player.rate > 0 { player.pause() } else { player.play() }; refresh() }
    @objc func pinReceiver() {
        guard let device = devices().first(where: { string($0, kAudioObjectPropertyName).contains("X100") && number($0, kAudioDevicePropertyDeviceIsAlive) == 1 }) else { label.stringValue = "X100 has no active HAL device"; return }
        player.allowsExternalPlayback = false
        player.audioOutputDeviceUniqueID = string(device, kAudioDevicePropertyDeviceUID)
        label.stringValue = "Pinned X100 for this player; system default was not modified"
        refresh()
    }
    @objc func useDefault() { player.audioOutputDeviceUniqueID = nil; player.allowsExternalPlayback = true; label.stringValue = "Native picker mode"; refresh() }
    @objc func directRAOP() {
        guard directProcess == nil else { return }
        player.pause()
        let root = aac.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = aac.deletingLastPathComponent().appendingPathComponent("raop-venv/bin/python")
        process.arguments = [root.appendingPathComponent("script/raop_direct_probe.py").path, source.path]
        let log = aac.deletingLastPathComponent().appendingPathComponent("direct-raop-probe.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: log) else { return }
        process.standardOutput = handle; process.standardError = handle
        process.terminationHandler = { [weak self] child in
            try? handle.close()
            Task { @MainActor in
                self?.label.stringValue = "Direct RAOP probe exited: \(child.terminationStatus). Check direct-raop-probe.log"
                self?.directProcess = nil
            }
        }
        do { try process.run(); directProcess = process; label.stringValue = "Direct RAOP probe running; system output is unchanged" }
        catch { try? handle.close(); label.stringValue = "Direct RAOP launch: \(error.localizedDescription)" }
    }
    @objc func checkNetwork() {
        connection?.cancel()
        let candidate = NWConnection(host: "192.168.0.11", port: 5000, using: .tcp)
        connection = candidate
        networkResult = "Connecting"
        candidate.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.connection === candidate else { return }
                switch state {
                case .ready:
                    self.networkResult = "TCP ready"
                    let request = Data("OPTIONS * RTSP/1.0\r\nCSeq: 1\r\nUser-Agent: ResonanceRouteProbe/1.0\r\n\r\n".utf8)
                    candidate.send(content: request, completion: .contentProcessed { error in
                        if let error { Task { @MainActor in self.networkResult = "Send: \(error)" } }
                    })
                    candidate.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                        Task { @MainActor in
                            self.networkResult = data.flatMap { String(data: $0, encoding: .utf8)?.components(separatedBy: "\r\n").first } ?? "Receive: \(String(describing: error))"
                            candidate.cancel()
                        }
                    }
                case .waiting(let error), .failed(let error): self.networkResult = "TCP error: \(error)"
                default: break
                }
                self.refresh()
            }
        }
        candidate.start(queue: .main)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            if self?.connection === candidate { candidate.cancel(); self?.refresh() }
        }
    }
    func refresh() {
        ticks += 1
        let device = number(1, kAudioHardwarePropertyDefaultOutputDevice), alert = number(1, kAudioHardwarePropertyDefaultSystemOutputDevice)
        let names = devices().map { string($0, kAudioObjectPropertyName) }.joined(separator: ", ")
        let text = "System: \(string(device, kAudioObjectPropertyName))\nAlerts: \(string(alert, kAudioObjectPropertyName))\nPlayer UID: \(player.audioOutputDeviceUniqueID ?? "default")\nState: \(player.timeControlStatus.rawValue), item: \(player.currentItem?.status.rawValue ?? -1), time: \(Int(player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0))\nHAL: \(names)\nError: \(player.currentItem?.error?.localizedDescription ?? "none")\nNetwork: \(networkResult)"
        status.stringValue = text
        let log = "System=\(string(device, kAudioObjectPropertyName)); alert=\(string(alert, kAudioObjectPropertyName)); explicit=\(player.audioOutputDeviceUniqueID != nil); HAL=\(names); rate=\(player.rate); state=\(player.timeControlStatus.rawValue); item=\(player.currentItem?.status.rawValue ?? -1); network=\(networkResult)"
        if log != lastLog || ticks % 10 == 0 {
            lastLog = log
            let line = "\(Date()) \(log); position=\(player.currentTime().seconds)\n"
            let path = aac.deletingLastPathComponent().appendingPathComponent("airplay-route-probe.log")
            if !FileManager.default.fileExists(atPath: path.path) { try? line.data(using: .utf8)?.write(to: path) }
            else if let handle = try? FileHandle(forWritingTo: path) { _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(line.utf8)); try? handle.close() }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { player.pause(); connection?.cancel(); directProcess?.terminate(); timer?.invalidate() }
}
