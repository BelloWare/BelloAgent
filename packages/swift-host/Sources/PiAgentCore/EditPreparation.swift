import Foundation
import Darwin

/// A retained edit needs the selected identities, replay metadata and the
/// original input, not every reply's text/provider bodies. Feed the ordinary
/// journal reducer metadata-only message records, retaining their real offsets
/// for the one input read. Branches, checkpoints and validation use the same
/// reducer and planner as a full replay. Appends take this index on from its end.
struct EditPreparationIndex: Sendable {
    let source: JournalSource
    private var consumer: JournalReplayConsumer
    private(set) var covered: UInt64 = 0
    private var stamp = ""
    private(set) var spans: [String: JournalCheckpoint.Row] = [:]
    private(set) var replay = JournalReplay()

    private init(source: JournalSource, id: String) {
        self.source = source
        consumer = JournalReplayConsumer(id: id, header: nil, marker: nil, spendTracked: false)
    }

    func openSource(_ url: URL) throws -> FileHandle {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw AgentError("edit_changed", "The edit's source journal is unavailable") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              UInt64(value.st_dev) == source.device, UInt64(value.st_ino) == source.inode,
              value.st_size >= 0, UInt64(value.st_size) >= covered else {
            try? file.close(); throw AgentError("edit_changed", "The edit's source journal changed")
        }
        return file
    }

    private static func stamp(_ url: URL) throws -> String {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw AgentError("session_damaged", "The edit's source journal is unavailable") }
        return "\(value.st_dev):\(value.st_ino):\(value.st_size):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)"
    }

    static func read(url: URL, source: JournalSource, size: UInt64, id: String, previous: Self?) throws -> Self {
        let stamp = try stamp(url)
        var index: Self
        if let previous, previous.source == source, previous.covered <= size,
           previous.covered < size || previous.stamp == stamp { index = previous }
        else { index = Self(source: source, id: id) }
        let reader = try JournalRecordReader(url, startingAt: index.covered)
        guard reader.device == source.device, reader.inode == source.inode, reader.size >= size else { throw AgentError("edit_changed", "The edit's source journal changed") }
        if index.covered == size { return index }
        while reader.completeBytes < size {
            try Task.checkCancellation()
            let offset = reader.completeBytes
            guard let line = try reader.nextLine(), reader.completeBytes <= size else { throw AgentError("edit_changed", "The edit's source journal changed") }
            if line.isEmpty { continue }
            if line.starts(with: JournalLineScan.statePrefix) {
                try index.consumer.consume(line, at: offset)
            } else {
                let record = try? JSONDecoder().decode(Record.self, from: line)
                var reduced: JSON?, rowID: String?, kind = JournalCheckpoint.Row.Kind.message
                if let record, let message = record.message {
                    if record.type == "message", record.customType == nil, !message.full {
                        reduced = ["type":"message", "id":record.id, "message":message.metadata]; rowID = record.id.text
                    } else if record.update {
                        reduced = ["type":"custom", "customType":JSON(JournalRecordKind.presentationUpdate), "id":record.id,
                                   "data":["id":record.target], "message":message.metadata]
                        rowID = record.target.text; kind = .update
                    }
                }
                if let reduced {
                    // Decoding only requested keys need not convert unknown
                    // numbers or strings. Keep the full parser's acceptance
                    // rules for every skipped value too.
                    if !JSONSyntax.checked(line) { _ = try JSON.parse(line) }
                    try index.consumer.consume(try reduced.data(), at: offset)
                    if let id = rowID, index.consumer.r.rowSpans[id]?.offset == offset {
                        index.spans[id] = .init(id: id, kind: kind, offset: offset, length: line.count)
                    }
                } else {
                    try index.consumer.consume(line, at: offset)
                    if let record, record.type == "message", let id = record.id.text,
                       let span = index.consumer.r.rowSpans[id], span.offset == offset {
                        index.spans[id] = span
                    }
                }
            }
        }
        let current = try JournalRecordReader(url)
        let currentStamp = try Self.stamp(url)
        guard current.device == source.device, current.inode == source.inode, current.size >= size,
              current.size > size || currentStamp == stamp else { throw AgentError("edit_changed", "The edit's source journal changed") }
        index.covered = reader.completeBytes; index.stamp = currentStamp
        index.replay = try index.consumer.finished()
        return index
    }

    private struct Record: Decodable {
        let type: String?
        let customType: String?
        let id: JSON
        let target: JSON
        let message: Message?
        var update: Bool { type != "message" && customType == JournalRecordKind.presentationUpdate }
        private struct Target: Decodable { var id: JSON }
        private enum CodingKeys: String, CodingKey { case type, customType, id, data, message }
        init(from decoder: Decoder) throws {
            let value = try decoder.container(keyedBy: CodingKeys.self)
            type = try? value.decode(String.self, forKey: .type)
            customType = try? value.decode(String.self, forKey: .customType)
            id = (try? value.decode(JSON.self, forKey: .id)) ?? .null
            let update = type != "message" && customType == JournalRecordKind.presentationUpdate
            target = update ? (try? value.decode(Target.self, forKey: .data).id) ?? .null : .null
            message = type == "message" || update ? try value.decode(Message.self, forKey: .message) : nil
        }
    }
    private struct Message: Decodable {
        let metadata: JSON
        let full: Bool
        private enum CodingKeys: String, CodingKey, CaseIterable {
            case role, toolCallId, nativeReplayEligible, nativeKind, nativeCompaction, nativeSubagent, nativeAgentDelivery, content
            case nativeOperationID, nativeRequestAttemptIds
        }
        private struct Block: Decodable {
            var metadata: JSON = [:]
            private enum CodingKeys: String, CodingKey { case type, id }
            init(from decoder: Decoder) throws {
                guard let value = try? decoder.container(keyedBy: CodingKeys.self) else { return }
                for key in [CodingKeys.type, .id] {
                    // The full parser tolerates non-string block fields; keep
                    // their exact value for its ordinary group validation.
                    if let field = try value.decodeIfPresent(JSON.self, forKey: key) { metadata[key.rawValue] = field }
                }
            }
        }
        init(from decoder: Decoder) throws {
            let value = try decoder.container(keyedBy: CodingKeys.self)
            var metadata: JSON = [:]
            for key in CodingKeys.allCases where key != .content {
                if let field = try value.decodeIfPresent(JSON.self, forKey: key) { metadata[key.rawValue] = field }
            }
            // Family delivery validation hashes the original content, so
            // those messages must retain the ordinary complete read.
            full = !metadata["nativeAgentDelivery"].isNull
            let blocks = (try? value.decode([Block].self, forKey: .content)) ?? []
            metadata["content"] = .array(blocks.map(\.metadata))
            self.metadata = metadata
        }
    }
}

