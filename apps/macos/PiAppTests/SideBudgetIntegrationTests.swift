import AppKit
import XCTest
@testable import PiApp

final class BudgetOwnerUnloadTests: XCTestCase {
    private enum Operation: CaseIterable { case connection, editing, folders, delete }

    @MainActor func testCatalogGrantNotificationDoesNotCreateAnUnshownSideDisplay() async throws {
        let model = try await sideBudgetFixture(), item = try XCTUnwrap(model.record("nested"))
        await model.loadSubagentModels(for: item)
        let host = try await model.open(item)
        let events = try await host.request("session.events", sessionID: item.id, params: ["since": .number(0)])
        XCTAssertTrue(events.object?["events"]?.array?.contains { $0.object?["type"]?.string == "context.inputs-changed" } == true,
                      "Installing nonempty grants emits the opening's context change")
        // Deliver that coalesced notification after the open has finished,
        // with the saved side still unshown, regardless of transport timing.
        model.displays.removeValue(forKey: item.id)
        model.refresh(item.id)
        XCTAssertNil(model.displays[item.id], "A grant notification must not materialize a hidden side transcript")
        XCTAssertNotNil(model.budgetStates[item.id]?.readTask, "The side's accounting is still refreshed")
    }

    @MainActor private func exercise(_ operation: Operation, model: WorkspaceModel) async throws {
        switch operation {
        case .connection:
            var second = try XCTUnwrap(model.profiles.first)
            second.id = "second"; second.name = "Second fixture"; second.baseUrl = "http://127.0.0.1:8/v1"
            let connection = VaultProfile(profile:second,apiKey:"fixture-unused")
            try await model.updateConfiguration { $0.profiles.append(connection) }
            await model.setConnection(second.id,for:"main")
            if let error = model.error { throw HostError.failure(error) }
            XCTAssertEqual(model.record("main")?.profileID,"second")
        case .editing:
            try await model.enableEditingAfterConfirmation("main")
            XCTAssertEqual(model.record("main")?.toolMode,ChatRecord.editingTools)
        case .folders:
            let extra = URL(fileURLWithPath:try XCTUnwrap(model.workspace(for:"w")?.path)).appendingPathComponent("extra")
            try FileManager.default.createDirectory(at:extra,withIntermediateDirectories:true)
            try await model.addFolders([extra.path],to:"w")
            XCTAssertTrue(model.workspace(for:"w")?.roots.contains(extra.path) == true)
        case .delete:
            model.familyFileRecycler = { urls in for url in urls { try FileManager.default.removeItem(at:url) } }
            try await model.deleteSubagentFamily(try XCTUnwrap(model.record("main")))
            XCTAssertNil(model.record("main"))
        }
    }

    @MainActor func testEveryOwnerChangeReleasesIdleSidesAtAllDepthsWithoutDisplays() async throws {
        for operation in Operation.allCases {
            let model = try await sideBudgetFixture()
            var main = try XCTUnwrap(model.record("main")); main.toolMode = ChatRecord.readOnlyTools
            try await model.store?.put(main,kind:"chat",id:main.id)
            model.chats[try XCTUnwrap(model.chats.firstIndex(where: { $0.id == main.id }))] = main
            _ = try await model.open(try XCTUnwrap(model.record("nested")))
            _ = try await model.open(try XCTUnwrap(model.record("sibling")))
            XCTAssertTrue(model.displays.isEmpty, "\(operation), before: \(model.displays.keys.sorted())")
            do { try await exercise(operation,model:model) }
            catch { XCTFail("\(operation): idle side runtimes must not block the owner: \(error)") }
            XCTAssertTrue(model.opened.isEmpty,"\(operation): release descendants before their owner")
            XCTAssertTrue(model.displays.isEmpty,"\(operation): owner changes must not create hidden transcripts: \(model.displays.keys.sorted())")
        }
    }

    @MainActor func testEveryOwnerChangeNamesTheRunningDependentAndPreservesTheFamily() async throws {
        for operation in Operation.allCases {
            let model = try await sideBudgetFixture()
            var main = try XCTUnwrap(model.record("main")); main.toolMode = ChatRecord.readOnlyTools
            try await model.store?.put(main,kind:"chat",id:main.id)
            model.chats[try XCTUnwrap(model.chats.firstIndex(where: { $0.id == main.id }))] = main
            _ = try await model.open(try XCTUnwrap(model.record("nested")))
            _ = try await model.open(try XCTUnwrap(model.record("sibling")))
            let view = SessionDisplay(id:"nested"); view.runState = .running; model.displays[view.id] = view
            let before = model.opened
            do { try await exercise(operation,model:model); XCTFail("\(operation): running dependent must block") }
            catch { XCTAssertTrue(error.localizedDescription.contains("nested"),"\(operation): name the dependent: \(error)") }
            XCTAssertEqual(model.opened,before,"Preflight before releasing any writer")
            XCTAssertNotNil(model.record("main"))
            XCTAssertEqual(model.record("main")?.toolMode,ChatRecord.readOnlyTools)
            view.runState = .idle
        }
    }

    @MainActor func testDeleteActionAllowsAnIdleVisibleSideAndDeletesItWithItsChat() async throws {
        let model = try await sideBudgetFixture(), side = try XCTUnwrap(model.record("side"))
        _ = try await model.open(side)
        model.sides["main"] = SideRecord(id:side.id,parentID:"main",workspaceID:"w",profileID:"p",title:side.title,kept:true)
        model.questions.answer = { _ in true }
        model.familyFileRecycler = { urls in for url in urls { try FileManager.default.removeItem(at:url) } }
        model.deleteChat("main")
        try await eventually("Deletion must reach its confirmation and finish") { model.record("main") == nil || model.error != nil }
        XCTAssertNil(model.error)
        XCTAssertNil(model.record("main"))
        XCTAssertNil(model.record("side"),"A saved side goes with its chat (0.1.129)")
        XCTAssertNil(model.sides["main"],"Remove the deleted parent's pane relationship")
    }

    @MainActor func testVisibleSavedSideCanEnableEditingAfterItsIdleNestedDependentUnloads() async throws {
        let model = try await sideBudgetFixture(), side = try XCTUnwrap(model.record("side"))
        let host = try await model.open(try XCTUnwrap(model.record("nested")))
        model.sides["main"] = SideRecord(id:side.id,parentID:"main",workspaceID:"w",profileID:"p",title:side.title,kept:true)
        try await model.enableEditingAfterConfirmation("side")
        XCTAssertFalse(model.opened.contains("side")); XCTAssertFalse(model.opened.contains("nested"))
        _ = try await model.open(try XCTUnwrap(model.record("side")))
        let snapshot = try await host.request("session.snapshot",sessionID:"side")
        XCTAssertEqual(snapshot.object?["toolMode"]?.string,ChatRecord.editingTools,"The acknowledged edit must use a new runtime")
    }

    @MainActor func testSideCannotReopenItsBudgetOwnerDuringAConnectionChange() async throws {
        let model = try await sideBudgetFixture()
        _ = try await model.open(try XCTUnwrap(model.record("nested")))
        let entered = expectation(description:"Owner and dependents released")
        let (held, release) = AsyncStream<Never>.makeStream()
        model.connectionSwitchSteps = { step in
            guard step == "closed" else { return }
            entered.fulfill(); for await _ in held {}
        }
        let switching = Task { try await self.exercise(.connection,model:model) }
        await fulfillment(of:[entered],timeout:10)
        let nested = try XCTUnwrap(model.record("nested"))
        do { _ = try await model.open(nested); XCTFail("A side cannot resurrect a changing owner") }
        catch { XCTAssertEqual(error.localizedDescription,model.connectionChanged.localizedDescription) }
        XCTAssertTrue(model.opened.isEmpty)
        release.finish(); try await switching.value
        _ = try await model.open(try XCTUnwrap(model.record("nested")))
        XCTAssertTrue(model.opened.isSuperset(of:["main","side","nested"]))
    }

