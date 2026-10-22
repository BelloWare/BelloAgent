import Foundation
import Darwin

/// Device/inode and nanosecond ctime also catch same-size edits with restored
/// mtimes. Keep the symlink and its target: either can change independently.
struct GitFileStamp: Hashable {
#if DEBUG
    private static let validationLock = NSLock()
    nonisolated(unsafe) private static var validationHook: (@Sendable (String) -> Void)?
    static var beforeValidation: (@Sendable (String) -> Void)? {
        get { validationLock.withLock { validationHook } }
        set { validationLock.withLock { validationHook = newValue } }
    }
#endif
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
#if DEBUG
        Self.beforeValidation?(path)
#endif
        let current = GitFileStamp(path, watchedPath: watchedPath, directoryIdentity: directoryIdentity)
        return cacheable && current.cacheable && identity == current.identity
    }
    var exists: Bool { !identity.isEmpty }

    var resolution: (stamps: [GitFileStamp], complete: Bool) {
        guard path.gitHasPrefix("/") else { return ([], false) }
        var pending = path.gitSplit(separator: 47), resolved: [String] = []
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
                let count = buffer.withUnsafeMutableBytes { bytes in
                    guard let base = bytes.baseAddress else { return -1 }
                    return readlink(prefix, base, bytes.count)
                }
                guard count > 0, count < buffer.count, let target = String(bytes: buffer[..<count], encoding: .utf8) else {
                    return (result, false)
                }
                if target.gitHasPrefix("/") { resolved.removeAll() }
                pending = target.gitSplit(separator: 47) + pending
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
    private var revision = 0
    private var building = false
    func get(invocation: GitInvocation, valid: (Value) throws -> Bool = { _ in true }, retain: (Value) -> Bool = { _ in true }, build: () throws -> Value) throws -> Value {
        while true {
            try invocation.check()
            condition.lock()
            let snapshot = value, ticket = revision
            if let snapshot {
                condition.unlock()
                let matches = try valid(snapshot)
                try invocation.check()
                condition.lock()
                guard revision == ticket else { condition.unlock(); continue }
                if matches { condition.unlock(); return snapshot }
            }
            if building {
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.02)); condition.unlock(); continue
            }
            value = nil; revision &+= 1; building = true; condition.unlock()
            // Releasing an override can remove its scratch config directory.
            withExtendedLifetime(snapshot) {}
            do {
                try invocation.check()
                let result = try build()
                try invocation.check()
                let kept = retain(result)
                condition.lock(); value = kept ? result : nil; revision &+= 1; building = false; condition.broadcast(); condition.unlock()
                return result
            } catch {
                condition.lock(); building = false; condition.broadcast(); condition.unlock(); throw error
            }
        }
    }
}

