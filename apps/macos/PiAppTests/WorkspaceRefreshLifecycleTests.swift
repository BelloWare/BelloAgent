import XCTest
@testable import PiApp

@MainActor private final class RefreshCommandLog {
    var frames: [[String: WireValue]] = []
}

@MainActor private struct RefreshFixture {
    let root: URL
    let model: WorkspaceModel
    let chat: ChatRecord
    let view: SessionDisplay
    let host: HostSupervisor
    let commands: RefreshCommandLog
}

final class WorkspaceRefreshLifecycleTests: XCTestCase {
    @MainActor private func fixture() async throws -> RefreshFixture {
        let root=URL(fileURLWithPath:scratchBase())
            .appendingPathComponent("refresh-lifecycle-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let model=WorkspaceModel(stateRoot:root.appendingPathComponent("state"),vault:ConfigurationVault(storage:MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model,root:root)
        try await model.reloadConfiguration()
        let chat=ChatRecord(id:"chat",workspaceID:"project",title:"Chat",path:nil,profileID:"profile")
        let view=SessionDisplay(id:chat.id)
        view.messages=[TranscriptMessage(id:"question",role:"user",text:"Question")]
        view.projectionRevision="old-runtime:1"; view.pageStartEnsured=true
        model.chats=[chat]; model.displays[chat.id]=view; model.selectedID=chat.id; model.selected=view
        let commands=RefreshCommandLog(), host=HostSupervisor(commandSender:{ commands.frames.append($0) })
        try await host.connect(cwd:root,state:root.appendingPathComponent("host"))
        model.hosts[chat.workspaceID]=host; model.opened.insert(chat.id)
        host.onLoss={ [weak model, weak view, weak host] in
            guard let model, let host, model.hosts[chat.workspaceID] === host else { return }
            model.opened.remove(chat.id)
            view?.lastSequence = -1; view?.state="interrupted"; view?.runStatus="interrupted"
            view?.notice="Host interrupted. No command was replayed."
        }
        return RefreshFixture(root:root,model:model,chat:chat,view:view,host:host,commands:commands)
    }

    @MainActor private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<2_000 {
            if condition() { return }
            try await Task.sleep(for:.milliseconds(1))
        }
        XCTFail("Refresh did not reach the expected state",file:file,line:line)
        throw HostError.failure("Timed out waiting for refresh")
    }

    @MainActor private func reply(_ frame: [String: WireValue], on host: HostSupervisor,
                                  result: [String: WireValue], ok: Bool = true) throws {
        let connection=try XCTUnwrap(host.connectionID), epoch=try XCTUnwrap(host.epoch)
        host.receive(.frame(["v":.number(1),"kind":.string("reply"),"hostEpoch":.string(epoch),
            "commandId":try XCTUnwrap(frame["commandId"]),"ok":.bool(ok),"result":.object(result)]),connectionID:connection)
    }

    private func snapshot(sequence: Double, revision: String, text: String? = nil) -> [String: WireValue] {
        var value: [String: WireValue]=["seq":.number(sequence),"state":.string("idle"),"runStatus":.string("idle"),
            "displayRevision":.string(revision),"commands":.array([])]
        if let text {
            value["messages"] = .array([.object(["id":.string("question"),"role":.string("user"),"text":.string(text)])])
        }
        return value
    }

    @MainActor func testAcceptedReplyCannotEraseHostLossBeforeItsContinuationRuns() async throws {
        let f=try await fixture()
        f.model.refresh(f.chat.id)
        try await wait { f.commands.frames.count==1 }
        let connection=try XCTUnwrap(f.host.connectionID)
        // Do not yield between accepting the reply and losing the connection:
        // the queued refresh continuation belongs to the retired connection.
        try reply(f.commands.frames[0],on:f.host,result:snapshot(sequence:99,revision:"retired:99",text:"Stale reply"))
        f.host.receive(.failed("Synthetic lost connection"),connectionID:connection)
        try await wait { !f.view.snapshotInFlight }
        XCTAssertEqual(f.view.state,"interrupted")
        XCTAssertEqual(f.view.notice,"Host interrupted. No command was replayed.")
        XCTAssertEqual(f.view.lastSequence,-1)
        XCTAssertEqual(f.view.messages.first?.text,"Question")
        XCTAssertEqual(f.view.projectionRevision,"old-runtime:1")
        XCTAssertFalse(f.view.dirty)
        try await f.host.shutdownAndWait()
    }