    @MainActor func testMountedIndependentForkDoesNotBlockItsSourcesConnectionChange() async throws {
        let model = try await sideBudgetFixture(), host = try await model.open(try XCTUnwrap(model.record("main")))
        let result = try await host.request("session.fork",sessionID:"main",params:["forkSessionId":.string("fork")])
        let fork = ChatRecord(id:"fork",workspaceID:"w",title:"Independent fork",path:result.object?["path"]?.string,profileID:"p",parentSessionID:"main")
        try await model.store?.put(fork,kind:"chat",id:fork.id); model.chats.append(fork); model.opened.insert(fork.id)
        model.sides["main"] = SideRecord(id:fork.id,parentID:"main",workspaceID:"w",profileID:"p",title:fork.title,kept:true)
        let view = SessionDisplay(id:fork.id); view.runState = .running; model.displays[view.id] = view
        try await exercise(.connection,model:model)
        XCTAssertTrue(model.opened.contains(fork.id),"Pane placement is not a budget dependency")
        view.runState = .idle
    }

    @MainActor func testOwnerChangesNeverPersistAnUnsentSideDraft() async throws {
        for operation in Operation.allCases {
            let model = try await sideBudgetFixture()
            var main = try XCTUnwrap(model.record("main")); main.toolMode = ChatRecord.readOnlyTools
            try await model.store?.put(main,kind:"chat",id:main.id)
            model.chats[try XCTUnwrap(model.chats.firstIndex(where: { $0.id == main.id }))] = main
            let draft = SessionDisplay(id:"private-side-draft"); draft.draft = "Only in memory"
            model.displays[draft.id] = draft
            model.sides[main.id] = SideRecord(id:draft.id,parentID:main.id,workspaceID:"w",profileID:"p",title:"Unsent",pending:true)
            if operation == .delete {
                var asked = false
                model.questions.answer = { question in asked = true; XCTAssertTrue(question.detail.contains("unsent side draft")); return true }
                model.familyFileRecycler = { urls in for url in urls { try FileManager.default.removeItem(at:url) } }
                model.deleteChat(main.id)
                try await eventually("Confirmed deletion completes") { model.record(main.id) == nil || model.error != nil }
                XCTAssertTrue(asked); XCTAssertNil(model.error); XCTAssertNil(model.displays[draft.id])
            } else {
                try await exercise(operation,model:model)
                XCTAssertTrue(model.sides[main.id]?.pending == true)
                XCTAssertEqual(model.displays[draft.id]?.draft,"Only in memory")
            }
            let storedDraft = try await model.store?.get(WireValue.self,kind:"draft",id:draft.id)
            let storedChat = try await model.store?.get(ChatRecord.self,kind:"chat",id:draft.id)
            XCTAssertNil(storedDraft); XCTAssertNil(storedChat)
        }
    }
}

