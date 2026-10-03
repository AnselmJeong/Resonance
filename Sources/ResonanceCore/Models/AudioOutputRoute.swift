import Foundation

public struct AudioOutputRoute: Equatable, Sendable {
    public var uid: String?
    public var name: String
    public var nominalRate: Double?
    public var isAirPlay: Bool
    public var available: Bool

    public init(uid: String? = nil, name: String = "출력 연결 없음", nominalRate: Double? = nil, isAirPlay: Bool = false, available: Bool = false) {
        self.uid = uid; self.name = name; self.nominalRate = nominalRate
        self.isAirPlay = isAirPlay; self.available = available
    }

    /// A healthy device switch keeps playing. An unexpected receiver loss must
    /// not send the remaining music to another output without the user's choice.
    public static func shouldPause(after previous: Self, current: Self, previousStillAvailable: Bool, userIsSelecting: Bool) -> Bool {
        guard !userIsSelecting else { return false }
        if !current.available { return true }
        return previous.available && previous.isAirPlay && previous.uid != current.uid && !previousStillAvailable && !current.isAirPlay
    }
}
