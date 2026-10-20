import Foundation
import Darwin

/// Device/inode and nanosecond ctime also catch same-size edits with restored
/// mtimes. Keep the symlink and its target: either can change independently.
struct GitFileStamp: Hashable {
    let path: String
    let watchedPath: String
    private let identity: [Int64]
    let cacheable: Bool
    private let directoryIdentity: Bool
    init(_ path: String, directoryIdentity: Bool = false) {
        self.init(path, watchedPath: URL(fileURLWithPath: path).resolvingSymlinksInPath().path, directoryIdentity: directoryIdentity)
    }
    private init(_ path: String, watchedPath: String, directoryIdentity: Bool) {
        self.path = path
        self.watchedPath = watchedPath
        self.directoryIdentity = directoryIdentity
        func fields(_ value: stat) -> [Int64] {
            if directoryIdentity, value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                return [Int64(value.st_dev), Int64(bitPattern: UInt64(value.st_ino)), Int64(value.st_mode)]
            }
            // devfs timestamps can advance with the clock or unrelated writes.
            // /dev/null is immutable empty config, identified by its device.
            if watchedPath == "/dev/null", value.st_mode & mode_t(S_IFMT) == mode_t(S_IFCHR) {
                return [Int64(value.st_dev), Int64(bitPattern: UInt64(value.st_ino)), Int64(value.st_mode), Int64(value.st_rdev)]
            }
            return [Int64(value.st_dev), Int64(bitPattern: UInt64(value.st_ino)), Int64(value.st_mode), value.st_size,
             Int64(value.st_mtimespec.tv_sec), Int64(value.st_mtimespec.tv_nsec),
             Int64(value.st_ctimespec.tv_sec), Int64(value.st_ctimespec.tv_nsec)]
        }
        var link = stat(), target = stat()
        if lstat(path, &link) == 0 {
            let symlink = link.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK)
            let followed = symlink && stat(path, &target) == 0
            identity = fields(link) + (followed ? fields(target) : [])
            let kind = (followed ? target.st_mode : link.st_mode) & mode_t(S_IFMT)
            let readableTarget = !symlink || followed || errno == ENOENT || errno == ENOTDIR
            cacheable = readableTarget && ([mode_t(S_IFREG), mode_t(S_IFDIR), mode_t(S_IFLNK)].contains(kind) || (kind == mode_t(S_IFCHR) && watchedPath == "/dev/null"))
        } else { identity = []; cacheable = errno == ENOENT || errno == ENOTDIR }
    }
    var unchanged: Bool {
        let current = GitFileStamp(path, watchedPath: watchedPath, directoryIdentity: directoryIdentity)
        return cacheable && current.cacheable && identity == current.identity
    }
    var exists: Bool { !identity.isEmpty }

    var resolution: (stamps: [GitFileStamp], complete: Bool) {
        guard path.hasPrefix("/") else { return ([], false) }
        var pending = path.split(separator: "/").map(String.init), resolved: [String] = []
        var result = [GitFileStamp("/", directoryIdentity: true)], links = 0
        // Walk each symlink target too, before processing "..". The final
        // inode alone cannot detect a changed relative gitdir: condition.
        while !pending.isEmpty {
            let component = pending.removeFirst()
            if component == "." { continue }
            if component == ".." { if !resolved.isEmpty { resolved.removeLast() }; continue }
            let prefix = "/" + (resolved + [component]).joined(separator: "/")
            result.append(GitFileStamp(prefix, directoryIdentity: pending.isEmpty ? directoryIdentity : true))
            var value = stat()
            guard lstat(prefix, &value) == 0 else {
                return (result, errno == ENOENT || errno == ENOTDIR)
            }
            if value.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                links += 1
                guard links <= 40 else { return (result, false) }
                var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX))
                let count = buffer.withUnsafeMutableBytes { readlink(prefix, $0.baseAddress!, $0.count) }
                guard count > 0, count < buffer.count, let target = String(bytes: buffer[..<count], encoding: .utf8) else {
                    return (result, false)
                }
                if target.hasPrefix("/") { resolved.removeAll() }
                pending = target.split(separator: "/").map(String.init) + pending
            } else {
                guard pending.isEmpty || value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { return (result, false) }
                resolved.append(component)
            }
        }
        return (result, result.allSatisfy(\.cacheable))
    }

    static func discovery(in directory: URL) -> [GitFileStamp] {
        var path = directory.path, result: [GitFileStamp] = []
        while true {
            // Directory identity ignores ordinary working-file saves. The
            // markers also cover bare repositories and a newly created .git.
            result += [GitFileStamp(path, directoryIdentity: true), GitFileStamp(path + "/.git", directoryIdentity: true),
                       GitFileStamp(path + "/HEAD"), GitFileStamp(path + "/commondir"), GitFileStamp(path + "/objects", directoryIdentity: true),
                       GitFileStamp(path + "/refs", directoryIdentity: true)]
            if path == "/" { break }
            path = (path as NSString).deletingLastPathComponent
        }
        return result
    }
}

/// Waiters can abandon a cold build without cancelling another read's work.
/// The builder's own invocation owns every subprocess it starts.
final class GitInventoryMemo<Value>: @unchecked Sendable {
    private let condition = NSCondition()
    private var value: Value?
    private var building = false
    var cached: Value? { condition.lock(); defer { condition.unlock() }; return value }
    func get(invocation: GitInvocation, valid: (Value) throws -> Bool = { _ in true }, retain: (Value) -> Bool = { _ in true }, build: () throws -> Value) throws -> Value {
        while true {
            try invocation.check()
            condition.lock()
            if let value {
                let matches: Bool
                do { matches = try valid(value) } catch { condition.unlock(); throw error }
                if matches { condition.unlock(); try invocation.check(); return value }
            }
            if building {
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.02)); condition.unlock(); continue
            }
            value = nil; building = true; condition.unlock()
            do {
                try invocation.check()
                let result = try build()
                try invocation.check()
                condition.lock(); value = retain(result) ? result : nil; building = false; condition.broadcast(); condition.unlock()
                return result
            } catch {
                condition.lock(); building = false; condition.broadcast(); condition.unlock(); throw error
            }
        }
    }
}