final class SideBudgetIntegrationTests: XCTestCase {
    @MainActor func testInterruptedSideFamilyDeletionKeepsRepairProofAndColdMainReadable() async throws {
        for interruption in ["before-trash","owner-trash","child-trash","repaired","files:side","files:child","metadata:child","intent:child","metadata:side"] {
            let model = try await sideBudgetFixture(), side = try XCTUnwrap(model.record("side"))
            let store = try XCTUnwrap(model.store), path = URL(fileURLWithPath:try XCTUnwrap(side.path))
            try await XCTUnwrap(model.hosts["w"]).shutdownAndWait()
            var link = SubagentTranscriptTests.link
            link.childSessionID = UUID().uuidString; link.budgetOwnerSessionID = side.id; link.call.parentSessionID = side.id
            let origin: WireValue = .object([
                "link":try JSONDecoder().decode(WireValue.self,from:JSONEncoder().encode(link)),
                "description":.string("Deletion fixture"),"model":.object(["model":.string("fixture")]),
                "tools":.array([]),"readOnly":.bool(true),"resourceRevision":.string("fixture")])
            let cost: [String:WireValue] = ["attemptId":.string("charged"),"sourceSessionId":.string(link.childSessionID),
                "budgetOwnerSessionId":.string(side.id),"delegationId":.string(link.delegationID),
                "purpose":.string("turn"),"outcome":.string("completed"),"usd":.number(0.7),
                "reported":.number(1),"unreported":.number(0),"accountingRevision":.number(2),
                "usage":.object(["input":.number(100),"output":.number(20)]),
                "usageStatus":.object(["input":.string("reported"),"output":.string("reported")])]
            func append(_ kind: String, _ value: [String:WireValue], to file: URL) throws {
                let rows = try self.fixtureJournalRows(file), id = UUID().uuidString
                let row: [String:WireValue] = ["type":.string("custom"),"customType":.string(kind),"id":.string(id),
                    "parentId":rows.last?["type"]?.string == "session" ? .null : (rows.last?["id"] ?? .null),"data":.object(value)]
                var bytes = try Data(contentsOf:file); bytes.append(try JSONEncoder().encode(row)); bytes.append(10)
                try bytes.write(to:file)
            }
            try append("pi-app.subagent-call.v1",["origin":origin,"task":.string("Private fixture"),"resultMessageID":.string("result")],to:path)
            try append("pi-app.budget-attempt.v1",["attemptId":.string("charged"),"sourceSessionId":.string(link.childSessionID),
                "budgetOwnerSessionId":.string(side.id),"delegationId":.string(link.delegationID),
                "purpose":.string("turn"),"state":.string("dispatched"),"accountingRevision":.number(1)],to:path)
            try append("pi-app.cost.v1",cost,to:path)
            let child = path.deletingLastPathComponent().appendingPathComponent(link.childSessionID + ".jsonl")
            let header: [String:WireValue] = ["type":.string("session"),"version":.number(3),"id":.string(link.childSessionID)]
            var bytes = try JSONEncoder().encode(header); bytes.append(10); try bytes.write(to:child)
            try append("pi-app.native.v2",["version":.number(2)],to:child)
            try append("pi-app.subagent-origin.v1",try XCTUnwrap(origin.object),to:child)
            try append("pi-app.cost.v1",cost,to:child)
            var interrupted = false
            func interrupt() throws { interrupted = true; throw StoreError.unavailable }
            model.familyFileRecycler = { urls in
                if interruption == "before-trash" { try interrupt() }
                for url in urls { try FileManager.default.removeItem(at:url) }
                if interruption == "owner-trash" && urls.contains(path) || interruption == "child-trash" && urls.contains(child) { try interrupt() }
            }
            model.familyDeletionStep = { step in
                let selected = interruption.replacingOccurrences(of:":child",with:":" + link.childSessionID)
                if step == selected { try interrupt() }
            }
            do { try await model.deleteSubagentFamily(side); XCTFail("Cleanup interruption was not injected") }
            catch { XCTAssertTrue(interrupted,"Fixture failed before cleanup: \(error)") }
            let intents = try await store.pendingFamilyDeletions()
            let ownerIntent = try XCTUnwrap(intents.first { $0.id == side.id })
            let saved = try JSONDecoder().decode(WireValue.self,from:JSONEncoder().encode(ownerIntent))
            XCTAssertEqual(saved.object?["repairCompleted"]?.bool,true,"Repair must be durable before any cleanup")
            if interruption != "metadata:side" { XCTAssertNotNil(model.record(side.id),"Keep the retry entry until all cleanup is done") }
            try await XCTUnwrap(model.hosts["w"]).shutdownAndWait()
            do {
                let host = try await model.open(try XCTUnwrap(model.record("main")))
                let status = try await host.request("session.status",sessionID:"main",params:["budgetOnly":.bool(true)])
                XCTAssertEqual(status.object?["cost"]?.object?["spentUSD"]?.number,0.7)
            } catch { XCTFail("Main became damaged during cleanup step \(interruption): \(error)") }
            await model.stopHostsAndWait()
            model.familyFileRecycler = { urls in for url in urls { try FileManager.default.removeItem(at:url) } }
            model.error = nil; model.familyDeletionStep = nil
            // Completed repair must make retry independent of the helper and
            // removed member journals, including older child-first cleanup.
            model.workspaceChangesInFlight.insert("w")
            await model.resumeFamilyDeletions(); await model.resumeFamilyDeletions()
            model.workspaceChangesInFlight.remove("w")
            XCTAssertNil(model.error,"Retry step \(interruption)")
            let remaining = try await store.pendingFamilyDeletions(); XCTAssertTrue(remaining.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath:path.path)); XCTAssertFalse(FileManager.default.fileExists(atPath:child.path))
            let host = try await model.open(try XCTUnwrap(model.record("main")))
            let status = try await host.request("session.status",sessionID:"main",params:["budgetOnly":.bool(true)])
            XCTAssertEqual(status.object?["cost"]?.object?["spentUSD"]?.number,0.7)
            XCTAssertEqual(status.object?["cost"]?.object?["familyUsage"]?.object?["output"]?.number,20)
        }
    }

    @MainActor func testColdSideDeletionRepairsSurvivingAncestorsBeforeTrashWithoutCaptures() async throws {
        for deleted in ["side","nested"] {
            let model = try await sideBudgetFixture(), target = try XCTUnwrap(model.record(deleted))
            try await XCTUnwrap(model.hosts["w"]).shutdownAndWait()
            _ = try interruptedSideMirror(model,terminalOwner:"nested")
            let captures = try await model.traces.list(sessionID:"nested"); XCTAssertTrue(captures.isEmpty)
            var recycled = false
            model.familyFileRecycler = { urls in
                if urls.contains(where: { $0.path == target.path }) {
                    recycled = true
                    for id in ["main"] + (deleted == "nested" ? ["side"] : []) {
                        let cost = try self.lastFixtureCost(URL(fileURLWithPath:try XCTUnwrap(model.record(id)?.path)))
                        XCTAssertEqual(cost["usd"]?.number,0.9,"\(id) must commit before deleting \(deleted)")
                        XCTAssertEqual(cost["usage"]?.object?["input"]?.number,100)
                        XCTAssertEqual(cost["usage"]?.object?["output"]?.number,20)
                    }
                }
                for url in urls { try FileManager.default.removeItem(at:url) }
            }
            try await model.deleteSubagentFamily(target)
            XCTAssertTrue(recycled)
            let host = try await model.open(try XCTUnwrap(model.record("main")))
            let snapshot = try await host.request("session.status",sessionID:"main",params:["budgetOnly":.bool(true)])
            XCTAssertEqual(snapshot.object?["cost"]?.object?["spentUSD"]?.number,0.9)
        }
    }

    @MainActor func testDeletingMainWithNoReadyHelperTrashesTheWholeFamilyWithoutStartingOne() async throws {
        for state in ["absent", "stopped", "stopping"] {
            let model = try await sideBudgetFixture(), parent = try XCTUnwrap(model.record("main"))
            let original = try XCTUnwrap(model.hosts["w"])
            try await original.shutdownAndWait()
            let paths = try interruptedSideMirror(model)
            if state == "absent" { model.hosts.removeValue(forKey:"w") }
            if state == "stopping" {
                _ = try await model.host(for:try XCTUnwrap(model.workspace(for:"w")))
                original.shutdown()
            }
            XCTAssertFalse(model.hosts["w"]?.isReady == true)
            // Nothing survives that could need a repaired ledger, so neither
            // a connection nor the project helper is needed.
            try await model.updateConfiguration { $0.profiles = [] }
            var recycled: [URL] = []
            model.familyFileRecycler = { urls in
                recycled += urls
                XCTAssertTrue(model.opened.isEmpty,"Deletion must not open conversation runtimes")
                XCTAssertTrue(model.displays.isEmpty,"Deletion must not allocate hidden transcripts")
                for url in urls { try FileManager.default.removeItem(at:url) }
            }
            let skipped = try await model.deleteSubagentFamily(parent)
            XCTAssertTrue(skipped.isEmpty,state)
            XCTAssertFalse(model.hosts["w"]?.isReady == true,state + ": no helper starts for a whole-family deletion")
            for path in paths + [URL(fileURLWithPath:try XCTUnwrap(parent.path))] {
                XCTAssertTrue(recycled.contains(path),state + ": " + path.lastPathComponent)
                XCTAssertFalse(FileManager.default.fileExists(atPath:path.path),state)
            }
            for id in ["main","side","nested","sibling"] { XCTAssertNil(model.record(id),state + ": " + id) }
        }
    }

    @MainActor func testDamagedSideEvidenceCannotBlockDeletingTheWholeFamily() async throws {
        for warm in [false,true] {
            let model = try await sideBudgetFixture(), parent = try XCTUnwrap(model.record("main"))
            try await XCTUnwrap(model.hosts["w"]).shutdownAndWait()
            let paths = try interruptedSideMirror(model,foreignSideIdentity:true)
            // A ready helper takes the runtime path; nothing is opened, since
            // opening any member already rejects the damaged family ledger.
            if warm { _ = try await model.host(for:try XCTUnwrap(model.workspace(for:"w"))) }
            model.familyFileRecycler = { urls in for url in urls { try FileManager.default.removeItem(at:url) } }
            do { try await model.deleteSubagentFamily(parent) }
            catch { XCTFail("warm=\(warm): a deleted side's damaged ledger blocked its family: \(error)") }
            XCTAssertNil(model.record(parent.id))
            for path in paths { XCTAssertFalse(FileManager.default.fileExists(atPath:path.path)) }
            let intents = try await XCTUnwrap(model.store).pendingFamilyDeletions()
            XCTAssertTrue(intents.isEmpty)
        }
    }

    @MainActor func testColdSideHelperStartFailureKeepsTheDeletionRetryable() async throws {
        let model = try await sideBudgetFixture(), parent = try XCTUnwrap(model.record("side"))
        try await XCTUnwrap(model.hosts["w"]).shutdownAndWait()
        _ = try interruptedSideMirror(model)
        // A project change temporarily prevents helper startup. No tombstone
        // or file cleanup may precede the surviving main chat's repair.
        model.workspaceChangesInFlight.insert("w")
        var recycled = false
        model.familyFileRecycler = { _ in recycled = true }
        do { try await model.deleteSubagentFamily(parent); XCTFail("Unavailable helper must not skip the repair barrier") } catch { }
        let store = try XCTUnwrap(model.store)
        let intents = try await store.pendingFamilyDeletions()
        let tombstone = try await store.get(String.self,kind:"session-deleted",id:parent.id)
        XCTAssertTrue(intents.isEmpty); XCTAssertNil(tombstone); XCTAssertFalse(recycled)
        XCTAssertNotNil(model.record(parent.id)); XCTAssertFalse(model.deletingFamilies.contains(parent.id))
        XCTAssertFalse(model.deletingFamilies.contains("nested"),"Release the blocked descendants too")
        XCTAssertTrue(FileManager.default.fileExists(atPath:try XCTUnwrap(parent.path)))
        model.workspaceChangesInFlight.remove("w")
        model.familyFileRecycler = { urls in for url in urls { try FileManager.default.removeItem(at:url) } }
        try await model.deleteSubagentFamily(parent)
        XCTAssertNil(model.record(parent.id)); XCTAssertNil(model.record("nested"))
        XCTAssertNotNil(model.record("main")); XCTAssertNotNil(model.record("sibling"))
    }

    @MainActor func testPendingColdOwnerDeletionRepairsBeforeRetryingTrash() async throws {
        let model = try await sideBudgetFixture(), parent = try XCTUnwrap(model.record("main"))
        try await XCTUnwrap(model.hosts["w"]).shutdownAndWait()
        let paths = try interruptedSideMirror(model), store = try XCTUnwrap(model.store)
        // A previous app may have committed an intent before attempting the
        // repair. Recovery must not treat that intent as proof of mirroring.
        try await store.beginFamilyDeletion([SessionDeletionRecord(id:parent.id,ownerID:parent.id,workspaceID:"w",path:parent.path)])
        model.chats = try await store.loadChats().filter { $0.id != parent.id }
        XCTAssertNil(model.record(parent.id))
        var attempts = 0
        model.familyFileRecycler = { urls in
            attempts += 1
            for path in paths { XCTAssertEqual(try self.lastFixtureCost(path)["usd"]?.number,0.9,"Retry must repair before Trash too") }
            if attempts == 1 { throw StoreError.unavailable }
            for url in urls { try FileManager.default.removeItem(at:url) }
        }
        await model.resumeFamilyDeletions()
        XCTAssertEqual(attempts,1)
        XCTAssertTrue(FileManager.default.fileExists(atPath:try XCTUnwrap(parent.path)))
        try await XCTUnwrap(model.hosts["w"]).shutdownAndWait()
        await model.resumeFamilyDeletions()
        XCTAssertEqual(attempts,2)
        let remaining = try await store.pendingFamilyDeletions()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:try XCTUnwrap(parent.path)))
        for path in paths {
            XCTAssertEqual(try fixtureJournalRows(path).filter { $0["customType"]?.string == "pi-app.cost-update.v1" }.count,1,"Retry is idempotent")
        }
    }

    @MainActor func testMissingOwnerReadingCannotOfferContinueFromRetainedCaptureTotals() async throws {
        let model = try await sideBudgetFixture()
        model.budgetStates.removeAll()
        model.publishChatStats(GatewayTotals(requests:1,costSamples:1,costUSD:0.2),sessionID:"main")
        let side = SessionDisplay(id:"side"); model.displays[side.id] = side
        model.observeCost(["cost":.object(["spentUSD":.number(0.1),"reportedRequests":.number(1)])],view:side)
        XCTAssertNil(side.footer.cost.budgetSpentUSD,"Retained captures are not the authoritative budget ledger")
        XCTAssertTrue(side.costLimitHeld,"Unknown owner spend must not unlock Continue")
    }

    @MainActor func testOpeningATranscriptPreservesTheAuthoritativeBudgetReading() async throws {
        let model = try await sideBudgetFixture()
        model.observeCost(["cost":.object(["spentUSD":.number(1.2),"reportedRequests":.number(2),"limitUSD":.number(0.75)])],sessionID:"main")
        let display = SessionDisplay(id:"main"); model.displays[display.id] = display
        XCTAssertEqual(display.footer.cost.spentUSD,1.2)
        XCTAssertTrue(display.costLimitHeld)
    }

    @MainActor func testBudgetOnlyRefreshCoalescesAndRejectsRetiredRuntimeReplies() async throws {
        let model = try await sideBudgetFixture()
        await model.stopHostsAndWait()
        var frames: [[String:WireValue]] = []
        let host = HostSupervisor(commandSender: { frames.append($0) })
        try await host.connect(cwd:model.root,state:model.root.appendingPathComponent("budget-host"))
        model.hosts["w"] = host; model.boundHostConnections["w"] = host.connectionID
        model.opened = ["main","side"]; model.budgetDependencySessions = ["main"]
        model.displays["side"] = SessionDisplay(id:"side")
        func reply(_ index: Int, _ spend: Double) throws {
            XCTAssertEqual(frames[index]["method"]?.string,"session.status")
            XCTAssertEqual(frames[index]["params"]?.object?["budgetOnly"],.bool(true))
            host.receive(.frame(["v":.number(1),"kind":.string("reply"),"hostEpoch":.string(try XCTUnwrap(host.epoch)),
                "commandId":try XCTUnwrap(frames[index]["commandId"]),"ok":.bool(true),
                "result":.object(["cost":.object(["spentUSD":.number(spend),"limitUSD":.number(0.75),"reportedRequests":.number(2)])])]),connectionID:try XCTUnwrap(host.connectionID))
        }
        model.refresh("main")
        try await eventually("First budget read") { frames.count == 1 }
        for _ in 0..<20 { model.refresh("main") }
        XCTAssertEqual(frames.count,1)
        try reply(0,0.4)
        try await eventually("One follow-up carries all invalidations") { frames.count == 2 }
        try reply(1,1.4)
        try await eventually("Authoritative root warns its side") {
            model.displays["side"]?.footer.cost.budgetSpentUSD == 1.4 && model.budgetStates["main"]?.readTask == nil
        }
        XCTAssertTrue(model.displays["side"]?.costLimitHeld == true)
        model.refresh("main")
        try await eventually("Held retired read") { frames.count == 3 }
        let retired = model.budgetStates["main"]?.readTask
        model.helperSessionDidUnload("main")
        model.opened.insert("main"); model.budgetDependencySessions.insert("main")
        model.refresh("main")
        try await eventually("Replacement runtime read") { frames.count == 4 }
        try reply(3,1.6)
        try await eventually("Replacement reading published") { model.budgetStates["main"]?.reading.spentUSD == 1.6 }
        try reply(2,0.1)
        await retired?.value
        XCTAssertEqual(model.budgetStates["main"]?.reading.spentUSD,1.6)
        XCTAssertEqual(model.displays["side"]?.footer.cost.budgetSpentUSD,1.6)
        XCTAssertNil(model.displays["main"])
    }

    @MainActor func testBudgetOnlyOwnerPublishesDurableSpendWithoutATranscript() async throws {
        let model = try await sideBudgetFixture()
        model.costSeedRead = { item in item.id == "main" ? .object(["usd":.number(1.2),"reported":.number(2),"unreported":.number(0)]) : nil }
        let nested = try XCTUnwrap(model.record("nested"))
        let view = SessionDisplay(id:nested.id); model.displays[nested.id] = view
        _ = try await model.open(nested)
        model.refreshCostReading(nested.id)
        XCTAssertEqual(model.costReading(for:nested.id).budgetSpentUSD,1.2)
        XCTAssertTrue(model.costReading(for:nested.id).reached,"Continue must stay blocked after capture expiration")
        XCTAssertTrue(view.footer.cost.reached)
        XCTAssertNil(model.displays["main"]); XCTAssertNil(model.displays["side"])
        try await model.setCostLimit(.usd(2),for:"main")
        try await eventually("Shared warning follows the raised owner limit") { view.footer.cost.limit == .usd(2) && !view.footer.cost.reached }
        XCTAssertNil(model.displays["main"])
    }

    @MainActor func testPersistedUnlistedSideAncestryRetiresAfterParentDeletionAndReload() async throws {
        let model = try await sideBudgetFixture(), parent = try XCTUnwrap(model.record("main"))
        let store = try XCTUnwrap(model.store)
        let fillers = (0..<10_001).map { ChatRecord(id:"filler-\($0)",workspaceID:"w",title:"Chat",profileID:"p") }
        try await store.putChats(fillers)
        try await store.put(parent,kind:"chat",id:parent.id)
        model.chats = try await store.loadChats()
        XCTAssertNil(model.record("side")); XCTAssertNil(model.record("nested"))
        try await model.traces.recordSideBudgets(["side":["main"],"nested":["side","main"]],workspaceID:"w")
        model.familyFileRecycler = { urls in for url in urls { try FileManager.default.removeItem(at:url) } }
        try await model.deleteSubagentFamily(parent)
        for id in ["side","nested","sibling"] {
            let tombstone = try await store.get(String.self,kind:"session-deleted",id:id)
            XCTAssertEqual(tombstone,"main","Unlisted sides go with their chat")
            let saved = try await store.get(ChatRecord.self,kind:"chat",id:id)
            XCTAssertNil(saved)
        }
        for _ in 0..<2 {
            try await model.restoreSideBudgets()
            XCTAssertNil(model.record("side"),"Deleted sides must not reappear in the chat window")
            XCTAssertNil(model.record("nested"))
            model.chats = try await store.loadChats()
        }
    }
    @MainActor func testColdSideOpensPersistedAncestorsMissingFromTheListedChats() async throws {
        let model = try await sideBudgetFixture(), side = try XCTUnwrap(model.record("nested"))
        model.chats = [side]
        let host = try await model.open(side)
        XCTAssertEqual(model.budgetOwner(for: side).id, "main")
        XCTAssertEqual(model.costLimit(for: side), .usd(0.75))
        XCTAssertTrue(Set(["main", "side", "nested"]).isSubset(of: model.opened))
        let status = try await host.request("session.status", sessionID: "main")
        XCTAssertEqual(status.object?["cost"]?.object?["limitUSD"]?.number, 0.75)
    }

    @MainActor func testRestoreKeepsUnlistedAncestorsAndDeletingMainRemovesItsListedDescendant() async throws {
        let model = try await sideBudgetFixture(), side = try XCTUnwrap(model.record("nested"))
        model.chats = [side]
        try await model.restoreSideBudgets()
        let parents = await model.traces.savedSideBudgets
        XCTAssertEqual(parents["w\u{0}nested"], ["side", "main"])
        XCTAssertEqual(model.budgetOwner(for: side).id, "main")
        let parent = try XCTUnwrap(model.record("main"))
        model.familyFileRecycler = { urls in for url in urls { try FileManager.default.removeItem(at: url) } }
        try await model.deleteSubagentFamily(parent)
        XCTAssertNil(model.record("main")); XCTAssertNil(model.record("nested"))
        do { _ = try await model.open(side); XCTFail("A deleted side cannot reopen") }
        catch { XCTAssertEqual(error.localizedDescription, "This chat is being deleted.") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(side.path)))
    }

    @MainActor func testLastDependentReleaseUnloadsImplicitAncestorsButKeepsDirectUses() async throws {
        let model = try await sideBudgetFixture()
        _ = try await model.open(try XCTUnwrap(model.record("nested")))
        _ = try await model.open(try XCTUnwrap(model.record("sibling")))
        XCTAssertNil(model.displays["main"]); XCTAssertNil(model.displays["side"])
        model.releaseHelperSession("nested")
        try await eventually("Nested dependency is released", timeout: .seconds(5)) { !model.opened.contains("nested") && !model.opened.contains("side") }
        XCTAssertTrue(model.opened.contains("main"), "The sibling still pins the root")
        model.releaseHelperSession("sibling")
        try await eventually("Last side releases its budget writer", timeout: .seconds(5)) { model.opened.isEmpty }

        let host = try await model.open(try XCTUnwrap(model.record("main")))
        _ = try await model.open(try XCTUnwrap(model.record("side")))
        model.releaseHelperSession("side")
        try await eventually("Side release settles") { !model.opened.contains("side") }
        XCTAssertTrue(model.opened.contains("main"), "A direct open has independent lifetime")
        _ = try await host.request("session.status", sessionID: "main")
    }
    @MainActor func testConcurrentSideOpensShareAndReleaseTheirImplicitWriter() async throws {
        let model = try await sideBudgetFixture()
        let (held, release) = AsyncStream<Never>.makeStream()
        model.sessionClosings["main"] = (UUID(), Task { for await _ in held {} })
        let side = try XCTUnwrap(model.record("side")), sibling = try XCTUnwrap(model.record("sibling"))
        let first = Task { try await model.open(side) }, second = Task { try await model.open(sibling) }
        try await eventually("Both dependents wait for the previous owner close") { model.budgetOpenCallers["main"] == 2 }
        model.sessionClosings.removeValue(forKey: "main"); release.finish()
        _ = try await first.value; _ = try await second.value
        XCTAssertTrue(model.budgetDependencySessions.contains("main"), "Concurrent budget opens must not look like a direct user open")
        model.releaseHelperSession("side"); model.releaseHelperSession("sibling")
        try await eventually("The shared writer releases after both sides", timeout: .seconds(3)) { model.opened.isEmpty }
        let (nextHeld, nextRelease) = AsyncStream<Never>.makeStream()
        model.sessionClosings["main"] = (UUID(), Task { for await _ in nextHeld {} })
        let main = try XCTUnwrap(model.record("main"))
        let direct = Task { try await model.open(main) }, dependent = Task { try await model.open(side) }
        try await eventually("A direct use shares the pending writer") { model.budgetOpenCallers["main"] == 2 }
        model.sessionClosings.removeValue(forKey: "main"); nextRelease.finish()
        _ = try await direct.value; _ = try await dependent.value
        model.releaseHelperSession("side")
        try await eventually("Dependent is released") { !model.opened.contains("side") }
        XCTAssertTrue(model.opened.contains("main")); XCTAssertFalse(model.budgetDependencySessions.contains("main"))
    }

    @MainActor func testFailedSideOpenReleasesPartiallyOpenedAncestors() async throws {
        let model = try await sideBudgetFixture(), side = try XCTUnwrap(model.record("nested"))
        try FileManager.default.removeItem(atPath: try XCTUnwrap(side.path))
        do { _ = try await model.open(side); XCTFail("Missing journal must fail") } catch { }
        try await eventually("Failed side open releases its partial ancestry") { model.opened.isEmpty && model.sessionClosings.isEmpty }
        XCTAssertTrue(model.budgetDependencySessions.isEmpty)
    }

    @MainActor func testOpeningDependentPinsAncestorsUntilItFailsOrReleases() async throws {
        let model = try await sideBudgetFixture(), side = try XCTUnwrap(model.record("nested"))
        var held: CheckedContinuation<WireValue?, Never>?
        model.costSeedRead = { item in
            if item.id == side.id { return await withCheckedContinuation { held = $0 } }
            return nil
        }
        let opening = Task { try await model.open(side) }
        try await eventually("The child is held before its runtime opens") { held != nil }
        model.releaseHelperSession("main"); model.releaseHelperSession("side")
        XCTAssertTrue(model.sessionClosings.isEmpty, "Credential/seed reads pin the budget before session.open is sent")
        XCTAssertTrue(model.opened.contains("main")); XCTAssertTrue(model.opened.contains("side"))
        held?.resume(returning: nil); held = nil
        _ = try await opening.value
        model.releaseHelperSession(side.id)
        try await eventually("Pending release runs after the last child unload") { model.opened.isEmpty && model.sessionClosings.isEmpty }
    }

    @MainActor func testConfigurationFallbackRetainsAnOwnerWhoseUnloadIsRejected() async throws {
        let model = try await sideBudgetFixture()
        await model.stopHostsAndWait()
        var frames: [[String: WireValue]] = []
        let host = HostSupervisor(commandSender: { frames.append($0) })
        try await host.connect(cwd: model.root, state: model.root.appendingPathComponent("mock-host"))
        model.hosts["w"] = host; model.boundHostConnections["w"] = host.connectionID
        model.opened = ["main", "side"]
        let profile = try XCTUnwrap(model.profiles.first)
        var finished = false
        let saving = Task { defer { finished = true }; try await model.saveProfile(profile, key: "synthetic-unused-key") }
        var replied = 0
        while !finished {
            try await eventually("Configuration command or completion") { finished || frames.count > replied }
            while replied < frames.count {
                let frame = frames[replied]; replied += 1
                let rejected = frame["method"]?.string == "session.configure" || frame["sessionId"]?.string == "main"
                host.receive(.frame(["v": .number(1), "kind": .string("reply"), "hostEpoch": .string(try XCTUnwrap(host.epoch)),
                    "commandId": try XCTUnwrap(frame["commandId"]), "ok": .bool(!rejected), "result": .object([:]),
                    "error": .object(["code": .string("session_busy"), "message": .string("Synthetic pinned owner")])]), connectionID: try XCTUnwrap(host.connectionID))
            }
        }
        try await saving.value
        XCTAssertTrue(model.opened.contains("main"), "A busy acknowledgement cannot forget the loaded owner")
        XCTAssertFalse(model.opened.contains("side"))
    }

}

