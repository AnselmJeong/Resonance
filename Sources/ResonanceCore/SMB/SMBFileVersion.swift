import Foundation

public enum SMBFileVersion {
    /// Foundation's mounted-file Date and libsmb2's timespec conversion can differ by
    /// less than one microsecond. Allow that conversion error only for legacy local records.
    /// Once a direct scan has stored the server timestamp, require exact equality again.
    public static func matches(size: Int64, modified: Double, track: Track) -> Bool {
        guard size == track.size, modified.isFinite, track.modified.isFinite else { return false }
        return modified == track.modified || (track.metadataStatus == nil && abs(modified - track.modified) < 0.000_001)
    }
}
