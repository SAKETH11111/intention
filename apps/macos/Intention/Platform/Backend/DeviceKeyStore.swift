import Foundation
import Security

/// Keeps the device key that sign-in returns. The key is the only proof of
/// the person's account on this Mac and the invite that produced it works
/// once, so it is never logged and never written anywhere but here.
protocol DeviceKeyStore: Sendable {
    /// Nil when this Mac has not signed in. Throws when the store could not
    /// be read, which does not mean the key is gone.
    func read() throws -> String?
    func save(_ key: String) throws
    func delete() throws
}

/// The login keychain, one item per bundle identifier, so a development
/// build and a release keep separate accounts. macOS ties the item to the
/// app's signature: a build signed with the same identity reads it without
/// asking, and any other app makes macOS ask the person first.
struct KeychainDeviceKey: DeviceKeyStore {
    struct Failure: Error {
        let status: OSStatus
    }

    private let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? "co.intention.mac") {
        self.service = service
    }

    private var item: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "device-key"]
    }

    func read() throws -> String? {
        var query = item
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = found as? Data else { throw Failure(status: status) }
        return String(data: data, encoding: .utf8)
    }

    func save(_ key: String) throws {
        let data = Data(key.utf8)
        var status = SecItemUpdate(item as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var added = item
            added[kSecValueData] = data
            added[kSecAttrLabel] = "Intention device key"
            status = SecItemAdd(added as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    func delete() throws {
        let status = SecItemDelete(item as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}
