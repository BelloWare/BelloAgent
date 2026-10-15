import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Rebuildable locators, never accounting authority. A cold process verifies
/// the two named records; an unchanged file can then reuse its validated origin.
/// No transcript content or parent identity is persisted in this cache.
enum SideOriginIndex {
    struct Stamp: Codable, Equatable {
        var device: UInt64, inode: UInt64, size: Int64
        var modified: Int64, modifiedNanos: Int64, changed: Int64, changedNanos: Int64
        init(_ info: stat) {
            device = UInt64(info.st_dev); inode = UInt64(info.st_ino); size = Int64(info.st_size)
            #if canImport(Darwin)
            modified = Int64(info.st_mtimespec.tv_sec); modifiedNanos = Int64(info.st_mtimespec.tv_nsec)
            changed = Int64(info.st_ctimespec.tv_sec); changedNanos = Int64(info.st_ctimespec.tv_nsec)
            #else
            modified = Int64(info.st_mtim.tv_sec); modifiedNanos = Int64(info.st_mtim.tv_nsec)
            changed = Int64(info.st_ctim.tv_sec); changedNanos = Int64(info.st_ctim.tv_nsec)
            #endif
        }
    }
    private struct Locator: Codable {
        var stamp: Stamp
        var header: JournalCheckpoint.Check
        var origin: JournalCheckpoint.Check
    }
    private struct Entry { var stamp: Stamp; var origin: SideBudgetRecovery.Origin? }
    private static let lock = NSLock()
    private static var entries: [String:Entry] = [:]
    static func url(for file: URL) -> URL { URL(fileURLWithPath:file.path + ".origin") }
    static func resetMemory() { lock.lock(); entries.removeAll(); lock.unlock() }

    static func read(_ file: URL) throws -> SideBudgetRecovery.Origin? {
        let fd = open(file.path,O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw AgentError("file_unavailable","Cannot read saved side origin") }
        let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        defer { try? handle.close() }
        func stamp() throws -> Stamp {
            var info = stat()
            guard fstat(fd,&info) == 0, info.st_size >= 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw AgentError("not_regular_file","Only regular journals have saved side origins")
            }
            return Stamp(info)
        }
        let before = try stamp()
        lock.lock(); let cached = entries[file.path]; lock.unlock()
        if let cached, cached.stamp == before { return cached.origin }
        func decode(_ bytes: Data) throws -> JSON {
            #if DEBUG
            SideOriginReadProbe.record(file,decoded:1)
            #endif
            return try JSON.parse(bytes)
        }
        func readBytes(_ offset: UInt64, _ count: Int) throws -> Data {
            try handle.seek(toOffset:offset)
            let bytes = try handle.read(upToCount:count) ?? Data()
            #if DEBUG
            SideOriginReadProbe.record(file,bytes:bytes.count)
            #endif
            return bytes
        }
        func check(_ value: JournalCheckpoint.Check) throws -> Data? {
            guard value.length > 0, value.length <= JournalRecordReader.maximumRecordBytes,
                  value.offset <= UInt64(before.size), UInt64(value.length + 1) <= UInt64(before.size) - value.offset else { return nil }
            let bytes = try readBytes(value.offset,value.length + 1)
            guard bytes.last == 10, JournalCheckpoint.digest(Data(bytes.dropLast())) == value.sha256 else { return nil }
            return Data(bytes.dropLast())
        }
        func origin(_ header: JSON, _ row: JSON) throws -> SideBudgetRecovery.Origin? {
            guard header["type"].text == "session", let id = header["id"].text,
                  file.lastPathComponent == "side_" + id + ".jsonl",
                  row["type"].text == "custom", row["customType"].text == JournalRecordKind.sideOrigin,
                  row["data"]["relationship"].text != "fork", let parent = row["data"]["parentSessionId"].text else { return nil }
            return try .init(id:identity(JSON(id)),parent:identity(JSON(parent)),file:file)
        }
        func remember(_ result: SideBudgetRecovery.Origin?) throws -> SideBudgetRecovery.Origin? {
            guard try stamp() == before else { throw AgentError("session_damaged","Saved side changed during origin discovery") }
            lock.lock()
            if entries.count >= 4096 { entries.removeAll(keepingCapacity:true) }
            entries[file.path] = Entry(stamp:before,origin:result); lock.unlock()
            return result
        }
        // A locator is an offset hint only. Even with the same stamp, validate
        // its bytes and current identities before accepting a disk cache.
        if let data = locatorBytes(for:file),
           var locator = try? JSONDecoder().decode(Locator.self,from:data),
           locator.stamp.device == before.device, locator.stamp.inode == before.inode,
           let header = try check(locator.header), let row = try check(locator.origin),
           let result = try origin(decode(header),decode(row)) {
            // Appends invalidate the cached value, but the old offsets can
            // still locate unchanged records. Revalidate both hashes/identities
            // before storing the new stamp; replacements never reuse hints.
            let validated = try remember(result)
            if locator.stamp != before {
                locator.stamp = before
                try? JSONEncoder().encode(locator).write(to:url(for:file),options:.atomic)
            }
            return validated
        }

