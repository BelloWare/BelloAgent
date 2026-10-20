import Foundation
import XCTest
@testable import PiApp

final class SubagentDeletionTests: XCTestCase {
    @MainActor func testSideDraftTransferKeepsOutputWhileParentIsUnloaded() async throws {
        let root = scratchRoot("transferring-output"), model = try SubagentOrganizationTests.fixture(root)
        registerWorkspaceFixtureTeardown(model, root: root)
        let store = try XCTUnwrap(model.store)
        let members = [SessionDeletionRecord(id:"deleted",ownerID:"deleted",workspaceID:"pane-project",path:nil,repairCompleted:true)]
        try await store.beginFamilyDeletion(members,repairCompleted:true)
        try await store.rememberDeletedToolOutputOwners(members)
        let folder = try ToolOutputOwnership.directory(root:model.subagentDirectory("pane-project").appendingPathComponent("tool-output"),sessionID:"deleted",create:true)
        let output = folder.appendingPathComponent("result.log")
        try Data("SURVIVING-DRAFT-OUTPUT".utf8).write(to:output)
        let info = SideRecord(id:"moving-side",parentID:"chat-parent",workspaceID:"pane-project",profileID:"fixture",title:"Side",pending:true)
        let side = SessionDisplay(id:info.id); side.draft = output.path
        model.sides[info.parentID] = info; model.displays[info.id] = side
        model.displays.removeValue(forKey:info.parentID)
        let gate = AsyncGate(); var transferring = false
        model.sideDraftTransferStep = { transferring = true; await gate.wait() }
        model.familyFileRecycler = { for file in $0 { try FileManager.default.removeItem(at:file) } }
        let moving = Task { try await model.moveSideDraft(info) }
        for _ in 0..<500 where !transferring { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertTrue(transferring); XCTAssertTrue(side.draft.isEmpty)
        try await model.recycleUnreferencedToolOutputs()
        XCTAssertTrue(FileManager.default.fileExists(atPath:output.path),"The transfer owns the draft after its composer is cleared")
        await gate.open(); try await moving.value
        let saved = try await store.get(DraftRecord.self,kind:"draft",id:info.parentID)
        XCTAssertEqual(saved?.text,output.path)
        try await model.recycleUnreferencedToolOutputs()
        XCTAssertTrue(FileManager.default.fileExists(atPath:output.path))
    }

    @MainActor func testRetainedExternalCopySurvivesAnotherCopyWithSameIDBeingDeleted() async throws {
        let root = scratchRoot("retained-copy-output"), model = try SubagentOrganizationTests.fixture(root)
        registerWorkspaceFixtureTeardown(model,root:root)
        try await model.traces.configure(quota:nil,bodyRetention:86_400,metricRetention:86_400)
        let store = try XCTUnwrap(model.store)
        let folder = try ToolOutputOwnership.directory(root:model.subagentDirectory("pane-project").appendingPathComponent("tool-output"),sessionID:"deleted",create:true)
        let output = folder.appendingPathComponent("result.log")
        try Data("RETAINED-COPY-OUTPUT".utf8).write(to:output)
        let external = root.appendingPathComponent("retained-copy.jsonl")
        var row = try JSONEncoder().encode(["text":output.path]); row.append(10); try row.write(to:external)
        let retained = ChatRecord(id:"deleted",workspaceID:"another-project",title:"Independent copy",path:external.path,profileID:"fixture")
        try await store.put(SideKeepIntent(chat:retained),kind:"side-keep",id:retained.id)
        try await store.dismissSideKeep(retained)
        let pendingOutput = folder.appendingPathComponent("pending.log"), pendingCopy = root.appendingPathComponent("pending-copy.jsonl")
        try Data("PENDING-COPY-OUTPUT".utf8).write(to:pendingOutput)
        var pendingRow = try JSONEncoder().encode(["text":pendingOutput.path]); pendingRow.append(10); try pendingRow.write(to:pendingCopy)
        var pending = retained; pending.path = pendingCopy.path
        try await store.put(SideKeepIntent(chat:pending),kind:"side-keep",id:pending.id)
        let members = [SessionDeletionRecord(id:"deleted",ownerID:"deleted",workspaceID:"pane-project",path:nil,repairCompleted:true)]
        try await store.beginFamilyDeletion(members,repairCompleted:true)
        try await store.rememberDeletedToolOutputOwners(members)
        model.familyFileRecycler = { for file in $0 { try FileManager.default.removeItem(at:file) } }
        try await model.recycleUnreferencedToolOutputs()
        XCTAssertTrue(FileManager.default.fileExists(atPath:output.path),"A tombstone for a chat ID does not delete independently retained copies")
        XCTAssertTrue(FileManager.default.fileExists(atPath:pendingOutput.path),"A pending keep also owns its particular copy")
        XCTAssertEqual(try Data(contentsOf:external),row)
        try await model.finishFamilyDeletion(members)
        while let cleanup = model.toolOutputCleanup { await cleanup.value }
        XCTAssertTrue(FileManager.default.fileExists(atPath:pendingOutput.path),"Finishing deletion must not drop a different pending copy's ownership")
        let copies = try await store.list(SideKeepIntent.self,kind:SideKeepIntent.retainedKind)
        XCTAssertTrue(copies.contains { $0.chat == pending },"The independent pending copy must transfer to durable retained ownership")
    }

    @MainActor func testDeletingMatchingPendingCopyReleasesItsOutput() async throws {
        try await checkDeletingMatchingPendingCopy(interrupted: false)
    }

    @MainActor func testRetiredKeepReclaimsOutputEvenWhenLaterMetadataCleanupFails() async throws {
        try await checkDeletingMatchingPendingCopy(interrupted: true)
    }

    @MainActor private func checkDeletingMatchingPendingCopy(interrupted: Bool) async throws {
        let root = scratchRoot("matching-pending-output"), model = try SubagentOrganizationTests.fixture(root)
        registerWorkspaceFixtureTeardown(model,root:root)
        try await model.traces.configure(quota:nil,bodyRetention:86_400,metricRetention:86_400)
        let store = try XCTUnwrap(model.store), sessions = try model.subagentDirectory("pane-project")
        let folder = try ToolOutputOwnership.directory(root:sessions.appendingPathComponent("tool-output"),sessionID:"deleted",create:true)
        let output = folder.appendingPathComponent("result.log"), journal = sessions.appendingPathComponent("deleted.jsonl")
        try Data("DELETED-COPY-OUTPUT".utf8).write(to:output)
        var row = try JSONEncoder().encode(["text":output.path]); row.append(10); try row.write(to:journal)
        let pending = ChatRecord(id:"deleted",workspaceID:"pane-project",title:"Deleted copy",path:journal.path,profileID:"fixture")
        try await store.put(SideKeepIntent(chat:pending),kind:"side-keep",id:pending.id)
        let members = [SessionDeletionRecord(id:pending.id,ownerID:pending.id,workspaceID:pending.workspaceID,path:pending.path,repairCompleted:true)]
        try await store.beginFamilyDeletion(members,repairCompleted:true)
        model.familyFileRecycler = { for file in $0 { try FileManager.default.removeItem(at:file) } }
        model.familyDeletionStep = { if interrupted, $0 == "metadata:" + pending.id { throw StoreError.unavailable } }
        do {
            try await model.finishFamilyDeletion(members)
            XCTAssertFalse(interrupted)
        } catch {
            XCTAssertTrue(interrupted); XCTAssertEqual(error as? StoreError, .unavailable)
        }
        try await eventually("deletion's automatic final output collection", timeout:.seconds(2)) {
            !FileManager.default.fileExists(atPath:output.path)
        }
        let copies = try await store.list(SideKeepIntent.self,kind:SideKeepIntent.retainedKind)
        XCTAssertFalse(copies.contains { $0.chat == pending },"The exact deleted journal has no surviving reference")
    }

    @MainActor func testDeletingImportedReferenceAutomaticallyReclaimsOutput() async throws {
        let root = scratchRoot("deleted-import-output"), model = try SubagentOrganizationTests.fixture(root)
        registerWorkspaceFixtureTeardown(model, root: root)
        model.prewarmsHelpers = false
        try await model.traces.configure(quota: nil, bodyRetention: 86_400, metricRetention: 86_400)
        let store = try XCTUnwrap(model.store), sessions = try model.subagentDirectory("pane-project")
        let folder = try ToolOutputOwnership.directory(root: sessions.appendingPathComponent("tool-output"), sessionID: "deleted", create: true)
        let output = folder.appendingPathComponent("result.log"), journal = root.appendingPathComponent("external.jsonl")
        try Data("IMPORTED-REFERENCE".utf8).write(to: output)
        var row = try JSONEncoder().encode(["text": output.path]); row.append(10); try row.write(to: journal)
        let chat = ChatRecord(id: "imported", workspaceID: "pane-project", title: "Imported", path: journal.path, profileID: "fixture", imported: true)
        try await store.put(chat, kind: "chat", id: chat.id)
        let members = [SessionDeletionRecord(id: "deleted", ownerID: "deleted", workspaceID: chat.workspaceID, path: nil, repairCompleted: true)]
        try await store.beginFamilyDeletion(members, repairCompleted: true)
        try await store.rememberDeletedToolOutputOwners(members)
        model.familyFileRecycler = { for file in $0 { try FileManager.default.removeItem(at: file) } }
        model.chats = [chat]; model.selectedID = chat.id; model.questions.answer = { _ in true }
        model.deleteChat()
        try await eventually("the imported index removal") { model.record(chat.id) == nil }
        try await eventually("import deletion's automatic output collection", timeout: .seconds(2)) { !FileManager.default.fileExists(atPath: output.path) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path), "The external original stays in place")
    }

