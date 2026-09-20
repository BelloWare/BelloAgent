import Foundation
import Security
import LocalAuthentication
import Darwin

struct KeychainVaultStorage: VaultStorage {
    static let service = "com.belloware.PiApp.configuration"
    static let account = "vault-v1"
    static let requirement = "anchor apple generic and identifier \"com.belloware.PiApp\" and certificate leaf[subject.OU] = \"43TXHV3TM3\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    let service: String
    let lockURL: URL
    init(service: String = Self.service, lockURL: URL? = nil) {
        self.service = service
        self.lockURL = lockURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.belloware.PiApp/configuration.lock")
    }
    static func validateIdentity() throws {
        var code: SecCode?, requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(Self.requirement as CFString, [], &requirement) == errSecSuccess,
              SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else { throw VaultError.unsigned }
    }
    private func query() -> [String: Any] {
        let context = LAContext(); context.interactionNotAllowed = true
        // Like BelloClipboardManager, use the ordinary macOS Keychain's
        // generic-password item and default trusted-application access policy.
        // This has no provisioning-profile or Data Protection group dependency.
        // That policy protects reads; it is not per-application write isolation.
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: Self.account, kSecUseAuthenticationContext as String: context]
    }
    func read() throws -> Data? {
        try Self.validateIdentity()
        var query = query(); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw VaultError.denied(status) }
        guard let data = result as? Data else { throw VaultError.corrupt }
        return data
    }
    func replace(expected: Data?, with replacement: Data) throws {
        try Self.validateIdentity()
        try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        // Only a lock another writer holds is "busy". A full disk, a read-only
        // or missing state directory used to report the same thing, so the user
        // retried forever on a problem retrying could never clear.
        guard fd >= 0 else {
            let reason = String(cString: strerror(errno))
            throw VaultError.invalid("The configuration lock at \(lockURL.path) could not be opened: \(reason)")
        }
        defer { _ = flock(fd, LOCK_UN); Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw VaultError.busy }
        guard try read() == expected else { throw VaultError.conflict }
        if expected != nil {
            let status = SecItemUpdate(query() as CFDictionary, [kSecValueData as String: replacement] as CFDictionary)
            guard status == errSecSuccess else { throw VaultError.denied(status) }
        } else {
            var item = query(); item[kSecValueData as String] = replacement
            item[kSecAttrLabel as String] = "Bello Agent configuration"
            let added = SecItemAdd(item as CFDictionary, nil)
            if added == errSecDuplicateItem { throw VaultError.conflict }
            guard added == errSecSuccess else { throw VaultError.denied(added) }
        }
    }
}
