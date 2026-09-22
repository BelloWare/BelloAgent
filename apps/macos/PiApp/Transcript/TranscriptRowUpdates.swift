import Foundation

/// The reader's side of the helper's row updates. The helper sends the page
/// once and afterwards says only what changed in it: the rows whose content is
/// new, the tokens appended to the reply still arriving, and the row order when
/// it moved. Everything else is the page this display already holds, reused by
/// identity — a settled row is immutable, so the row the transcript compares
/// against is literally the same value it compared against last time.
///
/// Nil means the update does not fit the page held here; the caller must ask
/// for a whole page again. That is the only recovery, and it is always allowed:
/// the helper answers any unknown revision with the whole page.
enum TranscriptRowUpdates {
    static func apply(_ patch: WireValue, to page: [TranscriptMessage]) -> [TranscriptMessage]? {
        guard let update = patch.object else { return nil }
        var rows: [String: TranscriptMessage] = [:], order: [String] = []
        rows.reserveCapacity(page.count + 4); order.reserveCapacity(page.count + 4)
        for row in page { rows[row.id] = row; order.append(row.id) }
        // Rows are addressed by id. A page that somehow holds the same id
        // twice cannot be updated in place; ask for it again instead.
        guard rows.count == page.count else { return nil }
        if let replaced = update["rows"]?.array, !replaced.isEmpty {
            guard let decoded = try? TranscriptMessage.page(.array(replaced)) else { return nil }
            for row in decoded { rows[row.id] = row }
        }
        for appended in update["appends"]?.array ?? [] {
            guard let fields = appended.object, let id = fields["id"]?.string, var row = rows[id] else { return nil }
            row.text += fields["text"]?.string ?? ""
            let thinking = fields["thinking"]?.string ?? ""
            if !thinking.isEmpty || row.thinking != nil { row.thinking = (row.thinking ?? "") + thinking }
            rows[id] = row
        }
        for part in update["parts"]?.array ?? [] {
            guard let fields = part.object, fields["version"]?.number == 1,
                  let id = fields["id"]?.string, var row = rows[id],
                  let raw = fields["segments"],
                  let changed = try? JSONDecoder().decode([ResponseTimeline.Segment].self, from: JSONEncoder().encode(raw)) else { return nil }
            var timeline = row.responseTimeline ?? ResponseTimeline()
            guard timeline.supported, Set(changed.map(\.id)).count == changed.count else { return nil }
            var segments = Dictionary(timeline.segments.map { ($0.id,$0) }, uniquingKeysWith: { _,last in last })
            for segment in changed { segments[segment.id] = segment }
            var appendedIDs = Set<String>()
            for value in fields["appends"]?.array ?? [] {
                guard let id = value.object?["id"]?.string, appendedIDs.insert(id).inserted,
                      !changed.contains(where: { $0.id == id }), var segment = segments[id],
                      value.object?["baseRevision"]?.number == Double(segment.revision),
                      let revision = value.object?["revision"]?.number.flatMap(Int.init(exactly:)), revision > segment.revision,
                      let text = value.object?["text"]?.string, let state = value.object?["state"]?.string else { return nil }
                segment.text += text; segment.state = state; segment.revision = revision; segments[id] = segment
            }

            let ids = fields["order"]?.array?.compactMap(\.string) ?? timeline.segments.map(\.id)
            guard Set(ids).count == ids.count, ids.allSatisfy({ segments[$0] != nil }) else { return nil }
            timeline.segments = ids.compactMap { segments[$0] }
            timeline.coverage = fields["coverage"]?.string ?? timeline.coverage
            timeline.omittedEvents = fields["omittedEvents"]?.number.flatMap(Int.init(exactly:)) ?? timeline.omittedEvents
            timeline.terminal = fields["terminal"]?.string
            guard timeline.supported else { return nil }
            row.responseTimeline = timeline; rows[id] = row
        }
        if let sent = update["order"]?.array {
            order = sent.compactMap(\.string)
            guard order.count == sent.count else { return nil }
        }
        var next: [TranscriptMessage] = []
        next.reserveCapacity(order.count)
        for id in order {
            guard let row = rows[id] else { return nil }
            next.append(row)
        }
        return next
    }
}