        // The origin of older kept sides follows the entire inherited history.
        // Start at the tail, skipping raw message records rather than decoding
        // them. This one-time legacy discovery writes a bounded cold locator.
        let headerBytes = try readBytes(0,16384)
        guard let newline = headerBytes.firstIndex(of:10) else { return try remember(nil) }
        let headerLine = Data(headerBytes[..<newline]), header = try decode(headerLine)
        var position = UInt64(before.size), fragments: [Data] = [], pendingBytes = 0, ignoreTail = true
        while position > 0 {
            let start = position > 32768 ? position - 32768 : 0
            let block = try readBytes(start,Int(position - start))
            var end = block.count, cursor = 0, newlines: [Int] = []
            while let newline = JournalRecordReader.newline(in:block,from:cursor) { newlines.append(newline); cursor = newline + 1 }
            // A partial final row belongs to ordinary damaged-history recovery,
            // not discovery. A complete earlier origin remains discoverable.
            for index in newlines.reversed() {
                var line = Data(block[(index + 1)..<end])
                let oversized = line.count + pendingBytes > JournalRecordReader.maximumRecordBytes
                if !oversized { for fragment in fragments.reversed() { line.append(fragment) } }
                fragments.removeAll(keepingCapacity:true); pendingBytes = 0
                if !oversized, !ignoreTail, !line.isEmpty {
                    let fields = JournalLineScan.fields(line)
                    if fields?.customType == JournalRecordKind.sideOrigin || fields == nil {
                        if let row = try? decode(line), let result = try origin(header,row) {
                            let locator = Locator(stamp:before,
                                header:.init(offset:0,length:headerLine.count,sha256:JournalCheckpoint.digest(headerLine)),
                                origin:.init(offset:start + UInt64(index + 1),length:line.count,sha256:JournalCheckpoint.digest(line)))
                            let validated = try remember(result)
                            // Cache loss/write failure never changes journal authority.
                            try? JSONEncoder().encode(locator).write(to:url(for:file),options:.atomic)
                            return validated
                        }
                    }
                }
                ignoreTail = false; end = index
            }
            if end > 0 {
                pendingBytes += end
                if pendingBytes <= JournalRecordReader.maximumRecordBytes { fragments.append(Data(block[..<end])) }
                else { fragments.removeAll(keepingCapacity:true) }
            }
            position = start
        }
        return try remember(nil)
    }

    private static func locatorBytes(for file: URL) -> Data? {
        let fd = open(url(for:file).path,O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:true); defer { try? handle.close() }
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size > 0, info.st_size <= 4096 else { return nil }
        return try? handle.read(upToCount:4096)
    }
}
