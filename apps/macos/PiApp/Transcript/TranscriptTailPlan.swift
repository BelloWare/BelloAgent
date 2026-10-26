import Foundation

/// The unchanged prefix of a plan survives a new reply or part. Replan from
/// the affected display turn, including any task whose summary needs that
/// turn's earlier rows. History replacement retains the complete planner.
struct TranscriptTailPlan {
    struct Replacement {
        var source: Int
        var item: Int
        var items: [TranscriptItem]
    }
    private struct Turn { var source: Int; var item: Int }
    private var sources: [String: Int] = [:]
    private var items: [String: Int] = [:]
    private var owners: [String: Int] = [:]
    private var ledgers: [String: [Int]] = [:]
    private var turns: [Turn] = []

    init(_ messages: [TranscriptMessage], items: [TranscriptItem]) { add(messages, items: items, source: 0, item: 0) }
    func position(of id: String) -> Int? { sources[id] }

    private func turn(at index: Int) -> Int? {
        var low = 0, high = turns.count
        while low < high {
            let middle = (low + high) / 2
            if turns[middle].source <= index { low = middle + 1 } else { high = middle }
        }
        return low > 0 ? low - 1 : nil
    }
    func replacing(_ previous: TranscriptPage.Snapshot, with input: TranscriptPresentationInput, complete: Bool) -> Replacement? {
        let changed = input.changes?.indices(since: previous.messageChanges)
        let tail = input.changes?.tailStart(since: previous.messageChanges)
        guard changed != nil || tail != nil,
              previous.lifecycle?.epoch == input.lifecycle?.epoch, previous.lifecycle?.timeline == input.lifecycle?.timeline else { return nil }
        var start = min(changed?.min() ?? Int.max, tail ?? Int.max)
        if start == Int.max { start = turns.last?.source ?? 0 }
        let before = (previous.lifecycle?.recent ?? []) + (previous.lifecycle?.active.map { [$0] } ?? [])
        let after = (input.lifecycle?.recent ?? []) + (input.lifecycle?.active.map { [$0] } ?? [])
        let old = Dictionary(before.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        let new = Dictionary(after.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        for record in before + after where old[record.key] != new[record.key] {
            let positions = [record.rootID, record.anchorSourceID, record.lastSourceID].compactMap { $0.flatMap { sources[$0] } }
            if !positions.isEmpty { start = min(start, sources[record.rootID] ?? 0) }
        }
        // A live bar and a task footer read all of their execution's rows,
        // even when a steer gave that execution another display turn.
        var extended = true
        while extended {
            let original = start
            for record in before + after {
                let touches = record.key == previous.lifecycle?.active?.key || record.key == input.lifecycle?.active?.key ||
                    [record.rootID, record.anchorSourceID, record.lastSourceID].compactMap { $0.flatMap { sources[$0] } }.contains { $0 >= start }
                if touches, let root = sources[record.rootID] { start = min(start, root) }
                else if touches { start = 0 }
            }
            for message in previous.messages.dropFirst(min(start, previous.messages.count)) + input.messages.dropFirst(min(start, input.messages.count)) {
                if let root = message.taskRootID ?? message.turn {
                    if let position = sources[root] { start = min(start, position) }
                    else if (before + after).contains(where: { $0.rootID == root }) { start = 0 }
                }
                if let ledger = ledgers[message.id]?.first { start = min(start, ledger) }
            }
            extended = start < original
        }
        let boundary = turn(at: start).map { turns[$0] } ?? Turn(source: 0, item: 0)
        start = boundary.source
        guard start <= min(previous.messages.count, input.messages.count), boundary.item <= previous.items.count else { return nil }
        // A split source or result whose issuer is before the boundary needs
        // the complete pairing context. Ordinary replies stay within a turn.
        var calls = Set<String>()
        for message in previous.messages.dropFirst(start) {
            if let owner = owners[message.id], owner < boundary.item { return nil }
            if let call = message.toolCallID, owners[message.id] == nil, !calls.contains(call) { return nil }
            if message.role == "assistant" || message.kind == "requestLedger" { calls.formUnion((message.tools ?? []).map(\.id)) }
        }
        let suffix = Array(input.messages.dropFirst(start))
        guard Set(suffix.map(\.id)).count == suffix.count,
              suffix.allSatisfy({ sources[$0.id].map { $0 >= start } ?? true }) else { return nil }
        let next = TranscriptActivity.blocks(of: suffix, lifecycle: input.lifecycle, complete: complete)
        guard Set(next.map(\.id)).count == next.count,
              next.allSatisfy({ items[$0.id].map { $0 >= boundary.item } ?? true }),
              next.flatMap(\.messageIDs).allSatisfy({ sources[$0].map { $0 >= start } ?? true }) else { return nil }
        var result = previous.items
        result.replaceSubrange(boundary.item..., with: next)
        return Replacement(source: start, item: boundary.item, items: result)
    }
    mutating func replace(_ previous: TranscriptPage.Snapshot, messages: [TranscriptMessage], replacement: Replacement) {
        for message in previous.messages.dropFirst(replacement.source) {
            sources[message.id] = nil
            if let target = message.presentationSourceID {
                ledgers[target]?.removeAll { $0 >= replacement.source }
                if ledgers[target]?.isEmpty == true { ledgers[target] = nil }
            }
        }
        for item in previous.items.dropFirst(replacement.item) {
            items[item.id] = nil
            for source in item.messageIDs where owners[source].map({ $0 >= replacement.item }) == true { owners[source] = nil }
        }
        let first = turn(at: replacement.source).map { turns[$0].source == replacement.source ? $0 : $0 + 1 } ?? 0
        turns.removeSubrange(first...)
        add(messages, items: replacement.items, source: replacement.source, item: replacement.item)
    }
    private mutating func add(_ messages: [TranscriptMessage], items next: [TranscriptItem], source: Int, item: Int) {
        for index in item..<next.count {
            items[next[index].id] = index
            for id in next[index].messageIDs where owners[id] == nil { owners[id] = index }
        }
        for index in source..<messages.count {
            let message = messages[index]
            sources[message.id] = index
            if message.kind == "requestLedger", let target = message.presentationSourceID { ledgers[target, default: []].append(index) }
            if TranscriptPaging.startsTurn(message), let row = items[TranscriptRenderIdentity.message(message.id).key] { turns.append(Turn(source: index, item: row)) }
        }
    }
}
