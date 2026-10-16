import Foundation
import Security
import LocalAuthentication
import Darwin
import QuotaCore


enum ConfigurationStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuotaPeek", isDirectory: true)
    }
    static var file: URL { directory.appendingPathComponent("preferences.json") }

    static func load() throws -> Preferences {
        guard FileManager.default.fileExists(atPath: file.path) else { return Preferences() }
        return try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: file))
    }

    static func save(_ preferences: Preferences) throws {
        let data = try JSONEncoder().encode(preferences)
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = directory.appendingPathComponent(".preferences-\(UUID().uuidString).json")
        defer { try? manager.removeItem(at: temporary) }
        guard manager.createFile(atPath: temporary.path, contents: data,
                                 attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        // Nothing may throw after replacement: the caller can safely roll back a Keychain change on failure.
        guard Darwin.rename(temporary.path, file.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

enum KeyStore {
    private static let service = "com.local.QuotaPeek.api-key"
    private static func query(for id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id,
         kSecAttrSynchronizable as String: false]
    }
    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "无法访问本机钥匙串（\(status)）。请解锁登录钥匙串后重试。" }
    }

    static func read(for id: String, allowInteraction: Bool = false) throws -> String {
        var request = query(for: id)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        // A changed signature or locked keychain must not block menu-bar startup.
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        request[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess else { throw Failure(status: status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw Failure(status: errSecDecode)
        }
        return value
    }

    static func save(_ value: String, for id: String) throws {
        let query = query(for: id)
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var request = query.merging(attributes) { _, new in new }
            request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(request as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure(status: added) }
        } else if status != errSecSuccess { throw Failure(status: status) }
    }

    static func delete(for id: String) throws {
        let status = SecItemDelete(query(for: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}
