import Foundation
import GitProcessSafety

public struct FolderEntry: Sendable, Equatable {
    public let url: URL
    public let isDirectory: Bool
    public let isDimmed: Bool
    public var name: String { url.lastPathComponent }
    public init(url: URL, isDirectory: Bool, isDimmed: Bool = false) {
        self.url = FileBreadcrumb.normalized(url); self.isDirectory = isDirectory; self.isDimmed = isDimmed
    }
}

/// One level only. Ignore decisions match Quick Open; ignored and dot files
/// remain visible but dimmed. As in Quick Open, .git, special files and links
/// to directories are omitted. No recursive scan and no agent/helper access.
public struct FolderDirectory: Sendable {
    public var entries: [FolderEntry]
    public var warning: String?
    public init(entries: [FolderEntry], warning: String? = nil) { self.entries = entries; self.warning = warning }

    public static func read(_ folder: URL, relativeTo root: URL,
                            environment: [String: String]? = nil,
                            limits: FileListingLimits = .init(files: 100_000, pathBytes: 16 * 1_048_576)) async throws -> FolderDirectory {
        let work = Task.detached(priority: .userInitiated) {
            try await readOffMain(folder, root: root, environment: environment ?? FinderProcess.environment,
                limits: .init(files: min(100_000, max(1, limits.files)), pathBytes: min(16 * 1_048_576, max(1, limits.pathBytes))))
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    private static func readOffMain(_ folder: URL, root: URL, environment: [String: String], limits: FileListingLimits) async throws -> FolderDirectory {
        try Task.checkCancellation()
        guard let directory = opendir(folder.path) else {
            throw FinderProcess.Failure(description: "This folder could not be read.")
        }
        // Bound memory even for hostile directories. The display is paged
        // separately; this safety ceiling is disclosed, never a silent cut.
        let (raw, complete) = try FileListing.entries(of: directory, in: folder.path,
            limits: limits)
        var entries: [FolderEntry] = []
        for value in raw.prefix(limits.files) {
            try Task.checkCancellation()
            switch value.kind {
            case .folder, .file: break
            case .link: if FileListing.kind(of: folder.path, value.name) != .file { continue }
            case .other: continue
            }
            let name = String(decoding: value.name, as: UTF8.self)
            let url = folder.appendingPathComponent(name, isDirectory: false)
            var status = stat()
            let hidden = name.gitHasPrefix(".") || (lstat(url.path, &status) == 0 && status.st_flags & UInt32(UF_HIDDEN) != 0)
            entries.append(FolderEntry(url: url, isDirectory: value.kind == .folder, isDimmed: hidden))
        }
        var warnings: [String] = complete ? [] : ["Only the first \(limits.files.formatted()) entries or \(limits.pathBytes.formatted()) bytes of names were read."]
        func warn(_ message: String) { if !warnings.contains(message) { warnings.append(message) } }
        var ignored = Set<String>()
        if FileListing.gitAvailable, try await FileListing.repositoryTop(of: folder.path, environment: environment) != nil {
            // check-ignore keeps tracked files, just as Quick Open's ls-files
            // does. Pass bounded batches after "--": config includes must
            // never consume repository-controlled filenames from stdin.
            var start = 0
            while start < entries.count {
                try Task.checkCancellation()
                var batch: [String] = [], bytes = 0
                while start < entries.count, batch.count < 2_048 {
                    let name = entries[start].name
                    if !batch.isEmpty, bytes + name.utf8.count + 1 > 32_768 { break }
                    batch.append(name); bytes += name.utf8.count + 1; start += 1
                }
                let result = try await FinderProcess.git(["check-ignore", "--"] + batch, in: folder.path,
                    limit: 1_048_576, timeout: 20, environment: environment)
                if result.status == 0 || result.status == 1 {
                    for name in result.stdout.split(separator: 10) { ignored.insert(unquoted(name)) }
                } else { warn("Ignore rules could not be applied.") }
            }
        } else {
            var rules = IgnoreRules(global: try await FileListing.globalIgnoreFile(in: folder.path, environment: environment, warn: warn))
            let base = FileBreadcrumb.contains(folder, in: root) ? root : folder
            var cursor = base, inherited = false
            let chain = [""] + Array(folder.pathComponents.dropFirst(base.pathComponents.count))
            for component in chain {
                try Task.checkCancellation()
                if !component.isEmpty {
                    cursor.appendPathComponent(component)
                    let relative = Array(cursor.path.gitDropFirst(base.path == "/" ? 1 : base.path.utf8.count + 1).utf8)
                    inherited = inherited || rules.isIgnored(relative, nameStart: relative.count - component.utf8.count, isDirectory: true)
                }
                let prefix = cursor == base ? "" : String(cursor.path.gitDropFirst(base.path == "/" ? 1 : base.path.utf8.count + 1)) + "/"
                switch FileListing.contents(of: cursor.path + "/.gitignore", limit: FileListing.ignoreFileLimit, following: false) {
                case .data(let data): rules.stack.append(IgnoreFile(base: Array(prefix.utf8), contents: data))
                case .tooLarge: warn("An ignore file over 1 MiB was not applied.")
                case .missing: break
                }
            }
            let prefix = folder == base ? "" : String(folder.path.gitDropFirst(base.path == "/" ? 1 : base.path.utf8.count + 1)) + "/"
            for entry in entries {
                try Task.checkCancellation()
                if inherited || rules.isIgnored(Array((prefix + entry.name).utf8), nameStart: prefix.utf8.count, isDirectory: entry.isDirectory) { ignored.insert(entry.name) }
            }
        }
        entries = entries.map { FolderEntry(url: $0.url, isDirectory: $0.isDirectory, isDimmed: $0.isDimmed || ignored.contains($0.name)) }
        entries.sort {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.name < $1.name : order == .orderedAscending
        }
        try Task.checkCancellation()
        return FolderDirectory(entries: entries, warning: warnings.isEmpty ? nil : warnings.joined(separator: " "))
    }

    // check-ignore permits NUL output only with --stdin. Its argument form
    // C-quotes control bytes, quotes and backslashes, including odd filenames.
    private static func unquoted(_ value: Data.SubSequence) -> String {
        guard value.first == 34, value.last == 34, value.count >= 2 else { return String(decoding: value, as: UTF8.self) }
        var rest = value.dropFirst().dropLast(), bytes: [UInt8] = []
        while let byte = rest.popFirst() {
            guard byte == 92, let next = rest.popFirst() else { bytes.append(byte); continue }
            switch next {
            case 97: bytes.append(7)
            case 98: bytes.append(8)
            case 116: bytes.append(9)
            case 110: bytes.append(10)
            case 118: bytes.append(11)
            case 102: bytes.append(12)
            case 114: bytes.append(13)
            case 48...55:
                var octal = Int(next - 48)
                for _ in 0..<2 {
                    if let digit = rest.first, (48...55).contains(digit) { octal = octal * 8 + Int(digit - 48); rest.removeFirst() }
                }
                bytes.append(UInt8(truncatingIfNeeded: octal))
            default: bytes.append(next)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