final class GitInventoryCache: @unchecked Sendable {
    static let shared = GitInventoryCache()
    private final class Cached {
        let memo: GitInventoryMemo<GitConfiguration>
        let configuration: GitConfiguration
        init(_ memo: GitInventoryMemo<GitConfiguration>, _ configuration: GitConfiguration) {
            self.memo = memo; self.configuration = configuration
        }
    }
    private struct Event {
        let paths: [String]
        let onChange: (@Sendable () -> Void)?
    }
    private final class Pending {
        let memo: GitInventoryMemo<GitConfiguration>
        var events: [Event] = [] // Guarded by the cache lock, never the memo lock.
        init(_ memo: GitInventoryMemo<GitConfiguration>) { self.memo = memo }
    }
    private let lock = NSLock()
    private var values: [Data: Cached] = [:]
    private var lookups: [Data: Data] = [:]
    private var building: [Data: Pending] = [:]
    private var generation = 0
    func configuration(in directory: URL, environment: [String: String], invocation: GitInvocation,
                       build: () throws -> GitConfiguration) throws -> GitConfiguration {
        try invocation.check()
        let lookup = Data(([directory.path] + environment.sorted(by: { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }).flatMap { [$0.key, $0.value] }).joined(separator: "\0").utf8)
        let (memo, ticket) = lock.withLock {
            if let key = lookups[lookup], let value = values[key] { return (value.memo, generation) }
            if let value = building[lookup] { return (value.memo, generation) }
            let value = Pending(GitInventoryMemo<GitConfiguration>()); building[lookup] = value; return (value.memo, generation)
        }
        var pending: Pending?, retained = false
        do {
            return try memo.get(invocation: invocation, valid: { configuration in
                guard configuration.cacheable else { return false }
                return try configuration.stamps.allSatisfy { stamp in try invocation.check(); return stamp.unchanged }
            }, retain: { _ in retained }, build: {
                // Register actual rebuilds too; a warm entry can fail its stamps.
                let current = lock.withLock {
                    if let value = building[lookup], value.memo === memo { return value }
                    let value = Pending(memo)
                    if ticket == generation, let key = lookups[lookup], values[key]?.memo === memo { building[lookup] = value }
                    return value
                }
                pending = current
                let result = try build()
                try invocation.check()
                retained = publish(result, pending: current, lookup: lookup, ticket: ticket)
                return result
            })
        } catch {
            // A cancelled waiter must not discard another invocation's build.
            if let pending { lock.withLock { if building[lookup] === pending { building.removeValue(forKey: lookup) } } }
            throw error
        }
    }
    private func publish(_ result: GitConfiguration, pending: Pending, lookup: Data, ticket: Int) -> Bool {
        let key = lookup + Data([0]) + result.identity, candidate = Cached(pending.memo, result)
        var retired: [Cached] = []
        let events = lock.withLock {
            let events = pending.events
            guard ticket == generation, building[lookup] === pending else { return events }
            building.removeValue(forKey: lookup)
            if let old = lookups.removeValue(forKey: lookup), let value = values.removeValue(forKey: old) { retired.append(value) }
            if values.count >= 128, let old = values.keys.first {
                if let value = values.removeValue(forKey: old) { retired.append(value) }
                lookups = lookups.filter { $0.value != old }
            }
            // Expose only completed source metadata to new watcher events.
            // The memo still has no value and its readers wait until the
            // earlier events below have decided whether to retain the result.
            values[key] = candidate; lookups[lookup] = key
            return events
        }
        withExtendedLifetime(retired) {}
        let changed = events.filter { Self.touches($0.paths, stamps: result.stamps) }
        let retained = lock.withLock {
            guard values[key] === candidate else { return false }
            guard result.cacheable, changed.isEmpty else {
                values.removeValue(forKey: key); lookups.removeValue(forKey: lookup)
                return false
            }
            return true
        }
        // Sources discovered by a cold build may have been ignored by the
        // watcher. Deliver their configuration signal after publication.
        for event in changed { event.onChange?() }
        return retained
    }
    func clear() {
        let retired = lock.withLock {
            let old = (values, building)
            generation &+= 1; values.removeAll(); lookups.removeAll(); building.removeAll()
            return old
        }
        withExtendedLifetime(retired) {}
    }
    func invalidate(paths: [String], onDeferredChange: (@Sendable () -> Void)? = nil) -> Bool {
        let snapshot = lock.withLock {
            for pending in building.values { pending.events.append(Event(paths: paths, onChange: onDeferredChange)) }
            return values
        }
        let affected = snapshot.filter { Self.touches(paths, stamps: $0.value.configuration.stamps) }
        lock.withLock {
            for (key, value) in affected where values[key] === value { values.removeValue(forKey: key) }
            lookups = lookups.filter { values[$0.value] != nil }
        }
        // Keep the removed inventories alive until both locks are released.
        withExtendedLifetime(snapshot) {}
        return !affected.isEmpty
    }
    private static func touches(_ paths: [String], stamps: [GitFileStamp]) -> Bool {
        // Resolve aliases using the inventory's recorded resolution, without
        // filesystem calls on the watcher or while holding either cache lock.
        var candidates = paths
        for stamp in stamps where stamp.path != stamp.watchedPath {
            for path in paths {
                if path == stamp.path { candidates.append(stamp.watchedPath) }
                else if path.gitHasPrefix(stamp.path + "/") { candidates.append(stamp.watchedPath + path.gitDropFirst(stamp.path.utf8.count)) }
            }
        }
        return stamps.contains { stamp in
            candidates.contains { path in
                stamp.path == path || stamp.path.gitHasPrefix(path + "/") || stamp.watchedPath == path || stamp.watchedPath.gitHasPrefix(path + "/")
            }
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
        guard options.count.isMultiple(of: 2) else { throw GitConfiguration.ConfinementRequired() }
        for index in stride(from: 1, to: options.count, by: 2) {
            guard options[index - 1] == "-c", let setting = options[index].gitSplitOnce(separator: 61),
                  let section = setting.before.gitSplitOnce(separator: 46),
                  let key = setting.before.gitSplitOnce(separator: 46, last: true),
                  !section.before.isEmpty, !key.after.isEmpty,
                  [section.before, key.after].allSatisfy({ part in
                      part.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
                  }) else { throw GitConfiguration.ConfinementRequired() }
            content += "[" + section.before
            if let subsection = section.after.gitSplitOnce(separator: 46, last: true) {
                content += " " + (try Self.subsection(subsection.before))
            }
            content += "]\n" + key.after + " = " + (try Self.value(setting.after)) + "\n"
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
