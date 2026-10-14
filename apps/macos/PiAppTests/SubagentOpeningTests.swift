import XCTest
import Darwin
@testable import PiApp

/// Real helper navigation over a generated loopback stream. The fixture's
/// explicit barrier keeps a child active until its viewer has attached.
final class SubagentOpeningTests: XCTestCase, SerialTestLane {
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

    @MainActor private func fixture() async throws -> (GatewayWorkspace, WorkspaceModel, HostSupervisor, ChatRecord, SubagentTarget) {
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