/// Owner decisions (2026-10-16): one Delete removes a chat with its saved
/// sides at every depth and their sub-agents; a missing project no longer
/// blocks deletion. Generated fixtures only; no provider request is sent.
final class FamilyDeletionTests: XCTestCase {
    @MainActor private func deleteAll(_ model: WorkspaceModel) { model.familyFileRecycler = { urls in for url in urls { try FileManager.default.removeItem(at:url) } } }
    @MainActor private func assertGone(_ model: WorkspaceModel, _ ids: [String], owner: String, _ label: String) async throws {
        let store = try XCTUnwrap(model.store)
        for id in ids {
            XCTAssertNil(model.record(id),label + ": " + id)
            let saved = try await store.get(ChatRecord.self,kind:"chat",id:id)
            XCTAssertNil(saved,label + ": " + id)
            let tombstone = try await store.get(String.self,kind:"session-deleted",id:id)
            XCTAssertEqual(tombstone,owner,label + ": " + id)
            XCTAssertFalse(model.deletingFamilies.contains(id),label + ": " + id)
        }
        let intents = try await store.pendingFamilyDeletions()
        XCTAssertTrue(intents.isEmpty,label)
    }

    @MainActor func testDeletingMainDeletesEverySavedSideAtEveryDepthAndTheirSubagents() async throws {
        for (warm, listed) in [(false,true),(true,true),(false,false)] {
            let label = "warm=\(warm) listed=\(listed)"
            let model = try await sideBudgetFixture()
            let paths = try ["main","side","nested","sibling"].map { URL(fileURLWithPath:try XCTUnwrap(model.record($0)?.path)) }
            try await XCTUnwrap(model.hosts["w"]).shutdownAndWait()
            let child = try appendManagedChild(model,owner:"nested")
            if warm { _ = try await model.open(try XCTUnwrap(model.record("nested"))) }
            if !listed { model.chats = model.chats.filter { $0.id == "main" } }
            deleteAll(model)
            try await model.deleteSubagentFamily(try XCTUnwrap(model.record("main")))
            try await assertGone(model,["main","side","nested","sibling",child.id],owner:"main",label)
            for path in paths + [child.path] { XCTAssertFalse(FileManager.default.fileExists(atPath:path.path),label + ": " + path.lastPathComponent) }
            XCTAssertTrue(model.opened.isEmpty,label)
        }
    }