extension AgentSession {
    func editSource(_ messageID: String) async throws -> (plan: HistoricalEditPlan, message: ChatMessage) {
        if !partialHistory {
            let plan = try Self.planEdit(messageID, history: history, visible: visible, context: context)
            guard let message = history.first(where: { $0.id == messageID }) else { throw AgentError("edit_target", "The message is not retained.") }
            return (plan, message)
        }
        try await loadEditIndex()
        guard let index = editPreparationIndex, let url = journal?.url else { throw AgentError.sessionClosed }
        // As fullHistory does, keep the loaded rows' live metadata. The
        // model context belongs to the current run, not to a durable replay.
        let live = Dictionary(history.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let history = index.replay.history.map { live[$0.id] ?? $0 }, visible = index.replay.visible.map { live[$0.id] ?? $0 }
        let plan = try Self.planEdit(messageID, history: history, visible: visible, context: context)
        if let message = live[messageID] { return (plan, message) }
        guard let span = index.spans[messageID] else { throw AgentError("edit_target", "The message is not retained.") }
        let file = try index.openSource(url)
        defer { try? file.close() }
        guard let message = Self.journalRow(span, in: file) else { throw AgentError("edit_target", "The original input could not be read.") }
        return (plan, message)
    }

    private func loadEditIndex() async throws {
        try throwIfClosed(); try Task.checkCancellation()
        let reader: @Sendable () async throws -> Void
        if let joined = editPreparationLoad?.reader() { historyLoadJoins += 1; reader = joined }
        else {
            let load = SharedHistoryLoad()
            guard let waiting = load.reader() else { throw CancellationError() }
            reader = waiting; editPreparationLoad = load
            load.start(Task {
                do { try await self.scanEditIndex(); load.finish(.success(())) }
                catch { load.finish(.failure(error)) }
                if self.editPreparationLoad === load { self.editPreparationLoad = nil }
            })
        }
        do { try await reader() } catch { try throwIfClosed(); throw error }
        try throwIfClosed()
    }

    private func scanEditIndex() async throws {
        guard let journal, let source = JournalSource(journal) else { throw AgentError.sessionClosed }
        let url = journal.url, size = journal.size, head = journal.head, id = self.id, previous = editPreparationIndex, hold = historyFillHold
        let made = await Self.offActor(priority: .userInitiated) { () -> Result<EditPreparationIndex, Error> in
            if let hold { await hold("edit") }
            return Result { try EditPreparationIndex.read(url: url, source: source, size: size, id: id, previous: previous) }
        }
        try throwIfClosed(); try Task.checkCancellation()
        let index = try made.get()
        // A run may have appended during the scan. Keep the validated prefix
        // for a retry, but never return an edit from a superseded head.
        if self.journal.flatMap(JournalSource.init) == source { editPreparationIndex = index }
        guard self.journal?.head == head, self.journal.flatMap(JournalSource.init) == source else { throw AgentError("edit_changed", "The conversation changed during edit preparation. Select the message again.") }
    }
}
