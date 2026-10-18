import AppKit
import XCTest
@testable import PiApp

@MainActor final class ToolOutputProducerTests: XCTestCase {
    private struct Fixture {
        let model: WorkspaceModel
        let store: MetadataStore
        let chat: ChatRecord
        let view: SessionDisplay
        let output: URL
    }

    private func fixture(_ name: String) async throws -> Fixture {
        let root = scratchRoot("output-producer-" + name), model = try SubagentOrganizationTests.fixture(root)
        registerWorkspaceFixtureTeardown(model,root:root)
        model.prewarmsHelpers = false
        model.automaticContextOperation = { _,_ in throw CancellationError() }
        let store = try XCTUnwrap(model.store), sessions = try model.subagentDirectory("pane-project")
        let folder = try ToolOutputOwnership.directory(root:sessions.appendingPathComponent("tool-output"),sessionID:"deleted",create:true)
        let output = folder.appendingPathComponent("result.log")
        try Data("PRODUCER-RETAINED-OUTPUT".utf8).write(to:output)
        let members = [SessionDeletionRecord(id:"deleted",ownerID:"deleted",workspaceID:"pane-project",path:nil,repairCompleted:true)]
        try await store.beginFamilyDeletion(members,repairCompleted:true)
        try await store.rememberDeletedToolOutputOwners(members)
        model.familyFileRecycler = { for file in $0 { try FileManager.default.removeItem(at:file) } }
        model.chats[0].path = sessions.appendingPathComponent(model.chats[0].id + ".jsonl").path
        let chat = model.chats[0]
        try SideKeepRecoveryTests.journal(id:chat.id).write(to:URL(fileURLWithPath:try XCTUnwrap(chat.path)))
        try await store.put(chat,kind:"chat",id:chat.id)
        let view = SessionDisplay(id:chat.id); view.selectionMetadataLoaded = true; view.draft = output.path
        model.displays[chat.id] = view; model.selectedID = chat.id
        return Fixture(model:model,store:store,chat:chat,view:view,output:output)
    }