    @MainActor func testConfirmationListsTheSidesThatGoWithTheChat() async throws {
        let model = try await sideBudgetFixture()
        var asked: [ChatQuestion] = []
        model.questions.answer = { asked.append($0); return false }
        model.deleteChat("main")
        try await eventually("The confirmation is asked") { !asked.isEmpty || model.error != nil }
        XCTAssertNil(model.error)
        let question = try XCTUnwrap(asked.first), list = try XCTUnwrap(question.list)
        XCTAssertEqual(question.title,"Delete this chat and its sides?")
        XCTAssertEqual(question.action,"Delete Chat")
        XCTAssertTrue(question.detail.contains("All 3 of its saved sides go with it"),question.detail)
        XCTAssertEqual(list.heading,"Saved sides deleted with it (3)")
        XCTAssertEqual(list.items.map(\.title),["sibling","side","nested"],"Each side under its parent, by name")
        XCTAssertEqual(list.items.map(\.depth),[1,1,2])
        XCTAssertTrue(list.notes.isEmpty)
        XCTAssertNotNil(model.record("side"),"Cancel deletes nothing")
        asked.removeAll()
        model.deleteChat("side")
        try await eventually("The side's confirmation is asked") { !asked.isEmpty || model.error != nil }
        let side = try XCTUnwrap(asked.first)
        XCTAssertEqual(side.title,"Delete this side and its sides?")
        XCTAssertEqual(side.action,"Delete Side","Owner decision 2026-10-17")
        XCTAssertEqual(side.list?.items.map(\.title),["nested"])
        XCTAssertTrue(side.detail.contains("Its spend stays counted in “Main”."),side.detail)
    }

