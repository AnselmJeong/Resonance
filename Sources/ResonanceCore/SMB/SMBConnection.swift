import Foundation
import Darwin

/// Non-secret, explicit mapping between a mounted volume and a direct SMB endpoint.
public struct SMBConnection: Codable, Identifiable, Equatable, Sendable {
    public var mountPath: String
    public var server: String
    public var share: String
    public var username: String
    public var enabled: Bool
    public var id: String { mountPath }
    public var credentialAccount: String { "smb:" + TextKey.id(server, share, username) }
    public init(mountPath: String, server: String, share: String, username: String, enabled: Bool = false) {
        self.mountPath = mountPath; self.server = server; self.share = share; self.username = username; self.enabled = enabled
    }
    public func validate() throws {
        guard mountPath.hasPrefix("/"), !server.isEmpty, !share.isEmpty, !username.isEmpty,
              server.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:").contains($0) }),
              !share.contains("/"), !share.contains("\\"),
              !username.contains("%"), !username.hasPrefix("-"),
              !(share + username).unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw AppError.message("SMB 서버 주소, 공유 이름, 사용자 이름을 확인하세요.")
        }
    }
    public func remotePath(for url: URL) throws -> String {
        let base = URL(fileURLWithPath: mountPath).standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { throw AppError.message("설정된 SMB 폴더 밖의 경로입니다.") }
        let relative = String(path.dropFirst(base.count + 1))
        guard !relative.split(separator: "/").contains("..") else { throw AppError.message("잘못된 SMB 경로입니다.") }
        return relative
    }
    public static func mounted(at path: String) -> SMBConnection? {
        var info = statfs()
        guard path.withCString({ statfs($0, &info) }) == 0 else { return nil }
        func string<T>(_ tuple: inout T) -> String {
            withUnsafePointer(to: &tuple) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) } }
        }
        guard string(&info.f_fstypename) == "smbfs" else { return nil }
        let mount = string(&info.f_mntonname), source = string(&info.f_mntfromname)
        guard let url = URL(string: "smb:" + source), let server = url.host else { return nil }
        let share = String(url.path.drop(while: { $0 == "/" }))
        guard !share.isEmpty else { return nil }
        return SMBConnection(mountPath: mount, server: server, share: share, username: url.user?.removingPercentEncoding ?? "")
    }
}