final class GitInventoryCache: @unchecked Sendable {
    static let shared = GitInventoryCache()
    private let lock = NSLock()
    private var values: [Data: GitInventoryMemo<GitConfiguration>] = [:]
    private var lookups: [Data: Data] = [:]
    private var building: [Data: GitInventoryMemo<GitConfiguration>] = [:]
    private var generation = 0
    func configuration(in directory: URL, environment: [String: String], invocation: GitInvocation,
                       build: () throws -> GitConfiguration) throws -> GitConfiguration {
        let lookup = Data(([directory.path] + environment.keys.sorted().flatMap { [$0, environment[$0]!] }).joined(separator: "\0").utf8)
        let (memo, ticket) = lock.withLock {
            if let key = lookups[lookup], let value = values[key] { return (value, generation) }
            if let value = building[lookup] { return (value, generation) }
            let value = GitInventoryMemo<GitConfiguration>(); building[lookup] = value; return (value, generation)
        }
        do {
            let result = try memo.get(invocation: invocation, valid: { configuration in
                guard configuration.cacheable else { return false }
                return try configuration.stamps.allSatisfy { stamp in try invocation.check(); return stamp.unchanged }
            }, retain: { $0.cacheable }, build: build)
            lock.withLock {
                // A trust change or watcher invalidation during a cold build
                // must not let that build repopulate the new cache generation.
                guard ticket == generation else { return }
                building.removeValue(forKey: lookup)
                if let old = lookups.removeValue(forKey: lookup) { values.removeValue(forKey: old) }
                guard result.cacheable else { return }
                let key = lookup + Data([0]) + result.identity
                if values.count >= 128, let old = values.keys.first {
                    values.removeValue(forKey: old); lookups = lookups.filter { $0.value != old }
                }
                values[key] = memo; lookups[lookup] = key
            }
            return result
        } catch {
            lock.withLock { if building[lookup] === memo { building.removeValue(forKey: lookup) } }
            throw error
        }
    }
    func clear() { lock.withLock { generation &+= 1; values.removeAll(); lookups.removeAll(); building.removeAll() } }
    func invalidate(paths: [String]) -> Bool {
        let paths = paths.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
        return lock.withLock {
            let keys = values.compactMap { key, memo -> Data? in
                guard let configuration = memo.cached else { return key }
                return configuration.stamps.contains { stamp in
                    let file = stamp.watchedPath
                    return paths.contains { file == $0 || file.hasPrefix($0 + "/") }
                } ? key : nil
            }
            guard !keys.isEmpty || !building.isEmpty else { return false }
            generation &+= 1; building.removeAll()
            for key in keys { values.removeValue(forKey: key) }
            lookups = lookups.filter { values[$0.value] != nil }
            return true
        }
    }
}

/// A child Git re-evaluates this condition in its own gitdir. A parent's
/// restored global value must never override a child's conditional global.
final class GitReadOverrides: @unchecked Sendable {
    let directory: URL
    let argument: String
    init(gitDirectory: String, options: [String]) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bello-git-policy-" + UUID().uuidString)
        self.directory = directory
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: directory) } }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("config")
        var content = ""
        for index in stride(from: 1, to: options.count, by: 2) {
            let option = options[index], equals = option.firstIndex(of: "=")!
            let name = option[..<equals], value = option[option.index(after: equals)...]
            let first = name.firstIndex(of: ".")!, last = name.lastIndex(of: ".")!
            content += "[" + name[..<first]
            if first != last { content += " " + (try Self.subsection(String(name[name.index(after: first)..<last]))) }
            content += "]\n" + name[name.index(after: last)...] + " = " + (try Self.value(String(value))) + "\n"
        }
        try Data(content.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let pattern = gitDirectory.unicodeScalars.reduce(into: "") { result, scalar in
            // A combining mark must not hide Git's glob punctuation.
            if "\\*?[]".unicodeScalars.contains(scalar) { result.append("\\") }; result.unicodeScalars.append(scalar)
        }
        let include = directory.appendingPathComponent("include")
        try Data(("[includeIf " + Self.subsection("gitdir:" + pattern) + "]\npath = " + Self.value(file.path) + "\n").utf8).write(to: include)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: include.path)
        // Keep repository path bytes out of -c's key/value separator syntax.
        argument = "include.path=\(include.path)"
        complete = true
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    private static func subsection(_ text: String) throws -> String {
        // Subsections do not support value escapes such as \n, \t or \b.
        guard text.rangeOfCharacter(from: .controlCharacters) == nil else { throw GitConfiguration.ConfinementRequired() }
        var result = "\""
        for scalar in text.unicodeScalars {
            if scalar == "\\" || scalar == "\"" { result.append("\\") }
            result.unicodeScalars.append(scalar)
        }
        return result + "\""
    }

    private static func value(_ text: String) throws -> String {
        // Keep generated values in the same conservative printable subset;
        // quotes/backslashes round-trip, and no unsupported escape is emitted.
        guard text.rangeOfCharacter(from: .controlCharacters) == nil else { throw GitConfiguration.ConfinementRequired() }
        var result = "\""
        for scalar in text.unicodeScalars {
            if scalar == "\\" || scalar == "\"" { result.append("\\") }
            result.unicodeScalars.append(scalar)
        }
        return result + "\""
    }
}
