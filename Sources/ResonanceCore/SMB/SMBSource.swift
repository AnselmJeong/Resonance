import Foundation

/// The root ID and legacy display path stay stable when switching transports.
/// All server paths are retained byte-for-byte; never use Swift String equality as a path key.
public struct SMBSource: Codable, Hashable, Sendable {
    public var server: String
    public var share: String
    public var subpath: String
    public var username: String
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }
    public func hash(into hasher: inout Hasher) { hasher.combine(identity) }
    private var identity: String { TextKey.id(server, share, subpath, username) }
    public var credentialAccount: String { connection.credentialAccount }
    public var connection: SMBConnection { SMBConnection(mountPath: "/", server: server, share: share, username: username, enabled: true) }
    public init(server: String, share: String, subpath: String = "", username: String) {
        self.server = server; self.share = share; self.subpath = subpath; self.username = username
    }
    public func validate() throws {
        try connection.validate()
        try Self.validatePath(subpath)
    }
    public func path(_ relative: String) throws -> String {
        try Self.validatePath(relative)
        return subpath.isEmpty ? relative : relative.isEmpty ? subpath : subpath + "/" + relative
    }
    public static func validatePath(_ path: String) throws {
        guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
              path.isEmpty || path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw AppError.message("SMB 공유 내부의 상대 경로를 입력하세요. 상위 경로·빈 경로 요소는 사용할 수 없습니다.")
        }
    }
}

struct ExactPathSet: ExpressibleByArrayLiteral, Sequence, Sendable {
    private var paths: [Data: String] = [:]
    init(arrayLiteral elements: String...) { for element in elements { insert(element) } }
    mutating func insert(_ path: String) { paths[Data(path.utf8)] = path }
    func contains(_ path: String) -> Bool { paths[Data(path.utf8)] != nil }
    func makeIterator() -> Dictionary<Data, String>.Values.Iterator { paths.values.makeIterator() }
}
