import Foundation
import CoreAudio
import Observation
import ResonanceCore

@MainActor @Observable
final class OutputMonitor {
    private(set) var route = AudioOutputRoute()
    var name: String { route.name }
    var nominalRate: Double? { route.nominalRate }
    var isAirPlay: Bool { route.isAirPlay }
    private var observation: OutputObservation?
    var onChange: ((AudioOutputRoute, AudioOutputRoute, Bool) -> Void)?

    init() {
        refresh()
        let callback: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        observation = OutputObservation(callback)
    }

    func refresh() {
        let devices = Self.devices()
        let current: AudioDeviceID = Self.number(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) ?? 0
        let alive = current != 0 && Self.number(current, kAudioDevicePropertyDeviceIsAlive) == 1
        let rate = current == 0 ? nil : Self.sampleRate(current)
        let next = AudioOutputRoute(
            uid: current == 0 ? nil : Self.string(current, kAudioDevicePropertyDeviceUID),
            name: alive ? (Self.string(current, kAudioObjectPropertyName) ?? "시스템 출력") : "출력 연결 없음",
            nominalRate: rate,
            isAirPlay: current != 0 && Self.number(current, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeAirPlay,
            available: alive
        )
        guard next != route else { return }
        let previous = route
        let previousAlive = previous.uid.map { uid in
            devices.contains { Self.string($0, kAudioDevicePropertyDeviceUID) == uid && Self.number($0, kAudioDevicePropertyDeviceIsAlive) == 1 }
        } ?? false
        route = next
        onChange?(previous, next, previousAlive)
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    private static func devices() -> [AudioDeviceID] {
        var address = address(kAudioHardwarePropertyDevices), size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var result = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = result.withUnsafeMutableBytes { AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!) }
        return status == noErr ? result : []
    }
    private static func number(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector), result: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &result) == noErr ? result : nil
    }
    private static func string(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector), result: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &result) == noErr, let result else { return nil }
        return result.takeRetainedValue() as String
    }
    private static func sampleRate(_ device: AudioDeviceID) -> Double? {
        var address = address(kAudioDevicePropertyNominalSampleRate), result: Double = 0, size = UInt32(MemoryLayout<Double>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &result) == noErr && result > 0 ? result : nil
    }
}

private final class OutputObservation {
    private let callback: AudioObjectPropertyListenerBlock
    private static let selectors = [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices]
    init(_ callback: @escaping AudioObjectPropertyListenerBlock) {
        self.callback = callback
        for selector in Self.selectors {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, callback)
        }
    }
    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    deinit {
        for selector in Self.selectors {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, callback)
        }
    }
}
