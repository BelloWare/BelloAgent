import Darwin
import Foundation

/// The history index files (`HistoryOffsetIndex`) an app left in the
/// temporary folder: those of an app that crashed, a test host that ended,
/// and every index an earlier version held when it quit. Removed once at
/// launch, but only the ones no process holds: another copy of the app, of
/// any version, may be reading its own.
enum HistoryIndexFiles {
    struct FileIdentity: Hashable { var device: UInt64; var inode: UInt64 }

    /// Removes the index files in `directory` that no running process holds:
    /// none whose name carries the id of a running process, none any process
    /// has open, and none at all when what is open cannot be read. Returns
    /// the names removed.
    @discardableResult
    static func removeStale(in directory: URL = FileManager.default.temporaryDirectory,
                            openFiles: () -> Set<FileIdentity>? = HistoryIndexFiles.openFiles) -> [String] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix(HistoryOffsetIndex.filePrefix) && $0.hasSuffix(".sqlite") }
        guard !names.isEmpty, let held = openFiles() else { return [] }
        var removed: [String] = []
        for name in names {
            if let pid = owner(name), running(pid) { continue }
            let path = directory.appendingPathComponent(name).path
            var status = stat()
            guard lstat(path, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
                  !held.contains(FileIdentity(device: UInt64(UInt32(bitPattern: status.st_dev)), inode: status.st_ino)) else { continue }
            if unlink(path) == 0 { removed.append(name) }
        }
        return removed
    }

    /// The process that named the file: `bello-history-p<pid>-<uuid>.sqlite`.
    /// Files earlier versions named carry none.
    static func owner(_ name: String) -> pid_t? {
        let rest = name.dropFirst(HistoryOffsetIndex.filePrefix.count)
        guard rest.first == "p", let dash = rest.firstIndex(of: "-") else { return nil }
        return pid_t(rest[rest.index(after: rest.startIndex)..<dash])
    }
    static func running(_ pid: pid_t) -> Bool { pid > 0 && (kill(pid, 0) == 0 || errno == EPERM) }

    /// Every file a process this user can see has open, by device and inode;
    /// nil when the processes cannot be listed.
    static func openFiles() -> Set<FileIdentity>? {
        let capacity = Int(proc_listallpids(nil, 0))
        guard capacity > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: capacity + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride)))
        guard count > 0 else { return nil }
        var held = Set<FileIdentity>()
        for pid in pids.prefix(count) where pid > 0 {
            let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard bytes > 0 else { continue }
            var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride + 16)
            let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * MemoryLayout<proc_fdinfo>.stride))
            guard filled > 0 else { continue }
            for descriptor in descriptors.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var info = vnode_fdinfo()
                let size = Int32(MemoryLayout<vnode_fdinfo>.stride)
                guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEINFO, &info, size) == size else { continue }
                held.insert(FileIdentity(device: UInt64(info.pvi.vi_stat.vst_dev), inode: info.pvi.vi_stat.vst_ino))
            }
        }
        return held
    }
}
