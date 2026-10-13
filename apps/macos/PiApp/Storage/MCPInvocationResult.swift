import Foundation
import Darwin

/// Inspector results are not chat messages or capture payloads. Each explicit
/// invocation keeps its complete reply in its project's private app storage.
enum MCPInvocationResult {
    static func save(_ record: WireValue, commandID: String, folder: URL, root: URL) throws {
        let folder = folder.standardizedFileURL, root = root.standardizedFileURL
        guard UUID(uuidString: commandID) != nil, folder.path.hasPrefix(root.path + "/") else { throw StoreError.invalidRecord }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard (try folder.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw StoreError.invalidRecord }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let file = folder.appendingPathComponent(commandID + ".json")
        try JSONEncoder().encode(record).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }; try handle.synchronize()
        // The file and its name must both survive a crash before the helper
        // is told to remove its only evidence that a remote effect happened.
        var directory = folder
        while true {
            let fd = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW); guard fd >= 0 else { throw StoreError.unavailable }
            let synced = fsync(fd); Darwin.close(fd); guard synced == 0 else { throw StoreError.unavailable }
            if directory.path == root.path { break }
            directory.deleteLastPathComponent()
        }
    }
}