    @MainActor func testFailedAndCancelledSweepsDoNotStrandLaterCleanup() async throws {
        let root = scratchRoot("cancelled-output-recycling"), model = try SubagentOrganizationTests.fixture(root)
        registerWorkspaceFixtureTeardown(model,root:root)
        let store = try XCTUnwrap(model.store), members = [SessionDeletionRecord(id:"deleted",ownerID:"deleted",workspaceID:"pane-project",path:nil)]
        try await store.beginFamilyDeletion(members,repairCompleted:true)
        try await store.rememberDeletedToolOutputOwners(members)
        let folder = try ToolOutputOwnership.directory(root:model.subagentDirectory("pane-project").appendingPathComponent("tool-output"),sessionID:"deleted",create:true)
        try Data("unreferenced".utf8).write(to:folder.appendingPathComponent("result.log"))
        let gate = AsyncGate(); var passes = 0
        model.familyFileRecycler = { files in
            passes += 1
            if passes == 1 { await gate.wait(); throw StoreError.unavailable }
            for file in files { try FileManager.default.removeItem(at:file) }
        }
        let first = Task { try await model.recycleUnreferencedToolOutputs() }
        for _ in 0..<500 where passes == 0 { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(passes,1)
        let running = model.toolOutputRecycling?.id
        let cancelled = Task { try await model.recycleUnreferencedToolOutputs() }
        for _ in 0..<500 where model.toolOutputRecycling?.id == running { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertNotEqual(model.toolOutputRecycling?.id,running)
        cancelled.cancel()
        let last = Task { try await model.recycleUnreferencedToolOutputs() }
        await gate.open()
        do { try await first.value; XCTFail("The failing recycler must report its error") }
        catch { XCTAssertEqual(error as? StoreError,.unavailable) }
        do { try await cancelled.value; XCTFail("A cancelled sweep must not recycle") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await last.value
        XCTAssertEqual(passes,2)
        XCTAssertFalse(FileManager.default.fileExists(atPath:folder.path))
        XCTAssertNil(model.toolOutputRecycling)
    }

    @MainActor func testOverlappingWorkspaceDeletionsSerializeSharedOutputRecycling() async throws {
        let root = scratchRoot("overlapping-output-recycling"), model = try SubagentOrganizationTests.fixture(root)
        registerWorkspaceFixtureTeardown(model, root: root)
        try await model.traces.configure(quota:nil,bodyRetention:86_400,metricRetention:86_400)
        let store = try XCTUnwrap(model.store)
        let first = [SessionDeletionRecord(id:"deleted-a",ownerID:"deleted-a",workspaceID:"pane-project",path:nil,repairCompleted:true)]
        let second = [SessionDeletionRecord(id:"deleted-b",ownerID:"deleted-b",workspaceID:"other-project",path:nil,repairCompleted:true)]
        for members in [first,second] {
            try await store.beginFamilyDeletion(members,repairCompleted:true)
            try await store.rememberDeletedToolOutputOwners(members)
            let folder = try ToolOutputOwnership.directory(root:model.subagentDirectory(members[0].workspaceID).appendingPathComponent("tool-output"),sessionID:members[0].id,create:true)
            try Data("unreferenced".utf8).write(to:folder.appendingPathComponent("result.log"))
        }
        let gate = AsyncGate()
        var recycling = 0, peak = 0, entered = false, secondReady = false
        model.familyDeletionStep = { if $0 == "files:deleted-b" { secondReady = true } }
        model.familyFileRecycler = { files in
            recycling += 1; peak = max(peak,recycling)
            defer { recycling -= 1 }
            if !entered { entered = true; await gate.wait() }
            for file in files { try FileManager.default.removeItem(at:file) }
        }
        let a = Task { try await model.finishFamilyDeletion(first) }
        for _ in 0..<500 where !entered { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertTrue(entered,"First sweep never reached recycling")
        let b = Task { try await model.finishFamilyDeletion(second) }
        for _ in 0..<500 where !secondReady { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertTrue(secondReady,"Second deletion never reached its sweep")
        try await Task.sleep(for:.milliseconds(300))
        await gate.open()
        for task in [a,b] {
            do { try await task.value } catch { XCTFail("Overlapping deletion failed: \(error)") }
        }
        XCTAssertEqual(peak,1,"Only one global inventory/recycle pass may be in flight")
        let pending = try await store.pendingFamilyDeletions()
        XCTAssertTrue(pending.isEmpty,"Both deletions must retire their durable intents")
    }

    @MainActor func testDeletingSourceKeepsCloneAndCopyForksFullToolOutputUntilLastReference() async throws {
        let bench = try await LifecycleHelperTests.Bench("fork-output-ownership")
        addTeardownBlock { @MainActor in await bench.close() }
        let model = bench.model, parent = try await bench.newChat("Source")
        let script = "print('SYNTHETIC-TOOL-OUTPUT')\nfor i in range(5000): print('retained line %05d' % i)\nprint('FORK-RETAINED-SENTINEL')\n"
        try Data(script.utf8).write(to:bench.folder.appendingPathComponent("stress-output.py"))
        let host = try await model.open(parent)
        _ = try await host.request("turn.submit",sessionID:parent.id,params:["clientTurnId":.string("output"),"text":.string("stress tool")])
        var settled: [String:WireValue] = [:]
        for _ in 0..<1000 {
            settled = try await host.request("session.snapshot",sessionID:parent.id).object ?? [:]
            if ["idle","error","paused"].contains(settled["state"]?.string ?? "") { break }
            try await Task.sleep(for:.milliseconds(10))
        }
        XCTAssertEqual(settled["state"]?.string,"idle")
        let source = try XCTUnwrap(model.record(parent.id)), sourcePath = URL(fileURLWithPath:try XCTUnwrap(source.path))
        let owned = try ToolOutputOwnership.directory(root:sourcePath.deletingLastPathComponent().appendingPathComponent("tool-output"),sessionID:parent.id)
        let output = try XCTUnwrap(FileManager.default.contentsOfDirectory(at:owned,includingPropertiesForKeys:nil).first { $0.pathExtension == "log" })
        XCTAssertTrue(try String(contentsOf:output,encoding:.utf8).contains("FORK-RETAINED-SENTINEL"))
        let unreferenced = owned.appendingPathComponent("crash-left.log"); try Data("unreferenced".utf8).write(to:unreferenced)
        let sourceLines = try Data(contentsOf:sourcePath).split(separator:10)
        var forks: [ChatRecord] = []
        for id in ["fork", "copy-fork-with-an-identity-longer-than-the-source-uuid"] {
            let made = try await host.request("session.fork",sessionID:parent.id,params:["forkSessionId":.string(id)])
            let path = try XCTUnwrap(made.object?["path"]?.string), lines = try Data(contentsOf:URL(fileURLWithPath:path)).split(separator:10)
            XCTAssertEqual(Array(lines.dropFirst().prefix(sourceLines.count - 1)) == Array(sourceLines.dropFirst()),id == "fork","Exercise both clone and copy fork paths")
            let fork = ChatRecord(id:id,workspaceID:parent.workspaceID,title:id,path:path,profileID:parent.profileID,parentSessionID:parent.id)
            try await model.store?.put(fork,kind:"chat",id:id); model.chats.append(fork); model.opened.insert(id); forks.append(fork)
        }
        model.familyFileRecycler = { urls in for url in urls { try FileManager.default.removeItem(at:url) } }
        try await model.deleteSubagentFamily(source)
        XCTAssertFalse(FileManager.default.fileExists(atPath:sourcePath.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:unreferenced.path),"Unreferenced output still belongs to the deleted source")
        for fork in forks {
            let rows = try Data(contentsOf:URL(fileURLWithPath:try XCTUnwrap(fork.path))).split(separator:10)
                .map { try JSONDecoder().decode([String:WireValue].self,from:Data($0)) }
            let message = try XCTUnwrap(rows.compactMap { $0["message"]?.object }.first { $0["role"]?.string == "toolResult" })
            let result = try XCTUnwrap(message["content"]?.array?.first?.object?["text"]?.string)
            let start = try XCTUnwrap(result.range(of:" bytes at ",options:.backwards))
            let end = try XCTUnwrap(result.range(of:". Use read with offset/limit to inspect.",range:start.upperBound..<result.endIndex))
            let retained = URL(fileURLWithPath:String(result[start.upperBound..<end.lowerBound]))
            XCTAssertEqual(retained.lastPathComponent,output.lastPathComponent)
            XCTAssertTrue(retained.path.contains("tool-output/"+parent.id+"/"))
            XCTAssertFalse(result.contains("FORK-RETAINED-SENTINEL"),"The sentinel requires the full file")
            do { let full = try String(contentsOf:retained,encoding:.utf8); XCTAssertTrue(full.contains("FORK-RETAINED-SENTINEL"),fork.id) }
            catch { XCTFail("\(fork.id) lost its full output after source deletion: \(error)") }
        }
        try await model.deleteSubagentFamily(forks[0])
        XCTAssertTrue(FileManager.default.fileExists(atPath:output.path),"The other fork still references the original bytes")
        let relaunched = try await bench.relaunch()
        relaunched.familyFileRecycler = { urls in for url in urls { try FileManager.default.removeItem(at:url) } }
        try await relaunched.deleteSubagentFamily(try XCTUnwrap(relaunched.record(forks[1].id)))
        XCTAssertFalse(FileManager.default.fileExists(atPath:owned.path),"The last reference releases the deleted source's retained output")
    }

    @MainActor func testOutputRetentionIncludesUnlistedSidesImportedHistoryAndUnsentDrafts() async throws {
        let root = scratchRoot("output-reference-sweep"), model = try SubagentOrganizationTests.fixture(root)
        registerWorkspaceFixtureTeardown(model, root: root)
        let store = try XCTUnwrap(model.store), sessions = try model.subagentDirectory("pane-project")
        let owner = try ToolOutputOwnership.directory(root:sessions.appendingPathComponent("tool-output"),sessionID:"original",create:true)
        let outputs = (0..<6).map { owner.appendingPathComponent("output-\($0).txt") }
        for file in outputs { try Data("retained output".utf8).write(to:file) }
        let side = model.root.appendingPathComponent("Workspaces/other-project/Sessions/side_unlisted.jsonl")
        try FileManager.default.createDirectory(at:side.deletingLastPathComponent(),withIntermediateDirectories:true)
        let imported = root.appendingPathComponent("imported-original.jsonl")
        for (path, output) in [(side,outputs[0]),(imported,outputs[1])] {
            let row: [String:WireValue] = ["type":.string("message"),"text":.string(output.path)]
            var data = try JSONEncoder().encode(row); data.append(10); try data.write(to:path)
        }
        let chat = ChatRecord(id:"imported",workspaceID:"pane-project",title:"Imported",path:imported.path,profileID:"fixture",imported:true)
        try await store.put(chat,kind:"chat",id:chat.id)
        try await store.put(DraftRecord(id:"unsent",text:outputs[2].path),kind:"draft",id:"unsent")
        let live = SessionDisplay(id:"live"); live.draftBeforeQueueEdit = DraftRecord(id:live.id,text:outputs[3].path); model.displays[live.id] = live
        // A completed deletion leaves its tombstone, not its old draft, as
        // authority. Relaunch must revisit retained outputs without an intent.
        try await store.put(DraftRecord(id:"original",text:outputs[4].path),kind:"draft",id:"original")
        try await store.put(DraftRecord(id:"original",text:outputs[5].path),kind:"future:original",id:"original")
        let members = [SessionDeletionRecord(id:"original",ownerID:"original",workspaceID:"pane-project",path:nil)]
        try await store.beginFamilyDeletion(members,repairCompleted:true)
        try await store.remove(kind:SessionDeletionRecord.kind,id:"original")
        model.familyFileRecycler = { files in for file in files { try FileManager.default.removeItem(at:file) } }
        try await model.recycleUnreferencedToolOutputs()
        XCTAssertTrue(outputs.allSatisfy { FileManager.default.fileExists(atPath:$0.path) },"An older unscoped tombstone cannot claim output")
        try await store.rememberDeletedToolOutputOwners(members)
        do {
            try await store.rememberDeletedToolOutputOwners([SessionDeletionRecord(id:"original",ownerID:"original",workspaceID:"other-project",path:nil)])
            XCTFail("Deletion authority cannot be moved to another project")
        } catch { XCTAssertEqual(error as? StoreError,.invalidRecord) }
        try await model.recycleUnreferencedToolOutputs()
        XCTAssertNil(model.error)
        XCTAssertTrue(outputs.prefix(4).allSatisfy { FileManager.default.fileExists(atPath:$0.path) })
        XCTAssertFalse(FileManager.default.fileExists(atPath:outputs[4].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:outputs[5].path),"Unknown metadata must not inherit chat deletion semantics")
        try FileManager.default.removeItem(at:side)
        try await store.remove(kind:"chat",id:chat.id)
        try await store.remove(kind:"draft",id:"unsent")
        try await model.recycleUnreferencedToolOutputs()
        XCTAssertNil(model.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath:outputs[3].path),"Displaced live drafts are references too")
        XCTAssertTrue(outputs.prefix(3).allSatisfy { !FileManager.default.fileExists(atPath:$0.path) })
        XCTAssertTrue(FileManager.default.fileExists(atPath:imported.path),"Unregistering an imported original never deletes it")
        live.draftBeforeQueueEdit = nil
        try await store.remove(kind:"future:original",id:"original")
        try await model.recycleUnreferencedToolOutputs()
        XCTAssertNil(model.error); XCTAssertFalse(FileManager.default.fileExists(atPath:owner.path))
    }

    @MainActor func testSavedForkAndKeptSideFamiliesDeleteTheirJournalsAndSidecars() async throws {
        for prefix in ["fork_", "side_"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let model = try SubagentOrganizationTests.fixture(root); registerWorkspaceFixtureTeardown(model, root: root)
            try await model.traces.configure(quota: nil, bodyRetention: 86_400, metricRetention: 86_400)
            model.chats.remove(at: 1)
            let family = try SubagentDiscoveryTests.family(model)
            let old = URL(fileURLWithPath: try XCTUnwrap(model.chats[0].path))
            let journal = old.deletingLastPathComponent().appendingPathComponent(prefix + old.lastPathComponent)
            try FileManager.default.moveItem(at: old, to: journal); model.chats[0].path = journal.path
            let parent = model.chats[0], store = try XCTUnwrap(model.store)
            try await store.putChats(model.chats)
            try await store.put(SideKeepRegistration(expected: parent, path: parent.path), kind: SideKeepRegistration.kind, id: parent.id)
            let files = [journal, family.path] + [".meta", ".stream"].map { URL(fileURLWithPath: journal.path + $0) }
            for file in files.dropFirst(2) { try Data("fixture".utf8).write(to: file) }
            model.familyFileRecycler = { urls in for url in urls { try FileManager.default.removeItem(at: url) } }
            do { try await model.deleteSubagentFamily(parent) } catch { XCTFail("\(prefix) deletion failed: \(error)"); continue }
            XCTAssertTrue(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
            XCTAssertNil(model.record(parent.id))
            let pending = try await store.pendingFamilyDeletions()
            XCTAssertTrue(pending.isEmpty)
            let receipt = try await store.get(SideKeepRegistration.self, kind: SideKeepRegistration.kind, id: parent.id)
            XCTAssertNil(receipt)
        }
    }

    @MainActor func testInvalidOwnerFilenameIsRejectedBeforeAnyDeletionIntentOrCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try SubagentOrganizationTests.fixture(root); registerWorkspaceFixtureTeardown(model, root: root)
        try await model.traces.configure(quota: nil, bodyRetention: 86_400, metricRetention: 86_400)
        model.chats.remove(at: 1)
        let family = try SubagentDiscoveryTests.family(model)
        let old = URL(fileURLWithPath: try XCTUnwrap(model.chats[0].path))
        let foreign = old.deletingLastPathComponent().appendingPathComponent("fork_another-chat.jsonl")
        try FileManager.default.moveItem(at: old, to: foreign); model.chats[0].path = foreign.path
        let parent = model.chats[0], store = try XCTUnwrap(model.store)
        try await store.putChats(model.chats)
        var recycled: [URL] = []
        model.familyFileRecycler = { recycled += $0 }
        do { try await model.deleteSubagentFamily(parent); XCTFail("An unrelated owner filename was accepted") } catch { }
        let intents = try await store.pendingFamilyDeletions()
        let tombstone = try await store.get(String.self, kind: "session-deleted", id: parent.id)
        XCTAssertTrue(intents.isEmpty); XCTAssertNil(tombstone)
        XCTAssertTrue(recycled.isEmpty); XCTAssertFalse(model.deletingFamilies.contains(parent.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: family.path.path))
        try await store.put(parent, kind: "chat", id: parent.id)
    }

    @MainActor func testPendingOwnerDeletionAcceptsLegacyNamesButChildDeletionKeepsUUIDNames() async throws {
        for child in [false, true] {
            for prefix in ["fork_", "side_"] {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                let model = try SubagentOrganizationTests.fixture(root); registerWorkspaceFixtureTeardown(model, root: root)
                try await model.traces.configure(quota: nil, bodyRetention: 86_400, metricRetention: 86_400)
                let directory = try model.subagentDirectory("pane-project")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let id = UUID().uuidString, path = directory.appendingPathComponent(prefix + id + ".jsonl")
                try Data("fixture".utf8).write(to: path)
                let store = try XCTUnwrap(model.store)
                let record = SessionDeletionRecord(id: id, ownerID: child ? "chat-parent" : id, workspaceID: "pane-project", path: path.path)
                let owner = SessionDeletionRecord(id: record.ownerID, ownerID: record.ownerID, workspaceID: record.workspaceID, path: nil)
                try await store.beginFamilyDeletion(child ? [owner, record] : [record])
                model.familyFileRecycler = { urls in for url in urls { try FileManager.default.removeItem(at: url) } }
                await model.resumeFamilyDeletions()
                let pending = try await store.pendingFamilyDeletions()
                XCTAssertEqual(FileManager.default.fileExists(atPath: path.path), child)
                XCTAssertEqual(pending.isEmpty, !child)
                XCTAssertEqual(model.error != nil, child)
            }
        }
    }

    @MainActor func testDeleteFindsAnUnregisteredChildAndPreventsRediscoveryAndStaleWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try SubagentOrganizationTests.fixture(root); registerWorkspaceFixtureTeardown(model, root: root)
        try await model.traces.configure(quota: nil, bodyRetention: 86_400, metricRetention: 86_400)
        model.chats.remove(at: 1)
        let family = try SubagentDiscoveryTests.family(model)
        let store = try XCTUnwrap(model.store), parent = try XCTUnwrap(model.record("chat-parent"))
        for chat in model.chats { try await store.put(chat, kind: "chat", id: chat.id) }
        for suffix in [".meta", ".origin", ".stream", ".stream-unrestored-fixture", ".promotion"] { try Data("fixture".utf8).write(to: URL(fileURLWithPath: family.path.path + suffix)) }
        let parentPromotion = URL(fileURLWithPath: try XCTUnwrap(parent.path) + ".promotion")
        try Data("private parent promotion fixture".utf8).write(to: parentPromotion)
        let temporary = family.path.deletingLastPathComponent().appendingPathComponent("." + family.path.lastPathComponent + ".meta." + UUID().uuidString)
        let unrelated = family.path.deletingLastPathComponent().appendingPathComponent(".another.jsonl.meta." + UUID().uuidString)
        for file in [temporary, unrelated] { try Data("private checkpoint fixture".utf8).write(to: file) }
        let outputs = family.path.deletingLastPathComponent().appendingPathComponent("tool-output")
        let ownedOutputs = [parent.id, family.child].map { outputs.appendingPathComponent($0) }
        let foreignOutputs = outputs.appendingPathComponent("foreign-chat")
        let otherSessions = model.root.appendingPathComponent("Workspaces/other-project/Sessions")
        let otherOutputs = otherSessions.appendingPathComponent("tool-output/" + parent.id)
        for folder in ownedOutputs + [foreignOutputs, otherOutputs] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("short private shell output".utf8).write(to: folder.appendingPathComponent(UUID().uuidString + ".log"))
        }
        // An unlisted chat in another project can have the same identity.
        // Its short output has no full-output path in the result text.
        try JSONEncoder().encode(["type":"session", "id":parent.id]).write(to:otherSessions.appendingPathComponent(parent.id + ".jsonl"))
        var recycled: [URL] = []
        model.familyFileRecycler = { urls in recycled += urls; for url in urls { try FileManager.default.removeItem(at: url) } }
        try await model.deleteSubagentFamily(parent)
        XCTAssertNil(model.record(parent.id)); XCTAssertFalse(FileManager.default.fileExists(atPath: family.path.path))
        XCTAssertTrue(recycled.contains { $0.path == family.path.path + ".meta" })
        XCTAssertTrue(recycled.contains { $0.path == family.path.path + ".origin" })
        XCTAssertTrue(recycled.contains { $0.path == family.path.path + ".promotion" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: parentPromotion.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertTrue(ownedOutputs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreignOutputs.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherOutputs.path),"A matching session ID in another project is not deletion authority")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertEqual(model.record("chat-side")?.parentSessionID, parent.id, "Ordinary sides retain their existing independent deletion policy")
        do { try await store.put(parent, kind: "chat", id: parent.id); XCTFail("Stale parent recreated after deletion") } catch { }
        await model.reconcileSubagents()
        XCTAssertNil(model.record(family.child))
    }
    @MainActor func testPartialDeletionIsDurableAndRetriesWithoutNewAuthorization() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try SubagentOrganizationTests.fixture(root); registerWorkspaceFixtureTeardown(model, root: root)
        try await model.traces.configure(quota: nil, bodyRetention: 86_400, metricRetention: 86_400)
        model.chats.remove(at: 1)
        let family = try SubagentDiscoveryTests.family(model)
        let store = try XCTUnwrap(model.store), parent = try XCTUnwrap(model.record("chat-parent"))
        for chat in model.chats { try await store.put(chat, kind: "chat", id: chat.id) }
        model.familyFileRecycler = { _ in throw StoreError.unavailable }
        do { try await model.deleteSubagentFamily(parent); XCTFail("Injected filesystem failure ignored") } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: family.path.path))
        let intents = try await store.list(SessionDeletionRecord.self, kind: SessionDeletionRecord.kind)
        XCTAssertEqual(Set(intents.map(\.id)), Set([parent.id, family.child]))
        await model.stopHostsAndWait(); model.shutdown()
        try await model.traces.close(); await store.close()
        // A real relaunch retains the project's configuration. The recovery
        // barrier can start its helper without opening any conversation.
        let reopened = WorkspaceModel(stateRoot: model.root, vault: model.vault)
        defer { reopened.shutdown() }
        addTeardownBlock { @MainActor in await reopened.stopHostsAndWait() }
        let nextStore = try XCTUnwrap(reopened.store)
        reopened.chats = try await nextStore.loadChats()
        try await reopened.traces.configure(quota: nil, bodyRetention: 86_400, metricRetention: 86_400)
        reopened.familyFileRecycler = { urls in for url in urls { try FileManager.default.removeItem(at: url) } }
        await reopened.resumeFamilyDeletions()
        XCTAssertFalse(FileManager.default.fileExists(atPath: family.path.path))
        let saved = try await nextStore.get(ChatRecord.self, kind: "chat", id: parent.id)
        XCTAssertNil(saved); XCTAssertNil(reopened.record(parent.id))
    }
    @MainActor func testUnreadableDirectoryListingKeepsTheIntentEvenWhenKnownPathsCanBeInspected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try SubagentOrganizationTests.fixture(root); registerWorkspaceFixtureTeardown(model, root: root)
        try await model.traces.configure(quota: nil, bodyRetention: 86_400, metricRetention: 86_400)
        let directory = try model.subagentDirectory("pane-project")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let parent = model.chats[0], path = directory.appendingPathComponent(parent.id + ".jsonl"), store = try XCTUnwrap(model.store)
        try Data("private fixture".utf8).write(to: path)
        try await store.putChats(model.chats)
        try await store.beginFamilyDeletion([SessionDeletionRecord(id: parent.id, ownerID: parent.id, workspaceID: parent.workspaceID, path: path.path)])
        model.familyFileRecycler = { urls in for url in urls { try FileManager.default.removeItem(at: url) } }
        // Search permission permits stat of known paths; read permission is
        // needed only to enumerate. This isolates the listing failure guard.
        try FileManager.default.setAttributes([.posixPermissions:0o100], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions:0o700], ofItemAtPath: directory.path) }
        await model.resumeFamilyDeletions()
        let pending = try await store.pendingFamilyDeletions()
        XCTAssertEqual(pending.count, 1); XCTAssertNotNil(model.record(parent.id)); XCTAssertNotNil(model.error)
        try FileManager.default.setAttributes([.posixPermissions:0o700], ofItemAtPath: directory.path)
        await model.resumeFamilyDeletions()
        let remaining = try await store.pendingFamilyDeletions()
        XCTAssertTrue(remaining.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    @MainActor func testEnumerationFailureKeepsDeletionIntentAndRetriesAfterRepair() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try SubagentOrganizationTests.fixture(root); registerWorkspaceFixtureTeardown(model, root: root)
        try await model.traces.configure(quota: nil, bodyRetention: 86_400, metricRetention: 86_400)
        model.chats.remove(at: 1)
        let family = try SubagentDiscoveryTests.family(model), store = try XCTUnwrap(model.store)
        let parent = try XCTUnwrap(model.record("chat-parent")), directory = family.path.deletingLastPathComponent()
        try await store.putChats(model.chats)
        let members = [SessionDeletionRecord(id: parent.id, ownerID: parent.id, workspaceID: parent.workspaceID, path: parent.path),
                       SessionDeletionRecord(id: family.child, ownerID: parent.id, workspaceID: parent.workspaceID, path: family.path.path)]
        try await store.beginFamilyDeletion(members)
        let saved = root.appendingPathComponent("saved-sessions")
        try FileManager.default.moveItem(at: directory, to: saved)
        try Data("enumeration must fail with ENOTDIR".utf8).write(to: directory)
        model.familyFileRecycler = { urls in for url in urls { try FileManager.default.removeItem(at: url) } }
        await model.resumeFamilyDeletions()
        let pending = try await store.pendingFamilyDeletions()
        XCTAssertEqual(Set(pending.map(\.id)), Set(members.map(\.id)))
        XCTAssertNotNil(model.record(parent.id)); XCTAssertNotNil(model.error)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: saved, to: directory)
        await model.resumeFamilyDeletions()
        let finished = try await store.pendingFamilyDeletions()
        XCTAssertTrue(finished.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: family.path.path))
    }

    @MainActor func testRunningFamilyCannotBeDeleted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try SubagentOrganizationTests.fixture(root); registerWorkspaceFixtureTeardown(model, root: root)
        let parent = try XCTUnwrap(model.record("chat-parent")), view = SessionDisplay(id: "chat-parent")
        view.runState = .running; model.displays[view.id] = view
        do { try await model.deleteSubagentFamily(parent); XCTFail("Running family deleted") } catch { }
    }
    @MainActor func testDeletionRechecksDelegationsAcceptedWhileConfirmationWasOpen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try SubagentOrganizationTests.fixture(root); registerWorkspaceFixtureTeardown(model, root: root)
        try await model.traces.configure(quota: nil, bodyRetention: 86_400, metricRetention: 86_400)
        model.chats.remove(at: 1)
        for chat in model.chats { try await model.store?.put(chat, kind: "chat", id: chat.id) }
        var childPath: URL?
        model.questions.answer = { _ in
            childPath = try? SubagentDiscoveryTests.family(model).path
            return true
        }
        model.familyFileRecycler = { urls in for url in urls { try FileManager.default.removeItem(at: url) } }
        model.deleteChat("chat-parent")
        for _ in 0..<200 where model.record("chat-parent") != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(model.record("chat-parent"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(childPath).path))
        try await model.traces.close(); await model.store?.close()
    }
    func testLateCaptureCannotRecreateDeletedFamilyGroupsOrDeleteAnotherWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root)
        try await archive.configure(quota: nil, bodyRetention: 86_400, metricRetention: 86_400)
        let summary = SubagentSummary(link: SubagentTranscriptTests.link, description: "Review", model: "model", status: .running, revision: 1)
        for workspace in ["one", "two"] { try await archive.recordSubagent(summary, workspaceID: workspace) }
        try await archive.forgetSubagentRelationships(sessionID: "chat-parent", workspaceID: "one")
        try await archive.recordSubagent(summary, workspaceID: "one")
        let deleted = try await archive.inspectorSubagents(owner: "chat-parent", workspaceID: "one")
        let retained = try await archive.inspectorSubagents(owner: "chat-parent", workspaceID: "two")
        XCTAssertTrue(deleted.isEmpty); XCTAssertEqual(retained.count, 1)
        try await archive.close()
    }

}