    @MainActor func testReplacementHostRefreshSurvivesOldSameViewRequestUnwinding() async throws {
        let f=try await fixture(), freshCommands=RefreshCommandLog()
        let freshHost=HostSupervisor(commandSender:{ freshCommands.frames.append($0) })
        try await freshHost.connect(cwd:f.root,state:f.root.appendingPathComponent("replacement-host"))
        defer { freshHost.shutdown() }
        f.model.refresh(f.chat.id)
        try await wait { f.commands.frames.count==1 }
        let connection=try XCTUnwrap(f.host.connectionID)
        try reply(f.commands.frames[0],on:f.host,result:snapshot(sequence:99,revision:"retired:99",text:"Stale reply"))
        f.host.receive(.failed("Synthetic lost connection"),connectionID:connection)
        f.model.hosts[f.chat.workspaceID]=freshHost; f.model.opened.insert(f.chat.id)
        f.view.state="idle"; f.view.runStatus="idle"; f.view.notice="Replacement is ready"
        f.model.refresh(f.chat.id)
        XCTAssertTrue(f.view.snapshotInFlight); XCTAssertTrue(f.view.dirty)
        try await wait { freshCommands.frames.count==1 }
        XCTAssertEqual(f.view.messages.first?.text,"Question")
        XCTAssertEqual(f.view.lastSequence,-1)
        XCTAssertEqual(f.view.notice,"Replacement is ready")
        try reply(freshCommands.frames[0],on:freshHost,result:snapshot(sequence:1,revision:"replacement:1",text:"Fresh reply"))
        try await wait { !f.view.snapshotInFlight }
        XCTAssertEqual(f.view.messages.first?.text,"Fresh reply")
        XCTAssertEqual(f.view.lastSequence,1)
        XCTAssertEqual(f.view.projectionRevision,"replacement:1")
        XCTAssertFalse(f.view.dirty)
        try await f.host.shutdownAndWait(); try await freshHost.shutdownAndWait()
    }

    @MainActor func testRetiredFailureCannotOverwriteReplacementDisplayNotice() async throws {
        let f=try await fixture()
        f.model.refresh(f.chat.id)
        try await wait { f.commands.frames.count==1 }
        let replacement=SessionDisplay(id:f.chat.id)
        replacement.messages=[TranscriptMessage(id:"replacement",role:"user",text:"Replacement")]
        replacement.notice="Current view notice"
        f.model.displays[f.chat.id]=replacement; f.model.selected=replacement
        f.view.notice="Retired view notice"
        try reply(f.commands.frames[0],on:f.host,result:["code":.string("fixture"),"message":.string("Stale failure")],ok:false)
        try await wait { !f.view.snapshotInFlight }
        XCTAssertEqual(replacement.notice,"Current view notice")
        XCTAssertEqual(f.view.notice,"Retired view notice")
        XCTAssertEqual(replacement.messages.first?.text,"Replacement")
        XCTAssertEqual(f.commands.frames.count,1)
        XCTAssertFalse(f.view.dirty)
        try await f.host.shutdownAndWait()
    }

    @MainActor func testSelectingDuringBackgroundStatusGetsFullOpaqueRevisionAndKeepsCursor() async throws {
        let f=try await fixture()
        f.model.selectedID="other"; f.model.selected=nil; f.view.hostBefore=12
        f.model.refresh(f.chat.id)
        try await wait { f.commands.frames.count==1 }
        XCTAssertEqual(f.commands.frames[0]["method"]?.string,"session.status")
        f.model.selectedID=f.chat.id; f.model.selected=f.view; f.model.refresh(f.chat.id)
        try reply(f.commands.frames[0],on:f.host,result:snapshot(sequence:2,revision:"same-runtime:2"))
        try await wait { f.commands.frames.count==2 }
        XCTAssertEqual(f.commands.frames[1]["method"]?.string,"session.snapshot")
        XCTAssertEqual(f.commands.frames[1]["params"]?.object?["displayRevision"]?.string,"old-runtime:1",
                       "A status token is not proof that its transcript was received")
        XCTAssertEqual(f.view.hostBefore,12,"Omitted status cursor must not erase the visible page cursor")
        var full=snapshot(sequence:2,revision:"same-runtime:2",text:"Current transcript"); full["before"] = .number(6)
        try reply(f.commands.frames[1],on:f.host,result:full)
        try await wait { !f.view.snapshotInFlight }
        XCTAssertEqual(f.view.messages.first?.text,"Current transcript")
        XCTAssertEqual(f.view.projectionRevision,"same-runtime:2")
        XCTAssertEqual(f.view.hostBefore,6)
        XCTAssertFalse(f.view.dirty)
        try await f.host.shutdownAndWait()
    }
}
