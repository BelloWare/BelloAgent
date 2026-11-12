import CryptoKit
import Foundation

/// The last good custom model catalog each saved connection read, kept in
/// the app's state folder so that a launch has the models, their limits and
/// the picker at once, also when the catalog's address is slow or cannot be
/// reached; a fresh read replaces it behind (owner, 2026-11-12: "Do both for
/// catalog loading").
///
/// One file per connection, named by a hash of the connection's id. It holds
/// the parsed models and a hash of the source they were read from (the API,
/// the gateway and the catalog's address or path), never the address itself,
/// a key or a header: a catalog URL can carry an access token in its query.
/// A list read from another source, or from another gateway, is not this
/// connection's list and is never returned. Earlier versions of the app do
/// not know the folder and leave it alone.
actor ModelCatalogStore {
    struct Saved: Sendable, Equatable {
        var descriptors: [ModelDescriptor]
        var savedAt: Date
    }
    private struct File: Codable {
        var version: Int
        var source: String
        var savedAt: Date
        var models: [ModelDescriptor]
    }
    static let version = 1
    /// More than any catalog the endpoint accepts can come to (2 MiB of JSON,
    /// 2,048 models), so a file beyond it is not one this store wrote.
    static let maximumBytes = 8 * 1024 * 1024
    static let maximumModels = ModelCatalogEndpoint.Limits().modelCount

    let directory: URL
    init(directory: URL) { self.directory = directory }

    /// What identifies where a connection's list comes from, as a digest: the
    /// stored file can then say which source it belongs to without naming it.
    static func source(api: String, baseUrl: String, catalogUrl: String?) -> String {
        digest(["catalog-source-v1", api, baseUrl, (catalogUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines)].joined(separator: "\n"))
    }
    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func file(for connection: String) -> URL {
        directory.appendingPathComponent(Self.digest("catalog-connection-v1\n" + connection) + ".json", isDirectory: false)
    }

    /// The connection's stored list, when it was read from this very source
    /// and is a list the endpoint could have produced. Anything else (another
    /// source, a damaged or foreign file) is as if nothing were stored.
    func read(connection: String, source: String) -> Saved? {
        let url = file(for: connection)
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= Self.maximumBytes,
              let data = try? Data(contentsOf: url),
              let file = try? decoder.decode(File.self, from: data),
              file.version == Self.version, file.source == source, Self.valid(file.models) else { return nil }
        return Saved(descriptors: file.models, savedAt: file.savedAt)
    }

    /// Replaces the connection's stored list. A list that cannot be written
    /// leaves the earlier file, or none: the next read fetches as before.
    func save(_ descriptors: [ModelDescriptor], connection: String, source: String, at date: Date) {
        guard Self.valid(descriptors),
              let data = try? encoder.encode(File(version: Self.version, source: source, savedAt: date, models: descriptors)),
              data.count <= Self.maximumBytes else { return }
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = file(for: connection)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// A deleted connection's list goes with it.
    func remove(connection: String) {
        try? FileManager.default.removeItem(at: file(for: connection))
    }

    /// Drops the lists of connections that are no longer saved (deleted by
    /// another window's save, an import or an earlier version of the app).
    func prune(keeping connections: Set<String>) {
        let kept = Set(connections.map { file(for: $0).lastPathComponent })
        let found = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in found where url.pathExtension == "json" && !kept.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func valid(_ descriptors: [ModelDescriptor]) -> Bool {
        guard descriptors.count <= maximumModels else { return false }
        var seen = Set<String>()
        return descriptors.allSatisfy { TurnOverrides.normalizedModel($0.id) == $0.id && seen.insert($0.id).inserted }
    }
    private var encoder: JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970; return encoder }
    private var decoder: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970; return decoder }
}
