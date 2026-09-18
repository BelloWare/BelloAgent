import Foundation

enum RoutingConfiguration {
    static func validate(_ value: WireValue?) throws {
        guard let value else { return }
        let allowed: Set<String> = ["reference", "modelHeader", "deploymentHeader", "groupHeader", "cacheHeader", "replayPolicy", "expectedModel", "replayContract"]
        func valid(_ value: WireValue?, max: Int = 512) -> Bool {
            guard let text=value?.string, !text.isEmpty, text.utf8.count <= max else { return false }
            return !text.utf8.contains(where: { $0 < 32 || $0 == 127 })
        }
        guard let fields=value.object, Set(fields.keys).isSubset(of: allowed), fields.values.allSatisfy({ valid($0) }),
              ["ask", "portable", "pinned"].contains(fields["replayPolicy"]?.string ?? "ask") else { throw VaultError.invalid("Choose a reasoning replay policy and bounded gateway metadata fields.") }
        let names=["modelHeader", "deploymentHeader", "groupHeader", "cacheHeader"].compactMap { fields[$0]?.string?.lowercased() }
        guard Set(names).count == names.count else { throw VaultError.invalid("Metadata headers must have distinct meanings.") }
        for name in names {
            guard valid(fields["reference"]), name.range(of: "^[a-z0-9-]{1,128}$", options: .regularExpression) != nil,
                  !["authorization", "cookie", "token", "secret", "key"].contains(where: { name.contains($0) }),
                  !["host", "location", "content-type", "content-length", "connection"].contains(name) else { throw VaultError.invalid("Metadata headers require a deployment contract reference and cannot expose authentication or transport fields.") }
        }
        if fields["replayPolicy"]?.string == "pinned" {
            guard valid(fields["expectedModel"], max: 256), valid(fields["replayContract"]) else { throw VaultError.invalid("Preserving native reasoning requires an expected model and a gateway contract guaranteeing a compatible fixed route.") }
        }
    }
}
