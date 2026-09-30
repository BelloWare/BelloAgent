import Foundation

// The files of a project's folders, for finding one by name: what git lists
// in a folder that is in a repository (tracked files, ignored or not, and
// untracked ones it does not ignore; another repository inside, a submodule
// or not, listed by its own git), and elsewhere a walk that ignores what the
// folders' `.gitignore` files and the user's global ignore file do. Only
// files that are there and can be opened: a regular file, or a link to one.
// Links to folders are not followed. The whole list is bounded, and says
// when it stopped short, and what it left out or could not apply.

/// Where a listing stops: at most this many files, and this many bytes of
/// their paths.
public struct FileListingLimits: Sendable, Equatable {
    public var files: Int
    public var pathBytes: Int
    public init(files: Int = 500_000, pathBytes: Int = 64 * 1_048_576) {
        self.files = files; self.pathBytes = pathBytes
    }
}

/// The files of one folder: their paths below it, one after another, in the
/// order they were found (git's, or the walk's).
struct FolderListing: Sendable {
    var bytes: [UInt8] = []
    /// Where each path ends in `bytes`.
    var ends: [Int] = []
    /// The list stopped at a limit.
    var truncated = false
    /// What the listing left out or could not apply, for the reader.
    var warnings: [String] = []
    /// Folders below this one that another of the project's folders lists
    /// (paths ending "/"): their files are left to it.
    var excluded: [[UInt8]] = []
    var count: Int { ends.count }
    func path(_ index: Int) -> ArraySlice<UInt8> { bytes[(index == 0 ? 0 : ends[index - 1])..<ends[index]] }

    /// Adds `prefix` and `path` if `limits` allow; false once they do not.
    mutating func add(_ prefix: [UInt8], _ path: some Collection<UInt8>, limits: FileListingLimits) -> Bool {
        let length = prefix.count + path.count
        guard count < limits.files, bytes.count + length <= limits.pathBytes else {
            truncated = true
            return false
        }
        bytes.append(contentsOf: prefix); bytes.append(contentsOf: path)
        ends.append(bytes.count)
        return true
    }
    /// Whether `prefix` and `path` are in a folder another lists.
    func isExcluded(_ prefix: [UInt8], _ path: some Collection<UInt8>) -> Bool {
        excluded.contains { folder in
            if folder.count <= prefix.count { return prefix.starts(with: folder) }
            return folder.starts(with: prefix) && path.starts(with: folder[prefix.count...])
        }
    }
    mutating func warn(_ warning: String) { if !warnings.contains(warning) { warnings.append(warning) } }
}

enum FileListing {
    /// How deep repositories inside repositories are followed.
    static let nestedDepth = 4

    /// Whether git can run without asking to install the command line
    /// tools: `/usr/bin/git` is a shim that asks for them when they are not
    /// there. Without them every folder is walked.
    static let gitAvailable: Bool = {
        let files = FileManager.default
        if files.isExecutableFile(atPath: "/Library/Developer/CommandLineTools/usr/bin/git") { return true }
        // The developer folder in use (Xcode's, say), as xcode-select says.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return false }
        let developer = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return !developer.isEmpty && files.isExecutableFile(atPath: developer + "/usr/bin/git")
    }()

    /// The most of an ignore file read: a larger one is left out, and said so.
    static let ignoreFileLimit = 1_048_576

    /// Lists `folder`'s files within `limits`, git run with `environment`,
    /// passing over the folders below it in `excluding` (paths ending "/"),
    /// which are listed on their own.
    static func list(_ folder: String, limits: FileListingLimits, excluding: [[UInt8]] = [],
                     environment: [String: String] = FinderProcess.environment) async throws -> FolderListing {
        var listing = FolderListing()
        listing.excluded = excluding
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue else {
            listing.warn("“\(shown(folder))” is not there, so no file in it is listed.")
            return listing
        }
        guard access(folder, R_OK | X_OK) == 0 else {
            listing.warn("“\(shown(folder))” could not be read, so no file in it is listed.")
            return listing
        }
        if gitAvailable, let top = try await repositoryTop(of: folder, environment: environment) {
            try await listRepository(folder, prefix: [], depth: 0, top: top, limits: limits, environment: environment, into: &listing)
        } else {
            var warnings: [String] = []
            let global = try await globalIgnoreFile(in: folder, environment: environment) { warnings.append($0) }
            for warning in warnings { listing.warn(warning) }
            try walk(folder, global: global, limits: limits, into: &listing)
        }
        return listing
    }

