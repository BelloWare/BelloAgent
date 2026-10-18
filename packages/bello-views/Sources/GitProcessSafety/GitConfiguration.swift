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

    public init(in directory: URL, environment: [String: String]) throws {
        let options = ["config", "--null", "--list", "--includes", "--show-scope", "--show-origin"]
        let output = try Self.query(options, in: directory, environment: environment)
        let names = try Self.query(options + ["--name-only"], in: directory, environment: environment)
        guard output.status == 0, names.status == 0 else { throw Failure("Git configuration could not be checked safely.") }
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
    }

    func readOptions(in directory: URL, environment: [String: String], submodules: Bool) throws -> [String] {
        let repositories = submodules ? try repositories(in: directory, environment: environment) : [(directory, self)]
        return try readOptions(local: repositories.flatMap {
            $0.1.entries.filter { $0.scope == "local" || $0.scope == "worktree" }
        })
    }

    private func repositories(in directory: URL, environment: [String: String], depth: Int = 0) throws -> [(URL, GitConfiguration)] {
        // Status/diff and recursive fetch spawn Git in initialized submodules,
        // inheriting our -c overrides. Inventory those repositories too.
        var result = [(directory, self)]
        let index = try Self.query(["ls-files", "--stage", "--sparse", "-z"], in: directory, environment: environment, limit: 64 * 1_048_576)
        if index.status == 0 {
            for record in index.data.split(separator: 0) where record.starts(with: Array("160000 ".utf8)) {
                guard let tab = record.firstIndex(of: 9) else { continue }
                guard let path = String(data: record[record.index(after: tab)...], encoding: .utf8) else {
                    throw Failure("Git submodule paths contain invalid UTF-8; their configuration cannot be checked safely.")
                }
                let child = directory.appendingPathComponent(path)
                guard FileManager.default.fileExists(atPath: child.appendingPathComponent(".git").path) else { continue }
                guard depth < 16 else { throw Failure("Git submodule configuration is nested too deeply to check safely.") }
                let configuration = try GitConfiguration(in: child, environment: environment)
                result += try configuration.repositories(in: child, environment: environment, depth: depth + 1)
            }
        }
        return result
    }

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
        return options + ["-c", "core.hooksPath=/dev/null", "-c", "log.showSignature=false",
                          "-c", "core.pager=", "-c", "core.editor=/usr/bin/false", "-c", "sequence.editor=/usr/bin/false"]
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
    public func redirectOptions(for command: String, in directory: URL, environment: [String: String]) throws -> (options: [String], protected: Bool) {
        var settings = [Data("http.followRedirects".utf8): "initial"], protected = false
        for (directory, configuration) in try repositories(in: directory, environment: environment) {
            func hasHeaders(_ url: String) throws -> Bool {
                let headers = try Self.query(["config", "--get-urlmatch", "http.extraHeader", url], in: directory, environment: environment)
                guard headers.status == 0 || headers.status == 1 else { throw Failure("Git HTTP header configuration could not be checked safely.") }
                return headers.status == 0 && headers.data.contains { $0 != 10 }
            }
            // Reset every URL-specific redirect setting too. A private-header
            // scope can be more specific than the configured remote's URL.
            for entry in configuration.entries where entry.name.hasPrefix("http.") && entry.name != "http.followredirects" && entry.name.hasSuffix(".followredirects") {
                let url = String(entry.name.dropFirst(5).dropLast(".followredirects".count))
                let deny = try hasHeaders(url)
                if deny || settings[Data(entry.name.utf8)] != "false" { settings[Data(entry.name.utf8)] = deny ? "false" : "initial" }
                protected = protected || deny
            }
            var remotes = Set(configuration.entries.compactMap { entry -> Data? in
                guard entry.name.hasPrefix("remote.") else { return nil }
                if entry.name.hasSuffix(".url") { return Data(entry.name.dropFirst(7).dropLast(4).utf8) }
                if entry.name.hasSuffix(".pushurl") { return Data(entry.name.dropFirst(7).dropLast(8).utf8) }
                return nil
            })
            let named = remotes
            for entry in configuration.entries where entry.name == "remote.pushdefault"
                || (entry.name.hasPrefix("branch.") && (entry.name.hasSuffix(".remote") || entry.name.hasSuffix(".pushremote"))) {
                remotes.insert(Data(entry.value.utf8))
            }
            for key in remotes.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                let remote = String(decoding: key, as: UTF8.self)
                let arguments = named.contains(key)
                    ? ["remote", "get-url", "--all"] + (command == "push" ? ["--push"] : []) + ["--", remote]
                    : ["ls-remote", "--get-url", "--", remote]
                let urls = try Self.query(arguments, in: directory, environment: environment)
                guard urls.status == 0 else { throw Failure("Git remote URLs could not be checked safely.") }
                for remoteURL in String(decoding: urls.data, as: UTF8.self).split(separator: "\n") {
                    var url = String(remoteURL)
                    // The explicit helper form passes only its address to the
                    // helper. Git/curl also accept mixed-case HTTP schemes.
                    if let colon = url.firstIndex(of: ":"), url[url.index(after: colon)...].hasPrefix(":") {
                        url = String(url[url.index(colon, offsetBy: 2)...])
                    }
                    guard url.lowercased().hasPrefix("http://") || url.lowercased().hasPrefix("https://") else { continue }
                    if try hasHeaders(String(url)) {
                        settings[Data("http.\(url).followRedirects".utf8)] = "false"
                        protected = true
                    }
                }
            }
        }
        guard !settings.keys.contains(where: { $0.contains(61) || $0.contains(10) }) else {
            throw Failure("Git HTTP configuration contains a URL that cannot be overridden safely.")
        }
        let options = settings.sorted { $0.key.lexicographicallyPrecedes($1.key) }.flatMap {
            ["-c", String(decoding: $0.key, as: UTF8.self) + "=" + $0.value]
        }
        try Self.requireUnchangedBytes(options)
        return (options, protected)
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
    /// Only fixed metadata commands enter here. Confine even the inventory:
    /// a malformed/sparse index must not fetch while we inspect configuration.
    static func query(_ arguments: [String], in directory: URL, environment: [String: String], limit: Int = 4 * 1_048_576) throws -> Output {
        try requireUnchangedBytes(arguments)
        let process = Process(), pipe = Pipe()
        process.currentDirectoryURL = directory
        let confinement = try GitReadProcess(process, arguments: arguments, environment: environment)
        defer { confinement.remove() }
        process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        let reader = pipe.fileHandleForReading
        defer { try? reader.close() }
        try process.run()
        let fd = reader.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 { bytes.append(contentsOf: buffer.prefix(count)) }
            else if count == 0 { break }
            else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { break }
            if bytes.count > limit || ProcessInfo.processInfo.systemUptime > deadline {
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
}
