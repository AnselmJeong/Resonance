import Foundation
import Security
import ResonanceCore

enum KeychainStore {
    static func contains(_ account: String) throws -> Bool {
        // Inspect metadata only: showing Settings must not decrypt keys or ask for access.
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.Resonance", kSecAttrAccount as String: account, kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw failure("상태 확인", status: status) }
        return true
    }
    static func readAsync(_ account: String) async throws -> String {
        try await Task.detached { try read(account) }.value
    }
    static func saveAndVerify(_ value: String, account: String) async throws {
        try await Task.detached {
            try save(value, account: account)
            guard try read(account) == value else { throw AppError.message("Keychain 저장 결과를 확인하지 못했습니다.") }
        }.value
    }
    static func read(_ account: String) throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.Resonance", kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data else { throw failure("읽기", status: status) }
        return String(decoding: data, as: UTF8.self)
    }
    static func save(_ value: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.Resonance", kSecAttrAccount as String: account]
        guard !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw failure("삭제", status: status) }
            return
        }
        let data = Data(value.utf8)
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw failure("저장", status: status) }
        } else if updated != errSecSuccess { throw failure("갱신", status: updated) }
    }
    private static func failure(_ operation: String, status: OSStatus) -> AppError {
        let reason = SecCopyErrorMessageString(status, nil) as String? ?? "오류 코드 \(status)"
        return .message("Keychain 키 \(operation) 실패: \(reason)")
    }
}
