import XCTest
@testable import PiApp

/// Reasoning continuation in Settings, and the question when a provider
/// refuses earlier reasoning (owner, 2026-11-11: "encrypted reasoning should
/// be not ignored… unless it got rejected by litellm due to model switch,
/// which then we need user confirmation"). What a connection stores must stay
/// readable by 0.1.137, which accepts three `replayPolicy` values, a closed
/// set of routing keys and no advanced field it does not know.
final class ReasoningReplaySettingsTests: XCTestCase {
    private func profile(_ advanced: String?) -> ProfileRecord {
        var profile = ProfileRecord(); profile.name = "Gateway"; profile.modelId = "fixture-model"; profile.baseUrl = "http://127.0.0.1:1/v1"; profile.advancedJSON = advanced
        return profile
    }

    @MainActor func testEveryConnectionSavedBeforeShowsSendUnlessItPinsARoute() throws {
        // `portable` was written into every new connection; `ask`, and a
        // connection with no policy, refused to send once a chat held reasoning.
        for stored in [#"{"routing":{"replayPolicy":"portable"}}"#, #"{"routing":{"replayPolicy":"ask"}}"#, "{}", nil] {
            let draft = ConnectionSettingsController.Draft.loaded(profile(stored), isSaved: true)
            XCTAssertEqual(draft.replayPolicy, ReasoningReplayChoice.send, stored ?? "nil")
            // Opening the form is not an edit, whatever policy was stored.
            XCTAssertEqual(draft.form, draft.baseline, stored ?? "nil")
            XCTAssertNil(draft.form.profile.reasoningReplay)
        }
        let pinned = ConnectionSettingsController.Draft.loaded(profile(#"{"routing":{"replayPolicy":"pinned","expectedModel":"m","replayContract":"c"}}"#), isSaved: true)
        XCTAssertEqual(pinned.replayPolicy, ReasoningReplayChoice.pinned); XCTAssertEqual(pinned.form, pinned.baseline)
        XCTAssertEqual(ConnectionSettingsController.Draft.loaded(ProfileRecord(), isSaved: false).replayPolicy, ReasoningReplayChoice.send, "A new connection sends reasoning back")
    }

    @MainActor func testWhatIsSavedIsWhatTheEarlierBuildReads() throws {
        var draft = ConnectionSettingsController.Draft.loaded(profile(#"{"routing":{"replayPolicy":"ask"}}"#), isSaved: true)
        for (choice, field) in [(ReasoningReplayChoice.send, nil), (ReasoningReplayChoice.never, "never")] as [(String, String?)] {
            draft.replayPolicy = choice
            let saved = try draft.form.normalizedProfile()
            XCTAssertEqual(saved.reasoningReplay, field, choice)
            let routing = try XCTUnwrap(saved.configuration["routing"]?.object)
            // 0.1.137: ask, portable or pinned, and under `portable` it sends no reasoning.
            XCTAssertEqual(routing["replayPolicy"]?.string, "portable", choice)
            XCTAssertNoThrow(try RoutingConfiguration.validate(.object(routing)))
            XCTAssertNil(saved.configuration["reasoningReplay"], "Not among the advanced fields, which that build checks against a closed list")
            // The helper gets the choice as a field of its own, only when it is not the default.
            XCTAssertEqual(saved.wire.object?["reasoningReplay"]?.string, field, choice)
            // A record written here decodes there (an unknown key is skipped) and back.
            let data = try JSONEncoder().encode(saved)
            XCTAssertEqual(try JSONDecoder().decode(ProfileRecord.self, from: data), saved)
        }
        draft.replayPolicy = ReasoningReplayChoice.pinned; draft.expectedModel = "m"; draft.replayContract = "c"
        let pinned = try draft.form.normalizedProfile()
        XCTAssertNil(pinned.reasoningReplay); XCTAssertEqual(pinned.configuration["routing"]?.object?["replayPolicy"]?.string, "pinned")
        // A record of 0.1.137 has no such key.
        let earlier = try JSONDecoder().decode(ProfileRecord.self, from: Data(#"{"id":"p","revision":"1","name":"Gateway","providerId":"litellm","modelId":"m","api":"openai-responses","baseUrl":"http://127.0.0.1:1/v1","contextWindow":128000,"maxOutputTokens":4096,"advancedJSON":"{\"routing\":{\"replayPolicy\":\"portable\"}}"}"#.utf8))
        XCTAssertNil(earlier.reasoningReplay); XCTAssertNil(earlier.wire.object?["reasoningReplay"])
    }

    func testTheChoicesAndTheirWords() {
        XCTAssertEqual(ReasoningReplayChoice.options.map(\.0), ["send", "never", "pinned"])
        XCTAssertEqual(ReasoningReplayChoice.options.map(\.1), ["Send reasoning back", "Never send reasoning back", "Preserve native state on a fixed route"])
        XCTAssertTrue(ReasoningReplayChoice.footer.contains("starting with replies made from Bello Agent 0.1.138 on"))
        XCTAssertTrue(ReasoningReplayChoice.footer.contains("the turn stops and its notice offers to continue without the earlier reasoning"))
    }

    @MainActor func testARefusalIsANoticeThatSaysWhatHappenedAndCarriesTheWayOn() throws {
        let display = SessionDisplay(id: "chat")
        let title = "flash-lite can't use the earlier reasoning"
        let body = "Its provider refused the hidden reasoning saved from earlier replies by luna. Your messages, the replies and the tool results are all still sent."
        let said = title + "\n" + body + "\n\nProvider's message: Corrupted thought signature."
        display.observeRunState(["state": .string("error"), "runStatus": .string("failed"), "queuePaused": .bool(true), "errorCode": .string("reasoning_rejected"), "preflightError": .string(said),
                                 "reasoningRejection": .object(["id": .string("q1"), "rule": .string("thoughtSignature"), "sentence": .string("Corrupted thought signature."), "routeChanged": .bool(false),
                                                                "model": .string("flash-lite"), "ownReasoning": .bool(false), "origins": .array([.string("luna")]), "title": .string(title), "body": .string(body),
                                                                "hint": .string("Switching back to luna keeps its reasoning."), "purpose": .string("turn")])])
        let notice = try XCTUnwrap(display.reasoningRejection)
        XCTAssertEqual(notice.id, "q1"); XCTAssertEqual(notice.title, title); XCTAssertEqual(notice.body, body)
        let row = try XCTUnwrap(display.presentedMessages.last { $0.kind == "failure" })
        XCTAssertEqual(row.failureCode, SessionDisplay.reasoningRejectedCode)
        // Title on the first line, what happened under it; the way back and the provider's words below, apart.
        XCTAssertEqual(row.text, title + "\n" + body)
        XCTAssertEqual(row.detail, "Switching back to luna keeps its reasoning.\nProvider’s message: Corrupted thought signature.")

        // Its own reasoning (the key or route changed): no way back to offer.
        let own = try XCTUnwrap(ReasoningRejectionNotice(.object(["id": .string("q2"), "title": .string("luna can't use the earlier reasoning"),
                                                                  "body": .string("Its provider refused the hidden reasoning saved from its own earlier replies; its key or route has probably changed. Your messages, the replies and the tool results are all still sent.")])))
        XCTAssertNil(own.detail); XCTAssertTrue(own.text.hasPrefix("luna can't use the earlier reasoning\nIts provider refused"))
        // Without the helper's words there is no notice to build.
        XCTAssertNil(ReasoningRejectionNotice(.object(["sentence": .string("no id")]))); XCTAssertNil(ReasoningRejectionNotice(nil))

        // A failure read from the journal, before the helper has the chat: the message itself carries the title and the body.
        let read = SessionDisplay(id: "read")
        read.observeRunState(["state": .string("error"), "runStatus": .string("failed"), "errorCode": .string("reasoning_rejected"), "preflightError": .string(said)])
        XCTAssertNil(read.reasoningRejection)
        XCTAssertEqual(read.presentedMessages.last { $0.kind == "failure" }?.text, said)

        // Once the run goes on, the notice is gone (the helper's quiet line takes its place).
        display.observeRunState(["state": .string("running"), "runStatus": .string("running"), "queuePaused": .bool(false)])
        XCTAssertNil(display.reasoningRejection); XCTAssertFalse(display.presentedMessages.contains { $0.failureCode == SessionDisplay.reasoningRejectedCode })
    }
}