    @MainActor func testConfirmationLimitsALongListAndTheSheetScrolls() async throws {
        let items = (0..<260).map { ChatQuestion.List.Item(title:"Side \($0)",depth:$0 % 3 + 1) }
        var question = ChatQuestion(title:"Delete this chat and its sides?",detail:"Move its managed conversation files to Trash.",action:"Delete Chat")
        question.list = .init(heading:"Saved sides deleted with it (260)",items:items,notes:["This chat's project folder is missing."])
        let sheet = ChatQuestionSheet(question:question,list:try XCTUnwrap(question.list),destructive:true,parentSize:NSSize(width:900,height:600),answer:{ _ in })
        sheet.frame = CGRect(origin:.zero,size:sheet.intrinsicContentSize); sheet.layoutSubtreeIfNeeded()
        XCTAssertLessThan(sheet.bounds.height,600); XCTAssertTrue(sheet.review.scrolls)
        let rows = ConversationPaneTests.views(ShellText.self,in:sheet).filter { $0.accessibilityIdentifier().hasPrefix("chat-question-item-") }
        XCTAssertEqual(rows.count,ChatQuestion.List.shownLimit)
        XCTAssertTrue(ConversationPaneTests.views(ShellText.self,in:sheet).contains { $0.text == "and 60 more" })
        for button in [sheet.cancel,sheet.confirm] { XCTAssertTrue(sheet.bounds.contains(button.convert(button.bounds,to:sheet))) }
        XCTAssertEqual(sheet.cancel.keyEquivalent,"\r","Return chooses Cancel for a destructive question")
        XCTAssertTrue(question.list?.plainText.contains("and 240 more") == true,"The windowless alert form is limited too")
    }

    @MainActor func testDeletingASideDeletesItsDescendantsAndKeepsItsSpendCountedInMain() async throws {
        let model = try await sideBudgetFixture()
        try await XCTUnwrap(model.hosts["w"]).shutdownAndWait()
        _ = try interruptedSideMirror(model,terminalOwner:"nested")
        deleteAll(model)
        try await model.deleteSubagentFamily(try XCTUnwrap(model.record("side")))
        try await assertGone(model,["side","nested"],owner:"side","side")
        XCTAssertNotNil(model.record("main")); XCTAssertNotNil(model.record("sibling"))
        let host = try await model.open(try XCTUnwrap(model.record("sibling")))
        let status = try await host.request("session.status",sessionID:"main",params:["budgetOnly":.bool(true)])
        XCTAssertEqual(status.object?["cost"]?.object?["spentUSD"]?.number,0.9,"Owner decision: a deleted side's spend stays counted")
    }

    @MainActor func testInterruptedFamilyDeletionResumesAndNeverReopensASide() async throws {
        for interruption in ["files:main","files:side","files:nested","metadata:sibling","intent:nested","metadata:side"] {
            let model = try await sideBudgetFixture(), store = try XCTUnwrap(model.store)
            try await XCTUnwrap(model.hosts["w"]).shutdownAndWait()
            var interrupted = false
            deleteAll(model)
            model.familyDeletionStep = { step in if step == interruption { interrupted = true; throw StoreError.unavailable } }
            do { try await model.deleteSubagentFamily(try XCTUnwrap(model.record("main"))); XCTFail("No interruption at \(interruption)") }
            catch { XCTAssertTrue(interrupted,"\(interruption): \(error)") }
            let intents = try await store.pendingFamilyDeletions()
            for intent in intents where ["side","nested","sibling"].contains(intent.id) { XCTAssertNotNil(intent.sideDepth,interruption) }
            // A relaunch blocks every member until the retry finishes.
            model.deletingFamilies.removeAll(); await model.markPendingFamilyDeletions()
            for id in ["side","nested","sibling"] where model.record(id) != nil {
                do { _ = try await model.open(try XCTUnwrap(model.record(id))); XCTFail("\(interruption): \(id) reopened") }
                catch { XCTAssertEqual(error.localizedDescription,"This chat is being deleted.") }
            }
            model.familyDeletionStep = nil
            await model.resumeFamilyDeletions()
            XCTAssertNil(model.error,interruption)
            try await assertGone(model,["main","side","nested","sibling"],owner:"main",interruption)
        }
    }

    @MainActor func testMissingOrRemovedProjectDeletesOnlyTheChatsOwnFiles() async throws {
        for project in ["missing","removed","untrusted"] {
            for target in ["main","side"] {
                let label = project + " " + target
                let model = try await sideBudgetFixture()
                try await XCTUnwrap(model.hosts["w"]).shutdownAndWait()
                let folder = URL(fileURLWithPath:try XCTUnwrap(model.workspace(for:"w")?.path))
                let sentinel = folder.appendingPathComponent("project-file.txt")
                try Data("not chat data".utf8).write(to:sentinel)
                if project == "missing" {
                    try await model.updateConfiguration { $0.workspaces[0].paths = [folder.appendingPathComponent("moved-away").path] }
                } else if project == "untrusted" {
                    try await model.updateConfiguration { $0.workspaces[0].trusted = false }
                } else {
                    try await model.updateConfiguration { $0.workspaces = [] }
                }
                XCTAssertNotNil(model.deletionProjectUnavailable("w"),label)
                var asked: ChatQuestion?
                model.questions.answer = { asked = $0; return true }
                deleteAll(model)
                model.deleteChat(target)
                try await eventually(label + ": deletion finishes") { model.record(target) == nil && !model.deletingFamilies.contains(target) || model.error != nil }
                XCTAssertNil(model.error,label)
                let notes = try XCTUnwrap(asked?.list?.notes)
                XCTAssertTrue(notes.first?.contains("nothing in the project folder is touched") == true,label)
                XCTAssertEqual(notes.contains { $0.hasPrefix("Skipped:") },target == "side",label + ": only a side's surviving ancestors need the folder")
                let deleted = target == "main" ? ["main","side","nested","sibling"] : ["side","nested"]
                try await assertGone(model,deleted,owner:target,label)
                XCTAssertFalse(model.hosts["w"]?.isReady == true,label + ": no helper for a missing project")
                XCTAssertTrue(FileManager.default.fileExists(atPath:sentinel.path),label + ": the project folder is never touched")
                if target == "side" { XCTAssertNotNil(model.record("main")); XCTAssertNotNil(model.record("sibling")) }
            }
        }
    }

