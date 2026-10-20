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
    private let directory: URL
    private let gitDirectory: String
    private let children: [GitConfiguration]
    private let policy: GitInventoryMemo<GitReadOverrides?>
    private let fetchRedirects: GitInventoryMemo<(options: [String], protected: Bool)>
    private let pushRedirects: GitInventoryMemo<(options: [String], protected: Bool)>

    public static func invalidate() { GitInventoryCache.shared.clear() }
    @discardableResult public static func invalidate(paths: [String]) -> Bool { GitInventoryCache.shared.invalidate(paths: paths) }

    public init(in directory: URL, environment: [String: String], invocation: GitInvocation = GitInvocation()) throws {
        self = try Self.inventory(in: directory.resolvingSymlinksInPath(), environment: environment, invocation: invocation, ancestors: [])
    }
    private static func inventory(in directory: URL, environment: [String: String], invocation: GitInvocation, ancestors: [URL]) throws -> GitConfiguration {
        guard ancestors.count <= 16, !ancestors.contains(directory) else {
            throw Failure("Git submodule configuration is nested too deeply to check safely.")
        }
        return try GitInventoryCache.shared.configuration(in: directory, environment: environment, invocation: invocation) {
            try GitConfiguration(loading: directory, environment: environment, invocation: invocation, ancestors: ancestors)
        }
    }
    private init(loading directory: URL, environment: [String: String], invocation: GitInvocation, ancestors: [URL]) throws {
        let discovery = GitFileStamp.discovery(in: directory)
        policy = GitInventoryMemo(); fetchRedirects = GitInventoryMemo(); pushRedirects = GitInventoryMemo()
        let options = ["config", "--null", "--list", "--includes", "--show-scope", "--show-origin"]
        let output = try Self.query(options, in: directory, environment: environment, invocation: invocation)
        let names = try Self.query(options + ["--name-only"], in: directory, environment: environment, invocation: invocation)
        guard output.status == 0, names.status == 0 else { throw ConfinementRequired() }
        guard String(data: output.data, encoding: .utf8) != nil, String(data: names.data, encoding: .utf8) != nil else {
            throw Failure("Git configuration contains invalid UTF-8; its program settings cannot be overridden safely.")
        }
        let fields = output.data.split(separator: 0, omittingEmptySubsequences: false).dropLast()
        let keys = names.data.split(separator: 0, omittingEmptySubsequences: false).dropLast()
        guard fields.count.isMultiple(of: 3), fields.count == keys.count,
              output.data.isEmpty || output.data.last == 0, names.data.isEmpty || names.data.last == 0 else {
            throw Failure("Git configuration origins could not be read.")
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
        self.directory = directory
        func path(_ arguments: [String]) throws -> String {
            let result = try Self.query(arguments, in: directory, environment: environment, invocation: invocation)
            guard result.status == 0, let text = String(data: result.data, encoding: .utf8) else { return "" }
            return text.hasSuffix("\n") ? String(text.dropLast()) : text
        }
        gitDirectory = try path(["rev-parse", "--absolute-git-dir"])
        let top = try path(["rev-parse", "--show-toplevel"])
        let common = gitDirectory.isEmpty ? "" : try path(["rev-parse", "--path-format=absolute", "--git-common-dir"])
        // Git setup changes cwd to the worktree (or bare gitdir) before it
        // reads config. --show-origin may still report relative filenames.
        let originBase = !top.isEmpty ? top : (!gitDirectory.isEmpty ? gitDirectory : directory.path)
        func absolute(_ file: String) -> String { file.hasPrefix("/") ? file : originBase + "/" + file }
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
        var files = entries.compactMap { $0.origin.hasPrefix("file:") ? absolute(String($0.origin.dropFirst(5))) : nil }
        let readFiles = Set(files.map { Data($0.utf8) })
        let home = environment["HOME"] ?? NSHomeDirectory()
        files.append(absolute(environment["GIT_CONFIG_GLOBAL"] ?? home + "/.gitconfig"))
        if environment["GIT_CONFIG_GLOBAL"] == nil {
            files.append(absolute((environment["XDG_CONFIG_HOME"] ?? home + "/.config") + "/git/config"))
        }
        if !["1", "true", "yes", "on"].contains(environment["GIT_CONFIG_NOSYSTEM"]?.lowercased() ?? "") {
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
                   let text = String(data: origin, encoding: .utf8), text.hasPrefix("file:") {
                    files.append(absolute(String(text.dropFirst(5))))
                } else if let text = String(data: system.data, encoding: .utf8), text.hasPrefix(prefix), text.hasSuffix(suffix) {
                    files.append(absolute(String(text.dropFirst(prefix.count).dropLast(suffix.count))))
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
            let defaults = entries.filter { $0.name == "remote.pushdefault" || ($0.name.hasPrefix("branch.") && ($0.name.hasSuffix(".remote") || $0.name.hasSuffix(".pushremote"))) }.map(\.value) + ["origin"]
            for base in Set([gitDirectory, common]).filter({ !$0.isEmpty }) {
                for kind in ["remotes", "branches"] {
                    files.append(base + "/" + kind)
                    files += defaults.map { base + "/" + kind + "/" + $0 }
                }
            }
        }
        if !top.isEmpty { files.append(top + "/.gitmodules") }
        if let index = environment["GIT_INDEX_FILE"], !index.isEmpty { files.append(absolute(index)) }
        let includes = entries.filter { $0.name == "include.path" || ($0.name.hasPrefix("includeif.") && $0.name.hasSuffix(".path")) }
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
                    if target.hasPrefix("/") { includeFiles.append(target) }
                    else if entry.origin.hasPrefix("file:") {
                        let source = absolute(String(entry.origin.dropFirst(5)))
                        // Preserve symlink/.. semantics; lexical normalization
                        // can watch a different file from the one Git opens.
                        includeFiles.append(String(source[...source.lastIndex(of: "/")!]) + target)
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
                includeFiles.append(target.hasPrefix("/") ? target : String(file[...file.lastIndex(of: "/")!]) + target)
            }
        }
        files += includeFiles
        var branchStamps: [GitFileStamp] = []
        if includes.contains(where: { $0.name.hasPrefix("includeif.onbranch:") }) {
            // onbranch follows the entire symbolic HEAD chain. Stamp each
            // link before reading it, not just the unchanged HEAD file.
            var reference = "HEAD", seen = Set<String>()
            while seen.insert(reference).inserted, seen.count <= 16 {
                let file = try path(["rev-parse", "--path-format=absolute", "--git-path", reference])
                guard !file.isEmpty else { canCache = false; break }
                branchStamps.append(GitFileStamp(file))
                let next = try Self.query(["symbolic-ref", "--quiet", "--no-recurse", reference],
                                          in: directory, environment: environment, invocation: invocation)
                if next.status == 1 { reference = ""; break }
                guard next.status == 0, let text = String(data: next.data, encoding: .utf8), text.hasSuffix("\n"),
                      text.hasPrefix("refs/") else { canCache = false; break }
                reference = String(text.dropLast())
            }
            if !reference.isEmpty { canCache = false }
        }
        var children: [GitConfiguration] = []
        var indexStamp: GitFileStamp?
        if !top.isEmpty {
            let root = URL(fileURLWithPath: top, isDirectory: true)
            indexStamp = GitFileStamp(absolute(environment["GIT_INDEX_FILE"] ?? gitDirectory + "/index"))
            let index = try Self.query(["ls-files", "--stage", "--sparse", "--full-name", "-z"], in: root, environment: environment,
                                       limit: 64 * 1_048_576, invocation: invocation)
            guard index.status == 0 else { throw Failure("Git submodules could not be checked safely.") }
            for record in index.data.split(separator: 0) where record.starts(with: Array("160000 ".utf8)) {
                try invocation.check()
                guard let tab = record.firstIndex(of: 9), let path = String(data: record[record.index(after: tab)...], encoding: .utf8) else {
                    throw Failure("Git submodule paths contain invalid UTF-8; their configuration cannot be checked safely.")
                }
                let child = root.appendingPathComponent(path).resolvingSymlinksInPath()
                files.append(child.appendingPathComponent(".git").path)
                guard FileManager.default.fileExists(atPath: child.appendingPathComponent(".git").path) else { continue }
                children.append(try Self.inventory(in: child, environment: environment, invocation: invocation, ancestors: ancestors + [directory]))
            }
        }
        self.children = children
        var stamps = Set(files).sorted().map { path in
            indexStamp?.path == path ? indexStamp! : GitFileStamp(path)
        }
        stamps += Set(files).flatMap { GitFileStamp.parents(of: $0) }
        stamps += discovery + branchStamps + includeStamps
        stamps += [top, gitDirectory, common].filter { !$0.isEmpty }.map { GitFileStamp($0, directoryIdentity: true) }
        if !top.isEmpty { stamps.append(GitFileStamp(top + "/.git", directoryIdentity: true)) }
        // Hunk reads create private indexes in .git. Those do not change its
        // identity; objects/refs and HEAD determine whether Git still finds it.
        stamps += Set([gitDirectory, common]).filter { !$0.isEmpty }.flatMap { directory in
            ["objects", "refs"].map { GitFileStamp(directory + "/" + $0, directoryIdentity: true) }
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
        let paths = [GitFileStamp(path)] + GitFileStamp.parents(of: path)
        // Check ancestors as well: /tmp/fd-link/0 may resolve through /dev/fd,
        // whose descriptor can refer to a different file in the next process.
        for stamp in paths where stamp.watchedPath == "/dev" || stamp.watchedPath.hasPrefix("/dev/")
            || stamp.watchedPath == "/proc" || stamp.watchedPath.hasPrefix("/proc/") {
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
            try Self.requireUnchangedBytes([overrides.argument])
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
            guard !name.contains("="), !name.contains("\n") else {
                throw Failure("Git configuration contains a key that cannot be overridden safely.")
            }
            let user = entries.filter { $0.userOwned && $0.name.utf8.elementsEqual(key) }
            if name == "credential.helper" || (name.hasPrefix("credential.") && name.hasSuffix(".helper")) {
                options += ["-c", name + "="]
                for entry in user { options += ["-c", name + "=" + entry.value] }
            } else {
                let fallback = name == "core.fsmonitor" || name.hasSuffix(".required") ? "false" : ""
                options += ["-c", name + "=" + (user.last?.value ?? fallback)]
            }
        }
        try Self.requireUnchangedBytes(options)
        // A read never needs hooks, a pager/editor, signature checks or a Git
        // transport. Global content filters and fsmonitor remain available.
        return options
    }

    private static func isProgram(_ name: String) -> Bool {
        if ["core.fsmonitor", "core.hookspath", "core.sshcommand", "core.gitproxy", "core.pager", "core.editor", "sequence.editor", "diff.external", "gpg.program", "log.showsignature"].contains(name.lowercased()) { return true }
        return name.hasPrefix("filter.") || name.hasPrefix("alias.") || name.hasPrefix("pager.")
            || (name.hasPrefix("diff.") && (name.hasSuffix(".command") || name.hasSuffix(".textconv")))
            || (name.hasPrefix("difftool.") && name.hasSuffix(".cmd"))
            || (name.hasPrefix("gpg.") && name.hasSuffix(".program"))
            || (name.hasPrefix("credential.") && name.hasSuffix(".helper"))
            || (name.hasPrefix("remote.") && [".vcs", ".uploadpack", ".receivepack", ".proxy"].contains(where: name.hasSuffix))
    }

    /// Ask Git to resolve remote aliases and URL-scoped headers. Generic -c
    /// alone loses to http.<url>.followRedirects, even in a lower scope.
    public func redirectOptions(for command: String, in directory: URL, environment: [String: String], invocation: GitInvocation = GitInvocation()) throws -> (options: [String], protected: Bool) {
        let memo = command == "push" ? pushRedirects : fetchRedirects
        return try memo.get(invocation: invocation) { try buildRedirects(for: command, environment: environment, invocation: invocation) }
    }
    private func buildRedirects(for command: String, environment: [String: String], invocation: GitInvocation) throws -> (options: [String], protected: Bool) {
        var settings = [Data("http.followredirects".utf8): "initial"], protected = false
        for configuration in repositories {
            let directory = configuration.directory
            func hasHeaders(_ url: String) throws -> Bool {
                let headers = try Self.query(["config", "--get-urlmatch", "http.extraHeader", url], in: directory, environment: environment, invocation: invocation)
                guard headers.status == 0 || headers.status == 1 else { throw Failure("Git HTTP header configuration could not be checked safely.") }
                return headers.status == 0 && headers.data.contains { $0 != 10 }
            }
            // Patterns (including wildcard hosts) are config scopes, never
            // destination arguments. Git matches headers against concrete URLs.
            for entry in configuration.entries where entry.name.hasPrefix("http.") && entry.name.hasSuffix(".followredirects") {
                if settings[Data(entry.name.utf8)] != "false" { settings[Data(entry.name.utf8)] = "initial" }
            }
            var remotes = Set(configuration.entries.compactMap { entry -> Data? in
                guard entry.name.hasPrefix("remote.") else { return nil }
                if entry.name.hasSuffix(".url") { return Data(entry.name.dropFirst(7).dropLast(4).utf8) }
                if entry.name.hasSuffix(".pushurl") { return Data(entry.name.dropFirst(7).dropLast(8).utf8) }
                return nil
            })
            remotes.insert(Data("origin".utf8))
            for entry in configuration.entries where entry.name == "remote.pushdefault"
                || (entry.name.hasPrefix("branch.") && (entry.name.hasSuffix(".remote") || entry.name.hasSuffix(".pushremote"))) {
                remotes.insert(Data(entry.value.utf8))
            }
            for key in remotes.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                let remote = String(decoding: key, as: UTF8.self)
                let urls: [String]
                let named = try Self.query(["remote", "get-url", "--all"] + (command == "push" ? ["--push"] : []) + ["--", remote],
                                           in: directory, environment: environment, invocation: invocation)
                guard named.status == 0 || named.status == 2 else { throw Failure("Git remote URLs could not be checked safely.") }
                if named.status == 0 {
                    guard let text = String(data: named.data, encoding: .utf8) else { throw Failure("Git remote URLs contain invalid UTF-8.") }
                    urls = text.components(separatedBy: "\n").filter { !$0.isEmpty }
                } else if command == "push", let rewritten = configuration.pushURL(remote) {
                    // Literal push defaults use pushInsteadOf on the original
                    // alias, before the fetch-only insteadOf fallback.
                    urls = [rewritten]
                } else {
                    let result = try Self.query(["ls-remote", "--get-url", "--", remote], in: directory, environment: environment, invocation: invocation)
                    guard result.status == 0 else { throw Failure("Git remote URLs could not be checked safely.") }
                    guard let text = String(data: result.data, encoding: .utf8) else { throw Failure("Git remote URLs contain invalid UTF-8.") }
                    urls = text.components(separatedBy: "\n").filter { !$0.isEmpty }
                }
                for remoteURL in urls {
                    var url = remoteURL
                    // The explicit helper form passes only its address to the
                    // helper. Git/curl also accept mixed-case HTTP schemes.
                    if let colon = url.firstIndex(of: ":"), url[url.index(after: colon)...].hasPrefix(":") {
                        url = String(url[url.index(colon, offsetBy: 2)...])
                    }
                    guard url.lowercased().hasPrefix("http://") || url.lowercased().hasPrefix("https://") else { continue }
                    let deny = try hasHeaders(url)
                    let key = Data("http.\(url).followredirects".utf8)
                    if deny || settings[key] != "false" { settings[key] = deny ? "false" : "initial" }
                    protected = protected || deny
                }
            }
        }
        guard !settings.keys.contains(where: { $0.contains(61) || $0.contains(10) }) else {
            throw Failure("Git HTTP configuration contains a URL that cannot be overridden safely.")
        }
        // Git normalizes URL scopes: two byte-distinct keys can match with
        // equal specificity. Refusals must follow every ordinary redirect rule.
        let options = settings.sorted {
            if ($0.value == "false") != ($1.value == "false") { return $0.value != "false" }
            return $0.key.lexicographicallyPrecedes($1.key)
        }.flatMap {
            ["-c", String(decoding: $0.key, as: UTF8.self) + "=" + $0.value]
        }
        try Self.requireUnchangedBytes(options)
        return (options, protected)
    }

    private func pushURL(_ literal: String) -> String? {
        let url = Data(literal.utf8)
        var match: Entry?
        let rewrites = entries.filter { $0.name.hasPrefix("url.") && $0.name.hasSuffix(".pushinsteadof") }
        var seen = Set<Data>()
        for base in rewrites where seen.insert(Data(base.name.utf8)).inserted {
            for entry in rewrites where entry.name.utf8.elementsEqual(base.name.utf8) {
                let prefix = Data(entry.value.utf8)
                if url.starts(with: prefix), match == nil || prefix.count > match!.value.utf8.count { match = entry }
            }
        }
        guard let match else { return nil }
        let base = match.name.dropFirst(4).dropLast(".pushinsteadof".count)
        return String(decoding: Data(base.utf8) + url.dropFirst(match.value.utf8.count), as: UTF8.self)
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
