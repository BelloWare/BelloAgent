import Foundation
import CryptoKit

enum TraceError: Error, LocalizedError {
    case invalid, budget, changed
    var errorDescription: String? { switch self {
    case .invalid: "Trace artifact is unavailable or invalid. Agent traffic continues."
    case .budget: "The global 1 GiB trace limit cannot retain this attempt. Agent traffic continues."
    case .changed: "Capture changed or was evicted during transfer. No complete trace was claimed."
    } }
}

// A single native actor owns the GLOBAL quota across every workspace host.
// Bodies are transferred in 32 KiB pages; filesystem failure never enters the host's lane.
actor TraceArchive {
    let root: URL
    let budget: Int64
    let retention: TimeInterval
    private var writing = false
    private var generation = 0
    init(root: URL, budget: Int64 = 1_073_741_824, retention: TimeInterval = 30 * 24 * 3600) { self.root = root; self.budget = budget; self.retention = retention }
    func clear(sessionID: String) throws {
        generation += 1
        for url in try directories() {
            let manifest = try? readManifest(url)
            if manifest?["sessionId"]?.string == sessionID { try FileManager.default.removeItem(at: url) }
        }
    }
    func list(sessionID: String) throws -> [[String: WireValue]] {
        try reconcile()
        return try directories().compactMap { url in
            guard let manifest = try? readManifest(url), manifest["sessionId"]?.string == sessionID else { return nil }
            return manifest
        }.sorted { ($0["wallTime"]?.string ?? "") > ($1["wallTime"]?.string ?? "") }
    }
    func body(attemptID: String, body: String, offset: Int) throws -> Data {
        guard UUID(uuidString: attemptID) != nil, ["request", "response"].contains(body), offset >= 0 else { throw TraceError.invalid }
        let file = root.appendingPathComponent(attemptID).appendingPathComponent(body + ".bin")
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset)); return try handle.read(upToCount: 32_768) ?? Data()
    }
    func exportRetained(sessionID: String, attemptID: String, destination: URL) async throws -> URL {
        guard UUID(uuidString: attemptID) != nil else { throw TraceError.invalid }
        let metadata = try readManifest(root.appendingPathComponent(attemptID))
        guard metadata["sessionId"]?.string == sessionID else { throw TraceError.invalid }
        return try await persist(metadata, destination: destination, read: { body, offset in
            let data = try await self.body(attemptID: attemptID, body: body, offset: offset)
            return ["bytes": .string(data.base64EncodedString()), "retainedBytes": metadata[body]?.object?["retainedBytes"] ?? .number(0)]
        }, verify: { try await self.readManifest(self.root.appendingPathComponent(attemptID)) })
    }
    func persist(_ metadata: [String: WireValue], destination: URL? = nil,
                 read: @Sendable (String, Int) async throws -> [String: WireValue],
                 verify: @Sendable () async throws -> [String: WireValue]) async throws -> URL {
        try Task.checkCancellation()
        guard !writing else { throw TraceError.budget }; try reconcile(); writing = true; defer { writing = false }
        let version = generation
        guard let id = metadata["attemptId"]?.string, UUID(uuidString: id) != nil else { throw TraceError.invalid }
        var lengths: [String: Int] = [:]
        for body in ["request", "response"] {
            let value = metadata[body]?.object?["retainedBytes"] ?? .number(0)
            guard let number = value.number, number.isFinite, number >= 0,
                  number <= 67_108_864, number.rounded() == number else { throw TraceError.invalid }
            lengths[body] = Int(number)
        }
        let retained = lengths.values.reduce(Int64(0)) { $0 + Int64($1) }
        guard retained >= 0, retained <= 67_108_864 else { throw TraceError.invalid }
        if destination == nil { try reconcile(reserving: retained + 65_536) }
        let base = destination ?? root
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let final = base.appendingPathComponent(id), staging = base.appendingPathComponent(".partial-" + UUID().uuidString)
        if FileManager.default.fileExists(atPath: final.path) { if destination != nil { throw TraceError.invalid }; return final }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: staging) } }
        var manifest = metadata
        manifest["artifactVersion"] = .number(1); manifest["retainedAt"] = .number(Date().timeIntervalSince1970)
        manifest["transformations"] = .array([.string("Authentication headers are masked; historical headers may contain labeled SHA-256 fingerprints. Request credential hashing and response credential-echo masking, if any, are declared in each body's transformations/byteExact. Other retained body bytes are unchanged transport observations.")])
        for body in ["request", "response"] {
            let descriptor = metadata[body]?.object
            let expected = lengths[body] ?? 0
            if descriptor == nil || ["credential-omitted", "not-captured", "not-retained", "unavailable", "purged", "expired"].contains(descriptor?["state"]?.string ?? "") {
                guard expected == 0 else { throw TraceError.invalid }
                // Absence is not an empty original body, including when
                // re-exporting a historical manifest from the live exporter.
                manifest.removeValue(forKey: body + "File")
                manifest.removeValue(forKey: body + "FileSHA256")
                continue
            }
            let url = staging.appendingPathComponent(body + ".bin")
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw TraceError.invalid }
            let handle = try FileHandle(forWritingTo: url); var hasher = SHA256(); var offset = 0
            do {
                while offset < expected {
                    let page = try await read(body, offset)
                    try Task.checkCancellation()
                    guard let base64 = page["bytes"]?.string, let data = Data(base64Encoded: base64), !data.isEmpty, data.count <= 32_768,
                          page["retainedBytes"]?.number == Double(expected), offset + data.count <= expected else { throw TraceError.changed }
                    try handle.write(contentsOf: data); hasher.update(data: data); offset += data.count
                }
                try handle.synchronize(); try handle.close()
            } catch { try? handle.close(); throw error }
            let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            if let expectedHash = metadata[body + "Hash"]?.object?["sha256"]?.string, expectedHash != hash { throw TraceError.changed }
            manifest[body + "File"] = .string(body + ".bin"); manifest[body + "FileSHA256"] = .string(hash)
        }
        guard version == generation else { throw TraceError.changed }
        let after = try await verify()
        try Task.checkCancellation()
        guard version == generation else { throw TraceError.changed }
        for body in ["request", "response"] {
            guard after[body + "Hash"] == metadata[body + "Hash"], after[body] == metadata[body] else { throw TraceError.changed }
        }
        let data = Data(WireValue.object(manifest).pretty.utf8)
        guard data.count <= 65_536 else { throw TraceError.invalid }
        try data.write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.appendingPathComponent("manifest.json").path)
        try FileManager.default.moveItem(at: staging, to: final); complete = true
        return final
    }
    func reconcile(reserving bytes: Int64 = 0) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var retained: [(URL, TimeInterval, Int64)] = []
        for url in try directories(includePartial: true) {
            if url.lastPathComponent.hasPrefix(".partial-") { if !writing { try? FileManager.default.removeItem(at: url) }; continue }
            guard let manifest = try? readManifest(url), let at = manifest["retainedAt"]?.number else { try FileManager.default.removeItem(at: url); continue }
            if Date().timeIntervalSince1970 - at > retention { try FileManager.default.removeItem(at: url); continue }
            let size = ["request.bin", "response.bin", "manifest.json"].reduce(Int64(0)) { total, name in total + ((try? FileManager.default.attributesOfItem(atPath: url.appendingPathComponent(name).path)[.size] as? NSNumber)?.int64Value ?? 0) }
            retained.append((url, at, size))
        }
        var used = retained.reduce(Int64(0)) { $0 + $1.2 }
        for item in retained.sorted(by: { $0.1 < $1.1 }) where used + bytes > budget { try FileManager.default.removeItem(at: item.0); used -= item.2 }
        guard used + bytes <= budget else { throw TraceError.budget }
    }
    private func directories(includePartial: Bool = false) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])
        guard urls.count <= 10_000 else { throw TraceError.budget }
        return urls.filter { (UUID(uuidString: $0.lastPathComponent) != nil || includePartial && $0.lastPathComponent.hasPrefix(".partial-")) && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true }
    }
    private func readManifest(_ directory: URL) throws -> [String: WireValue] {
        let url = directory.appendingPathComponent("manifest.json")
        guard ((try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max) <= 65_536 else { throw TraceError.invalid }
        guard let value = try JSONDecoder().decode(WireValue.self, from: Data(contentsOf: url)).object else { throw TraceError.invalid }
        return value
    }
}
