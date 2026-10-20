import Foundation
import Darwin

/// Git reports the scope of includes as the scope of their including file.
/// Never infer trust from a pathname: a local include can name a global file.
public struct GitConfiguration {
    struct Entry {
        let scope: String
        let origin: String
        let name: String
        let value: String
        var userOwned: Bool { scope == "global" || scope == "system" }
    }
    let entries: [Entry]
    let stamps: [GitFileStamp]
    let identity: Data
    let cacheable: Bool
    let permitsUnconfinedRead: Bool
    private let gitDirectory: String
    private let children: [GitConfiguration]
    private let policy: GitInventoryMemo<GitReadOverrides?>
    private let redirects: GitInventoryMemo<(options: [String], protected: Bool)>

    public static func invalidate() { GitInventoryCache.shared.clear() }
    @discardableResult public static func invalidate(paths: [String]) -> Bool { GitInventoryCache.shared.invalidate(paths: paths) }

    public init(in directory: URL, environment: [String: String], invocation: GitInvocation = GitInvocation()) throws {
        // Keep the queried spelling so discovery also stamps its symlinks.
        self = try Self.inventory(in: directory, environment: environment, invocation: invocation, ancestors: [])
    }
    private static func inventory(in directory: URL, environment: [String: String], invocation: GitInvocation, ancestors: [URL], stored: Bool = false) throws -> GitConfiguration {
        guard ancestors.count <= 16, !ancestors.contains(directory) else {
            throw Failure("Git submodule configuration is nested too deeply to check safely.")
        }
        return try GitInventoryCache.shared.configuration(in: directory, environment: environment, invocation: invocation) {
            try GitConfiguration(loading: directory, environment: environment, invocation: invocation, ancestors: ancestors, stored: stored)
        }
    }
    private init(loading directory: URL, environment: [String: String], invocation: GitInvocation, ancestors: [URL], stored: Bool) throws {
        let discovery = GitFileStamp.discovery(in: directory)
        policy = GitInventoryMemo(); redirects = GitInventoryMemo()
        let options = ["config", "--null", "--list", "--includes", "--show-scope", "--show-origin"]
        let output = try Self.query(options, in: directory, environment: environment, invocation: invocation)
        let names = try Self.query(options + ["--name-only"], in: directory, environment: environment, invocation: invocation)
        guard output.status == 0, names.status == 0 else { throw ConfinementRequired() }
        guard String(data: output.data, encoding: .utf8) != nil, String(data: names.data, encoding: .utf8) != nil else {
            throw ConfinementRequired()
        }
        let fields = output.data.split(separator: 0, omittingEmptySubsequences: false).dropLast()
        let keys = names.data.split(separator: 0, omittingEmptySubsequences: false).dropLast()
        guard fields.count.isMultiple(of: 3), fields.count == keys.count,
              output.data.isEmpty || output.data.last == 0, names.data.isEmpty || names.data.last == 0 else {
            throw ConfinementRequired()
        }
        var entries: [Entry] = []
        for index in stride(from: 0, to: fields.count, by: 3) {
            let name = String(decoding: keys[index + 2], as: UTF8.self)
            let prefix = keys[index + 2] + Data([10]), record = fields[index + 2]
            guard fields[index] == keys[index], fields[index + 1] == keys[index + 1],
                  record == keys[index + 2] || record.starts(with: prefix) else {
                throw Failure("Git configuration changed while its origins were being checked. Try again.")
            }
            entries.append(Entry(scope: String(decoding: fields[index], as: UTF8.self),
                origin: String(decoding: fields[index + 1], as: UTF8.self), name: name,
                value: record == keys[index + 2] ? "true" : String(decoding: record.dropFirst(prefix.count), as: UTF8.self)))
        }
        self.entries = entries
        func path(_ arguments: [String]) throws -> String {
            let result = try Self.query(arguments, in: directory, environment: environment, invocation: invocation)
            guard result.status == 0 else { return "" }
            let bytes = result.data.last == 10 ? result.data.dropLast() : result.data
            guard let text = String(data: bytes, encoding: .utf8) else { throw ConfinementRequired() }
            return text
        }
        gitDirectory = try path(["rev-parse", "--absolute-git-dir"])
        let top = try path(["rev-parse", "--show-toplevel"])
        let common = gitDirectory.isEmpty ? "" : try path(["rev-parse", "--path-format=absolute", "--git-common-dir"])
        if stored, gitDirectory.isEmpty || common.isEmpty { throw ConfinementRequired() }
        // Git setup changes cwd to the worktree (or bare gitdir) before it
        // reads config. --show-origin may still report relative filenames.
        let originBase = !top.isEmpty ? top : (!gitDirectory.isEmpty ? gitDirectory : directory.path)
        func absolute(_ file: String) -> String { file.gitHasPrefix("/") ? file : originBase + "/" + file }
        func resolved(_ file: String) -> String { file.isEmpty ? "" : URL(fileURLWithPath: absolute(file)).resolvingSymlinksInPath().path }
        // --show-toplevel is the effective worktree, including core.worktree;
        // a linked worktree also has its own gitdir and shared commondir.
        identity = Data(["toplevel", resolved(top), "gitdir", resolved(gitDirectory),
                         "commondir", resolved(common), "worktree", resolved(top)].joined(separator: "\0").utf8)
        // Unresolved repository/worktree identity is safe to query afresh, but
        // cannot be a reusable inventory (including a non-repository folder).
        var canCache = !top.isEmpty && !gitDirectory.isEmpty && !common.isEmpty
        var canReadUnconfined = true
        var ancestor = directory.path
        while canCache, ancestor != resolved(top) {
            // An unrecognized candidate below the selected root can become a
            // repository through an external commondir without changing .git.
            if discovery.contains(where: { ($0.path == ancestor + "/.git" || $0.path == ancestor + "/commondir") && $0.exists }) {
                canCache = false; break
            }
            guard ancestor != "/" else { canCache = false; break }
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
        var files = entries.compactMap { $0.origin.gitHasPrefix("file:") ? absolute($0.origin.gitDropFirst(5)) : nil }
        let readFiles = Set(files.map { Data($0.utf8) })
        let home = environment["HOME"] ?? NSHomeDirectory()
        files.append(absolute(environment["GIT_CONFIG_GLOBAL"] ?? home + "/.gitconfig"))
        if environment["GIT_CONFIG_GLOBAL"] == nil {
            files.append(absolute((environment["XDG_CONFIG_HOME"] ?? home + "/.config") + "/git/config"))
        }
        if !["1", "true", "yes", "on"].contains(environment["GIT_CONFIG_NOSYSTEM"]?.gitASCIILowercased ?? "") {
            if let system = environment["GIT_CONFIG_SYSTEM"] {
                // Git lexically normalizes this particular environment path.
                // Do not expand a leading tilde as NSString would.
                files.append(URL(fileURLWithPath: absolute(system)).standardizedFileURL.path)
            } else {
                // Git installations need not use /etc/gitconfig. Ask the
                // selected Git; an empty/unrecognizable result disables reuse.
                var probeEnvironment = environment; probeEnvironment["LC_ALL"] = "C"
                let system = try Self.query(["config", "--system", "--no-includes", "--null", "--list", "--show-origin"], in: directory,
                                            environment: probeEnvironment, diagnostics: true, invocation: invocation)
                let prefix = "fatal: unable to read config file '", suffix = "': No such file or directory\n"
                if system.status == 0, let origin = system.data.split(separator: 0).first,
                   let text = String(data: origin, encoding: .utf8), text.gitHasPrefix("file:") {
                    files.append(absolute(text.gitDropFirst(5)))
                } else if let text = String(data: system.data, encoding: .utf8), text.gitHasPrefix(prefix), text.gitHasSuffix(suffix) {
                    files.append(absolute(text.gitDropFirst(prefix.utf8.count).gitDropLast(suffix.utf8.count)))
                } else { canCache = false }
            }
        }
        var configurationFiles = files
        if !gitDirectory.isEmpty {
            configurationFiles += [gitDirectory + "/config", gitDirectory + "/config.worktree"]
            if !common.isEmpty { configurationFiles.append(common + "/config") }
            files += [gitDirectory + "/config", gitDirectory + "/config.worktree", gitDirectory + "/commondir",
                      gitDirectory + "/gitdir", gitDirectory + "/index", gitDirectory + "/HEAD"]
            if !common.isEmpty { files += [common + "/config", common + "/packed-refs"] }
        }
        if !top.isEmpty { files.append(top + "/.gitmodules") }
        if let index = environment["GIT_INDEX_FILE"], !index.isEmpty { files.append(absolute(index)) }
        let includes = entries.filter { $0.name == "include.path" || ($0.name.gitHasPrefix("includeif.") && $0.name.gitHasSuffix(".path")) }
        var includeFiles: [String] = []
        if !includes.isEmpty {
            // --type=path uses Git's own ~, ~user and %(prefix) expansion,
            // including includeIf directives whose condition is not active.
            let expanded = try Self.query(["config", "--null", "--includes", "--show-scope", "--show-origin", "--type=path",
                                           "--get-regexp", "^(include\\.path|includeif\\..*\\.path)$"],
                                          in: directory, environment: environment, invocation: invocation)
            let fields = expanded.data.split(separator: 0, omittingEmptySubsequences: false).dropLast()
            if expanded.status != 0 || expanded.data.last != 0 || fields.count != includes.count * 3 {
                canCache = false; canReadUnconfined = false
            }
            else {
                for (index, entry) in includes.enumerated() {
                    try invocation.check()
                    let record = fields[index * 3 + 2], prefix = Data((entry.name + "\n").utf8)
                    guard fields[index * 3].elementsEqual(entry.scope.utf8), fields[index * 3 + 1].elementsEqual(entry.origin.utf8),
                          record.starts(with: prefix), let target = String(data: record.dropFirst(prefix.count), encoding: .utf8) else {
                        canCache = false; canReadUnconfined = false; continue
                    }
                    if target.gitHasPrefix("/") { includeFiles.append(target) }
                    else if entry.origin.gitHasPrefix("file:") {
                        let source = absolute(entry.origin.gitDropFirst(5))
                        // Preserve symlink/.. semantics; lexical normalization
                        // can watch a different file from the one Git opens.
                        guard let parent = source.gitSplitOnce(separator: 47, last: true) else { throw ConfinementRequired() }
                        includeFiles.append(parent.before + "/" + target)
                    } else { canCache = false; canReadUnconfined = false }
                }
            }
        }
        // Inspect inactive conditional branches too. Their include targets
        // must be regular files even when Git did not read them this time.
        var includeStamps: [GitFileStamp] = [], seen = Set<Data>(), cursor = 0
        while cursor < includeFiles.count, canReadUnconfined {
            try invocation.check()
            let file = includeFiles[cursor]; cursor += 1
            guard seen.insert(Data(file.utf8)).inserted else { continue }
            let stamp = GitFileStamp(file); includeStamps.append(stamp)
            guard seen.count <= 256, Self.staticConfiguration(file) else { canReadUnconfined = false; break }
            if !stamp.exists { continue }
            // Git already expanded every directive in reported origins.
            // Only unseen conditional branches need a separate parse; never
            // let Process rewrite an include filename for that query.
            if readFiles.contains(Data(file.utf8)) { continue }
            do { try Self.requireUnchangedBytes([file]) }
            catch { canReadUnconfined = false; break }
            let arguments = ["config", "--file", file, "--no-includes", "--null"]
            let pattern = "^(include\\.path|includeif\\..*\\.path)$"
            let names = try Self.query(arguments + ["--name-only", "--get-regexp", pattern],
                                       in: directory, environment: environment, invocation: invocation)
            if names.status == 1 { continue }
            let expanded = try Self.query(arguments + ["--type=path", "--get-regexp", pattern],
                                          in: directory, environment: environment, invocation: invocation)
            let keys = names.data.split(separator: 0, omittingEmptySubsequences: false).dropLast()
            let values = expanded.data.split(separator: 0, omittingEmptySubsequences: false).dropLast()
            guard names.status == 0, expanded.status == 0, names.data.last == 0, expanded.data.last == 0,
                  keys.count == values.count else { canReadUnconfined = false; break }
            for (key, value) in zip(keys, values) {
                let prefix = key + Data([10])
                guard value.starts(with: prefix), let target = String(data: value.dropFirst(prefix.count), encoding: .utf8) else {
                    canReadUnconfined = false; break
                }
                guard let parent = file.gitSplitOnce(separator: 47, last: true) else { throw ConfinementRequired() }
                includeFiles.append(target.gitHasPrefix("/") ? target : parent.before + "/" + target)
            }
        }
        files += includeFiles
        var branchStamps: [GitFileStamp] = []
        if includes.contains(where: { $0.name.gitHasPrefix("includeif.onbranch:") }) {
            // onbranch follows the entire symbolic HEAD chain. Stamp each
            // link before reading it, not just the unchanged HEAD file.
            var reference = "HEAD", seen = Set<Data>()
            while seen.insert(Data(reference.utf8)).inserted, seen.count <= 16 {
                let file = try path(["rev-parse", "--path-format=absolute", "--git-path", reference])
                guard !file.isEmpty else { canCache = false; break }
                branchStamps.append(GitFileStamp(file))
                let next = try Self.query(["symbolic-ref", "--quiet", "--no-recurse", reference],
                                          in: directory, environment: environment, invocation: invocation)
                if next.status == 1 { reference = ""; break }
                guard next.status == 0, next.data.last == 10, let text = String(data: next.data.dropLast(), encoding: .utf8),
                      text.gitHasPrefix("refs/") else { canCache = false; break }
                reference = text
            }
            if !reference.isEmpty { canCache = false }
        }
        var children: [GitConfiguration] = []
        var moduleStamps: [GitFileStamp] = []
        var indexStamp: GitFileStamp?
        if !top.isEmpty, !stored {
            let root = URL(fileURLWithPath: top, isDirectory: true)
            indexStamp = GitFileStamp(absolute(environment["GIT_INDEX_FILE"] ?? gitDirectory + "/index"))
            let index = try Self.query(["ls-files", "--stage", "--sparse", "--full-name", "-z"], in: root, environment: environment,
                                       limit: 64 * 1_048_576, invocation: invocation)
            guard index.status == 0 else { throw Failure("Git submodules could not be checked safely.") }
            for record in index.data.split(separator: 0) where record.starts(with: Array("160000 ".utf8)) {
                try invocation.check()
                guard let tab = record.firstIndex(of: 9), let path = String(data: record[record.index(after: tab)...], encoding: .utf8) else {
                    throw ConfinementRequired()
                }
                let child = root.appendingPathComponent(path)
                files.append(child.appendingPathComponent(".git").path)
                guard FileManager.default.fileExists(atPath: child.appendingPathComponent(".git").path) else { continue }
                children.append(try Self.inventory(in: child, environment: environment, invocation: invocation, ancestors: ancestors + [directory]))
            }
        }
        // Deinitializing a checkout leaves its repository here. Fetch and
        // inherited -c options can still reach it, including nested modules.
        func storedModules(in folder: URL, depth: Int = 0) throws {
            try invocation.check()
            guard depth <= 16 else { throw ConfinementRequired() }
            let stamp = GitFileStamp(folder.path)
            guard stamp.cacheable else { throw ConfinementRequired() }
            moduleStamps.append(stamp)
            guard stamp.exists else { return }
            let contents: [URL]
            do { contents = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) }
            catch { throw ConfinementRequired() }
            for child in contents {
                try invocation.check()
                let markers = ["HEAD", "config", "commondir"].map { child.appendingPathComponent($0).path }
                if markers.contains(where: { GitFileStamp($0).exists }) {
                    // Foundation encodes environment values like argv too.
                    do { try Self.requireUnchangedBytes([child.path]) }
                    catch { throw ConfinementRequired() }
                    // A symlink spelling can activate other gitdir includes.
                    if children.contains(where: { $0.gitDirectory.utf8.elementsEqual(child.path.utf8) }) { continue }
                    // Relative root config paths depend on a missing
                    // checkout's cwd, which this metadata query cannot prove.
                    guard ["HOME", "XDG_CONFIG_HOME", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM"].allSatisfy({
                        environment[$0].map { $0.gitHasPrefix("/") } ?? true
                    }) else { throw ConfinementRequired() }
                    var childEnvironment = environment
                    // Stored modules need no checkout. Give Git a valid cwd
                    // without changing gitdir/onbranch/include resolution.
                    childEnvironment["GIT_DIR"] = child.path
                    childEnvironment["GIT_WORK_TREE"] = child.path
                    childEnvironment.removeValue(forKey: "GIT_INDEX_FILE")
                    children.append(try Self.inventory(in: child, environment: childEnvironment, invocation: invocation,
                                                       ancestors: ancestors + [directory], stored: true))
                } else { try storedModules(in: child, depth: depth + 1) }
            }
        }
        if !common.isEmpty { try storedModules(in: URL(fileURLWithPath: common).appendingPathComponent("modules")) }
        self.children = children
        var stamps = Set(files.map { Data($0.utf8) }).sorted(by: { $0.lexicographicallyPrecedes($1) }).map { bytes in
            let path = String(decoding: bytes, as: UTF8.self)
            if let indexStamp, indexStamp.path.utf8.elementsEqual(bytes) { return indexStamp }
            return GitFileStamp(path)
        }
        stamps += discovery + branchStamps + includeStamps + moduleStamps
        stamps += [top, gitDirectory, common].filter { !$0.isEmpty }.map { GitFileStamp($0, directoryIdentity: true) }
        if !top.isEmpty { stamps.append(GitFileStamp(top + "/.git", directoryIdentity: true)) }
        // Hunk reads create private indexes in .git. Those do not change its
        // identity; objects/refs and HEAD determine whether Git still finds it.
        stamps += Set([gitDirectory, common]).filter { !$0.isEmpty }.flatMap { directory in
            ["objects", "refs"].map { GitFileStamp(directory + "/" + $0, directoryIdentity: true) }
        }
        // Include repository/discovery paths as well as config origins.
        // Retargeting any link in either chain changes Git's conditions.
        for stamp in stamps {
            try invocation.check()
            let chain = stamp.resolution
            canCache = canCache && chain.complete
            stamps += chain.stamps
        }
        stamps += children.flatMap(\.stamps)
        self.stamps = Array(Set(stamps))
        permitsUnconfinedRead = canReadUnconfined && configurationFiles.allSatisfy { Self.staticConfiguration($0, allowNull: true) }
        cacheable = permitsUnconfinedRead && canCache && self.stamps.allSatisfy(\.cacheable) && children.allSatisfy(\.cacheable)
        // Recheck the data after capturing origins, including missing include
        // files. Filesystem timestamps need not share Date's clock precision.
        let confirmed = try Self.query(options, in: directory, environment: environment, invocation: invocation)
        guard confirmed.status == 0, confirmed.data == output.data, self.stamps.allSatisfy({ !$0.cacheable || $0.unchanged }) else {
            throw Failure("Git configuration changed while its inventory was being read. Try again.")
        }
    }

    private static func staticConfiguration(_ path: String, allowNull: Bool = false) -> Bool {
        let stamp = GitFileStamp(path), chain = stamp.resolution
        guard chain.complete else { return false }
        let paths = [stamp] + chain.stamps
        // Check ancestors as well: /tmp/fd-link/0 may resolve through /dev/fd,
        // whose descriptor can refer to a different file in the next process.
        for stamp in paths where stamp.watchedPath == "/dev" || stamp.watchedPath.gitHasPrefix("/dev/")
            || stamp.watchedPath == "/proc" || stamp.watchedPath.gitHasPrefix("/proc/") {
            // The explicitly selected empty root config is stable. This
            // exception never applies to an include directive, even /dev/null.
            if allowNull, paths[0].watchedPath == "/dev/null" { continue }
            return false
        }
        var value = stat()
        if stat(path, &value) == 0 { return value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) || (allowNull && paths[0].watchedPath == "/dev/null") }
        guard errno == ENOENT || errno == ENOTDIR else { return false }
        // A dangling link cannot prove the kind of its eventual target.
        return lstat(path, &value) != 0 && (errno == ENOENT || errno == ENOTDIR)
    }

    func readOptions(in directory: URL, environment: [String: String], submodules: Bool, invocation: GitInvocation) throws -> [String] {
        let repositories = submodules ? repositories : [self]
        let overrides = try repositories.flatMap { configuration -> [String] in
            let overrides = try configuration.policy.get(invocation: invocation) {
                let local = configuration.entries.filter { $0.scope == "local" || $0.scope == "worktree" }
                let options = try configuration.readOptions(local: local)
                return options.isEmpty ? nil : try GitReadOverrides(gitDirectory: configuration.gitDirectory, options: options)
            }
            guard let overrides else { return [] }
            do { try Self.requireUnchangedBytes([overrides.argument]) }
            catch { throw ConfinementRequired() }
            return ["-c", overrides.argument]
        }
        return overrides + ["-c", "core.hooksPath=/dev/null", "-c", "log.showSignature=false",
                            "-c", "core.pager=", "-c", "core.editor=/usr/bin/false", "-c", "sequence.editor=/usr/bin/false"]
    }

    private var repositories: [GitConfiguration] { [self] + children.flatMap(\.repositories) }

    private func readOptions(local: [Entry]) throws -> [String] {
        // Git subsection names are byte-sensitive; Swift String equality folds
        // canonically equivalent Unicode spellings and would lose an override.
        let names = Set(local.filter { Self.isProgram($0.name) }.map { Data($0.name.utf8) })
        var options: [String] = []
        for key in names.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            let name = String(decoding: key, as: UTF8.self)
            // Only an override must fit -c's encoding. User-owned settings
            // that Git reads directly retain their original names and bytes.
            guard !name.utf8.contains(61), !name.utf8.contains(10) else {
                throw ConfinementRequired()
            }
            let user = entries.filter { $0.userOwned && $0.name.utf8.elementsEqual(key) }
            if name == "credential.helper" || (name.gitHasPrefix("credential.") && name.gitHasSuffix(".helper")) {
                options += ["-c", name + "="]
                for entry in user { options += ["-c", name + "=" + entry.value] }
            } else {
                let fallback = name == "core.fsmonitor" || name.gitHasSuffix(".required") ? "false" : ""
                options += ["-c", name + "=" + (user.last?.value ?? fallback)]
            }
        }
        do { try Self.requireUnchangedBytes(options) }
        catch { throw ConfinementRequired() }
        // A read never needs hooks, a pager/editor, signature checks or a Git
        // transport. Global content filters and fsmonitor remain available.
        return options
    }

    private static func isProgram(_ name: String) -> Bool {
        if ["core.fsmonitor", "core.hookspath", "core.sshcommand", "core.gitproxy", "core.pager", "core.editor", "sequence.editor", "diff.external", "gpg.program", "log.showsignature"].contains(name.gitASCIILowercased) { return true }
        return name.gitHasPrefix("filter.") || name.gitHasPrefix("alias.") || name.gitHasPrefix("pager.")
            || (name.gitHasPrefix("diff.") && (name.gitHasSuffix(".command") || name.gitHasSuffix(".textconv")))
            || (name.gitHasPrefix("difftool.") && name.gitHasSuffix(".cmd"))
            || (name.gitHasPrefix("gpg.") && name.gitHasSuffix(".program"))
            || (name.gitHasPrefix("credential.") && name.gitHasSuffix(".helper"))
            || (name.gitHasPrefix("remote.") && [".vcs", ".uploadpack", ".receivepack", ".proxy"].contains(where: name.gitHasSuffix))
    }

    /// Any configured extraHeader makes every network destination protected.
    /// Generic -c alone loses to a URL-scoped followRedirects setting.
    public func redirectOptions(invocation: GitInvocation = GitInvocation()) throws -> (options: [String], protected: Bool) {
        try redirects.get(invocation: invocation) {
            guard repositories.allSatisfy(\.permitsUnconfinedRead) else { throw ConfinementRequired() }
            let entries = repositories.flatMap(\.entries)
            // Names come from Git's NUL-delimited inventory. Header values,
            // URL matching and remote resolution cannot weaken this policy.
            let protected = entries.contains { entry in
                let name = entry.name.gitASCIILowercased
                return name == "http.extraheader" || (name.gitHasPrefix("http.") && name.gitHasSuffix(".extraheader"))
            }
            let configured = Set(entries.compactMap { entry -> Data? in
                let name = entry.name.gitASCIILowercased
                return name.gitHasPrefix("http.") && name.gitHasSuffix(".followredirects") ? Data(entry.name.utf8) : nil
            })
            // Without headers, preserve each repository's own stricter
            // settings instead of propagating a weaker -c into children.
            if !protected, !configured.isEmpty { return ([], false) }
            let names = configured.union([Data("http.followredirects".utf8)])
            guard !names.contains(where: { $0.contains(61) || $0.contains(10) }) else {
                throw Failure("Git HTTP configuration contains a URL that cannot be overridden safely.")
            }
            let options = names.sorted(by: { $0.lexicographicallyPrecedes($1) }).flatMap {
                ["-c", String(decoding: $0, as: UTF8.self) + "=" + (protected ? "false" : "initial")]
            }
            try Self.requireUnchangedBytes(options)
            return (options, protected)
        }
    }

    /// Foundation's macOS Process converts arguments/environment through the
    /// filesystem representation, which decomposes Unicode. Refuse a safety
    /// key or lookup it would silently change, even though Git distinguishes it.
    private static func requireUnchangedBytes(_ arguments: [String]) throws {
        for argument in arguments {
            let passed = String(cString: (argument as NSString).fileSystemRepresentation)
            guard argument.utf8.elementsEqual(passed.utf8) else {
                throw Failure("Git configuration contains text that cannot be passed to Git without changing its bytes.")
            }
        }
    }

    struct Output { let data: Data; let status: Int32 }
    #if DEBUG
    private static let countLock = NSLock()
    nonisolated(unsafe) private static var queries = 0
    static var queryCount: Int { countLock.withLock { queries } }
    #endif
    /// Only fixed metadata commands enter here. Confine even the inventory:
    /// a malformed/sparse index must not fetch while we inspect configuration.
    static func query(_ arguments: [String], in directory: URL, environment: [String: String], limit: Int = 4 * 1_048_576, diagnostics: Bool = false, invocation: GitInvocation = GitInvocation()) throws -> Output {
        #if DEBUG
        countLock.withLock { queries += 1 }
        #endif
        try invocation.check()
        try requireUnchangedBytes(arguments)
        let process = Process(), pipe = Pipe()
        process.currentDirectoryURL = directory
        let confinement = try GitReadProcess(process, arguments: arguments, environment: environment, regularFilesOnly: true, invocation: invocation)
        defer { confinement.remove() }
        process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = diagnostics ? pipe : FileHandle.nullDevice
        let reader = pipe.fileHandleForReading
        defer { try? reader.close() }
        guard invocation.adopt(process) else { throw CancellationError() }
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) }; process.waitUntilExit() }
        let fd = reader.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        var ended = false
        while !ended || process.isRunning {
            try invocation.check()
            let count = read(fd, &buffer, buffer.count)
            if count > 0 { bytes.append(contentsOf: buffer.prefix(count)) }
            else if count == 0 { ended = true }
            else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { break }
            if bytes.count > limit {
                kill(process.processIdentifier, SIGKILL); process.waitUntilExit()
                throw Failure("Git's configuration safety check exceeded its read limit.")
            }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            _ = poll(&descriptor, 1, 20)
        }
        process.waitUntilExit()
        return Output(data: bytes, status: process.terminationStatus)
    }
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
    struct ConfinementRequired: LocalizedError {
        var errorDescription: String? { "Git configuration depends on a source that cannot be checked safely." }
    }
}
