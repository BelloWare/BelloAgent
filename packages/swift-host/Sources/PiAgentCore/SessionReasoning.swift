import Foundation

/// A provider refused reasoning sent back from earlier replies, and the owner
/// is asked (owner, 2026-11-11: "we need user confirmation to proceed with
/// previous encrypted reasoning removed… while keep new encrypted reasoning";
/// 2026-11-13: "try to make the UX even more intuitive and better").
///
/// The run ends as a failure with its own code, which is durable like any
/// failed run: its notice in the transcript says what happened and carries
/// one button, now or after a relaunch. Nothing is retried until the owner
/// presses it. **Continue without earlier reasoning** means "this model goes
/// on without whatever earlier reasoning its provider refuses": the request
/// is sent again without the reasoning other models wrote; if that is
/// refused too, once more without the model's own, without asking again;
/// if that is refused, it is the provider's ordinary error. Each step is in
/// the journal before its request is sent, and says what was left out. The
/// model that refused no longer gets that reasoning; a model that never
/// refused still gets everything (switching back to the model that made the
/// reasoning recovers it), reasoning of later replies is stored and sent as
/// always, and the chat's history is not rewritten. Not pressing the button
/// leaves the turn stopped with the provider's error.
extension AgentSession {
    /// The failed run's code while the owner's answer is awaited.
    static let reasoningRejectedCode = "reasoning_rejected"
    /// An answer to a question that no longer stands.
    static let reasoningConfirmationStaleCode = "reasoning_confirmation_stale"

    /// The model that refused: a model alias on a connection. The same alias
    /// on another connection (after a move) is a model that never refused.
    static func reasoningRouteKey(_ profile: Profile) -> String { profile.id + "\n" + profile.model }
    static func reasoningWithheld(_ saved: JSON) -> [String: Set<String>] {
        saved.map.mapValues { Set($0.list.compactMap(\.text)) }.filter { !$0.value.isEmpty }
    }
    static func saved(_ withheld: [String: Set<String>]) -> JSON {
        .object(withheld.mapValues { .array($0.sorted().map(JSON.string)) })
    }
    /// What each model that refused is no longer sent: this chat's own
    /// answers, and those of the chat it was forked or started from as they
    /// stood then (a fork cut before the answer was given must not send it again).
    var effectiveReasoningWithheld: [String: Set<String>] {
        var all = reasoningWithheld
        for (route, ids) in Self.reasoningWithheld(parentInfo["reasoningWithheld"]) { all[route, default: []].formUnion(ids) }
        for (route, ids) in subagents.origin?.reasoningWithheld ?? [:] { all[route, default: []].formUnion(ids) }
        return all
    }
    /// For a fork's, a side's or a sub-agent's origin; nil when there is none.
    var inheritableReasoningWithheld: [String: [String]]? {
        let all = effectiveReasoningWithheld
        return all.isEmpty ? nil : all.mapValues { $0.sorted() }
    }
    /// `profile` with what its model refused, for every projection of the chat.
    func withholdingReasoning(_ profile: Profile) -> Profile {
        guard !reasoningWithheld.isEmpty || !parentInfo["reasoningWithheld"].isNull || subagents.origin?.reasoningWithheld != nil else { return profile }
        return profile.withholding(effectiveReasoningWithheld[Self.reasoningRouteKey(profile)] ?? [])
    }

