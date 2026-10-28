import Foundation

/// A helper delta applied to the resident window off the main actor. The
/// source revision and accounting figures must still stand when it lands.
struct TranscriptStreamUpdate: Sendable {
    var revision: UUID
    var accountingRevision: Int
    var rows: [TranscriptMessage]
    var indices: [Int]
    var held: Set<String>?
    var tail: Int? = nil

    static func prepare(delta: WireValue, projected: [TranscriptMessage], displayed: [TranscriptMessage],
                        positions: [String: Int], bytes: Int, revision: UUID, accounting: [String: GatewayTotals],
                        accountingRevision: Int, caps: (rows: Int, bytes: Int), held: Set<String> = [], follows: String? = nil) -> Self? {
        // A later held turn no longer needs this prefix. Let ordinary
        // reconciliation cut the released turns before retaining its rows.
        let firstHeld = held.compactMap { positions[$0] }.min()
        let extended = (displayed.count > caps.rows || bytes > caps.bytes)
            && firstHeld.map { TranscriptPaging.turnStart($0, in: displayed) == 0 } == true
        guard let fields = delta.object, displayed.count <= caps.rows || extended else { return nil }
        var ids = Set<String>()
        for key in ["rows", "appends", "parts", "toolInputs"] {
            for entry in fields[key]?.array ?? [] {
                guard let id = entry.object?["id"]?.string else { return nil }
                ids.insert(id)
            }
        }
        if fields["order"] != nil || ids.contains(where: { positions[$0] == nil }) {
            guard let first = projected.first,
                  let cut = positions[first.id] ?? (follows != nil && displayed.last?.id == follows ? displayed.count : nil),
                  Set(projected.map(\.id)).count == projected.count,
                  projected.allSatisfy({ positions[$0.id].map { $0 >= cut } ?? true }) else { return nil }
            let tail = projected.map { source in var row = source; row.accounting = accounting[row.id]; return row }
            let size = bytes - displayed.dropFirst(cut).reduce(0) { $0 + TranscriptPaging.size($1) } + tail.reduce(0) { $0 + TranscriptPaging.size($1) }
            guard cut + tail.count <= caps.rows || extended, size <= caps.bytes || cut + tail.count <= 1 || extended else { return nil }
            return Self(revision: revision, accountingRevision: accountingRevision, rows: Array(displayed.prefix(cut)) + tail,
                        indices: [], held: extended ? held : nil, tail: cut)
        }
        var next = displayed, changed: [Int] = [], size = bytes
        for id in ids {
            guard let index = positions[id], displayed.indices.contains(index), displayed[index].id == id,
                  var row = projected.first(where: { $0.id == id }) else { return nil }
            row.accounting = accounting[id]
            size += TranscriptPaging.size(row) - TranscriptPaging.size(displayed[index])
            next[index] = row; changed.append(index)
        }
        guard size <= caps.bytes || displayed.count <= 1 || extended else { return nil }
        return Self(revision: revision, accountingRevision: accountingRevision, rows: next, indices: changed.sorted(), held: extended ? held : nil)
    }
}