    @MainActor func testDeletingMainFinishesAnInterruptedSideDeletionInsteadOfAdoptingIt() async throws {
        let model = try await sideBudgetFixture(), store = try XCTUnwrap(model.store)
        try await XCTUnwrap(model.hosts["w"]).shutdownAndWait()
        let nestedPath = URL(fileURLWithPath:try XCTUnwrap(model.record("nested")?.path))
        deleteAll(model)
        model.familyDeletionStep = { step in if step == "files:side" { throw StoreError.unavailable } }
        do { try await model.deleteSubagentFamily(try XCTUnwrap(model.record("side"))); XCTFail("No interruption") } catch { }
        model.familyDeletionStep = nil
        // The interrupted side's nested member is outside the chat window.
        model.chats.removeAll { $0.id == "nested" }
        try await model.deleteSubagentFamily(try XCTUnwrap(model.record("main")))
        for id in ["side","nested"] {
            let tombstone = try await store.get(String.self,kind:"session-deleted",id:id)
            XCTAssertEqual(tombstone,"side","The earlier deletion keeps its own receipts")
        }
        let intents = try await store.pendingFamilyDeletions()
        XCTAssertTrue(intents.isEmpty)
        try await assertGone(model,["main","sibling"],owner:"main","main")
        XCTAssertNil(model.record("side"))
        XCTAssertFalse(FileManager.default.fileExists(atPath:nestedPath.path))
        await model.resumeFamilyDeletions()
        XCTAssertNil(model.error)
    }

    @MainActor func testPublishedSideWithoutAChatRowGoesWithItsChat() async throws {
        let model = try await sideBudgetFixture(), store = try XCTUnwrap(model.store)
        try await XCTUnwrap(model.hosts["w"]).shutdownAndWait()
        // side.open published the journal, but registering its chat failed.
        let path = try model.subagentDirectory("w").appendingPathComponent("side_pending.jsonl")
        try Data("{\"type\":\"session\",\"version\":3,\"id\":\"pending\"}\n".utf8).write(to:path)
        let pending = ChatRecord(id:"pending",workspaceID:"w",title:"Published side",path:path.path,profileID:"p",toolMode:ChatRecord.readOnlyTools,parentSessionID:"side")
        try await store.put(SideKeepIntent(chat:pending),kind:"side-keep",id:pending.id)
        model.sideKeepIssues = [SideKeepIssue(chat:pending,parentTitle:"side",reason:"The chat could not be registered.")]
        var asked: ChatQuestion?
        model.questions.answer = { asked = $0; return true }
        deleteAll(model)
        model.deleteChat("main")
        try await eventually("Deletion finishes") { model.record("main") == nil && !model.deletingFamilies.contains("main") || model.error != nil }
        XCTAssertNil(model.error)
        XCTAssertTrue(asked?.list?.items.map(\.title).contains("Published side") == true)
        try await assertGone(model,["main","side","nested","sibling","pending"],owner:"main","pending side")
        XCTAssertFalse(FileManager.default.fileExists(atPath:path.path))
        let intent = try await store.get(SideKeepIntent.self,kind:"side-keep",id:"pending")
        XCTAssertNil(intent,"Launch recovery must not register it later")
        XCTAssertTrue(model.sideKeepIssues.isEmpty,"The deleted side's recovery notice goes with it")
    }

    @MainActor func testFailedTombstoneReadReleasesEverySideMark() async throws {
        let model = try await sideBudgetFixture()
        try await XCTUnwrap(model.hosts["w"]).shutdownAndWait()
        model.deletionTombstoneRead = { id in if id == "side" { throw StoreError.unavailable }; return nil }
        deleteAll(model)
        do { try await model.deleteSubagentFamily(try XCTUnwrap(model.record("main"))); XCTFail("The read failure must stop the deletion") } catch { }
        XCTAssertTrue(model.deletingFamilies.isEmpty,"No durable intent exists, so no member stays marked: \(model.deletingFamilies)")
        _ = try await model.open(try XCTUnwrap(model.record("side")))
        model.deletionTombstoneRead = nil
        try await model.deleteSubagentFamily(try XCTUnwrap(model.record("main")))
        try await assertGone(model,["main","side","nested","sibling"],owner:"main","retry")
    }

    @MainActor func testOrphanedSideFromAnEarlierVersionStaysUntilItIsDeletedItself() async throws {
        let model = try await sideBudgetFixture(), store = try XCTUnwrap(model.store)
        try await XCTUnwrap(model.hosts["w"]).shutdownAndWait()
        let directory = try model.subagentDirectory("w"), path = directory.appendingPathComponent("side_orphan.jsonl")
        try Data("{\"type\":\"session\",\"version\":3,\"id\":\"orphan\"}\n".utf8).write(to:path)
        let orphan = ChatRecord(id:"orphan",workspaceID:"w",title:"Recovered side",path:path.path,profileID:"p",toolMode:ChatRecord.readOnlyTools,parentSessionID:"deleted-in-0.1.128")
        try await store.put(orphan,kind:"chat",id:orphan.id); model.chats.append(orphan)
        deleteAll(model)
        try await model.deleteSubagentFamily(try XCTUnwrap(model.record("main")))
        XCTAssertNotNil(model.record("orphan"),"Never delete user data retroactively")
        XCTAssertTrue(FileManager.default.fileExists(atPath:path.path))
        XCTAssertFalse(model.deletionNeedsAncestorRepair(orphan),"An orphan is its own budget owner")
        try await model.deleteSubagentFamily(orphan)
        try await assertGone(model,["orphan"],owner:"orphan","orphan")
        XCTAssertFalse(FileManager.default.fileExists(atPath:path.path))
    }
}

// This class opens the real Inspector window; run it alone in the serial lane.
final class SideBudgetInspectorLifetimeTests: XCTestCase, SerialTestLane {
    @MainActor func testRaiseLimitFromNestedSideHasAnEditableOwnerWithoutADisplay() async throws {
        let model = try await sideBudgetFixture()
        model.costSeedRead = { item in item.id == "main" ? .object(["usd":.number(1.2),"reported":.number(2),"unreported":.number(0)]) : nil }
        _ = try await model.open(try XCTUnwrap(model.record("nested")))
        model.costLimitNotice(.raise,sessionID:"nested",anchor:NSView())
        let controller = try XCTUnwrap(SessionInspectorWindows.shared.controller(sessionID:"main"))
        let content = try XCTUnwrap(controller.window?.contentView)
        try await eventually("Raise limit presents the owner editor") { !ConversationPaneTests.views(CostLimitLiveEditor.self,in:content).isEmpty }
        let editor = try XCTUnwrap(ConversationPaneTests.views(CostLimitLiveEditor.self,in:content).first)
        XCTAssertEqual(editor.reading.spentUSD,1.2)
        try await editor.choose(.usd(2))
        try await eventually("Owner editor follows its saved value") { editor.reading.limit == .usd(2) }
        XCTAssertEqual(model.costReading(for:"nested").limit,.usd(2))
        XCTAssertFalse(model.costReading(for:"nested").reached)
        XCTAssertNil(model.displays["main"]); XCTAssertNil(model.displays["side"])
        controller.close()
    }
    @MainActor func testInspectorPinsAnImplicitWriterUntilItsWindowCloses() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("side-budget-inspector-" + UUID().uuidString)
        let model = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        try await model.traces.configure(quota: nil, bodyRetention: 86400, metricRetention: 86400)
        model.chats = [ChatRecord(id: "main", workspaceID: "w", title: "Main", profileID: "p")]
        var frames: [[String: WireValue]] = []
        let host = HostSupervisor(commandSender: { frames.append($0) })
        try await host.connect(cwd: root, state: root.appendingPathComponent("host"))
        model.hosts["w"] = host; model.opened = ["main"]; model.budgetDependencySessions = ["main"]
        let inspector = SessionInspectorWindows.shared.show(model: model, sessionID: "main", workspaceID: "w", title: "Main", focus: .overview)
        model.releaseUnusedBudgetSessions()
        XCTAssertTrue(model.sessionClosings.isEmpty); XCTAssertTrue(frames.isEmpty)
        inspector.close()
        try await eventually("Closing the last Inspector releases the budget-only runtime") { !frames.isEmpty }
        let frame = try XCTUnwrap(frames.first)
        XCTAssertEqual(frame["method"]?.string, "session.close")
        host.receive(.frame(["v": .number(1), "kind": .string("reply"), "hostEpoch": .string(try XCTUnwrap(host.epoch)),
            "commandId": try XCTUnwrap(frame["commandId"]), "ok": .bool(true), "result": .object(["accepted": .bool(true)])]), connectionID: try XCTUnwrap(host.connectionID))
        try await eventually("The unload is acknowledged") { model.opened.isEmpty && model.sessionClosings.isEmpty }
        XCTAssertTrue(model.budgetDependencySessions.isEmpty)
    }
}

