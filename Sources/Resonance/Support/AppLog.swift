import OSLog

enum AppLog {
    static let library = Logger(subsystem: "local.Resonance", category: "library")
    static let playback = Logger(subsystem: "local.Resonance", category: "playback")
}
