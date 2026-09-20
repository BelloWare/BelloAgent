import Foundation
import CoreServices

/// Watches a repository for changes nobody in the panel made: a file saved in
/// an editor, a commit or a checkout from a terminal.
///
/// FSEvents rather than a vnode source, because a vnode source on a directory
/// reports entries appearing and disappearing but never a change to a file's
/// contents, which is most of what a working tree does. Everything inside
/// `.git` is ignored except HEAD, the refs and the index, so git's own
/// housekeeping does not keep waking the panel, and bursts are collapsed to at
/// most one call every `interval`.
@MainActor final class GitWorkingTreeWatcher {
    /// The repository this watcher is on, resolved through any symbolic links.
    let root: String
    /// Where this working tree's git state actually lives when `.git` is a
    /// file rather than a directory: a linked worktree or a submodule keeps
    /// its HEAD, refs and index somewhere else entirely.
    let gitDirectory: String?
    private let interval: TimeInterval
    private let onChange: () -> Void
    private let handle = GitWatchStream()
    private(set) var bridge: GitWatchBridge?
    private var generation = UUID()
    private let queue = DispatchQueue(label: "com.belloware.PiApp.git.watch", qos: .utility)
    private var lastCall = -Double.greatestFiniteMagnitude
    private var trailing: DispatchWorkItem?
    deinit { handle.stop() }
    /// How long FSEvents itself gathers events before handing them over. Short
    /// enough that a saved file appears at once, long enough that one save is
    /// one callback rather than several.
    private static let latency = 0.3

    var isWatching: Bool { handle.isRunning }
    /// Streams open in this process, so a test can prove none was left behind.
    nonisolated static var liveStreamCount: Int { GitWatchStream.liveCount }

    init(root: String, interval: TimeInterval = 1, onChange: @escaping () -> Void) {
        let resolved = URL(fileURLWithPath: root, isDirectory: true).resolvingSymlinksInPath().path
        self.root = resolved
        self.gitDirectory = Self.gitDirectory(under: resolved)
        self.interval = interval
        self.onChange = onChange
    }

    /// The directory holding this working tree's git state, when it is not a
    /// `.git` directory inside the tree. `git worktree add` and `git submodule`
    /// both leave a `.git` file naming somewhere else.
    nonisolated static func gitDirectory(under root: String) -> String? {
        let marker = root + "/.git"
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: marker, isDirectory: &isDirectory), !isDirectory.boolValue,
              let text = try? String(contentsOfFile: marker, encoding: .utf8),
              let line = text.split(whereSeparator: { $0.isNewline }).first(where: { $0.hasPrefix("gitdir:") })
        else { return nil }
        let named = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !named.isEmpty else { return nil }
        let absolute = named.hasPrefix("/") ? named : root + "/" + named
        let resolved = URL(fileURLWithPath: absolute, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
        return resolved == root || resolved.hasPrefix(root + "/") ? nil : resolved
    }

    func start() {
        guard !handle.isRunning else { return }
        let root = root, gitDirectory = gitDirectory, generation = UUID()
        self.generation = generation
        let bridge = GitWatchBridge { @Sendable [weak self] paths, flags in
            // The folder this stream is on stopped being the project's folder:
            // it was renamed, moved or deleted under the panel.
            let moved = flags.contains { $0 & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 }
            guard moved || paths.contains(where: { Self.isInteresting($0, under: root, gitDirectory: gitDirectory) }) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation, self.handle.isRunning else { return }
                if moved { self.rootChanged() } else { self.changed() }
            }
        }
        self.bridge = bridge
        var context = gitWatchContext(bridge)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        let watched = [root] + (gitDirectory.map { [$0] } ?? [])
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, gitWatchCallback, &context, watched as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency, flags) else {
            self.bridge = nil
            return
        }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created); FSEventStreamRelease(created); self.bridge = nil
            return
        }
        handle.adopt(created)
    }

    func stop() {
        generation = UUID()
        trailing?.cancel(); trailing = nil
        bridge?.invalidate(); bridge = nil
        handle.stop()
        lastCall = -Double.greatestFiniteMagnitude
    }

    /// The project's folder was renamed, moved or deleted. This stream is on
    /// an inode that is no longer it, so it is stopped and the panel told once:
    /// the refresh that follows either finds the repository again and starts a
    /// new watch, or finds nothing and says so.
    private func rootChanged() {
        guard handle.isRunning else { return }
        Self.countRootChange()
        stop()
        onChange()
    }
    /// Root changes seen in this process, so a test can prove the flag was
    /// acted on rather than the move being noticed some other way.
    nonisolated private static let rootLock = NSLock()
    nonisolated(unsafe) private static var rootChanges = 0
    nonisolated private static func countRootChange() { rootLock.lock(); rootChanges += 1; rootLock.unlock() }
    nonisolated static var rootChangeCount: Int { rootLock.lock(); defer { rootLock.unlock() }; return rootChanges }
    /// One call per `interval` at most: the first change is acted on, and
    /// anything that arrives during the wait becomes one call at its end.
    private func changed() {
        guard handle.isRunning else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastCall >= interval {
            lastCall = now; onChange(); return
        }
        guard trailing == nil else { return }
        let generation = generation
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation, self.handle.isRunning else { return }
                self.trailing = nil; self.lastCall = ProcessInfo.processInfo.systemUptime; self.onChange()
            }
        }
        trailing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (interval - (now - lastCall)), execute: work)
    }

    /// True for a path the panel would show: anything in the working tree, and
    /// inside `.git` only what says where HEAD is and what is staged. A stage
    /// writes `index.lock` and a dozen object files; none of those are it.
    nonisolated static func isInteresting(_ path: String, under root: String, gitDirectory: String? = nil) -> Bool {
        // A linked worktree keeps its git state outside the tree; the same few
        // names matter there as inside a `.git` directory.
        if let gitDirectory, path == gitDirectory || path.hasPrefix(gitDirectory + "/") {
            return isGitState(path.dropFirst(gitDirectory.count).drop(while: { $0 == "/" }))
        }
        guard path.hasPrefix(root) else { return true }
        let relative = path.dropFirst(root.count).drop(while: { $0 == "/" })
        var parts = relative.split(separator: "/", omittingEmptySubsequences: true)
        guard let first = parts.first else { return false }
        guard first == ".git" else { return true }
        parts.removeFirst()
        return isGitState(parts.joined(separator: "/")[...])
    }
    /// True for the few names that say where HEAD is and what is staged.
    private nonisolated static func isGitState(_ relative: Substring) -> Bool {
        guard let first = relative.split(separator: "/", omittingEmptySubsequences: true).first else { return false }
        return ["HEAD", "index", "refs", "packed-refs", "MERGE_HEAD", "ORIG_HEAD", "REBASE_HEAD"].contains(String(first))
    }
}

