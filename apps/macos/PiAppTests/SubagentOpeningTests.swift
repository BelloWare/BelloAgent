import XCTest
import Darwin
import AppKit
@testable import PiApp

/// Real helper navigation over a generated loopback stream. The fixture's
/// explicit barrier keeps a child active until its viewer has attached.
final class SubagentOpeningTests: XCTestCase, SerialTestLane {
    @MainActor func testLiveDiscoverySurvivesTopicMovesAndLosesAuthorityWhenTheHelperExits() async throws {
        let (_, model, host, parent, target) = try await fixture()
        let connection = try XCTUnwrap(host.connectionID)
        try await model.refreshSubagentGroups(parent: try XCTUnwrap(model.record(parent.id)), host: host, connection: connection)
        XCTAssertEqual(model.subagentSummaries[target.sessionID]?.status, .running)
        let topic = try await model.createTopic(in: parent.workspaceID, title: "Moved family")
        try await model.moveSessions([parent.id], in: parent.workspaceID, toTopic: topic.id)
        XCTAssertEqual(model.record(target.sessionID)?.topicID, topic.id)
        XCTAssertEqual(model.subagentSummaries[target.sessionID]?.status, .running)
        XCTAssertEqual(kill(try XCTUnwrap(host.helperProcessIdentifier), SIGKILL), 0)
        try await eventually("Fixture host did not exit") { host.connectionID == nil }
        XCTAssertEqual(model.subagentSummaries[target.sessionID]?.status, .interrupted, "A lost runtime must not leave preserved progress authoritative")
        await model.reconcileSubagents(parentID: parent.id)
        XCTAssertEqual(model.subagentSummaries[target.sessionID]?.status, .interrupted)
    }

    @MainActor func testEverySelectionAndInspectorEntryAttachesAnAlreadyRegisteredLiveChild() async throws {
        for route in ["selection", "reveal", "reselect reveal", "family Inspector", "child Inspector", "search", "launch", "cold launch"] {
            let (setup, model, host, parent, target) = try await fixture()
            var inspector: SessionInspectorModel?
            switch route {
            case "selection": await model.select(target.sessionID)
            case "reveal": _ = await model.revealMessage(sessionID: target.sessionID, messageID: nil)
            case "reselect reveal":
                await model.select(target.sessionID)
                model.opened.remove(target.sessionID)
                _ = await model.revealMessage(sessionID: target.sessionID, messageID: nil)
            case "family Inspector", "child Inspector":
                let value = SessionInspectorModel(scope: .init(sessionID: route == "family Inspector" ? parent.id : target.sessionID, workspaceID: parent.workspaceID), title: "Fixture", archive: model.traces, workspace: model, usageLoader: { _,_,_ in throw CancellationError() })
                inspector = value; value.setVisible(true)
                try await eventually("Inspector never indexed the child") { value.index.requests.contains { $0.sessionID == target.sessionID } }
                let request = try XCTUnwrap(value.index.requests.first { $0.sessionID == target.sessionID })
                value.focus(.request(request.id)); value.showInChat()
                try await eventually("Inspector never selected the child") { model.selectedID == target.sessionID && model.selected?.historyState != .loading }
                await model.navigationTask?.value
            case "search":
                await model.openFromSidebar(target.sessionID)
                let row = try XCTUnwrap(model.selected?.messages.first)
                await SidebarSearchReveal.reveal(model, chatID: target.sessionID, messageID: row.id)
            case "launch", "cold launch":
                if route == "cold launch" {
                    XCTAssertEqual(kill(try XCTUnwrap(host.helperProcessIdentifier), SIGKILL), 0)
                    try await eventually("Fixture host did not exit") { host.connectionID == nil }
                }
                model.selectedID = nil; model.selected = nil
                _ = await model.reopenRememberedSelection(.init(chatID: target.sessionID, projectID: parent.workspaceID), unlessSelectedSince: model.selectionRevision)
            default: XCTFail("Unknown route")
            }
            XCTAssertNil(model.error, route)
            if route == "cold launch" {
                XCTAssertFalse(model.opened.contains(target.sessionID)); XCTAssertNil(host.connectionID, "Restoring saved history must not start a helper or recover the parent")
            } else { XCTAssertTrue(model.opened.contains(target.sessionID), route + " must attach before revealing") }
            XCTAssertTrue(model.subagentGroupExpanded(parent.id), route + " must reveal the selected child's group")
            try Data().write(to: setup.root.appendingPathComponent("release-child"))
            if model.opened.contains(target.sessionID) {
                try await eventually("\(route) did not stream the child's final reply") {
                    model.displays[target.sessionID]?.messages.contains { $0.role == "assistant" && $0.isStreaming != true && $0.text.contains("Unicode:") } == true
                }
            }
            inspector?.setVisible(false)
            model.shutdown(); try await host.shutdownAndWait()
        }
    }