    /// A path as the reader knows it, their home folder as "~".
    static func shown(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    // MARK: A repository's files, as git lists them

    /// The top of the repository `folder` is in, or nil when it is in none.
    static func repositoryTop(of folder: String, environment: [String: String]) async throws -> String? {
        let output = try await FinderProcess.git(["rev-parse", "--show-toplevel"], in: folder, limit: 65_536, timeout: 20, environment: environment)
        guard output.status == 0 else { return nil }
        let top = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        return top.isEmpty ? nil : top
    }

    private static func listRepository(_ folder: String, prefix: [UInt8], depth: Int, top: String, limits: FileListingLimits,
                                       environment: [String: String], into listing: inout FolderListing) async throws {
        // Paths below `folder`, as git prints them: tracked ones (ignored or
        // not) and untracked ones it does not ignore; an untracked
        // repository inside as its folder and "/".
        let output = try await FinderProcess.git(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], in: folder,
                                                 limit: min(max(limits.pathBytes, 1_048_576) * 2, 256 * 1_048_576), environment: environment)
        guard output.status == 0 else { throw FinderProcess.Failure(description: "git could not list the files") }
        var inner: [[UInt8]] = []
        try output.stdout.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var start = 0, previous: Range<Int>?
            for index in 0..<bytes.count where bytes[index] == 0 {
                defer { start = index + 1 }
                guard index > start else { continue }
                if listing.count & 4_095 == 0 { try Task.checkCancellation() }
                let range = start..<index
                // An unmerged file is listed once for each of its stages.
                if let previous, bytes[previous].elementsEqual(bytes[range]) { continue }
                previous = range
                let relative = bytes[range]
                // Another of the project's folders lists what is in its own.
                if !listing.excluded.isEmpty, listing.isExcluded(prefix, relative) { continue }
                if relative.last == 0x2F {
                    // An untracked repository inside: listed by its own git.
                    inner.append(Array(relative.dropLast())); continue
                }
                switch kind(of: folder, relative) {
                case .file:
                    guard listing.add(prefix, relative, limits: limits) else { return }
                case .folder:
                    // A submodule, listed by its own git if it is there.
                    inner.append(Array(relative))
                case .link, .other:
                    // Not there (deleted, or outside a sparse checkout), or
                    // not a file that can be opened.
                    continue
                }
            }
        }
        guard !listing.truncated else { return }
        for relative in inner {
            try Task.checkCancellation()
            if listing.isExcluded(prefix, relative + [0x2F]) { continue }
            let path = folder + "/" + String(decoding: relative, as: UTF8.self)
            guard FileManager.default.fileExists(atPath: path + "/.git") else { continue }
            guard depth < nestedDepth else {
                listing.warn("Repositories nested more than \(nestedDepth) levels deep are not listed.")
                continue
            }
            guard let innerTop = try await repositoryTop(of: path, environment: environment), innerTop != top else { continue }
            try await listRepository(path, prefix: prefix + relative + [0x2F], depth: depth + 1, top: innerTop,
                                     limits: limits, environment: environment, into: &listing)
            if listing.truncated { return }
        }
    }

    // MARK: A folder outside any repository, walked

    /// The user's global ignore file, as git finds it: `core.excludesFile`,
    /// else `$XDG_CONFIG_HOME/git/ignore`, else `~/.config/git/ignore`.
    static func globalIgnoreFile(in folder: String, environment: [String: String], warn: (String) -> Void = { _ in }) async throws -> IgnoreFile? {
        var path: String?
        if gitAvailable, let output = try? await FinderProcess.git(["config", "--path", "--get", "core.excludesFile"], in: folder,
                                                                   limit: 65_536, timeout: 20, environment: environment), output.status == 0 {
            let value = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
            if !value.isEmpty { path = value }
        }
        if path == nil {
            let home = environment["HOME"] ?? NSHomeDirectory()
            let config = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.config"
            path = config + "/git/ignore"
        }
        guard let path else { return nil }
        switch contents(of: path, limit: ignoreFileLimit) {
        case .data(let data): return IgnoreFile(base: [], contents: data)
        case .tooLarge: warn("The global ignore file “\(shown(path))” is over 1 MB, so it is not applied.")
        case .missing: break
        }
        return nil
    }

    enum Contents: Equatable { case data(Data), tooLarge, missing }

    /// The regular file at `path`, when it is at most `limit` bytes; a link
    /// to one when `following`.
    static func contents(of path: String, limit: Int, following: Bool = true) -> Contents {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | (following ? 0 : O_NOFOLLOW))
        guard descriptor >= 0 else { return .missing }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return .missing }
        guard status.st_size <= limit else { return .tooLarge }
        var data = Data(), chunk = [UInt8](repeating: 0, count: max(4_096, min(65_536, Int(status.st_size) + 1)))
        while true {
            let count = read(descriptor, &chunk, chunk.count)
            if count < 0 { if errno == EINTR { continue }; return .missing }
            if count == 0 { return .data(data) }
            data.append(contentsOf: chunk.prefix(count))
            // It grew since.
            if data.count > limit { return .tooLarge }
        }
    }

    static func walk(_ root: String, global: IgnoreFile?, limits: FileListingLimits, into listing: inout FolderListing) throws {
        var rules = IgnoreRules(global: global)
        // Folders to read, each with how many ignore files were in force
        // above it: depth first, on a stack of its own.
        struct Pending { let relative: [UInt8]; let rulesDepth: Int }
        var pending = [Pending(relative: [], rulesDepth: 0)]
        while let folder = pending.popLast() {
            try Task.checkCancellation()
            rules.stack.removeLast(rules.stack.count - folder.rulesDepth)
            let absolute = folder.relative.isEmpty ? root : root + "/" + String(decoding: folder.relative, as: UTF8.self)
            let base = folder.relative.isEmpty ? [] : folder.relative + [0x2F]
            // Only a file of its own: git does not follow a link there.
            switch contents(of: absolute + "/.gitignore", limit: ignoreFileLimit, following: false) {
            case .data(let data): rules.stack.append(IgnoreFile(base: base, contents: data))
            case .tooLarge: listing.warn("“\(String(decoding: base, as: UTF8.self)).gitignore” is over 1 MB, so it is not applied.")
            case .missing: break
            }
            guard let directory = opendir(absolute) else {
                if folder.relative.isEmpty { listing.warn("“\(shown(root))” could not be read, so no file in it is listed.") }
                continue
            }
            // A folder of more entries than a whole listing holds is not read
            // whole: the listing stops with it.
            let (entries, complete) = try entries(of: directory, in: absolute, limits: limits)
            var folders: [[UInt8]] = []
            for (name, entryKind) in entries {
                let relative = base + name
                switch entryKind {
                case .folder:
                    // A folder another of the project's folders lists is its.
                    if listing.isExcluded([], relative + [0x2F]) { continue }
                    if !rules.isIgnored(relative, nameStart: base.count, isDirectory: true) { folders.append(relative) }
                case .file:
                    if !rules.isIgnored(relative, nameStart: base.count, isDirectory: false) {
                        guard listing.add([], relative, limits: limits) else { return }
                    }
                case .link:
                    // A link is not a folder to git; one to a file is listed.
                    if !rules.isIgnored(relative, nameStart: base.count, isDirectory: false), kind(of: absolute, name) == .file {
                        guard listing.add([], relative, limits: limits) else { return }
                    }
                case .other:
                    continue
                }
            }
            guard complete, pending.count + folders.count <= limits.files else { listing.truncated = true; return }
            // Read in order: the last pushed is read first.
            for relative in folders.reversed() { pending.append(Pending(relative: relative, rulesDepth: rules.stack.count)) }
        }
    }

    /// The entries of the open `directory` at `path`, but ".", ".." and
    /// ".git", in byte order; not all of them (not `complete`) when there
    /// are more than a whole listing holds. Closes it.
    static func entries(of directory: UnsafeMutablePointer<DIR>, in path: String,
                        limits: FileListingLimits) throws -> (entries: [(name: [UInt8], kind: EntryKind)], complete: Bool) {
        defer { closedir(directory) }
        var entries: [(name: [UInt8], kind: EntryKind)] = [], names = 0, complete = true
        while let entry = readdir(directory) {
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: entry.pointee.d_name) { Array($0.bindMemory(to: UInt8.self).prefix(length)) }
            if name == [0x2E] || name == [0x2E, 0x2E] || name == [0x2E, 0x67, 0x69, 0x74] { continue }  // ".", "..", ".git"
            let entryKind: EntryKind
            switch Int32(entry.pointee.d_type) {
            case Int32(DT_DIR): entryKind = .folder
            case Int32(DT_REG): entryKind = .file
            default: entryKind = kind(of: path, name, following: false)
            }
            entries.append((name, entryKind))
            names += name.count
            if entries.count & 4_095 == 0 { try Task.checkCancellation() }
            if entries.count > limits.files || names > limits.pathBytes { complete = false; break }
        }
        entries.sort { $0.name.lexicographicallyPrecedes($1.name) }
        return (entries, complete)
    }

    // MARK: Shared

    enum EntryKind { case file, folder, link, other }

    /// What is at `name` in `folder`: what a link names, unless asked not to
    /// follow it, when it is a link.
    static func kind(of folder: String, _ name: some Collection<UInt8>, following: Bool = true) -> EntryKind {
        let path = folder + "/" + String(decoding: name, as: UTF8.self)
        var status = stat()
        guard lstat(path, &status) == 0 else { return .other }
        switch status.st_mode & S_IFMT {
        case S_IFREG: return .file
        case S_IFDIR: return .folder
        case S_IFLNK:
            guard following else { return .link }
            guard stat(path, &status) == 0 else { return .other }
            return status.st_mode & S_IFMT == S_IFREG ? .file : .other
        default: return .other
        }
    }
}