extension XCTestCase {
    @MainActor fileprivate func fixtureJournalRows(_ path: URL) throws -> [[String:WireValue]] {
        try Data(contentsOf:path).split(separator:10).map { try JSONDecoder().decode([String:WireValue].self,from:Data($0)) }
    }

    @MainActor fileprivate func lastFixtureCost(_ path: URL) throws -> [String:WireValue] {
        try XCTUnwrap(fixtureJournalRows(path).last {
            ["pi-app.cost.v1","pi-app.cost-update.v1"].contains($0["customType"]?.string ?? "")
        }?["data"]?.object)
    }

    /// A crash after the root's durable correction but before either saved
    /// side mirror. Existing journal identities/parent links stay intact.
    @MainActor fileprivate func interruptedSideMirror(_ model: WorkspaceModel, foreignSideIdentity: Bool = false, terminalOwner: String = "main") throws -> [URL] {
        let unknown: [String:WireValue] = ["attemptId":.string("crashed-mirror"),"sourceSessionId":.string("nested"),
            "budgetOwnerSessionId":.string("nested"),"sideParents":.array([.string("side"),.string("main")]),
            "purpose":.string("turn"),"outcome":.string("completed"),"usd":.number(0),
            "reported":.number(0),"unreported":.number(1),"accountingRevision":.number(1)]
        var corrected = unknown
        corrected["usd"] = .number(0.9); corrected["reported"] = .number(1); corrected["unreported"] = .number(0)
        corrected["accountingRevision"] = .number(2)
        corrected["usage"] = .object(["input":.number(100),"output":.number(20),"total":.number(120)])
        var sides: [URL] = []
        for id in ["main","side","nested"] {
            let path = URL(fileURLWithPath:try XCTUnwrap(model.record(id)?.path))
            let rows = try fixtureJournalRows(path)
            var previous = try XCTUnwrap(rows.last?["id"]?.string), data = try Data(contentsOf:path)
            var cost = unknown
            if foreignSideIdentity && id == "side" { cost["budgetOwnerSessionId"] = .string("foreign") }
            for (kind, value) in [("pi-app.cost.v1",cost)] + (id == terminalOwner ? [("pi-app.cost-update.v1",corrected)] : []) {
                let key = UUID().uuidString
                let row: [String:WireValue] = ["type":.string("custom"),"id":.string(key),"parentId":.string(previous),
                    "customType":.string(kind),"data":.object(value)]
                data.append(try JSONEncoder().encode(row)); data.append(10); previous = key
            }
            try data.write(to:path)
            if id != "main" { sides.append(path) }
        }
        return sides
    }

    /// A completed managed sub-agent owned by a saved side: its accepted
    /// plan in the owner's journal and its own child journal beside it.
    @MainActor fileprivate func appendManagedChild(_ model: WorkspaceModel, owner: String) throws -> (id: String, path: URL) {
        let path = URL(fileURLWithPath:try XCTUnwrap(model.record(owner)?.path))
        var link = SubagentTranscriptTests.link
        link.childSessionID = UUID().uuidString; link.budgetOwnerSessionID = owner; link.call.parentSessionID = owner
        let origin: WireValue = .object([
            "link":try JSONDecoder().decode(WireValue.self,from:JSONEncoder().encode(link)),
            "description":.string("Deletion fixture"),"model":.object(["model":.string("fixture")]),
            "tools":.array([]),"readOnly":.bool(true),"resourceRevision":.string("fixture")])
        func append(_ kind: String, _ value: [String:WireValue], to file: URL) throws {
            let rows = try fixtureJournalRows(file), id = UUID().uuidString
            let row: [String:WireValue] = ["type":.string("custom"),"customType":.string(kind),"id":.string(id),
                "parentId":rows.last?["type"]?.string == "session" ? .null : (rows.last?["id"] ?? .null),"data":.object(value)]
            var bytes = try Data(contentsOf:file); bytes.append(try JSONEncoder().encode(row)); bytes.append(10)
            try bytes.write(to:file)
        }
        try append("pi-app.subagent-call.v1",["origin":origin,"task":.string("Private fixture"),"resultMessageID":.string("result")],to:path)
        let child = path.deletingLastPathComponent().appendingPathComponent(link.childSessionID + ".jsonl")
        let header: [String:WireValue] = ["type":.string("session"),"version":.number(3),"id":.string(link.childSessionID)]
        var bytes = try JSONEncoder().encode(header); bytes.append(10); try bytes.write(to:child)
        try append("pi-app.native.v2",["version":.number(2)],to:child)
        try append("pi-app.subagent-origin.v1",try XCTUnwrap(origin.object),to:child)
        return (link.childSessionID, child)
    }

    @MainActor fileprivate func sideBudgetFixture() async throws -> WorkspaceModel {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("side-budget-integration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = WorkspaceRecord(id: "w", path: root.path, trusted: true)
        var profile = ProfileRecord(); profile.id = "p"; profile.baseUrl = "http://127.0.0.1:9/v1"; profile.modelId = "fixture"
        let connection = VaultProfile(profile: profile, apiKey: "synthetic-unused-key")
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        _ = try await vault.update(expectedRevision: 0) {
            $0.workspaces = [workspace]; $0.profiles = [connection]
            $0.resources[workspace.id] = .object(["codexHome": .string(root.appendingPathComponent("codex").path)])
        }
        let model = makeWorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: vault)
        registerWorkspaceFixtureTeardown(model, root: root)
        try await model.reloadConfiguration()
        let parent = ChatRecord(id: "main", workspaceID: "w", title: "Main", profileID: "p", costLimit: .usd(0.75))
        try await model.store?.put(parent, kind: "chat", id: parent.id); model.chats = [parent]
        let host = try await model.open(parent)
        for (id, owner) in [("side", "main"), ("nested", "side"), ("sibling", "main")] {
            _ = try await host.request("side.open", sessionID: owner, params: ["sideSessionId": .string(id)])
            let result = try await host.request("side.keep", sessionID: id)
            let record = ChatRecord(id: id, workspaceID: "w", title: id, path: result.object?["path"]?.string,
                                    profileID: "p", toolMode: ChatRecord.readOnlyTools, parentSessionID: owner, costLimit: .usd(99))
            XCTAssertNotNil(record.path)
            try await model.store?.put(record, kind: "chat", id: id); model.chats.append(record)
        }
        // Keep the process alive, but release every runtime to model a cold
        // visit. No request is sent to the synthetic connection.
        for id in ["nested", "sibling", "side", "main"] { _ = try await host.request("session.close", sessionID: id) }
        model.opened.removeAll(); model.displays.removeAll()
        return model
    }

}
