import CryptoKit
import Darwin
import Foundation

/// An immutable formatted snapshot. Text lives in an unlinked private file,
/// so a long conversation does not become a second in-memory history. Readers
/// use positional I/O; concurrent searches and pages never share a file cursor.
final class RetainedContent: @unchecked Sendable {
    struct Key: Equatable {
        let generation: UInt64
        let revision: String
    }
    struct Row {
        let id: String, offset: UInt64, length: Int
    }
    let key: Key, digest: String
    private let file: FileHandle, rows: [Row]
    var count: Int { rows.count }
    private init(key: Key, digest: String, file: FileHandle, rows: [Row]) {
        self.key = key; self.digest = digest; self.file = file; self.rows = rows
    }
    deinit { try? file.close() }

    static func build(key: Key, older: OlderRows?, visible: [ChatMessage], url: URL?,
                      cancellation: BlockingWorkCancellation, step: (@Sendable (String) -> Void)?) throws -> RetainedContent {
        let journal = try url.map { try FileHandle(forReadingFrom: $0) }
        defer { try? journal?.close() }
        var shown = ShownRows(older: older, base: 0, visible: visible, history: [], descriptor: journal?.fileDescriptor)
        shown.cancellation = cancellation
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("bello-content-\(UUID().uuidString)").path
        let descriptor = Darwin.open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw AgentError("content_read", "Cannot prepare retained conversation text") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard unlink(path) == 0 else { try? file.close(); throw AgentError("content_read", "Cannot secure retained conversation text") }
        var rows: [Row] = [], offset: UInt64 = 0, hash = SHA256()
        for start in stride(from: 0, to: shown.count, by: 128) {
            try cancellation.checkCancellation()
            let range = start..<min(shown.count, start + 128)
            try shown.prefetch(range)
            try autoreleasepool {
                for index in range {
                    step?("content"); try cancellation.checkCancellation()
                    let message = try shown.row(index), text = message.retainedConversationText, bytes = Data(text.utf8)
                    for value in [message.id, text] {
                        hash.update(data: Data("\(value.utf8.count):".utf8)); hash.update(data: Data(value.utf8))
                    }
                    try file.write(contentsOf: bytes)
                    rows.append(Row(id: message.id, offset: offset, length: bytes.count)); offset += UInt64(bytes.count)
                }
            }
            shown.forget()
        }
        try cancellation.checkCancellation()
        return RetainedContent(key: key, digest: hash.finalize().map { String(format: "%02x", $0) }.joined(), file: file, rows: rows)
    }

    private func text(_ index: Int, cancellation: BlockingWorkCancellation) throws -> String {
        let row = rows[index]
        var bytes = Data(count: row.length), read = 0
        try bytes.withUnsafeMutableBytes { buffer in
            while read < row.length {
                try cancellation.checkCancellation()
                let count = pread(file.fileDescriptor, buffer.baseAddress!.advanced(by: read), row.length - read, off_t(row.offset) + off_t(read))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw AgentError("content_read", "Cannot read retained conversation text") }
                read += count
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
    func search(query: String, start: Int, cancellation: BlockingWorkCancellation) throws -> JSON {
        var hits: [JSON] = [], cursor = min(start, count)
        while cursor < count && hits.count < 100 {
            try cancellation.checkCancellation()
            try autoreleasepool {
                let text = try text(cursor, cancellation: cancellation)
                if query.isEmpty || text.range(of: query, options: [.caseInsensitive]) != nil {
                    var occurrences = 0, from = text.startIndex
                    if !query.isEmpty {
                        while let found = text.range(of: query, options: [.caseInsensitive], range: from..<text.endIndex) {
                            occurrences += 1; from = found.upperBound
                        }
                    }
                    hits.append(["id": JSON(rows[cursor].id), "position": JSON(cursor + 1), "preview": JSON(preview(text, bytes: 240)), "count": JSON(occurrences)])
                }
            }
            cursor += 1
        }
        return ["hits": .array(hits), "total": JSON(count), "next": cursor < count ? JSON(cursor) : .null]
    }
    func page(first: Int, last: Int, index: Int, offset: Int, cancellation: BlockingWorkCancellation) throws -> JSON {
        guard first >= 1, last >= first, last <= count, index >= first, index <= last else { throw AgentError("invalid_range", "Invalid history range") }
        let page = try textPage(text(index - 1, cancellation: cancellation), offset: offset)
        return ["text": page["text"], "next": page["next"].isNull ? (index < last ? ["index": JSON(index + 1), "offset": 0] : .null) : ["index": JSON(index), "offset": page["next"]]]
    }
}
