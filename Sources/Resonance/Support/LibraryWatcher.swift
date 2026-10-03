import Foundation
import CoreServices

final class LibraryWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: @Sendable () -> Void
    init(paths: [String], onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<LibraryWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 3, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        if let stream { FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "local.Resonance.watcher")); FSEventStreamStart(stream) }
    }
    deinit { if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) } }
}
