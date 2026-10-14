import Foundation

/// Establish ownership before execution: even short, failed or crash-left
/// output has a physical session directory independent of a result reference.
enum ToolOutputOwnership {
    static func directory(root: URL, sessionID: String, create: Bool = false) throws -> URL {
        guard !sessionID.isEmpty, sessionID != ".", sessionID != "..", !sessionID.contains("/"), !sessionID.contains("\\"),
              sessionID.utf8.count <= 128 else { throw CocoaError(.fileReadInvalidFileName) }
        let base = root.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(root.lastPathComponent, isDirectory: true)
        let folder = base.appendingPathComponent(sessionID, isDirectory: true)
        guard base.path == base.resolvingSymlinksInPath().path, folder.path == folder.resolvingSymlinksInPath().path else { throw CocoaError(.fileReadInvalidFileName) }
        if create { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700]) }
        return folder
    }
}
