import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A bounded JSONL cursor, not a bound on a conversation's lifetime. Only one
/// record and one read buffer are resident, including when reopening or copying
/// a journal larger than memory. The caller owns the cursor on its actor.
final class JournalRecordReader {
    static let maximumRecordBytes = 32 * 1024 * 1024
    private static let newline = Data([10])
    private let file: FileHandle
    let size: UInt64
    private let allowIncompleteTail: Bool
    private let chunkBytes: Int
    private var buffer = Data(), cursor = 0, bytesRead: UInt64 = 0
    private var finished = false
    private var hasher: StreamingSHA256?
    private(set) var digest: String?
    private(set) var completeBytes: UInt64 = 0
    private(set) var rawLine = Data()
    var omittedBytes: UInt64 { size - completeBytes }

    init(_ url: URL, expectedBytes: UInt64? = nil, allowIncompleteTail: Bool = false, hash: Bool = false, chunkBytes: Int = 64 * 1024) throws {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw AgentError("file_unavailable", "Cannot open \(url.path)") }
        file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size >= 0 else {
            throw AgentError("not_regular_file", "Only regular files can be read")
        }
        size = UInt64(info.st_size)
        guard expectedBytes == nil || expectedBytes == size else { throw Self.changed() }
        self.allowIncompleteTail = allowIncompleteTail
        hasher = hash ? StreamingSHA256() : nil
        self.chunkBytes = max(1, min(chunkBytes, 1024 * 1024))
    }

    func next() throws -> JSON? {
        while let line = try nextLine() {
            // Match the existing JSONL reader's tolerance of empty lines.
            if !line.isEmpty { return try JSON.parse(line) }
        }
        return nil
    }

    func nextLine() throws -> Data? {
        rawLine = Data()
        guard !finished else { return nil }
        var oversizedTail = false
        while true {
            if cursor < buffer.count {
                let end = buffer.range(of: Self.newline, in: cursor..<buffer.count)?.lowerBound
                let stop = end ?? buffer.count
                if oversizedTail || rawLine.count + stop - cursor > Self.maximumRecordBytes {
                    // Recovery omits an unfinished last record, however large;
                    // a newline makes it a complete oversized record and must
                    // still fail. Do not retain discarded tail bytes in memory.
                    guard allowIncompleteTail, end == nil else {
                        throw AgentError("session_damaged", "An individual journal record exceeds 32 MiB")
                    }
                    oversizedTail = true; rawLine = Data()
                } else {
                    rawLine.append(buffer[cursor..<stop])
                }
                cursor = stop
                if end != nil {
                    cursor += 1
                    completeBytes = bytesRead - UInt64(buffer.count - cursor)
                    return rawLine
                }
            }
            if bytesRead == size {
                var info = stat()
                guard fstat(file.fileDescriptor, &info) == 0, info.st_size >= 0, UInt64(info.st_size) == size else { throw Self.changed() }
                finished = true
                digest = hasher?.finalize(); hasher = nil
                guard rawLine.isEmpty || allowIncompleteTail else {
                    throw AgentError("session_damaged", "Incomplete journal tail preserved; recover a copy before continuing")
                }
                rawLine = Data(); buffer = Data()
                return nil
            }
            buffer = try file.read(upToCount: Int(min(UInt64(chunkBytes), size - bytesRead))) ?? Data()
            guard !buffer.isEmpty else { throw Self.changed() }
            hasher?.update(buffer)
            cursor = 0; bytesRead += UInt64(buffer.count)
        }
    }

    private static func changed() -> AgentError {
        AgentError("session_damaged", "The source journal changed while it was being read")
    }
    deinit { try? file.close() }
}