    /// What a refusal the owner is asked about would leave out first.
    struct RefusedReasoning {
        let replies: [String], own: Bool
        /// The models that wrote the refused reasoning, and those of them
        /// this connection still offers (their replies were made on it).
        let origins: [String], selectable: [String]
        let found: ReasoningRejection?
    }
    /// The replies whose reasoning the failed request of `error` carried,
    /// read from its own projected input; nil unless the provider's text is
    /// a refusal of reasoning and the request did carry some. A call id
    /// refused for its length counts only when the request sent one with a
    /// thought signature in it.
    private func refusedCarriers(_ error: Error) -> (failed: AgentError, found: ReasoningRejection?, carriers: [String])? {
        guard let failed = error as? AgentError, failed.failure == .reasoningRejected else { return nil }
        let found = ReasoningRejection.match(message: failed.providerMessage ?? failed.message)
        let carriers = (try? ProviderClient.reasoningCarriers(requestContext, profile: turnProfile, signedOnly: found?.rule == .signedCallID)) ?? []
        return carriers.isEmpty ? nil : (failed, found, carriers)
    }
    /// Whether `error` is a refusal the owner is asked about, and of what.
    /// A sub-agent has no one to ask (`holdRejectedReasoning` names its
    /// failure instead). Where there is no request to send again, as after a
    /// manual compaction of an idle chat whose last row is the model's
    /// reply, nothing is offered and the failure is the compaction's own.
    ///
    /// What goes first, for the model that refused: the reasoning other
    /// models wrote (or this alias on another connection); the model keeps
    /// what it wrote itself. Its own goes first only when the request
    /// carried no one else's (its key or route changed under the same name).
    func reasoningQuestion(_ error: Error) -> RefusedReasoning? {
        guard !isSubagent, let last = history.last(where: { $0.replayEligible }), last.role != "assistant", let refused = refusedCarriers(error) else { return nil }
        let target = turnProfile
        // An answer already given for this model covers this request.
        if reasoningRetry?["route"].text == Self.reasoningRouteKey(target) { return nil }
        let (foreign, origins, selectable) = foreignReasoning(refused.carriers, target: target)
        return RefusedReasoning(replies: foreign.isEmpty ? refused.carriers : foreign, own: foreign.isEmpty, origins: origins, selectable: selectable, found: refused.found)
    }
    private func foreignReasoning(_ carriers: [String], target: Profile) -> (replies: [String], origins: [String], selectable: [String]) {
        var replies: [String] = [], origins: [String] = [], selectable: [String] = []
        for reply in requestContext where carriers.contains(reply.id) {
            let here = (reply.providerBinding?["profileId"].text).map { $0 == target.id } ?? true
            if ProviderClient.sameModel(reply, profile: target), here { continue }
            replies.append(reply.id)
            guard let model = reply.providerBinding?["profile"]["model"].text, model != target.model || !here else { continue }
            if !origins.contains(model) { origins.append(model) }
            if here, model != target.model, !selectable.contains(model) { selectable.append(model) }
        }
        return (replies, origins, selectable)
    }
    /// The request the owner's Continue sent again, without the others'
    /// reasoning, was refused too: what is left in it is the model's own,
    /// which Continue covers without another question (`widenReasoningWithholding`).
    func reasoningWidening(_ error: Error) -> [String]? {
        guard let answered = reasoningRetry, answered["route"].text == Self.reasoningRouteKey(turnProfile), answered["own"].flag != true else { return nil }
        return refusedCarriers(error)?.carriers
    }
    /// A refusal the session handles itself, by a question or within an
    /// answer already given: not a summary that was paid for and wasted.
    func handlesRefusedReasoning(_ error: Error) -> Bool { reasoningQuestion(error) != nil || reasoningWidening(error) != nil }

    /// The notice's words, in the owner's terms.
    static func refusalWords(model: String, own: Bool, origins: [String], selectable: [String]) -> (title: String, body: String, hint: String?) {
        let title = "\(model) can't use the earlier reasoning"
        let kept = " Your messages, the replies and the tool results are all still sent."
        if own { return (title, "Its provider refused the hidden reasoning saved from its own earlier replies; its key or route has probably changed." + kept, nil) }
        let names: String
        switch origins.count {
        case 0: names = "other models"
        case 1: names = origins[0]
        default: names = origins.dropLast().joined(separator: ", ") + " and " + origins[origins.count - 1]
        }
        return (title, "Its provider refused the hidden reasoning saved from earlier replies by \(names)." + kept, selectable.first.map { "Switching back to \($0) keeps its reasoning." })
    }
    /// Ends the run as the owner's question. The summary request of a
    /// compaction counts like the turn's own: it replays the same replies.
    /// A sub-agent's refusal stays its turn's failure, named the same way,
    /// so the parent's view of it says what it was.
    func holdRejectedReasoning(_ error: Error) -> AgentError? {
        let target = turnProfile
        if isSubagent {
            guard let refused = refusedCarriers(error) else { return nil }
            let foreign = foreignReasoning(refused.carriers, target: target)
            let words = Self.refusalWords(model: target.model, own: foreign.replies.isEmpty, origins: foreign.origins, selectable: [])
            return AgentError(refused.failed.code, Self.refusalText(words, sentence: refused.found?.sentence), failure: .reasoningRejected, attemptID: refused.failed.attemptID, providerMessage: refused.failed.providerMessage)
        }
        guard let failed = error as? AgentError, let refused = reasoningQuestion(error) else { return nil }
        let found = refused.found, words = Self.refusalWords(model: target.model, own: refused.own, origins: refused.origins, selectable: refused.selectable)
        var held: JSON = ["id": JSON(UUID().uuidString), "replies": .array(refused.replies.map(JSON.string)), "route": JSON(Self.reasoningRouteKey(target)),
                          "model": JSON(target.model), "ownReasoning": JSON(refused.own), "origins": .array(refused.origins.map(JSON.string)),
                          "title": JSON(words.title), "body": JSON(words.body),
                          "purpose": JSON(failed.attemptID.map(compactionAttemptIDs.contains) == true ? "compaction" : "turn")]
        if let hint = words.hint { held["hint"] = JSON(hint) }
        if let found { held["rule"] = JSON(found.rule.rawValue); held["sentence"] = JSON(found.sentence); held["routeChanged"] = JSON(found.routeChanged) }
        if let attempt = failed.attemptID { held["failedAttemptId"] = JSON(attempt) }
        reasoningRejection = held
        return AgentError(Self.reasoningRejectedCode, Self.refusalText(words, sentence: found?.sentence), failure: .reasoningRejected, attemptID: failed.attemptID, providerMessage: failed.providerMessage)
    }
    /// The failed run's message: the notice's title on its first line, its
    /// body, and the provider's own sentence apart from both.
    static func refusalText(_ words: (title: String, body: String, hint: String?), sentence: String?) -> String {
        words.title + "\n" + words.body + ((sentence ?? "").isEmpty ? "" : "\n\nProvider's message: " + (sentence ?? ""))
    }
    /// What the app needs to ask: no reply ids, which only the helper uses.
    var reasoningRejectionNotice: JSON? {
        guard errorCode == Self.reasoningRejectedCode, let held = reasoningRejection else { return nil }
        return held.removing(["replies", "failedAttemptId", "route"])
    }