    private func wait(_ reason: String, _ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for:.milliseconds(10))
        }
        XCTFail(reason)
    }

    /// Exercise each real entry point at its first suspension, then remove
    /// the previous holder as a concurrent deletion/unload may do. Its local
    /// work must keep the bytes until it publishes or abandons that reference.
    func testEveryReferenceProducerRegistersBeforeItsFirstSuspension() async throws {
        for kind in ToolOutputProducer.allCases {
            let f = try await fixture(kind.rawValue), model = f.model
            let gate = AsyncGate(); var entered = false
            model.toolOutputProducerStep = { producer in
                guard producer == kind else { return }
                entered = true; await gate.wait(); throw CancellationError()
            }
            let side = SideRecord(id:"moving-side",parentID:f.chat.id,workspaceID:f.chat.workspaceID,profileID:f.chat.profileID,title:"Side")
            var task: Task<Void,Never>?, window: NSWindow?, content: ConversationContentView?, handoff: SideHandoffView?
            switch kind {
            case .sideDraft:
                let view = SessionDisplay(id:side.id); view.draft = f.output.path
                model.sides[f.chat.id] = side; model.displays[side.id] = view
                task = Task { try? await model.moveSideDraft(side) }
            case .draftWrite: model.draftChanged(f.view)
            case .draftFlush: task = Task { try? await model.flushDrafts() }
            case .draftMaterialization:
                model.pendingChatIDs.insert(f.chat.id)
                task = Task { try? await model.materializeChat(f.chat.id) }
            case .draftRecovery:
                let intent = CommandIntent(id:"unsent",sessionID:f.chat.id,turnID:"turn",text:f.output.path,state:"intent",epoch:nil)
                f.view.recovered = [intent]; model.recoverDraft(intent,insert:true)
            case .submission: model.send(sessionID:f.chat.id)
            case .messageEdit: model.editMessage("message",sessionID:f.chat.id)
            case .queuedEdit:
                task = Task { _ = try? await model.queueEditRequest("queue.edit.save",sessionID:f.chat.id,params:["text":.string(f.output.path)]) }
            case .sidePublication:
                task = Task { try? await model.publishPendingSide(side,view:f.view,draft:DraftRecord(id:side.id,text:f.output.path)) }
            case .keep:
                model.sides[f.chat.id] = side
                model.displays[side.id] = SessionDisplay(id:side.id)
                model.hosts[f.chat.workspaceID] = HostSupervisor(commandSender:{ _ in XCTFail("The admission barrier must precede helper commands") })
                model.keepSide(side.id)
            case .sideClose:
                model.sides[f.chat.id] = side; model.displays[side.id] = SessionDisplay(id:side.id)
                model.closeSide(side.id)
            case .sideHandoff:
                // The editor is a holder for its whole lifetime, including
                // time before any asynchronous action has been requested.
                handoff = SideHandoffView(model:model,session:f.view,dismiss:{})
                handoff?.editor.text = f.output.path; entered = true
            case .keepRegistration:
                task = Task { try? await model.registerKeptSide(id:f.chat.id,path:f.chat.path) }
            case .keepDismissal:
                let issue = SideKeepIssue(chat:f.chat,parentTitle:nil,reason:"Fixture")
                model.sideKeepIssues = [issue]
                window = NSWindow(contentRect:.zero,styleMask:[],backing:.buffered,defer:false)
                window?.isReleasedWhenClosed = false
                var answer: ((Bool)->Void)?
                model.questions.presentSheet = { _,_,respond in answer = respond }
                model.dismissSideKeep(issue,over:try XCTUnwrap(window)); try XCTUnwrap(answer)(true)
            case .fork: task = Task { _ = try? await model.createFork(parentID:f.chat.id) }
            case .recovery: model.recoverCopy(f.chat.id)
            case .handoff: model.portableHandoff()
            case .importChat:
                task = Task { await model.importChat(from:URL(fileURLWithPath:f.chat.path!),workspaceID:f.chat.workspaceID,store:f.store) }
            case .export:
                content = ConversationContentView(model:model,sessionID:f.chat.id,pasteboard:NSPasteboard(name:.init(UUID().uuidString)))
                content?.copyRange.onPress?()
            }
            try await wait(kind.rawValue + " did not register") { entered }
            XCTAssertTrue(model.toolOutputProducers.values.contains(kind),kind.rawValue)
            model.displays.removeAll()
            try await model.recycleUnreferencedToolOutputs()
            XCTAssertTrue(FileManager.default.fileExists(atPath:f.output.path),kind.rawValue + " lost locally held output")
            await gate.open(); await task?.value; handoff?.cancel.onPress?()
            try await wait(kind.rawValue + " leaked a registration") { model.toolOutputProducers.isEmpty }
            content?.prepareForRelease(); window?.close()
            await model.toolOutputCleanup?.value
        }
    }

    func testEveryProducerWaitsThroughAnAlreadySubmittedRecycle() async throws {
        for kind in ToolOutputProducer.allCases {
            let f = try await fixture("recycle-" + kind.rawValue), model = f.model
            f.view.draft = ""
            let gate = AsyncGate(); var recycling = false, started = false
            model.familyFileRecycler = { _ in recycling = true; await gate.wait() }
            let collection = Task { try await model.recycleUnreferencedToolOutputs() }
            try await wait("Recycler did not start") { recycling }
            let use = model.beginToolOutputUse(kind)
            let producer = Task {
                defer { model.finishToolOutputUse(use) }
                try await model.prepareToolOutputUse(use)
                started = true
            }
            try await Task.sleep(for:.milliseconds(20))
            XCTAssertFalse(started,kind.rawValue + " overtook asynchronous recycling")
            XCTAssertEqual(model.toolOutputProducers[use.id],kind)
            await gate.open(); try await collection.value; try await producer.value
            XCTAssertTrue(started); XCTAssertTrue(model.toolOutputProducers.isEmpty)
        }
    }

    func testDisplacedAndQueuedDraftWritesRemainReferencesWithoutTheirDisplay() async throws {
        for queued in [false,true] {
            let f = try await fixture(queued ? "queued" : "displaced"), model = f.model
            let saved = DraftRecord(id:f.chat.id,text:f.output.path)
            if queued { f.view.queueEditingID = "turn"; f.view.draftBeforeQueueEdit = saved }
            else { f.view.editingMessageID = "message"; f.view.draftBeforeEdit = saved }
            f.view.draft = "Editing"
            let gate = AsyncGate(); var entered = false
            model.toolOutputProducerStep = { if $0 == .draftWrite { entered = true; await gate.wait() } }
            model.draftChanged(f.view)
            try await wait("Draft write did not start") { entered }
            model.displays.removeValue(forKey:f.chat.id)
            try await model.recycleUnreferencedToolOutputs()
            XCTAssertTrue(FileManager.default.fileExists(atPath:f.output.path))
            await gate.open(); await model.draftWrites.tasks[f.chat.id]?.value
            try await model.recycleUnreferencedToolOutputs()
            XCTAssertTrue(FileManager.default.fileExists(atPath:f.output.path),"The committed displaced/queued draft still owns the file")
        }
    }

    func testCancelledExportScopeRetainsOutputUntilItsReaderActuallyReturns() async throws {
        let f = try await fixture("cancelled-export"), model = f.model
        f.view.draft = ""
        let scope = PayloadTaskScope(), gate = AsyncGate(), use = model.beginToolOutputUse(.export)
        var entered = false, completed = false
        let task = scope.run({
            try await model.prepareToolOutputUse(use)
            entered = true; await gate.wait()
        },finally:{ model.finishToolOutputUse(use) }) { _ in completed = true }
        try await wait("Export did not start") { entered }
        scope.cancel()
        try await model.recycleUnreferencedToolOutputs()
        XCTAssertTrue(FileManager.default.fileExists(atPath:f.output.path))
        XCTAssertFalse(model.toolOutputProducers.isEmpty)
        await gate.open(); await task?.value
        XCTAssertFalse(completed); XCTAssertTrue(model.toolOutputProducers.isEmpty)
        await model.toolOutputCleanup?.value
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.output.path))
    }

    func testProducerArrivingDuringReferenceScanPreventsRecycleUntilPublication() async throws {
        let f = try await fixture("late-producer"), model = f.model
        f.view.draft = ""
        let scan = AsyncGate(), publication = AsyncGate()
        var scanned = false, producing = false
        model.toolOutputReferenceScanStep = { scanned = true; await scan.wait() }
        let collection = Task { try await model.recycleUnreferencedToolOutputs() }
        try await wait("Scan did not finish") { scanned }
        let use = model.beginToolOutputUse(.recovery)
        let producer = Task {
            defer { model.finishToolOutputUse(use) }
            try await model.prepareToolOutputUse(use)
            producing = true; await publication.wait()
            try await f.store.put(DraftRecord(id:"survivor",text:f.output.path),kind:"draft",id:"survivor")
        }
        await scan.open(); try await collection.value
        try await wait("Producer never passed the deferred collection") { producing }
        XCTAssertTrue(FileManager.default.fileExists(atPath:f.output.path))
        await publication.open(); try await producer.value; await model.toolOutputCleanup?.value
        XCTAssertTrue(FileManager.default.fileExists(atPath:f.output.path),"The fresh scan must find the published reference")
    }

    func testEditableSideHandoffRetainsOutputUntilDismissed() async throws {
        let f = try await fixture("side-handoff"), model = f.model
        f.view.draft = ""
        let handoff = SideHandoffView(model:model,session:f.view,dismiss:{})
        handoff.editor.text = f.output.path
        try await model.recycleUnreferencedToolOutputs()
        XCTAssertTrue(FileManager.default.fileExists(atPath:f.output.path),"The editable handoff is a reference even before it reaches a composer")
        handoff.cancel.onPress?()
        try await model.recycleUnreferencedToolOutputs()
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.output.path),"Dismissal releases the abandoned handoff")
    }

    func testSideHandoffWaitsForRecyclingAndDismissalCancelsPendingInsertion() async throws {
        for dismiss in [false,true] {
            let f = try await fixture("handoff-admission-\(dismiss)"), model = f.model
            f.view.draft = ""
            let gate = AsyncGate(); var recycling = false
            model.familyFileRecycler = { _ in recycling = true; await gate.wait() }
            let collection = Task { try await model.recycleUnreferencedToolOutputs() }
            try await wait("Recycler did not start") { recycling }
            let side = SideRecord(id:"handoff-side",parentID:f.chat.id,workspaceID:f.chat.workspaceID,profileID:f.chat.profileID,title:"Side",kept:true)
            model.sides[f.chat.id] = side
            let view = SessionDisplay(id:side.id); model.displays[side.id] = view
            let handoff = SideHandoffView(model:model,session:view,dismiss:{})
            handoff.editor.text = f.output.path; handoff.insert.onPress?()
            XCTAssertTrue(f.view.draft.isEmpty,"The handoff cannot publish during recycling")
            if dismiss { handoff.cancel.onPress?() }
            await gate.open(); try await collection.value
            try await wait("Handoff did not settle") { model.toolOutputProducers.isEmpty }
            XCTAssertEqual(f.view.draft,dismiss ? "" : f.output.path)
        }
    }
}
