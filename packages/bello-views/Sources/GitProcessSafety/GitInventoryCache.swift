import Foundation
import Darwin

/// Device/inode and nanosecond ctime also catch same-size edits with restored
/// mtimes. Keep the symlink and its target: either can change independently.
struct GitFileStamp: Equatable {
    let path: String
    let watchedPath: String
    private let identity: [Int64]
    private let cacheable: Bool
    init(_ path: String) {
        self.init(path, watchedPath: URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
    }
    private init(_ path: String, watchedPath: String) {
        self.path = path
        self.watchedPath = watchedPath
        func fields(_ value: stat) -> [Int64] {
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
            cacheable = [mode_t(S_IFREG), mode_t(S_IFDIR), mode_t(S_IFLNK)].contains(kind) || (kind == mode_t(S_IFCHR) && watchedPath == "/dev/null")
        } else { identity = []; cacheable = true }
    }
    var unchanged: Bool { cacheable && identity == GitFileStamp(path, watchedPath: watchedPath).identity }
}

/// Waiters can abandon a cold build without cancelling another read's work.
/// The builder's own invocation owns every subprocess it starts.
final class GitInventoryMemo<Value>: @unchecked Sendable {
    private let condition = NSCondition()
    private var value: Value?
    private var building = false
    var cached: Value? { condition.lock(); defer { condition.unlock() }; return value }
    func get(invocation: GitInvocation, valid: (Value) throws -> Bool = { _ in true }, build: () throws -> Value) throws -> Value {
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
                condition.lock(); value = result; building = false; condition.broadcast(); condition.unlock()
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
    func configuration(in directory: URL, environment: [String: String], invocation: GitInvocation,
                       build: () throws -> GitConfiguration) throws -> GitConfiguration {
        let key = Data(([directory.path] + environment.keys.sorted().flatMap { [$0, environment[$0]!] }).joined(separator: "\0").utf8)
        let memo = lock.withLock {
            if let value = values[key] { return value }
            // Bound retained metadata and private policy files, not disk copies
            // of a repository. Active invocations keep their own references.
            if values.count >= 128, let completed = values.first(where: { $0.value.cached != nil })?.key { values.removeValue(forKey: completed) }
            let value = GitInventoryMemo<GitConfiguration>(); values[key] = value; return value
        }
        return try memo.get(invocation: invocation, valid: { configuration in
            try configuration.stamps.allSatisfy { stamp in try invocation.check(); return stamp.unchanged }
        }, build: build)
    }
    func clear() { lock.withLock { values.removeAll() } }
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
            for key in keys { values.removeValue(forKey: key) }
            return !keys.isEmpty
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
        func quote(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t").replacingOccurrences(of: "\u{8}", with: "\\b") + "\""
        }
        var content = ""
        for index in stride(from: 1, to: options.count, by: 2) {
            let option = options[index], equals = option.firstIndex(of: "=")!
            let name = option[..<equals], value = option[option.index(after: equals)...]
            let first = name.firstIndex(of: ".")!, last = name.lastIndex(of: ".")!
            content += "[" + name[..<first]
            if first != last { content += " " + quote(String(name[name.index(after: first)..<last])) }
            content += "]\n" + name[name.index(after: last)...] + " = " + quote(String(value)) + "\n"
        }
        try Data(content.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let pattern = gitDirectory.reduce(into: "") { result, character in
            if "\\*?[]".contains(character) { result.append("\\") }; result.append(character)
        }
        let include = directory.appendingPathComponent("include")
        try Data(("[includeIf " + quote("gitdir:" + pattern) + "]\npath = " + quote(file.path) + "\n").utf8).write(to: include)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: include.path)
        // Keep repository path bytes out of -c's key/value separator syntax.
        argument = "include.path=\(include.path)"
        complete = true
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}
