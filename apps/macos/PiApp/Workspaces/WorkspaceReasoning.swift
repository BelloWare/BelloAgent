import Foundation

/// What the helper reports when a provider refused reasoning sent back from
/// earlier replies (its `reasoningRejection`): the notice's own words, and
/// the identity an answer is given for.
struct ReasoningRejectionNotice: Equatable, Sendable {
    let id: String
    /// "{model} can't use the earlier reasoning".
    let title: String
    /// What its provider refused, and what is still sent.
    let body: String
    /// "Switching back to {model} keeps its reasoning.", when another model
    /// of this connection wrote it.
    let hint: String?
    /// The provider's own sentence, when the helper found one.
    let sentence: String?
    init?(_ value: WireValue?) {
        guard let fields = value?.object, let id = fields["id"]?.string, !id.isEmpty, let title = fields["title"]?.string, !title.isEmpty else { return nil }
        self.id = id; self.title = title; body = fields["body"]?.string ?? ""; hint = fields["hint"]?.string; sentence = fields["sentence"]?.string
    }
    /// The notice's first line is its title; the rest is what happened.
    var text: String { body.isEmpty ? title : title + "\n" + body }
    /// Under the body, quietly: the way back, and the provider's words.
    var detail: String? {
        let lines = [hint, sentence.map { "Provider’s message: " + $0 }].compactMap { $0 }.filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

/// The owner's answer when a provider refuses earlier reasoning (owner,
/// 2026-11-11: "encrypted reasoning should be not ignored… unless it got
/// rejected by litellm due to model switch, which then we need user
/// confirmation to proceed with previous encrypted reasoning removed… while
/// keep new encrypted reasoning"; 2026-11-13: "try to make the UX even more
/// intuitive and better").
///
/// One step. The helper ends the run with its own failure code and keeps the
/// question with the failed run, so the notice in the transcript is there
/// after a relaunch. It says what happened and what is still sent, and
/// carries one button, **Continue without earlier reasoning**, which acts at
/// once: pressing the clearly named button is the confirmation. Not pressing
/// it leaves the turn stopped. Nothing pops up; the chat is marked as any
/// stopped run is. Afterwards the helper leaves one quiet line in the
/// transcript, "Continued without earlier reasoning · {model}".
extension WorkspaceModel {
    /// What is answered is what the helper holds: on a failure read from the
    /// journal, before the helper has the chat, the question is fetched
    /// first, and the answer goes with its identity.
    func continueWithoutEarlierReasoning(sessionID: String) {
        guard let view = displays[sessionID], view.failureCode == SessionDisplay.reasoningRejectedCode,
              let item = record(sessionID), !item.isSubagent, !item.isArchived else { return }
        Task { @MainActor in
            var notice = view.reasoningRejection
            if notice == nil {
                do {
                    let status = try await open(item).request("session.status", sessionID: item.id).object ?? [:]
                    notice = ReasoningRejectionNotice(status["reasoningRejection"])
                } catch { self.error = error.localizedDescription }
            }
            // The helper no longer holds the question, or the chat moved on
            // while it was fetched: nothing to answer.
            guard let notice, let view = displays[sessionID], view.failureCode == SessionDisplay.reasoningRejectedCode,
                  view.reasoningRejection == nil || view.reasoningRejection?.id == notice.id, let item = record(sessionID) else { return }
            // A second press while the request is on its way sends nothing
            // (`runActionKey`), and the helper takes one answer a question.
            var params = turnOverrides(for: item)
            params["withoutEarlierReasoning"] = .object(["rejection": .string(notice.id)])
            action("turn.retry", params: params, sessionID: sessionID)
        }
    }
}
