import Foundation
import Darwin

/// The file's vnode catches in-place writes; its folder catches atomic
/// saves, deletion and recreation. Descriptors are opened off the UI actor.
@MainActor final class FileWatch {
    private final class Sources: @unchecked Sendable {
        let values: [DispatchSourceFileSystemObject]
        init(_ values: [DispatchSourceFileSystemObject]) { self.values = values }
        func cancel() { values.forEach { $0.cancel() } }
        deinit { cancel() }
    }
    let url: URL
    private let changed: () -> Void
    private var sources: Sources?
    private var opening: Task<Void, Never>?
    private var trailing: Task<Void, Never>?
    private var token = 0
    private(set) var isWatching = false
    var isArmed: Bool { sources != nil }
    init(url: URL, changed: @escaping () -> Void) { self.url = url; self.changed = changed }

    func start() {
        guard !isWatching else { return }
        isWatching = true
        arm()
    }
    func stop() {
        isWatching = false; token &+= 1
        opening?.cancel(); opening = nil
        trailing?.cancel(); trailing = nil
        sources?.cancel(); sources = nil
    }
    private func arm() {
        token &+= 1
        let token = token, url = url
        opening?.cancel()
        let notify: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                guard let self, self.isWatching, self.token == token else { return }
                self.event()
            }
        }
        opening = Task { [weak self] in
            let created = await Task.detached(priority: .utility) {
                let queue = DispatchQueue(label: "BelloAgent.file.watch", qos: .utility)
                let paths = [url.path, url.deletingLastPathComponent().path, url.deletingLastPathComponent().deletingLastPathComponent().path]
                var sources: [DispatchSourceFileSystemObject] = []
                for path in Set(paths) {
                    let descriptor = open(path, O_EVTONLY | O_CLOEXEC)
                    guard descriptor >= 0 else { continue }
                    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                        eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke], queue: queue)
                    source.setEventHandler(handler: notify)
                    source.setCancelHandler { Darwin.close(descriptor) }
                    source.resume(); sources.append(source)
                }
                return Sources(sources)
            }.value
            guard let self, !Task.isCancelled, self.isWatching, self.token == token else { created.cancel(); return }
            self.sources?.cancel(); self.sources = created
            self.opening = nil
            // A second save may have landed while descriptors were rearmed.
            self.changed()
        }
    }
    private func event() {
        trailing?.cancel()
        trailing = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard let self, self.isWatching else { return }
            self.changed()
            self.arm()
            self.trailing = nil
        }
    }
}
