import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

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

extension ToolOutputOwnership {
    /// Journals are the durable reference set, including copied old branches.
    /// There is one physical output file regardless of how many chats inherit it.
    struct Inventory: Sendable {
        var folders: [URL: [URL]] = [:]
        var directories: [URL: Stamp] = [:]
        var journals: Set<URL> = []
        var keys: Set<String> { Set(folders.values.flatMap { $0 }.compactMap(Self.key)) }
        static func key(_ file: URL) -> String? {
            let text = "tool-output/" + file.deletingLastPathComponent().lastPathComponent + "/" + file.lastPathComponent
            let matches = ToolOutputOwnership.names(in: text)
            let key = file.deletingLastPathComponent().lastPathComponent + "/" + file.lastPathComponent
            return matches.contains(key.lowercased()) ? key.lowercased() : nil
        }
        func recyclable(keeping keys: Set<String>) -> [URL] {
            folders.flatMap { folder, files in
                let unused = files.filter { Self.key($0).map { !keys.contains($0) } == true }
                return unused.count == files.count ? [folder] : unused
            }.sorted { $0.path < $1.path }
        }
        var unchanged: Bool { directories.allSatisfy { (try? Stamp($0.key)) == $0.value } }
    }

    struct Stamp: Equatable, Sendable {
        let device: UInt64, inode: UInt64, size: Int64, modified: Int64, modifiedNS: Int64, changed: Int64, changedNS: Int64
        let mode: mode_t
        init(_ path: URL) throws {
            var value = stat()
            guard lstat(path.path, &value) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            device = UInt64(truncatingIfNeeded: value.st_dev); inode = UInt64(value.st_ino); size = Int64(value.st_size); mode = value.st_mode & mode_t(S_IFMT)
            #if canImport(Darwin)
            modified = Int64(value.st_mtimespec.tv_sec); modifiedNS = Int64(value.st_mtimespec.tv_nsec)
            changed = Int64(value.st_ctimespec.tv_sec); changedNS = Int64(value.st_ctimespec.tv_nsec)
            #else
            modified = Int64(value.st_mtim.tv_sec); modifiedNS = Int64(value.st_mtim.tv_nsec)
            changed = Int64(value.st_ctim.tv_sec); changedNS = Int64(value.st_ctim.tv_nsec)
            #endif
        }
    }

    static func inventory(appRoot: URL, deleted: [String: Set<String>]) throws -> Inventory {
        var result = Inventory()
        let root = appRoot.resolvingSymlinksInPath().appendingPathComponent("Workspaces")
        func children(_ folder: URL) throws -> [URL] {
            do {
                let stamp = try Stamp(folder)
                guard stamp.mode == mode_t(S_IFDIR) else { throw CocoaError(.fileReadInvalidFileName) }
                result.directories[folder] = stamp
                return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { return [] }
        }
        for workspace in try children(root) {
            try Task.checkCancellation()
            let stamp = try Stamp(workspace)
            guard stamp.mode != mode_t(S_IFLNK) else { throw CocoaError(.fileReadInvalidFileName) }
            guard stamp.mode == mode_t(S_IFDIR) else { continue }
            result.directories[workspace] = stamp
            let sessions = workspace.appendingPathComponent("Sessions")
            for journal in try children(sessions) where journal.pathExtension == "jsonl" && !journal.lastPathComponent.hasPrefix(".") { result.journals.insert(journal) }
            let outputs = sessions.appendingPathComponent("tool-output")
            for folder in try children(outputs) where deleted[workspace.lastPathComponent]?.contains(folder.lastPathComponent) == true {
                try Task.checkCancellation()
                let safe = try directory(root: outputs, sessionID: folder.lastPathComponent)
                let files = try children(safe)
                guard try files.allSatisfy({ try Stamp($0).mode == mode_t(S_IFREG) }) else { throw CocoaError(.fileReadInvalidFileName) }
                result.folders[safe] = files
            }
        }
        return result
    }

    private static let referencePattern = try! NSRegularExpression(pattern: #"tool-output/([A-Za-z0-9_.:-]{1,128}/[A-Za-z0-9_.-]+\.(?:log|txt))"#, options: .caseInsensitive)
    private static func names(in text: String) -> Set<String> {
        let string = text as NSString
        return Set(referencePattern.matches(in: text, range: NSRange(location: 0, length: string.length)).map { string.substring(with: $0.range(at: 1)).lowercased() })
    }
    static func references(in data: Data, candidates: Set<String>) throws -> Set<String> {
        let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        var found: Set<String> = []
        func visit(_ value: Any) {
            if let text = value as? String { found.formUnion(names(in: text).intersection(candidates)) }
            else if let object = value as? [String: Any] { for (key, value) in object { visit(key); visit(value) } }
            else if let array = value as? [Any] { for value in array { visit(value) } }
        }
        visit(value); return found
    }
    struct References: Sendable {
        var keys: Set<String> = []
        var files: [URL: Stamp] = [:]
        var unchanged: Bool { files.allSatisfy { (try? Stamp($0.key)) == $0.value } }
    }
    /// One bounded JSONL record at a time. Decode strings before finding
    /// paths, so slash/unicode escapes in an imported record remain references.
    static func references(in journals: Set<URL>, candidates: Set<String>) throws -> References {
        var result = References()
        for path in journals {
            try Task.checkCancellation()
            if candidates.isSubset(of: result.keys) { break }
            do {
                let before = try Stamp(path)
                guard before.mode == mode_t(S_IFREG), before.size >= 0 else { throw CocoaError(.fileReadInvalidFileName) }
                let fd = open(path.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw CocoaError(.fileReadUnknown) }
                let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? file.close() }
                var opened = stat()
                guard fstat(fd, &opened) == 0, UInt64(opened.st_ino) == before.inode, UInt64(truncatingIfNeeded: opened.st_dev) == before.device else { throw CocoaError(.fileReadUnknown) }
                var remaining = before.size, pending = Data()
                while remaining > 0 {
                    try Task.checkCancellation()
                    let bytes = try file.read(upToCount: Int(min(65_536, remaining))) ?? Data()
                    guard !bytes.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                    remaining -= Int64(bytes.count)
                    let parts = bytes.split(separator: 10, omittingEmptySubsequences: false)
                    for part in parts.dropLast() {
                        pending.append(part)
                        guard pending.count <= 32 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                        if !pending.isEmpty { result.keys.formUnion(try references(in: pending, candidates: candidates)) }
                        pending.removeAll(keepingCapacity: true)
                    }
                    if let last = parts.last { pending.append(last) }
                    guard pending.count <= 32 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                }
                if !pending.isEmpty { result.keys.formUnion(try references(in: pending, candidates: candidates)) }
                guard try Stamp(path) == before else { throw CocoaError(.fileReadUnknown) }
                result.files[path] = before
            } catch is CancellationError { throw CancellationError() }
            catch {
                // Unknown references cannot authorize removal. Keep the files;
                // a later deletion/relaunch can reclaim them after repair.
                result.keys = candidates; return result
            }
        }
        return result
    }
}
