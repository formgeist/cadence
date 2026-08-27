import Foundation
import Security
import CadenceCore

/// The `KeychainStore` the app ships — a thin wrapper over `SecItem*` for the
/// one secret scrobbling holds, the Last.fm session key (#95).
///
/// Under `swift run` this is the login keychain and just works. Inside the
/// sandboxed `make app` bundle it needs the `keychain-access-groups`
/// entitlement and a real signing identity — see `Scripts/make-app.sh`. A
/// failure here is not fatal: `ScrobbleController` treats a missing key as
/// "signed out".
struct KeychainStore: CadenceCore.KeychainStore {
    /// Namespaces the items; shows up as the "where" in Keychain Access.
    private let service = "com.formgeist.cadence.scrobble"

    func string(forAccount account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    func set(_ value: String?, forAccount account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        guard let value else {
            SecItemDelete(base as CFDictionary)
            return
        }

        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // Available once the device has been unlocked since boot; a
            // background scrobble flush after a lock/unlock still reads it.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            SecItemAdd(base.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }
}
