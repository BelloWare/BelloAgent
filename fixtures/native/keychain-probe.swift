// Acceptance executable only. Compiles the production Keychain backend but
// uses a fresh synthetic item; it never reads existing application secrets.
import Foundation
import Security
import LocalAuthentication

enum VaultError: Error { case denied(Int32), corrupt, conflict, busy, invalid(String), unsigned }
protocol VaultStorage: Sendable { func read() throws -> Data?; func replace(expected: Data?, with replacement: Data) throws }

// The ordinary login Keychain's legacy UI switch is needed only for this
// standalone raw-client probe. Declaring this legacy test client deprecated
// confines the deprecated API to acceptance code, not the application backend.
@available(macOS, deprecated: 10.10)
@main struct KeychainProbe {
    static func main() {
        guard CommandLine.arguments.count == 4 else { exit(2) }
        let operation = CommandLine.arguments[1], service = CommandLine.arguments[2]
        guard service.hasPrefix("com.belloware.PiApp.acceptance."), service.count > 40 else { exit(2) }
        // Deny optional interaction in this process; this grants no access and
        // changes no Keychain item, trust list or persistent system setting.
        guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { exit(2) }
        let store = KeychainVaultStorage(service: service, lockURL: URL(fileURLWithPath: CommandLine.arguments[3]))
        let initial = Data("SYNTHETIC-VAULT-ACCEPTANCE-ONLY revision 1".utf8)
        let updated = Data("SYNTHETIC-VAULT-ACCEPTANCE-ONLY revision 2".utf8)
        let tampered = Data("SYNTHETIC-RAW-UPDATE-ACCEPTANCE-ONLY".utf8)
        do {
            switch operation {
            case "missing": guard try store.read() == nil else { throw VaultError.corrupt }
            case "create": try store.replace(expected: nil, with: initial)
            case "read": guard try store.read() == initial else { throw VaultError.corrupt }
            case "update": try store.replace(expected: initial, with: updated)
            case "read-updated": guard try store.read() == updated else { throw VaultError.corrupt }
            case "read-raw-update": guard try store.read() == tampered else { throw VaultError.corrupt }
            case "restore": try store.replace(expected: tampered, with: updated)
            case "conflict-missing", "conflict-stale", "conflict-create":
                do {
                    try store.replace(expected: operation == "conflict-create" ? nil : initial, with: updated)
                    throw VaultError.invalid("conflicting update unexpectedly succeeded")
                } catch VaultError.conflict { }
            case "raw-read", "raw-update", "raw-delete", "cleanup":
                // No production identity guard here: test the OS policy itself.
                // Keep the production LAContext and additionally suppress the
                // legacy raw client's authorization dialog above.
                let context = LAContext(); context.interactionNotAllowed = true
                var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service, kSecAttrAccount as String: KeychainVaultStorage.account,
                    kSecUseAuthenticationContext as String: context]
                let status: OSStatus
                if operation == "raw-read" {
                    query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
                    var result: CFTypeRef?; status = SecItemCopyMatching(query as CFDictionary, &result)
                } else if operation == "raw-update" {
                    status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: tampered] as CFDictionary)
                } else { status = SecItemDelete(query as CFDictionary) }
                print("status=\(status)")
                exit(status == errSecSuccess || operation == "cleanup" && status == errSecItemNotFound ? 0 : 3)
            default: exit(2)
            }
            #if UPDATE_PROBE
            print("success updated executable")
            #else
            print("success original executable")
            #endif
        } catch { print("denied \(error)"); exit(3) }
    }
}
