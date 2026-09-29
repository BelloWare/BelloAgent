import Foundation

/// The receipts of the last 128 commands a chat accepted, one per turn: what
/// lets a command sent again after a crash be recognised instead of run twice,
/// and what the app reads each command's outcome from. They travel in the
/// chat's run-state records (`pi-app.native.state.v1`), written several times
/// a turn. Written whole every time, 128 receipts made those records most of a
/// long chat's journal, though one receipt had usually changed.
///
/// A record holds the whole list only now and then. In between, `commandsDelta`
/// marks a record whose `commands` are only the receipts added or changed
/// since the record before it; every other field is whole. A version that
/// reads `commands` as the whole list still has the queue and the run right,
/// and the newest receipts. `docs/Journal-Command-Receipts.md` has the format.
enum CommandReceipts {
    static let limit = 128
    /// A record holds the whole list after at most this many with changes
    /// only, so an open reads back a bounded run of them.
    static let wholeListEvery = 64
    static let deltaKey = "commandsDelta"
    /// A record with changes only, as its line shows it: the helper writes
    /// records with sorted keys and no spaces, and JSON text cannot hold this
    /// inside a string, where every quote is escaped.
    static let deltaMarker = Data(#""commandsDelta":true"#.utf8)

    /// `changes` in order: a receipt replaces the one for its turn, or joins
    /// the end, and the oldest go past the limit, as `commandState` does.
    static func apply(_ changes: [JSON], to base: [JSON]) -> [JSON] {
        var list = base
        for receipt in changes {
            if let turn = receipt["turnId"].text, let index = list.firstIndex(where: { $0["turnId"].text == turn }) { list[index] = receipt }
            else { list.append(receipt) }
        }
        if list.count > limit { list.removeFirst(list.count - limit) }
        return list
    }

    /// The receipts of `target` that `base` does not hold as they are, when
    /// they turn `base` into `target` exactly. nil when they would not (a
    /// receipt taken back, an order changed): the whole list is written then.
    static func changes(from base: [JSON], to target: [JSON]) -> [JSON]? {
        var held: [String: JSON] = [:]
        for receipt in base { if let turn = receipt["turnId"].text, held[turn] == nil { held[turn] = receipt } }
        let changes = target.filter { receipt in receipt["turnId"].text.map { held[$0] != receipt } ?? true }
        return apply(changes, to: base) == target ? changes : nil
    }

    /// Whether a run-state record's line holds changes only.
    static func holdsChanges(_ line: Data) -> Bool {
        line.withUnsafeBytes { bytes in
            deltaMarker.withUnsafeBytes { marker in
                guard let base = bytes.baseAddress, let needle = marker.baseAddress else { return false }
                return memmem(base, bytes.count, needle, marker.count) != nil
            }
        }
    }

    /// Where a journal's receipts start from: nothing, a record with the
    /// whole list (read when needed), or a list already read.
    enum Base {
        case none, line(Data), list([JSON])
    }

    /// The receipts `base` and the records with changes after it add up to.
    /// A record read as changes that turns out to hold the whole list starts
    /// the list again.
    static func rebuild(_ base: Base, _ changes: [Data]) throws -> [JSON] {
        var list: [JSON]
        switch base {
        case .none: list = []
        case .line(let line): list = try JSON.parse(line)["data"]["commands"].list
        case .list(let whole): list = whole
        }
        for line in changes {
            let data = try JSON.parse(line)["data"]
            list = data[deltaKey].flag == true ? apply(data["commands"].list, to: list) : data["commands"].list
        }
        return list
    }
}