    @MainActor func testBackAndStandaloneInspectorFindTheIssuingCallAfterAnAncestorEdit() async throws {
        let (setup, model, host, parent, target) = try await fixture(ancestor: true)
        try Data().write(to: setup.root.appendingPathComponent("release-child"))
        try await waitForParent(parent.id, host: host)
        _ = try await host.request("turn.edit", sessionID: parent.id, params: ["messageId":.string("ancestor"), "text":.string("Edited ancestor"), "clientTurnId":.string("replacement")])
        try await waitForParent(parent.id, host: host)
        let link = try XCTUnwrap(model.record(target.sessionID)?.delegation)
        SessionInspectorWindows.shared.closeAll()
        defer { SessionInspectorWindows.shared.closeAll() }
        for route in ["Back", "standalone Inspector", "family Inspector", "standalone Parent request", "family Parent request"] {
            await model.openSubagent(target)
            model.latestVersion(sessionID: parent.id)
            if route == "Back" { await model.backToSubagentParent(target.sessionID) }
            else {
                let inspector = SessionInspectorModel(scope: .init(sessionID: route.hasPrefix("family") ? parent.id : target.sessionID, workspaceID: parent.workspaceID), title: "Child", archive: model.traces, workspace: model, usageLoader: { _,_,_ in throw CancellationError() })
                inspector.setVisible(true)
                try await eventually("Inspector request not captured") { inspector.index.requests.contains { $0.sessionID == target.sessionID } }
                if route == "standalone Inspector" { XCTAssertTrue(inspector.groups.isEmpty) }
                inspector.focus(.request(try XCTUnwrap(inspector.index.requests.first { $0.sessionID == target.sessionID }).id))
                let page = InspectorRequestPage(inspector: inspector, request: inspector.request, compact: true)
                let button = try XCTUnwrap(ConversationPaneTests.views(PiKit.Button.self, in: page).first { $0.title == (route.hasSuffix("Parent request") ? "Parent request" : "Originating tool") })
                button.onPress?()
                if route.hasSuffix("Parent request") {
                    let owner = route.hasPrefix("family") ? inspector : try XCTUnwrap(SessionInspectorWindows.shared.controller(sessionID: parent.id)?.inspector)
                    try await eventually("Parent request was excluded by its Inspector filter") { owner.page == .request(link.parentAttemptID ?? "") }
                    owner.showInChat()
                }
                try await eventually("Originating tool never selected the parent") { model.selectedID == parent.id && model.selected?.historyState != .loading }
                await model.navigationTask?.value
                // The action finishes its version lookup after selecting the parent.
                for _ in 0..<300 where model.displays[parent.id]?.reveal?.toolCallID != link.call.toolCallID { try await Task.sleep(for: .milliseconds(10)) }
                inspector.setVisible(false)
            }
            let view = try XCTUnwrap(model.displays[parent.id])
            XCTAssertEqual(view.versionView?.latestID, "replacement", route)
            XCTAssertEqual(view.reveal?.messageID, link.call.assistantMessageID, route)
            XCTAssertEqual(view.reveal?.toolCallID, link.call.toolCallID, route)
            XCTAssertTrue(view.presentedMessages.contains { $0.id == link.call.assistantMessageID }, route)
            XCTAssertNil(view.revealFailure, route)
            view.reveal = nil
        }
    }

    @MainActor func testRestoredChildPreviewDoesNotBlockAnyParentRecoveryEntryPoint() async throws {
        for route in ["sidebar Resume", "parent preview", "Back to Parent"] {
            let (setup, model, host, parent, target) = try await fixture()
            let pid = try XCTUnwrap(host.helperProcessIdentifier)
            XCTAssertEqual(kill(pid, SIGKILL), 0)
            try await eventually("Killed fixture helper stayed attached") { host.connectionID == nil && !model.opened.contains(parent.id) }
            let child = try XCTUnwrap(model.record(target.sessionID))
            _ = try await model.open(child)
            XCTAssertTrue(model.opened.contains(child.id))
            XCTAssertFalse(model.opened.contains(parent.id))
            // The explicit Next Request preview owns the same child runtime.
            _ = try await host.request("context.preview", sessionID: child.id)
            if route == "Back to Parent" { await model.backToSubagentParent(child.id) }
            else { await model.openFromSidebar(parent.id) }
            do {
                if route == "parent preview" {
                    _ = try await model.open(try XCTUnwrap(model.record(parent.id)))
                    _ = try await host.request("context.preview", sessionID: parent.id)
                } else {
                    var steps: [String] = []; model.resumeSteps = { steps.append($0) }
                    model.resumeRun(sessionID: parent.id)
                    try await eventually("Resume never settled: \(route)", timeout: .seconds(30)) { steps.contains("answered") || steps.contains("failed") }
                    XCTAssertTrue(steps.contains("answered"), "\(route): \(model.error ?? "no error")")
                }
                XCTAssertFalse(model.opened.contains(child.id), "\(route) must invalidate the restored reader")
                XCTAssertTrue(model.opened.contains(parent.id))
                await model.openSubagent(target)
                XCTAssertTrue(model.opened.contains(child.id), "The viewer can reopen after recovery")
            } catch { XCTFail("\(route): \(error)") }
            try Data().write(to: setup.root.appendingPathComponent("release-child"))
            model.shutdown(); try await host.shutdownAndWait()
        }
    }

