import Foundation

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
            let hidden = name.hasPrefix(".") || (lstat(url.path, &status) == 0 && status.st_flags & UInt32(UF_HIDDEN) != 0)
            entries.append(FolderEntry(url: url, isDirectory: value.kind == .folder, isDimmed: hidden))
        }
        var warnings: [String] = complete ? [] : ["Only the first \(limits.files.formatted()) entries or \(limits.pathBytes.formatted()) bytes of names were read."]
        func warn(_ message: String) { if !warnings.contains(message) { warnings.append(message) } }
        var ignored = Set<String>()
        if FileListing.gitAvailable, try await FileListing.repositoryTop(of: folder.path, environment: environment) != nil {
            // check-ignore keeps tracked files, just as Quick Open's ls-files
            // does. Bounded NUL-delimited batches also handle embedded newlines.
            var start = 0
            while start < entries.count {
                try Task.checkCancellation()
                var batch: [String] = [], bytes = 0
                while start < entries.count, batch.count < 2_048 {
                    let name = entries[start].name
                    if !batch.isEmpty, bytes + name.utf8.count + 1 > 32_768 { break }
                    batch.append(name); bytes += name.utf8.count + 1; start += 1
                }
                let input = Data((batch.joined(separator: "\0") + "\0").utf8)
                let result = try await FinderProcess.git(["check-ignore", "-z", "--stdin"], in: folder.path,
                    limit: 1_048_576, timeout: 20, environment: environment, input: input)
                if result.status == 0 || result.status == 1 {
                    for name in result.stdout.split(separator: 0) { ignored.insert(String(decoding: name, as: UTF8.self)) }
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
                    let relative = Array(cursor.path.dropFirst(base.path == "/" ? 1 : base.path.count + 1).utf8)
                    inherited = inherited || rules.isIgnored(relative, nameStart: relative.count - component.utf8.count, isDirectory: true)
                }
                let prefix = cursor == base ? "" : String(cursor.path.dropFirst(base.path == "/" ? 1 : base.path.count + 1)) + "/"
                switch FileListing.contents(of: cursor.path + "/.gitignore", limit: FileListing.ignoreFileLimit, following: false) {
                case .data(let data): rules.stack.append(IgnoreFile(base: Array(prefix.utf8), contents: data))
                case .tooLarge: warn("An ignore file over 1 MiB was not applied.")
                case .missing: break
                }
            }
            let prefix = folder == base ? "" : String(folder.path.dropFirst(base.path == "/" ? 1 : base.path.count + 1)) + "/"
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
}
