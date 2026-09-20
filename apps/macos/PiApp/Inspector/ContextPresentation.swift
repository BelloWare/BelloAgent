import Foundation

/// Event order is not input identity. Only committed replay/configuration
/// changes advance this revision, within one helper runtime.
struct ContextInputIdentity: Equatable {
    let epoch: String
    let revision: Double
    init?(_ value: [String: WireValue]) {
        guard let epoch=value["runtimeEpoch"]?.string, !epoch.isEmpty,
              let revision=value["replayRevision"]?.number, revision.isFinite,
              revision >= 0, revision.rounded() == revision else { return nil }
        self.epoch=epoch; self.revision=revision
    }
}

/// The footer and inspector select the same scope. A previous request never
/// measures new input, even if its reported count is more precise.
struct ContextPresentation: Equatable {
    let context: [String: WireValue]
    var scope: String { context["scope"]?.string ?? "pending" }
    var reason: String { context["selectionReason"]?.string ?? "input-changed" }

    static func resolve(state: [String: WireValue], observation: [String: WireValue],
                        preview: [String: WireValue]?, fallback: [String: WireValue],
                        preparing: Bool, submissionPending: Bool, busy: Bool, runStatus: String) -> Self {
        func selected(_ input: [String: WireValue], scope: String, reason: String) -> Self {
            var value=input; value["scope"] = .string(scope); value["selectionReason"] = .string(reason)
            return Self(context:value)
        }
        func pending(_ text: String, reason: String, scope: String = "pending") -> Self {
            selected(["state":.string("pending"),"tokens":.null,"source":.string(text)],scope:scope,reason:reason)
        }
        if runStatus == "compacting" || state["phase"]?.string == "compacting" {
            return pending("Compacting context…",reason:"compaction-started",scope:"compacting")
        }
        if submissionPending { return pending("Preparing request input…",reason:"new-request-preparing") }
        if state["version"]?.number == 1 {
            let phase=state["phase"]?.string
            if phase == "current-request" || phase == "preparing" {
                let current=state["currentRequest"]?.object ?? [:]
                if current["sessionID"] == state["sessionID"], current["runtimeEpoch"] == state["runtimeEpoch"],
                   current["generation"] == state["generation"], ["turn","title"].contains(current["purpose"]?.string ?? ""), !current.isEmpty,
                   let count=RequestContextObservation(current).context {
                    return selected(count,scope:"current-request",reason:count["estimated"]?.bool == false ? "usage-observed" : "new-request-preparing")
                }
                return pending("Preparing request input…",reason:"new-request-preparing")
            }
            if phase == "last-request" {
                if let last=state["lastRequest"]?.object, last["sessionID"] == state["sessionID"],
                   last["runtimeEpoch"] == state["runtimeEpoch"], ["turn","title"].contains(last["purpose"]?.string ?? ""),
                   let count=RequestContextObservation(last).context {
                    return selected(count,scope:"last-request",reason:"request-completed")
                }
                return pending("Preparing next input…",reason:"input-changed")
            }
            if let preview { return selected(preview,scope:"next-input",reason:"same-input-preview-ready") }
            let reason=state["reason"]?.string ?? "input-changed"
            return pending(reason == "compaction-committed" ? "Preparing compacted input…" : "Preparing next input…",reason:reason)
        }
        // Older helpers can supply estimates without a scoped-state version.
        // Keep the limitation visible rather than inventing an attempt identity.
        if preparing { return pending("Preparing next input…",reason:"input-changed") }
        if !busy, let preview { return selected(preview,scope:"next-input",reason:"same-input-preview-ready") }
        if let last=RequestContextObservation(observation).context {
            return selected(last,scope:"last-request",reason:"legacy-observation")
        }
        return selected(fallback,scope:"legacy",reason:"legacy-estimate")
    }
}
