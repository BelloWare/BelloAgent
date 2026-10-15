import Foundation

extension SessionDisplay {
    /// A Save's answer can overtake a snapshot already being decoded. The
    /// queue and its hold share the helper's revision, so old rows cannot
    /// undo an acknowledged rewrite or bring a removed message back.
    func queueSnapshotIsCurrent(_ snapshot: [String: WireValue]) -> Bool {
        guard let revision = snapshot["queueEditRevision"]?.number.map(Int.init) else { return queueEditHoldRevision < 0 }
        return revision >= queueEditHoldRevision
    }

    @discardableResult func applyQueueSnapshot(_ snapshot: [String: WireValue]) -> [[String: WireValue]]? {
        guard queueSnapshotIsCurrent(snapshot) else { return nil }
        observeQueueEdit(snapshot)
        if let revision = snapshot["queueEditRevision"]?.number.map(Int.init) { queuePresentedEditRevision = revision }
        let pending = snapshot["queue"]?.array?.compactMap(\.object) ?? []
        let rows = panelQueue(pending)
        if queue != rows { queue = rows }
        queueCount = Int(snapshot["queueCount"]?.number ?? 0)
        return pending
    }

    /// Publish only after the helper accepted the Save. Never recreate a row
    /// a newer snapshot has already delivered, removed or edited again.
    func reflectQueuedRewrite(turnID: String, text: String, reply: [String: WireValue]) {
        if let revision = reply["revision"]?.number.map(Int.init) {
            guard revision >= queueEditHoldRevision, revision > queuePresentedEditRevision else { return }
            queuePresentedEditRevision = revision
        }
        guard let index = queue.firstIndex(where: { $0["turnId"]?.string == turnID }) else { return }
        // A local display preview only; the full text was sent to the helper
        // and future edits still read it there. Bound work and retained text
        // like a queue snapshot, without walking the transcript.
        let preview = ToolInputDisplay.preview(text, bytes: 1_024)
        var row = queue[index]
        row["text"] = .string((row["kind"]?.string == "steering" ? "[Steering] " : "") + preview)
        row["textBytes"] = .number(Double(text.utf8.count))
        row["textTruncated"] = .bool(preview.utf8.count < text.utf8.count)
        if queueEditOriginal != text { row["textRevision"] = .number((row["textRevision"]?.number ?? 0) + 1) }
        queue[index] = row
    }
}
