import Foundation
import LocalAuthentication
import Security

/// The sealed-mail identity key, readable only after Face ID or Touch ID on this
/// device. Enrolling a new face or finger invalidates it. Everything else about
/// the key stays in the Rust core's memory.
enum SealedKeychain {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.inbox2.sealed-identity",
        kSecAttrAccount as String: "identity",
    ]

    /// "Face ID" or "Touch ID", or nil when the phone can't offer biometrics.
    static var biometryName: String? {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return nil
        }
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                           .biometryCurrentSet, nil) else { return false }
        delete()
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessControl as String] = access
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Whether a key is saved, without asking for Face ID.
    static var hasKey: Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = base
        query[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    /// Shows the Face ID prompt and blocks: call off the main thread.
    static func load(reason: String) -> String? {
        let context = LAContext()
        context.localizedReason = reason
        var query = base
        query[kSecReturnData as String] = true
        query[kSecUseAuthenticationContext as String] = context
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() { SecItemDelete(base as CFDictionary) }
}