    @MainActor func testUnloadDuringOpeningCannotReinsertAStaleChildRuntime() async throws {
        let (_, model, host, _, target) = try await fixture()
        // Deliver the same invalidation as family recovery, exactly after the
        // open reply and before the app finishes persisting/attaching it.
        host.requestObserver = { method, _, _ in
            if method == "session.open" {
                host.onEvent?(["type":.string("session.unloaded"), "sessionId":.string(target.sessionID)])
            }
        }
        await model.openSubagent(target)
        XCTAssertFalse(model.opened.contains(target.sessionID), "An overtaken open must not revive an invalidated runtime")
        host.requestObserver = nil
        await model.openSubagent(target)
        XCTAssertTrue(model.opened.contains(target.sessionID), "A new explicit open can attach normally")
    }

    @MainActor private func fixture(ancestor: Bool = false) async throws -> (GatewayWorkspace, WorkspaceModel, HostSupervisor, ChatRecord, SubagentTarget) {
        let setup = try await gatewayWorkspace("subagent-opening", projectID: "subagent-opening")
        let model = WorkspaceModel(stateRoot: setup.state, vault: setup.vault)
        model.automaticContextOperation = { _, _ in throw CancellationError() }
        addTeardownBlock { @MainActor in
            model.shutdown()
            for host in model.hosts.values { try? await host.shutdownAndWait() }
            try? await model.traces.close(); await model.store?.close()
        }
        try await model.reloadConfiguration()
        let parent = ChatRecord(id: UUID().uuidString, workspaceID: setup.workspace.id, title: "Parent", profileID: setup.profile.id)
        model.chats = [parent]
        try await model.store?.put(parent, kind: "chat", id: parent.id)
        let host = try await model.open(parent)
        if ancestor {
            _ = try await host.request("turn.submit", sessionID: parent.id, params: ["text":.string("Earlier task"), "clientTurnId":.string("ancestor")])
            try await waitForParent(parent.id, host: host)
        }
        _ = try await host.request("turn.submit", sessionID: parent.id, params: ["text":.string("delegate opening fixture"), "clientTurnId":.string(UUID().uuidString)])
        try await eventually("Child never reached its streaming barrier", timeout: .seconds(30)) {
            FileManager.default.fileExists(atPath: setup.root.appendingPathComponent("child-streaming").path)
        }
        await model.reconcileSubagents(parentID: parent.id)
        XCTAssertNil(model.error, "Discovery after the child starts: " + model.chats.map { "\($0.id): \($0.path ?? "no path")" }.joined(separator: "\n"))
        let child = try XCTUnwrap(model.chats.first { $0.isSubagent })
        return (setup, model, host, parent, SubagentTarget(try XCTUnwrap(child.delegation)))
    }

    @MainActor func testCardOpeningInheritsCaptureAndKeepsTheLiveChildAttached() async throws {
        try await checkOpening(sidebar: false)
    }
    @MainActor func testSidebarOpeningAttachesToTheStreamingChild() async throws {
        try await checkOpening(sidebar: true)
    }
    @MainActor private func checkOpening(sidebar: Bool) async throws {
        let (setup, model, host, parent, target) = try await fixture()
        if sidebar { await model.openFromSidebar(target.sessionID) }
        else { await model.openSubagent(target) }
        XCTAssertNil(model.error)
        XCTAssertTrue(model.opened.contains(target.sessionID), "The viewer must attach to the child's existing runtime")
        let inherited = try await model.capturePreference(sessionID: target.ownerID)
        XCTAssertEqual(model.displays[target.sessionID]?.captureMode, inherited.mode)
        try Data().write(to: setup.root.appendingPathComponent("release-child"))
        try await eventually("The child's saved snapshot never became its streamed final reply", timeout: .seconds(30)) {
            model.displays[target.sessionID]?.messages.contains { $0.role == "assistant" && $0.isStreaming != true && $0.text.contains("Unicode:") } == true
        }
        try await waitForParent(parent.id, host: host)
        _ = try await host.request("session.status", sessionID: target.sessionID)
        XCTAssertTrue(model.subagentGroupExpanded(target.ownerID))
    }

    @MainActor func testUnviewedTerminalChildIsEvictedAndCanReopenFromItsJournal() async throws {
        let (setup, model, host, parent, target) = try await fixture()
        try Data().write(to: setup.root.appendingPathComponent("release-child"))
        try await waitForParent(parent.id, host: host)
        do { _ = try await host.request("session.status", sessionID: target.sessionID); XCTFail("Unviewed terminal runtime was retained") }
        catch { XCTAssertTrue(error.localizedDescription.contains("loaded"), error.localizedDescription) }
        await model.openSubagent(target)
        XCTAssertNil(model.error); XCTAssertTrue(model.opened.contains(target.sessionID))
        let saved = try await host.request("session.snapshot", sessionID: target.sessionID)
        XCTAssertEqual(saved.object?["cost"]?.object?["reportedRequests"]?.number, 1)
    }

    @MainActor private func waitForParent(_ id: String, host: HostSupervisor) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            let state = try await host.request("session.status", sessionID: id)
            if state.object?["state"]?.string == "idle" { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The parent did not consume the settled child result")
    }
}
