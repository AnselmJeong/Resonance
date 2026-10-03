import Testing
@testable import ResonanceCore

struct AudioOutputTests {
    private let mac = AudioOutputRoute(uid: "mac", name: "Mac", available: true)
    private let receiver = AudioOutputRoute(uid: "x100", name: "X100", nominalRate: 44100, isAirPlay: true, available: true)

    @Test func selectingHealthyOutputsKeepsPlayback() {
        #expect(!AudioOutputRoute.shouldPause(after: mac, current: receiver, previousStillAvailable: true, userIsSelecting: false))
        // AirPlay may rebuild its HAL object while keeping the same receiver UID.
        #expect(!AudioOutputRoute.shouldPause(after: receiver, current: receiver, previousStillAvailable: false, userIsSelecting: false))
        let other = AudioOutputRoute(uid: "soundbar", name: "Soundbar", isAirPlay: true, available: true)
        #expect(!AudioOutputRoute.shouldPause(after: receiver, current: other, previousStillAvailable: false, userIsSelecting: false))
        #expect(!AudioOutputRoute.shouldPause(after: receiver, current: mac, previousStillAvailable: false, userIsSelecting: true))
        #expect(!AudioOutputRoute.shouldPause(after: receiver, current: mac, previousStillAvailable: true, userIsSelecting: false))
    }

    @Test func unexpectedOutputLossPausesInsteadOfPlayingThroughSpeakers() {
        #expect(AudioOutputRoute.shouldPause(after: receiver, current: mac, previousStillAvailable: false, userIsSelecting: false))
        #expect(AudioOutputRoute.shouldPause(after: mac, current: AudioOutputRoute(), previousStillAvailable: false, userIsSelecting: false))
        let unavailableReceiver = AudioOutputRoute(uid: "x100", name: "X100", isAirPlay: true)
        #expect(AudioOutputRoute.shouldPause(after: receiver, current: unavailableReceiver, previousStillAvailable: false, userIsSelecting: false))
    }
}