    /// The owner's Continue for the refusal `rejection`. The answer must be
    /// for the question that stands: an edit, another turn or an earlier
    /// answer makes it stale. The decision is in the journal, synchronized,
    /// before the request it changes is sent, and one quiet line in the
    /// transcript says it was taken.
    func withholdReasoning(answering rejection: String?) throws {
        guard errorCode == Self.reasoningRejectedCode, let held = reasoningRejection, let id = held["id"].text, id == rejection else {
            throw AgentError(Self.reasoningConfirmationStaleCode, "This chat has moved on since that notice was shown. Nothing was changed.")
        }
        let replies = held["replies"].list.compactMap(\.text), route = held["route"].text ?? Self.reasoningRouteKey(turnProfile), own = held["ownReasoning"].flag == true
        try recordReasoningWithheld(rejection: id, route: route, replies: replies, own: own, rule: held["rule"].text)
        var line = ChatMessage(role: "system", content: [])
        line.id = "reasoning-continued:" + id; line.kind = "notice"; line.displayText = Self.continuedText(model: held["model"].text ?? turnProfile.model, own: own)
        try appendPresentation(line)
        reasoningRejection = nil
        reasoningRetry = ["id": JSON(id), "route": JSON(route), "own": JSON(own), "model": held["model"]]
        // The owner acted: a summary may be paid for again, and whether one
        // is still needed is worked out afresh from the reduced context.
        automaticSummarySpent = false; unavailableCompaction = nil; recheckCompactionOnRetry = true
    }
    /// The request sent again was refused too: the model's own earlier
    /// reasoning goes as well, within the answer already given. Written down
    /// before the next request, and the transcript's line says so.
    func widenReasoningWithholding(_ replies: [String]) throws {
        guard var answered = reasoningRetry, let id = answered["id"].text, let route = answered["route"].text else { return }
        try recordReasoningWithheld(rejection: id, route: route, replies: replies, own: true, rule: nil)
        answered["own"] = true; reasoningRetry = answered
        // A line of the transcript is not rewritten: a second one says what was added.
        var line = ChatMessage(role: "system", content: [])
        line.id = "reasoning-continued-own:" + id; line.kind = "notice"
        line.displayText = "Continued without its own earlier reasoning too · " + (answered["model"].text ?? turnProfile.model)
        try appendPresentation(line)
    }
    static func continuedText(model: String, own: Bool) -> String {
        "Continued without earlier reasoning" + (own ? ", including its own" : "") + " · " + model
    }
    /// What a model is no longer sent, and why. A side not saved yet has no
    /// journal: the answer is held in memory and its first journal carries
    /// it (`keepNow`).
    private func recordReasoningWithheld(rejection: String, route: String, replies: [String], own: Bool, rule: String?) throws {
        var data: JSON = ["rejection": JSON(rejection), "route": JSON(route), "replies": .array(replies.map(JSON.string)), "own": JSON(own), "at": JSON(isoNow())]
        if let rule { data["rule"] = JSON(rule) }
        try journal?.append(["type": "custom", "customType": JSON(JournalRecordKind.reasoningWithheld), "data": data], flush: true)
        reasoningWithheld[route, default: []].formUnion(replies)
        replayInputsChanged(reason: "reasoning-withheld")
    }
}
