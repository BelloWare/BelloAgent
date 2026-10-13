import Foundation

extension HistoryReader {
    /// Acceptance is monotonic, unlike the current branch or the bounded
    /// receipt list. Read the entire journal only when an unacknowledged app
    /// intent needs reconciling; an old user row or receipt still proves the
    /// helper took it, even if that turn is no longer on the current branch.
    func acceptedCommands(in path: String, intents: [CommandIntent], missingIsEmpty: Bool = false) throws -> Set<String> {
        guard !intents.isEmpty else { return [] }
        let file: FileHandle
        do { file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)) }
        catch let error as CocoaError where missingIsEmpty && (error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile) { return [] }
        defer { try? file.close() }
        var accepted: Set<String> = [], pending = Data()
        acceptanceScannedBytes = 0
        let commands = Set(intents.map(\.id)), turns = Dictionary(intents.map { ($0.turnID, $0.id) }, uniquingKeysWith: { first, _ in first })
        func read(_ line: Data) throws {
            let row = try JSONDecoder().decode(AcceptanceRecord.self, from: line)
            if row.type == "message", row.message?.role == "user", let turn = row.id, let command = turns[turn] { accepted.insert(command) }
            for state in [row.data, row.nativeState].compactMap({ $0 }) {
                for receipt in state.commands ?? [] where commands.contains(receipt.commandId) { accepted.insert(receipt.commandId) }
                for item in (state.queue ?? []) + (state.steering ?? []) + (state.delivering.map { [$0.submission] } ?? []) {
                    if let command = item.commandID, commands.contains(command) { accepted.insert(command) }
                    if let turn = item.turnID, let command = turns[turn] { accepted.insert(command) }
                }
            }
        }
        while let bytes = try file.read(upToCount: 65_536), !bytes.isEmpty {
            try Task.checkCancellation()
            // Search only the new chunk. An image-bearing row can span
            // hundreds of reads; searching its accumulated prefix is quadratic.
            var start = bytes.startIndex
            while let newline = bytes[start...].firstIndex(of: 10) {
                acceptanceScannedBytes += newline - start + 1
                pending.append(bytes[start..<newline]); start = newline + 1
                guard pending.count <= 33_554_432 else { throw StoreError.unreadableRecord }
                if !pending.isEmpty { try read(pending) }
                pending.removeAll(keepingCapacity: true)
                if accepted == commands { return accepted }
            }
            acceptanceScannedBytes += bytes.endIndex - start
            pending.append(bytes[start...])
            // The same read-safety limit as HistoryReader's page scanner.
            // Nothing is truncated or offered for recovery on a read failure.
            guard pending.count <= 33_554_432 else { throw StoreError.unreadableRecord }
        }
        // A trailing partial write cannot prove a durable acceptance.
        return accepted
    }
}

private struct AcceptanceRecord: Decodable {
    struct Message: Decodable { var role: String? }
    struct Receipt: Decodable { var commandId: String }
    struct Pending: Decodable { var commandID: String?; var turnID: String? }
    struct Delivery: Decodable { var submission: Pending }
    struct State: Decodable { var commands: [Receipt]?; var queue: [Pending]?; var steering: [Pending]?; var delivering: Delivery? }
    var type: String?; var id: String?; var message: Message?; var data: State?; var nativeState: State?
    private enum CodingKeys: String, CodingKey { case type, id, message, data, nativeState, customType }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decodeIfPresent(String.self, forKey: .type); id = try values.decodeIfPresent(String.self, forKey: .id)
        if type == "message" { message = try values.decodeIfPresent(Message.self, forKey: .message) }
        if try values.decodeIfPresent(String.self, forKey: .customType) == StateRecordTail.customType { data = try values.decodeIfPresent(State.self, forKey: .data) }
        nativeState = try values.decodeIfPresent(State.self, forKey: .nativeState)
    }
}