/// Owns the FSEvents stream so it is released even if the watcher is dropped
/// without being stopped; the stream is not a Sendable type, and a nonisolated
/// deinit may not reach into main-actor state.
final class GitWatchStream: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return stream != nil }
    func adopt(_ value: FSEventStreamRef) {
        lock.lock(); let previous = stream; stream = value; if previous == nil { Self.count(1) }; lock.unlock()
        if let previous { FSEventStreamStop(previous); FSEventStreamInvalidate(previous); FSEventStreamRelease(previous) }
    }
    func stop() {
        lock.lock(); let current = stream; stream = nil; if current != nil { Self.count(-1) }; lock.unlock()
        guard let current else { return }
        FSEventStreamStop(current); FSEventStreamInvalidate(current); FSEventStreamRelease(current)
    }
    /// The last reference going away stops the stream, so a controller nobody
    /// told to stop still leaves nothing running behind it.
    deinit { stop() }

    /// Streams open right now, so a test can prove none was left behind.
    private static let liveLock = NSLock()
    nonisolated(unsafe) private static var live = 0
    // Taken while the instance lock is held; nothing takes them the other way.
    private static func count(_ delta: Int) { liveLock.lock(); live += delta; liveLock.unlock() }
    static var liveCount: Int { liveLock.lock(); defer { liveLock.unlock() }; return live }
}

/// Carries FSEvents' C callback to Swift. The stream owns a reference to it and
/// gives it up when it is released, so a callback in flight never lands on a
/// freed object; `invalidate` drops the handler before the stream is stopped.
final class GitWatchBridge: @unchecked Sendable {
    typealias Handler = @Sendable ([String], [FSEventStreamEventFlags]) -> Void
    private let lock = NSLock()
    private var handler: Handler?
    init(handler: @escaping Handler) { self.handler = handler }
    func deliver(_ paths: [String], _ flags: [FSEventStreamEventFlags]) {
        lock.lock(); let handler = handler; lock.unlock()
        handler?(paths, flags)
    }
    func invalidate() { lock.lock(); handler = nil; lock.unlock() }
}

// These are C callbacks, not UI closures. Let FSEvents retain the borrowed
// context when it creates a stream, and balance that retain on any executor.
// Failed creation leaves only the caller's ordinary Swift reference to release.
func gitWatchContext(_ bridge: GitWatchBridge) -> FSEventStreamContext {
    FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(bridge).toOpaque(),
                         retain: retainGitWatchBridge, release: releaseGitWatchBridge, copyDescription: nil)
}
private func retainGitWatchBridge(_ pointer: UnsafeRawPointer?) -> UnsafeRawPointer? {
    guard let pointer else { return nil }
    _ = Unmanaged<GitWatchBridge>.fromOpaque(pointer).retain()
    return pointer
}
private func releaseGitWatchBridge(_ pointer: UnsafeRawPointer?) {
    if let pointer { Unmanaged<GitWatchBridge>.fromOpaque(pointer).release() }
}

private func gitWatchCallback(_ stream: ConstFSEventStreamRef, _ info: UnsafeMutableRawPointer?, _ count: Int,
                              _ paths: UnsafeMutableRawPointer, _ flags: UnsafePointer<FSEventStreamEventFlags>,
                              _ identifiers: UnsafePointer<FSEventStreamEventId>) {
    guard let info, count > 0 else { return }
    let bridge = Unmanaged<GitWatchBridge>.fromOpaque(info).takeUnretainedValue()
    let list = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
    bridge.deliver(list, (0..<count).map { flags[$0] })
}
