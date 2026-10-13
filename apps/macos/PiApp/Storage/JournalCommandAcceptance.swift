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
            pending.append(bytes)
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
                guard line.count <= 33_554_432 else { throw StoreError.unreadableRecord }
                if !line.isEmpty { try read(line) }
                if accepted == commands { return accepted }
            }
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
