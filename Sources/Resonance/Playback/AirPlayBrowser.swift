import Foundation
import Network
import Observation
import ResonanceCore

/// Finds AirPlay 1 receivers the app can stream to directly. This Mac's own receiver is excluded.
@MainActor @Observable
final class AirPlayBrowser {
    private(set) var receivers: [AirPlayReceiver] = []
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private let ownName = Host.current().localizedName

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_raop._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> AirPlayReceiver? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                var txt: [String: String] = [:]
                if case let .bonjour(record) = result.metadata { txt = record.dictionary }
                return AirPlayReceiver(serviceName: name, txt: txt)
            }
            MainActor.assumeIsolated { self?.update(found) }
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state { AppLog.playback.error("AirPlay browse failed: \(error.localizedDescription, privacy: .public)") }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func update(_ found: [AirPlayReceiver]) {
        var unique: [String: AirPlayReceiver] = [:]
        // The same receiver is advertised once per network interface.
        for receiver in found where receiver.supportsDirectStreaming && receiver.name != ownName { unique[receiver.id] = receiver }
        let sorted = unique.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard sorted != receivers else { return }
        receivers = sorted
        AppLog.playback.info("AirPlay receivers: \(sorted.count, privacy: .public)")
        onChange?()
    }
}
