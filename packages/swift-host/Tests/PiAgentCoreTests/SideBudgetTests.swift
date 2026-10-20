import XCTest
@testable import PiAgentCore

final class SideBudgetTests: XCTestCase {
    func testRecoveredCopyDropsOriginalPausedSidesButKeepsItsOwnHeldWork() async throws {
        for ownWork in [false,true] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let main = try await session("main",root:root), side = try await session("side",root:root,parent:main)
            _ = try await side.keep(whenFinished:false)
            let request = try await start(side,attempt:"paid"); try await finish(request,attempt:"paid",cost:0.4)
            try await main.append(ChatMessage(role:"user",content:[textBlock("Finished task")]))
            try await main.append(ChatMessage(role:"assistant",content:[textBlock("Done")]))
            if ownWork { try await main.append(ChatMessage(role:"user",content:[textBlock("Held question")])) }
            let source = root.appendingPathComponent("main.jsonl"), sidePath = await side.path
            await side.close(); await main.close()
            // The last complete record before a torn tail names an existing
            // side of the original family, never a descendant of the copy.
            var saved: JSON = ["active":false,"queue":[],"steering":[],"commands":[],"runStatus":"cancelled"]
            saved["costPaused"] = true; saved["queuePaused"] = true; saved["costPausedMembers"] = ["side"]
            do {
                let journal = try SessionJournal(url:source,id:"main",cwd:root,binding:fixtureProfile().binding,create:false)
                try journal.append(["type":"custom","customType":JSON(JournalRecordKind.state),"data":saved],flush:true)
            }
            let writer = try FileHandle(forWritingTo:source)
            try writer.seekToEnd(); try writer.write(contentsOf:Data("{\"type\":\"message\"".utf8)); try writer.close()
            let original = try Data(contentsOf:source), sideBytes = try Data(contentsOf:URL(fileURLWithPath:XCTUnwrap(sidePath)))
            let service = try await host(root)
            let recovered = try await service.command("session.recover",sessionID:nil,params:["path":JSON(source.path),"newSessionId":"copy"])
            let path = try XCTUnwrap(recovered["sessionFile"].text)
            let copy = try await open(service,"copy",path:path,limit:0.3)
            let snapshot = await copy.snapshot()
            XCTAssertEqual(snapshot["cost"]["spentUSD"].double ?? -1,0.4,accuracy:1e-9)
            XCTAssertTrue(snapshot["cost"]["pausedMembers"].list.isEmpty,"Existing original-family files confer no membership on a recovered copy")
            XCTAssertEqual(snapshot["costPaused"].flag == true,ownWork,"Only the copy's own held work keeps its pause")
            XCTAssertEqual(snapshot["continuable"].flag,ownWork)
            _ = try await service.command("session.configure",sessionID:"copy",params:["costLimit":["usd":1]])
            if !ownWork {
                do {
                    let reply = try await service.command("run.continue",sessionID:"copy",params:[:])
                    XCTAssertTrue(reply["pausedMembers"].list.isEmpty)
                } catch { XCTAssertEqual((error as? AgentError)?.code,AgentErrorCode.nothingToContinue) }
                let after = await copy.snapshot()
                XCTAssertEqual(after["state"].text,"idle",after["preflightError"].encoded()); XCTAssertNotEqual(after["costPaused"].flag,true)
            }
            await service.shutdown()
            if ownWork {
                let client = AccountedAgentScript([answer("Answered the copy's held question")])
                let resumed = try AgentSession(id:"copy",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,
                    readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore(),resumePath:path)
                let tail = await resumed.continuationTail
                XCTAssertEqual(tail?.text,"Held question")
                await resumed.setCostLimit(1)
                let reply = try await resumed.continueRun(commandID:"own-resume")
                XCTAssertEqual(reply["continued"].flag,true,reply.encoded())
                XCTAssertTrue(reply["pausedMembers"].list.isEmpty)
                try await eventually { !(await resumed.isRunning) }
                let after = await resumed.snapshot(), calls = await client.requests.count
                XCTAssertEqual(after["state"].text,"idle",after["preflightError"].encoded()); XCTAssertNotEqual(after["costPaused"].flag,true)
                XCTAssertEqual(calls,1,"Ancestry repair must preserve the copy's own continuation")
                await resumed.close()
            }
            let savedCopy = try SideBudgetRecovery.pauseState(URL(fileURLWithPath:path),id:"copy").state
            XCTAssertTrue(savedCopy["costPausedMembers"].list.isEmpty,"The ancestry repair must be durable")
            XCTAssertEqual(try Data(contentsOf:source),original)
            XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:XCTUnwrap(sidePath))),sideBytes)
        }
    }

    func testForgetDamagedUnrelatedHistoryDoesNotInventBudgetAncestry() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let host = try await host(root)
        for prefix in ["","fork_","side_"] {
            let file = root.appendingPathComponent(prefix + "damaged.jsonl")
            try Data("cut off before a valid origin".utf8).write(to:file)
            _ = try await host.command("session.forget",sessionID:"damaged",params:[:])
            XCTAssertEqual(try Data(contentsOf:file),Data("cut off before a valid origin".utf8))
            try FileManager.default.removeItem(at:file)
        }
        await host.shutdown()
    }

    func testReleaseDependentsPreflightsRunningNestedSidesAndKeepsTheOwnerPinnedUntilIdle() async throws {
        for running in ["side","nested","sibling"] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let host = try await host(root), owner = try await open(host,"main")
            for (id,parent) in [("side","main"),("nested","side"),("sibling","main")] {
                _ = try await host.command("side.open",sessionID:parent,params:["sideSessionId":JSON(id)])
            }
            let value = await host.loadedSession(running), nested = try XCTUnwrap(value)
            let request = try await start(nested,attempt:"running")
            do {
                _ = try await host.command("session.releaseDependents",sessionID:"main",params:[:])
                XCTFail("Preflight must reject actual in-flight work without unloading idle siblings")
            } catch {
                XCTAssertEqual((error as? AgentError)?.code,"side_budget_busy")
                XCTAssertTrue((error as? AgentError)?.message.contains(running) == true)
            }
            for id in ["main","side","nested","sibling"] { let loaded = await host.loadedSession(id); XCTAssertNotNil(loaded) }
            do { _ = try await host.command("session.close",sessionID:"main",params:[:]); XCTFail("Keep the pinned-owner guard") }
            catch { XCTAssertEqual((error as? AgentError)?.code,"session_busy") }
            try await finish(request,attempt:"running",cost:0.2)
            let result = try await host.command("session.releaseDependents",sessionID:"main",params:[:])
            XCTAssertEqual(Set(result["released"].list.compactMap(\.text)),["side","nested","sibling"])
            for id in ["side","nested","sibling"] { let loaded = await host.loadedSession(id); XCTAssertNil(loaded) }
            let loadedOwner = await host.loadedSession("main"); XCTAssertTrue(loadedOwner === owner)
            _ = try await host.command("session.close",sessionID:"main",params:[:])
            let unloaded = await host.loadedSession("main"); XCTAssertNil(unloaded)
            await host.shutdown()
        }
    }

    func testFailedSettlementDrainsEveryAncestorAndPreservesTerminalEvidence() async throws {
        for failedWriters in [["main"], ["side"], ["main","side"]] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let main = try await session("main",root:root,failSettlement:failedWriters.contains("main"))
            let sideFile = root.appendingPathComponent("side_side.jsonl"), seed = await main.sideSeed()
            do {
                let writer = try SessionJournal(url:sideFile,id:"side",cwd:root,binding:fixtureProfile().binding,create:true)
                try writer.append(["type":"custom","customType":JSON(JournalRecordKind.sideOrigin),"data":seed.info])
            }
            let side = try await session("side",root:root,parent:main,path:sideFile.path,failSettlement:failedWriters.contains("side"))
            let nested = try await session("nested",root:root,parent:side)
            _ = try await nested.keep(whenFinished:false)
            let request = try await start(nested,attempt:"settling")
            for member in [main,side,nested] {
                let pending = await member.inFlightBudgetAttempts
                XCTAssertEqual(pending,["settling"])
            }
            do { try await finish(request,attempt:"settling",cost:0.7); XCTFail("The injected append must fail") }
            catch { XCTAssertEqual((error as? AgentError)?.code,"accounting_persistence","Preserve the original failure") }
            let evidence = await nested.accounting.attempts["settling"]?.contribution
            XCTAssertEqual(evidence?["usd"].double,0.7)
            XCTAssertEqual(evidence?["usage"]["total"].int,120)
            for member in [nested,side,main] {
                let pending = await member.inFlightBudgetAttempts, permits = await member.requestPermits
                XCTAssertTrue(pending.isEmpty,"\(failedWriters): finished requests cannot pin an ancestor")
                XCTAssertTrue(permits.isEmpty)
                let unloaded = await member.unloadIfIdle()
                XCTAssertTrue(unloaded,"\(failedWriters): every finished runtime must be releasable")
                if !unloaded { await member.close() }
            }
            let recovered = try await session("main",root:root,path:root.appendingPathComponent("main.jsonl").path)
            let spend = await recovered.spend, usage = await recovered.familyUsage
            XCTAssertEqual(spend.usd,0.7); XCTAssertEqual(spend.reported,1); XCTAssertEqual(spend.unreported,0)
            XCTAssertEqual(usage["total"].int,120,"Saved terminal evidence repairs the failed ancestor without captures")
            await recovered.close()
        }
    }

    func testReleaseFindsColdSideOwnedReadersAndDoesNotFollowForkProvenance() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        var f = SideBudgetUpgradeFixture(root:root,shape:.current,family:.nestedAgents,usage:.priced,crash:.afterAll)
        try f.write(); let host = try await f.host()
        _ = try await f.open(host,"child"); _ = try await f.open(host,"main")
        _ = try await host.command("session.fork",sessionID:"main",params:["forkSessionId":"fork"])
        let independent = try await host.command("session.releaseDependents",sessionID:"fork",params:[:])
        XCTAssertTrue(independent["released"].list.isEmpty)
        let child = await host.loadedSession("child"); XCTAssertNotNil(child)
        let result = try await host.command("session.releaseDependents",sessionID:"main",params:[:])
        XCTAssertEqual(result["released"].list,["child"])
        let released = await host.loadedSession("child"), fork = await host.loadedSession("fork")
        XCTAssertNil(released); XCTAssertNotNil(fork)
        await host.shutdown()
    }

    func testColdSideDeletionRepairsEveryAncestorAfterRealSettlementAppendFailures() async throws {
        for failedWriters in [["main"], ["side"], ["main","side"]] {
            for deleted in ["side","nested"] {
                let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
                let main = try await session("main",root:root,failSettlement:failedWriters.contains("main"))
                let sideFile = root.appendingPathComponent("side_side.jsonl"), seed = await main.sideSeed()
                do {
                    let writer = try SessionJournal(url:sideFile,id:"side",cwd:root,binding:fixtureProfile().binding,create:true)
                    try writer.append(["type":"custom","customType":JSON(JournalRecordKind.sideOrigin),"data":seed.info])
                }
                let side = try await session("side",root:root,parent:main,path:sideFile.path,failSettlement:failedWriters.contains("side"))
                let nested = try await session("nested",root:root,parent:side)
                _ = try await nested.keep(whenFinished:false)
                let request = try await start(nested,attempt:"settling")
                do { try await finish(request,attempt:"settling",cost:0.7); XCTFail("Inject failed owner settlement") }
                catch { XCTAssertEqual((error as? AgentError)?.code,"accounting_persistence") }
                for member in [nested,side,main] { await member.close() }
                let host = try await host(root)
                _ = try await host.command("session.forget",sessionID:deleted,params:[:])
                try FileManager.default.removeItem(at:root.appendingPathComponent("side_" + deleted + ".jsonl"))
                for id in ["main"] + (deleted == "nested" ? ["side"] : []) {
                    let owner = try await open(host,id,path:root.appendingPathComponent((id == "main" ? "" : "side_") + id + ".jsonl").path)
                    let spend = await owner.spend, usage = await owner.familyUsage
                    XCTAssertEqual(spend.usd,0.7,"\(failedWriters), deleting \(deleted)")
                    XCTAssertEqual(spend.reported,1); XCTAssertEqual(spend.unreported,0)
                    XCTAssertEqual(usage["total"].int,120)
                }
                await host.shutdown()
            }
        }
    }

    func testRecoveredSavedSideIsIndependentWithItsOwnLimitAndUntouchedOriginal() async throws {
        for withChild in [false,true] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let main = try await session("main",root:root), side = try await session("side",root:root,parent:main)
            let request = try await start(side,attempt:"paid")
            try await finish(request,attempt:"paid",cost:0.4)
            _ = try await side.keep(whenFinished:false)
            var childPath: String?
            if withChild {
                await side.beginPresentedTask("turn")
                try await side.appendAgentRecord(JournalRecordKind.familyRun,AgentFamilyRun(epoch:"old-run"))
                var origin = subagentFixtureOrigin(child:"managed",parent:"side")
                origin.link.parentExecutionID = await side.activeTaskPresentation!.executionID
                try await side.installAdmissionFixturePlan(SubagentPlan(origin:origin,task:"Old task",resultMessageID:"old-result"))
                let child = try AgentSession(id:"managed",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
                    resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),prepared:nil,subagentOrigin:origin)
                try await child.bindBudgetOwner(side,generation:0)
                let delegated = try await start(child,attempt:"delegated")
                try await finish(delegated,attempt:"delegated",cost:0.2)
                childPath = await child.path; await child.close()
            }
            let expected = withChild ? 0.6 : 0.4
            let maybePath = await side.path, maybeMainPath = await main.path
            let path = try XCTUnwrap(maybePath), mainPath = try XCTUnwrap(maybeMainPath)
            await side.close(); await main.close()
            let source = URL(fileURLWithPath:path), writer = try FileHandle(forWritingTo:source)
            try writer.seekToEnd(); try writer.write(contentsOf:Data("{\"type\":\"message\"".utf8)); try writer.close()
            let damaged = try Data(contentsOf:source), mainBytes = try Data(contentsOf:URL(fileURLWithPath:mainPath))
            let childBytes = try childPath.map { try Data(contentsOf:URL(fileURLWithPath:$0)) }
            let service = try await host(root)
            let recovered = try await service.command("session.recover",sessionID:nil,params:["path":JSON(path),"newSessionId":"recovered"])
            let copyPath = try XCTUnwrap(recovered["sessionFile"].text)
            let copy = try await open(service,"recovered",path:copyPath,limit:0.3)
            let isSide = await copy.isSideChat, parents = await copy.sideBudgetIDs, spend = await copy.spend
            XCTAssertFalse(isSide); XCTAssertTrue(parents.isEmpty); XCTAssertEqual(spend.usd,expected,accuracy:1e-9)
            let copiedPlans = await copy.subagents.plans
            XCTAssertTrue(copiedPlans.isEmpty,"Historical children retain the original side as their direct owner")
            let originalParent = await service.loadedSession("main")
            XCTAssertNil(originalParent,"Recovery must not need an unloaded original budget owner")
            do { try await copy.enforceSharedCostLimit(); XCTFail("The copy has its own enforced limit") }
            catch { XCTAssertEqual((error as? AgentError)?.code,"cost_limit") }
            await copy.setCostLimit(1); try await copy.enforceSharedCostLimit()
            let provenance = await copy.parentInfo
            XCTAssertEqual(provenance["relationship"].text,"recovered-copy")
            XCTAssertEqual(provenance["sourceSessionId"].text,"side"); XCTAssertNil(provenance["parentSessionId"].text)
            XCTAssertEqual(try Data(contentsOf:source),damaged)
            XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:mainPath)),mainBytes,"No duplicate adoption into the original family")
            if let childPath { XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:childPath)),childBytes) }
            await service.shutdown()
            let again = try await host(root), reopened = try await open(again,"recovered",path:copyPath,limit:0.3)
            let againSpend = await reopened.spend; XCTAssertEqual(againSpend.usd,expected,accuracy:1e-9)
            await again.shutdown()
        }
    }

    func testBudgetStatusReadsNumericStateWithoutTranscriptOrCaptureContext() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let host = try await host(root), owner = try await open(host,"main",seed:1.2)
        let status = try await host.command("session.status",sessionID:"main",params:["budgetOnly":true])
        XCTAssertEqual(Set(status.map.keys),["cost"])
        let cost = await owner.costSnapshot; XCTAssertEqual(status["cost"],cost)
        await host.shutdown()
    }
    func testUnrelatedSideWithUnreadableOriginDoesNotBlockHealthyColdOpens() async throws {
        for tail in [Data("{\"type\":\"message\"".utf8), Data(repeating: 120, count: 33 * 1024 * 1024)] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let main = try await session("main",root:root), path = await main.path
            await main.close()
            let bad = root.appendingPathComponent("side_damaged.jsonl")
            var bytes = Data("{\"type\":\"session\",\"id\":\"damaged\"}\n".utf8); bytes.append(tail)
            try bytes.write(to:bad)
            do {
                let reopened = try await session("main",root:root,path:path)
                let spend = await reopened.spend; XCTAssertEqual(spend.usd,0)
                await reopened.close()
            } catch { XCTFail("Unknown side membership must not poison another chat: \(error)") }
            do {
                let damaged = try await session("damaged",root:root,path:bad.path)
                await damaged.close(); XCTFail("The damaged side must still use history recovery")
            } catch { }
            XCTAssertEqual(try Data(contentsOf:bad),bytes,"Discovery never rewrites damaged history")
        }
    }

    func testReconciliationCreatesAMissingLoadedChildChargeAndPersistsIt() async throws {
        try await reconcileManagedMirror(readerLoaded:true,missingCharge:true)
    }
    func testMissingManagedMirrorRejectsForeignOwnershipAndIgnoresUnrelatedSources() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let origin = subagentFixtureOrigin()
        let child = try AgentSession(id:"child",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
            resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),prepared:nil,subagentOrigin:origin)
        let cost = await child.contribution(billingObservation(profile:try fixtureProfile(),session:"child",attempt:"missing",cost:0.7),owner:"parent",delegation:origin.link.delegationID)
        for key in ["budgetOwnerSessionId","delegationId"] {
            var foreign = cost; foreign[key] = "foreign"
            do { _ = try await child.mirrorSharedCharge(foreign); XCTFail("A missing entry must not bypass \(key)") } catch { }
        }
        var unrelated = cost; unrelated["sourceSessionId"] = "other-child"
        let ignored = try await child.mirrorSharedCharge(unrelated); XCTAssertFalse(ignored)
        let before = await child.spend; XCTAssertEqual(before.usd,0)
        for _ in 0..<2 { _ = try await child.mirrorSharedCharge(cost) }
        let after = await child.spend; XCTAssertEqual(after.usd,0.7); XCTAssertEqual(after.reported,1)
        await child.close()
    }
    func testUnsettledManagedWorkPinsItsMainOrSideOwnerBetweenRequests() async throws {
        for isSide in [false,true] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let host = try await host(root)
            if isSide {
                _ = try await open(host,"main")
                _ = try await host.command("side.open",sessionID:"main",params:["sideSessionId":"parent"])
            }
            let owner = try await open(host,"parent")
            await owner.beginPresentedTask("turn")
            var origin = subagentFixtureOrigin()
            let execution = await owner.activeTaskPresentation?.executionID
            origin.link.parentExecutionID = try XCTUnwrap(execution)
            try await owner.installAdmissionFixturePlan(SubagentPlan(origin:origin,task:"Task",resultMessageID:"result"))
            let child = try AgentSession(id:"child",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
                resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),prepared:nil,subagentOrigin:origin)
            await child.close()
            let live = try await open(host,"child",path:root.appendingPathComponent("child.jsonl").path)
            try await live.bindBudgetOwner(owner,generation:0)
            await live.installManagedCancellation(SubagentCoordinator(),key:origin.link.call)
            let permits = await owner.inFlightBudgetAttempts
            XCTAssertTrue(permits.isEmpty,"Exercise queued/tool work between model requests")
            do { _ = try await host.command("session.close",sessionID:owner.id,params:[:]); XCTFail("An unsettled managed child still needs its writer") }
            catch { XCTAssertEqual((error as? AgentError)?.code,"session_busy") }
            do { _ = try await host.command("session.releaseDependents",sessionID:owner.id,params:[:]); XCTFail("Tool/queued work must block family release between requests") }
            catch {
                XCTAssertEqual((error as? AgentError)?.code,"side_budget_busy")
                XCTAssertTrue((error as? AgentError)?.message.contains("child") == true)
            }
            let retained = await host.loadedSession(owner.id)
            XCTAssertTrue(retained === owner)
            await host.shutdown()
        }
    }

    func testUnreadableSideDirectoryCannotSilentlyEraseTheRecoveredFamilyBudget() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let main = try await session("main",root:root), side = try await session("side",root:root,parent:main)
        _ = try await side.keep(whenFinished:false)
        await side.close(); await main.close()
        try FileManager.default.setAttributes([.posixPermissions:0o300],ofItemAtPath:root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:root.path) }
        do {
            _ = try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
            throw XCTSkip("This test runner can bypass directory read permissions")
        } catch is CocoaError { }
        XCTAssertThrowsError(try SideBudgetRecovery.charges(owner:"main",directory:root),"An unreadable family is not an empty family")
    }

    private func host(_ root: URL) async throws -> NativeHostService {
        let host = NativeHostService(emit: { _ in })
        _ = try await host.command("workspace.open",sessionID:nil,params:["cwd":JSON(root.path),"directory":JSON(root.path),"resources":["codexHome":JSON(root.appendingPathComponent("codex").path)]])
        return host
    }
    private func open(_ host: NativeHostService, _ id: String, path: String? = nil, seed: Double? = nil, limit: Double = 1) async throws -> AgentSession {
        var params: JSON = ["profile":try fixtureProfile().raw,"apiKey":"fixture","toolMode":"read-only","costLimit":["usd":JSON(limit)]]
        if let path { params["path"] = JSON(path) }
        if let seed { params["costSeed"] = ["usd":JSON(seed),"reported":1,"unreported":0] }
        _ = try await host.command("session.open",sessionID:id,params:params)
        let loaded = await host.loadedSession(id); return try XCTUnwrap(loaded)
    }

    func testLegacySideSeedJoinsTheBudgetImmediatelyAndOnlyOnce() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let main = try await session("main",root:root), seed = await main.sideSeed()
        let path = root.appendingPathComponent("side_legacy.jsonl")
        do {
            let journal = try SessionJournal(url:path,id:"legacy",cwd:root,binding:fixtureProfile().binding,create:true)
            try journal.append(["type":"custom","customType":JSON(JournalRecordKind.sideOrigin),"data":seed.info])
        }
        let mainPath = await main.path; await main.close()
        for _ in 0..<2 {
            let host = try await host(root)
            let owner = try await open(host,"main",path:mainPath,limit:0.5)
            let side = try await open(host,"legacy",path:path.path,seed:0.7)
            try await side.bindSideBudget(to:owner)
            let spend = await owner.spend
            XCTAssertEqual(spend.usd,0.7); XCTAssertEqual(spend.reported,1)
            do { _ = try await start(side,attempt:UUID().uuidString); XCTFail("Legacy side spend must block before any cold reopen") }
            catch { XCTAssertEqual((error as? AgentError)?.code,"cost_limit") }
            await host.shutdown()
        }
    }

    func testSavedOrphanReopensWithItsOwnSpendAndBudgetWithoutRecreatingParent() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let main = try await session("main",root:root), side = try await session("side",root:root,parent:main)
        let request = try await start(side,attempt:"before-delete")
        try await finish(request,attempt:"before-delete",cost:0.4)
        let kept = try await side.keep(whenFinished:false), mainPath = await main.path
        await side.close(); await main.close()
        try FileManager.default.removeItem(atPath:try XCTUnwrap(mainPath))
        for _ in 0..<2 {
            let host = try await host(root)
            do {
                let orphan = try await open(host,"side",path:kept["path"].text,limit:0.3)
                let cost = await orphan.costSnapshot
                XCTAssertEqual(cost["spentUSD"].double,0.4); XCTAssertEqual(cost["limitUSD"].double,0.3)
                do { _ = try await start(orphan,attempt:"over-limit"); XCTFail("The surviving side must enforce its own budget") }
                catch { XCTAssertEqual((error as? AgentError)?.code,"cost_limit") }
            } catch { XCTFail("Saved orphan is a surviving chat: \(error)") }
            XCTAssertFalse(FileManager.default.fileExists(atPath:try XCTUnwrap(mainPath)))
            await host.shutdown()
        }
    }

    func testExplicitCloseRejectsPinnedOwnerAndForgetDetachesIdleSideWriters() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let host = try await host(root), owner = try await open(host,"main")
        _ = try await host.command("side.open",sessionID:"main",params:["sideSessionId":"side"])
        let loaded = await host.loadedSession("side"), side = try XCTUnwrap(loaded)
        do { _ = try await host.command("session.close",sessionID:"main",params:[:]); XCTFail("An explicit close must mean the runtime is gone") }
        catch { XCTAssertEqual((error as? AgentError)?.code,"session_busy") }
        let original = await host.loadedSession("main"); XCTAssertTrue(original === owner)
        let request = try await start(side,attempt:"in-flight")
        do { _ = try await host.command("session.forget",sessionID:"main",params:[:]); XCTFail("Deleting an owner cannot abandon dispatched side accounting") }
        catch { XCTAssertEqual((error as? AgentError)?.code,"session_busy") }
        try await finish(request,attempt:"in-flight",cost:0.2)
        _ = try await host.command("session.forget",sessionID:"main",params:[:])
        let removed = await host.loadedSession("main"), detached = await host.loadedSession("side")
        XCTAssertNil(removed); XCTAssertNil(detached,"Deleting the parent must release surviving sides for an orphan reopen")
        await host.shutdown()
    }

    /// Round 7: deleting an idle paused side takes it off its root's list of
    /// sides waiting for Resume; a root paused only for it is not paused.
    func testDeletingAPausedSideTakesItOffItsRootsPause() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let host = try await host(root), owner = try await open(host,"main", limit: 5)
        _ = try await host.command("side.open",sessionID:"main",params:["sideSessionId":"side"])
        let loaded = await host.loadedSession("side"), side = try XCTUnwrap(loaded)
        _ = try await side.keep(whenFinished:false)
        await side.roundSevenPause()
        try await side.bindSideBudget(to:owner)
        var members = await owner.costPausedMembers, paused = await owner.costPaused
        XCTAssertEqual(members,["side"]); XCTAssertTrue(paused)
        _ = try await host.command("session.forget",sessionID:"side",params:["descendantsDeleted":true,"ancestorsRepaired":true])
        members = await owner.costPausedMembers; paused = await owner.costPaused
        XCTAssertTrue(members.isEmpty, "A deleted side waits for no Resume"); XCTAssertFalse(paused, "Nothing else held the root")
        await host.shutdown()
    }

    func testDeletingMainWithLegacyReportedManagedSpendKeepsOrphanFamilyCountedOnce() async throws {
        for loadedSide in [false,true] {
            for loadedChild in [false,true] {
                let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
                let main = try await session("main",root:root), seed = await main.sideSeed()
                // Before shared side budgets, both physical journals lacked
                // sideParents even though this saved side belonged to main.
                let side = try AgentSession(id:"side",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
                    resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),seed:seed.messages,parent:seed.info)
                let kept = try await side.keep(whenFinished:false), mainPath = await main.path
                await side.enableFamilyBudget()
                await side.beginPresentedTask("turn")
                var origin = subagentFixtureOrigin(parent:"side")
                let execution = await side.activeTaskPresentation?.executionID
                origin.link.parentExecutionID = try XCTUnwrap(execution)
                try await side.installAdmissionFixturePlan(SubagentPlan(origin:origin,task:"Private legacy task",resultMessageID:"result"))
                let child = try AgentSession(id:"child",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
                    resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),prepared:nil,subagentOrigin:origin)
                try await child.bindBudgetOwner(side,generation:0)
                let request = try await start(child,attempt:"legacy-reported")
                try await finish(request,attempt:"legacy-reported",cost:0.7)
                try await child.setSubagentState(.completed)
                await child.close(); await side.close(); await main.close()
                let host = try await host(root)
                let owner = try await open(host,"main",path:mainPath)
                if loadedSide { _ = try await open(host,"side",path:kept["path"].text) }
                if loadedChild { _ = try await open(host,"child",path:root.appendingPathComponent("child.jsonl").path) }
                let total = await owner.spend; XCTAssertEqual(total.usd,0.7); XCTAssertEqual(total.reported,1)
                do { _ = try await host.command("session.forget",sessionID:"main",params:[:]) }
                catch {
                    XCTFail("Migrated known child cost must not block deletion (side=\(loadedSide), child=\(loadedChild)): \(error)")
                    await host.shutdown(); continue
                }
                await host.shutdown()
                try FileManager.default.removeItem(atPath:try XCTUnwrap(mainPath))
                for _ in 0..<2 {
                    let reopened = try await self.host(root)
                    let orphan = try await open(reopened,"side",path:kept["path"].text,limit:0.5)
                    let cost = await orphan.costSnapshot
                    XCTAssertEqual(cost["spentUSD"].double,0.7); XCTAssertEqual(cost["reportedRequests"].int,1)
                    XCTAssertEqual(cost["familyUsage"]["output"].int,20)
                    do { _ = try await start(orphan,attempt:UUID().uuidString); XCTFail("Orphan must enforce its own family budget") }
                    catch { XCTAssertEqual((error as? AgentError)?.code,"cost_limit") }
                    await reopened.shutdown()
                }
            }
        }
    }

    func testReconciliationUpdatesALoadedSideOwnedManagedMirror() async throws {
        try await reconcileManagedMirror(readerLoaded:true)
    }

    func testReconciliationRepairsAnUnloadedSideAndItsManagedMirrorOnOpen() async throws {
        try await reconcileManagedMirror(readerLoaded:false)
    }

    func testReconciliationPersistsUnloadedSidesBeforeParentDeletionWithoutCaptureRecovery() async throws {
        for nested in [false,true] {
            for managed in [false,true] {
                for readerLoaded in managed ? [false,true] : [false] {
                    try await reconcileThenDeleteParent(nested:nested,managed:managed,readerLoaded:readerLoaded)
                }
            }
        }
    }

    func testForgettingAColdParentRepairsAnInterruptedMirrorBeforeDeletingItsOnlyEvidence() async throws {
        try await reconcileThenDeleteParent(nested:true,managed:true,readerLoaded:false,interruptedMirror:true)
    }

    private func reconcileThenDeleteParent(nested: Bool, managed: Bool, readerLoaded: Bool, interruptedMirror: Bool = false) async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let host = try await host(root), main = try await open(host,"main")
        _ = try await host.command("side.open",sessionID:"main",params:["sideSessionId":"parent"])
        if nested { _ = try await host.command("side.open",sessionID:"parent",params:["sideSessionId":"nested"]) }
        let ownerID = nested ? "nested" : "parent", sourceID = managed ? "child" : ownerID
        let loaded = await host.loadedSession(ownerID), owner = try XCTUnwrap(loaded)
        let source: AgentSession
        if managed {
            await owner.beginPresentedTask("turn")
            var origin = subagentFixtureOrigin(parent:ownerID)
            let execution = await owner.activeTaskPresentation?.executionID
            origin.link.parentExecutionID = try XCTUnwrap(execution)
            try await owner.installAdmissionFixturePlan(SubagentPlan(origin:origin,task:"Private side task",resultMessageID:"result"))
            source = try AgentSession(id:"child",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
                resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),prepared:nil,subagentOrigin:origin)
            try await source.bindBudgetOwner(owner,generation:0)
        } else { source = owner }
        let request = try await start(source,attempt:"unknown")
        try await request.settleAttempt(AttemptSettlement(scope:request.scope,observation:billingObservation(profile:try fixtureProfile(),session:sourceID,attempt:"unknown",cost:nil),dispatched:true))
        if managed {
            try await source.setSubagentState(.completed); await source.close()
            if readerLoaded { _ = try await open(host,"child",path:root.appendingPathComponent("child.jsonl").path) }
        }
        if nested { _ = try await host.command("session.close",sessionID:"nested",params:[:]) }
        _ = try await host.command("session.close",sessionID:"parent",params:[:])
        // The only capture evidence is this transient value. No archive can
        // rescue the orphan after the main journal has been deleted.
        let evidence: JSON = ["attemptId":"unknown","sessionId":JSON(sourceID),"turnId":"turn","purpose":"turn","outcome":"completed",
            "requestScope":try subagentJSON(request.scope),"gateway":["cost":["status":"reported","usd":0.7]],"usage":["inputIncludingCache":100,"output":20,"total":120]]
        let ids = ["parent"] + (nested ? ["nested"] : []) + (managed ? ["child"] : [])
        let label = "nested=\(nested) managed=\(managed) readerLoaded=\(readerLoaded)"
        let mainPath = await main.path
        func assertDisk(_ ids: [String]) throws {
            for id in ids {
                let url = root.appendingPathComponent((id == "child" ? "" : "side_") + id + ".jsonl")
                let journal = try SessionJournal(url:url,id:id,cwd:root,binding:nil,create:false)
                let replay = try AgentSession.replay(journal,url:url,id:id,binding:fixtureProfile().binding,spendTracked:false,resume:false)
                XCTAssertEqual(replay.spend.usd,0.7,label + " disk " + id)
                XCTAssertEqual(replay.spend.reported,1,label); XCTAssertEqual(replay.spend.unreported,0,label)
                XCTAssertEqual(replay.accounting.usageTotals["output"],20,label)
            }
        }
        if interruptedMirror {
            // Simulate the durable owner commit followed by a helper exit
            // before mirroring. No capture or loaded owner remains to retry it.
            _ = try await main.reconcileCapturedAccounting([evidence],mirrorChildren:false)
            _ = try await host.command("session.close",sessionID:"main",params:[:])
        } else {
            for _ in 0..<2 { _ = try await host.command("budget.reconcile",sessionID:"main",params:["evidence":.array([evidence])]) }
            try assertDisk(ids.filter { $0 != "child" || !readerLoaded })
        }
        _ = try await host.command("session.forget",sessionID:"main",params:[:])
        await host.shutdown()
        try FileManager.default.removeItem(atPath:try XCTUnwrap(mainPath))
        // Inspect disk before any session initializer can repair a mirror.
        try assertDisk(ids)
        for _ in 0..<2 {
            let reopened = try await self.host(root)
            for id in ids {
                let value = try await open(reopened,id,path:root.appendingPathComponent((id == "child" ? "" : "side_") + id + ".jsonl").path,limit:0.5)
                let cost = await value.costSnapshot
                XCTAssertEqual(cost["spentUSD"].double,0.7,label + " reopen " + id)
                XCTAssertEqual(cost["reportedRequests"].int,1,label); XCTAssertEqual(cost["unreportedRequests"].int,0,label)
                if id != "child" {
                    do { _ = try await start(value,attempt:UUID().uuidString); XCTFail("Corrected orphan family must enforce its budget: " + label) }
                    catch { XCTAssertEqual((error as? AgentError)?.code,"cost_limit",label) }
                }
            }
            await reopened.shutdown()
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath:try XCTUnwrap(mainPath)))
    }

    private func reconcileManagedMirror(readerLoaded: Bool, missingCharge: Bool = false) async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let host = try await host(root), main = try await open(host,"main")
        _ = try await host.command("side.open",sessionID:"main",params:["sideSessionId":"parent"])
        let loaded = await host.loadedSession("parent"), side = try XCTUnwrap(loaded)
        await side.beginPresentedTask("turn")
        var origin = subagentFixtureOrigin()
        let execution = await side.activeTaskPresentation?.executionID
        origin.link.parentExecutionID = try XCTUnwrap(execution)
        try await side.installAdmissionFixturePlan(SubagentPlan(origin:origin,task:"Task",resultMessageID:"result"))
        let child = try AgentSession(id:"child",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),prepared:nil,subagentOrigin:origin)
        try await child.bindBudgetOwner(side,generation:0)
        let request = try await start(child,attempt:"unknown-child")
        let observation = billingObservation(profile:try fixtureProfile(),session:"child",attempt:"unknown-child",cost:nil)
        try await request.settleAttempt(AttemptSettlement(scope:request.scope,observation:observation,dispatched:true))
        try await child.setSubagentState(.completed); await child.close()
        if missingCharge {
            let path = root.appendingPathComponent("child.jsonl")
            let rows = try String(contentsOf:path,encoding:.utf8).split(separator:"\n").map { line -> String in
                var record = try JSON.parse(Data(line.utf8))
                if record["data"]["attemptId"].text == "unknown-child" {
                    record["customType"] = "fixture.uncommitted-cost"; record["data"] = [:]
                }
                return String(decoding:try record.data(),as:UTF8.self)
            }
            try Data((rows.joined(separator:"\n") + "\n").utf8).write(to:path)
        }
        if readerLoaded { _ = try await open(host,"child",path:root.appendingPathComponent("child.jsonl").path) }
        else { _ = try await host.command("session.close",sessionID:"parent",params:[:]) }
        let evidence: JSON = ["attemptId":"unknown-child","sessionId":"child","turnId":"turn","purpose":"turn","outcome":"completed","requestScope":try subagentJSON(request.scope),"gateway":["cost":["status":"reported","usd":0.7]],"usage":["inputIncludingCache":100,"output":20]]
        for _ in 0..<2 {
            do { _ = try await host.command("budget.reconcile",sessionID:"main",params:["evidence":.array([evidence])]) }
            catch { XCTFail("A contribution-only managed mirror must accept the owner's correction: \(error)") }
        }
        let currentSide = try await open(host,"parent",path:root.appendingPathComponent("side_parent.jsonl").path)
        let reader = try await open(host,"child",path:root.appendingPathComponent("child.jsonl").path)
        for value in [main,currentSide,reader] {
            let cost = await value.costSnapshot
            XCTAssertEqual(cost["spentUSD"].double,0.7); XCTAssertEqual(cost["reportedRequests"].int,1)
            XCTAssertEqual(cost["unreportedRequests"].int,0)
        }
        await host.shutdown()
        if missingCharge {
            let reopened = try await session("child",root:root,path:root.appendingPathComponent("child.jsonl").path)
            let spend = await reopened.spend
            XCTAssertEqual(spend.usd,0.7); XCTAssertEqual(spend.reported,1)
            await reopened.close()
        }
    }

    func testColdRecoveryAdoptsAReportedCorrectionFromALegacySideOnce() async throws {
        try await legacyCorrection(cold:true)
    }

    func testLiveLegacyCorrectionUpdatesTheContributionOnlyAncestor() async throws {
        try await legacyCorrection(cold:false)
    }

    private func legacyCorrection(cold: Bool) async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let main = try await session("main",root:root), seed = await main.sideSeed()
        let side = try AgentSession(id:"legacy",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
            resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),seed:seed.messages,parent:seed.info)
        await side.enableSubagents(SubagentCoordinator(),steering:false)
        await side.enableFamilyBudget()
        let request = try await start(side,attempt:"legacy-unknown")
        try await request.settleAttempt(AttemptSettlement(scope:request.scope,observation:billingObservation(profile:try fixtureProfile(),session:"legacy",attempt:"legacy-unknown",cost:nil),dispatched:true))
        let kept = try await side.keep(whenFinished:false), mainPath = await main.path
        await main.close(); await side.close()
        let baseline = try await session("main",root:root,path:mainPath)
        let before = await baseline.spend; XCTAssertEqual(before.unreported,1)
        await baseline.close()
        let evidence: JSON = ["attemptId":"legacy-unknown","sessionId":"legacy","turnId":"turn","purpose":"turn","outcome":"completed",
            "requestScope":try subagentJSON(request.scope),"gateway":["cost":["status":"reported","usd":0.7]],"usage":["inputIncludingCache":100,"output":20]]
        if cold {
            let legacy = try await session("legacy",root:root,path:kept["path"].text)
            _ = try await legacy.reconcileCapturedAccounting([evidence]); await legacy.close()
        } else {
            let host = try await host(root), main = try await open(host,"main",path:mainPath)
            _ = try await open(host,"legacy",path:kept["path"].text)
            for _ in 0..<2 { _ = try await host.command("budget.reconcile",sessionID:"legacy",params:["evidence":.array([evidence])]) }
            let total = await main.spend; XCTAssertEqual(total.usd,0.7); XCTAssertEqual(total.unreported,0)
            await host.shutdown()
        }
        for _ in 0..<2 {
            let reopened = try await session("main",root:root,path:mainPath)
            let total = await reopened.costSnapshot
            XCTAssertEqual(total["spentUSD"].double,0.7); XCTAssertEqual(total["reportedRequests"].int,1)
            XCTAssertEqual(total["unreportedRequests"].int,0); XCTAssertEqual(total["familyUsage"]["output"].int,20)
            await reopened.setCostLimit(0.5)
            do { _ = try await start(reopened,attempt:UUID().uuidString); XCTFail("Recovered corrections must enforce the budget immediately") }
            catch { XCTAssertEqual((error as? AgentError)?.code,"cost_limit") }
            await reopened.close()
        }
    }

    func testExistingUnloadedParentCannotBeBypassedAndNestedOrphansUseTheirSurvivingOwner() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let host = try await host(root), main = try await open(host,"main")
        _ = try await host.command("side.open",sessionID:"main",params:["sideSessionId":"side"])
        _ = try await host.command("side.open",sessionID:"side",params:["sideSessionId":"nested"])
        let mainPath = await main.path
        _ = try await host.command("session.forget",sessionID:"main",params:[:])
        do { _ = try await open(host,"side",path:root.appendingPathComponent("side_side.jsonl").path); XCTFail("An unloaded parent still owns the budget") }
        catch { XCTAssertEqual((error as? AgentError)?.code,"side_budget_parent") }
        try FileManager.default.removeItem(atPath:try XCTUnwrap(mainPath))
        let side = try await open(host,"side",path:root.appendingPathComponent("side_side.jsonl").path,limit:0.5)
        let nested = try await open(host,"nested",path:root.appendingPathComponent("side_nested.jsonl").path,limit:9)
        let request = try await start(nested,attempt:"surviving-side")
        XCTAssertEqual(request.scope.sideParents,["side"])
        try await finish(request,attempt:"surviving-side",cost:0.6)
        let total = await side.spend; XCTAssertEqual(total.usd,0.6)
        do { _ = try await start(nested,attempt:"over-limit"); XCTFail("An existing nested side shares the surviving owner's limit") }
        catch { XCTAssertEqual((error as? AgentError)?.code,"cost_limit") }
        await host.shutdown()
    }

    func testForkOfASideStartsAnIndependentFamilyBudgetOnCreateAndReload() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let host = try await host(root), main = try await open(host,"main",limit:0.1)
        _ = try await host.command("side.open",sessionID:"main",params:["sideSessionId":"source"])
        let held = await host.loadedSession("source"), source = try XCTUnwrap(held)
        let request = try await start(source,attempt:"source-spend"); try await finish(request,attempt:"source-spend",cost:0.2)
        try await source.sideBudgetFixtureReply("point")
        let forked = try await host.command("session.fork",sessionID:"source",params:["forkSessionId":"fork","costLimit":["usd":0.5]])
        let fork = try await open(host,"fork",path:forked["path"].text,limit:0.5)
        let zero = await fork.spend; XCTAssertEqual(zero,SessionSpend())
        _ = try await host.command("side.open",sessionID:"fork",params:["sideSessionId":"fork-side"])
        let loaded = await host.loadedSession("fork-side"), side = try XCTUnwrap(loaded)
        let own = try await start(side,attempt:"fork-side-spend")
        XCTAssertEqual(own.scope.sideParents,["fork"])
        try await finish(own,attempt:"fork-side-spend",cost:0.6)
        let original = await main.spend, total = await fork.spend
        XCTAssertEqual(original.usd,0.2); XCTAssertEqual(total.usd,0.6)
        await host.shutdown()
        let reopenedHost = try await self.host(root)
        let reopened = try await open(reopenedHost,"fork",path:forked["path"].text,limit:0.5)
        let parents = await reopened.sideBudgetIDs, spend = await reopened.spend
        XCTAssertTrue(parents.isEmpty); XCTAssertEqual(spend.usd,0.6)
        do { _ = try await start(reopened,attempt:"fork-limit"); XCTFail("The fork must enforce its own family spend") }
        catch { XCTAssertEqual((error as? AgentError)?.code,"cost_limit") }
        await reopenedHost.shutdown()
    }

    private func session(_ id: String, root: URL, parent: AgentSession? = nil, path: String? = nil, failSettlement: Bool = false) async throws -> AgentSession {
        let seed = await parent?.sideSeed()
        let value = try AgentSession(id: id, profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root,
            readOnly: true, resources: Resources(cwd: root, home: root), client: ScriptClient([]), tools: DisabledTools(), traces: TraceStore(),
            resumePath: path, seed: path == nil ? seed?.messages : nil, parent: seed?.info ?? .null,
            beforeJournalAppend: { record in
                if failSettlement, record["customType"].text == JournalRecordKind.cost,
                   record["data"]["attemptId"].text == "settling" { throw AgentError("fixture_append","Injected \(id) settlement failure") }
            })
        if let parent { try await value.bindSideBudget(to: parent) }
        return value
    }
    private func start(_ side: AgentSession, attempt: String) async throws -> RequestLifecycle {
        let pending = try await side.requestLifecycle(turnID: "turn", purpose: "turn")
        let lifecycle = try XCTUnwrap(pending)
        _ = try await lifecycle.admitAttempt(attempt); try await lifecycle.willDispatch(attempt)
        return lifecycle
    }
    private func finish(_ lifecycle: RequestLifecycle, attempt: String, cost: Double, outcome: String = "completed") async throws {
        var observation = billingObservation(profile: try fixtureProfile(), session: lifecycle.scope.sourceSessionID, attempt: attempt, cost: cost)
        observation.monitoring["outcome"] = JSON(outcome)
        observation.fields = ["input":100,"output":20,"total":120]
        try await lifecycle.settleAttempt(AttemptSettlement(scope: lifecycle.scope, observation: observation, dispatched: true))
    }

    func testEphemeralSpendSurvivesDiscardAndBlocksTheWholeFamilyWithoutSideContent() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let parent = try await session("main", root: root)
        await parent.setCostLimit(1)
        let side = try await session("side", root: root, parent: parent)
        try await side.append(ChatMessage(role:"user",content:[textBlock("EPHEMERAL SECRET SIDE CONTENT")]))
        let first = try await start(side, attempt:"first"), running = try await start(parent, attempt:"running-main")
        let permit = await parent.requestPermits["running-main"]
        try await finish(first, attempt:"first",cost:1.2,outcome:"failed")
        XCTAssertThrowsError(try XCTUnwrap(permit).check(), "The family pauses at once: a dispatched request is cancelled")
        do { _ = try await start(side,attempt:"blocked"); XCTFail("Side must use main budget") }
        catch { XCTAssertEqual((error as? AgentError)?.code,"cost_limit") }
        do { _ = try await start(parent,attempt:"also-blocked"); XCTFail("Main must include side spend") }
        catch { XCTAssertEqual((error as? AgentError)?.code,"cost_limit") }
        // Admission preceded the limit crossing. Its settlement (what the
        // aborted request reported) must still succeed.
        try await finish(running,attempt:"running-main",cost:0.3)
        await side.close(); let path = await parent.path; await parent.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("side_side.jsonl").path))
        let bytes = try String(contentsOfFile:try XCTUnwrap(path),encoding:.utf8)
        XCTAssertFalse(bytes.contains("EPHEMERAL SECRET SIDE CONTENT"))
        let reopened = try await session("main",root:root,path:path)
        let cost = await reopened.costSnapshot
        XCTAssertEqual(cost["spentUSD"].double ?? 0,1.5,accuracy:1e-9)
        XCTAssertEqual(cost["familyUsage"]["input"].int,200)
        XCTAssertEqual(cost["familyUsage"]["output"].int,40)
        await reopened.close()
    }

    func testKeepAndReloadRetainAttemptIdentityTokensAndDoNotChargeAgain() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        var parent = try await session("main",root:root)
        var side = try await session("side",root:root,parent:parent)
        let lifecycle = try await start(side,attempt:"physical")
        try await finish(lifecycle,attempt:"physical",cost:0.4,outcome:"cancelled")
        let kept = try await side.keep(whenFinished:false), parentPath = await parent.path
        await side.close(); await parent.close()
        for _ in 0..<2 {
            parent = try await session("main",root:root,path:parentPath)
            side = try await session("side",root:root,parent:parent,path:kept["path"].text)
            let own = await side.costSnapshot, total = await parent.costSnapshot
            XCTAssertEqual(own["spentUSD"].double,0.4)
            XCTAssertEqual(total["spentUSD"].double,0.4)
            XCTAssertEqual(own["familyUsage"]["input"].int,100)
            XCTAssertEqual(total["familyUsage"]["output"].int,20)
            let ids = await side.accounting.attempts.keys.sorted()
            XCTAssertEqual(ids,["physical"])
            await side.close(); await parent.close()
        }
    }

    func testOpeningMainAdoptsLegacySavedSidesWithoutReopeningTheirContent() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let main = try await session("main",root:root), seed = await main.sideSeed()
        let old = try AgentSession(id:"legacy", profile:fixtureProfile(), apiKey:"fixture", cwd:root,directory:root,readOnly:true,
            resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),seed:seed.messages,parent:seed.info)
        try await old.append(ChatMessage(role:"user",content:[textBlock("LEGACY SIDE PRIVATE CONTENT")]))
        await old.countAttempt(billingObservation(profile:try fixtureProfile(),session:"legacy",attempt:"old-attempt",cost:0.7))
        _ = try await old.keep(whenFinished:false)
        let path = await main.path; await old.close(); await main.close()
        for _ in 0..<2 {
            let reopened = try await session("main",root:root,path:path)
            let total = await reopened.spend
            XCTAssertEqual(total.usd,0.7); XCTAssertEqual(total.reported,1)
            let bytes = try String(contentsOfFile:try XCTUnwrap(path),encoding:.utf8)
            XCTAssertFalse(bytes.contains("LEGACY SIDE PRIVATE CONTENT"))
            await reopened.close()
        }
    }

    func testSideOwnedSubagentUsesTheMainBudgetWithoutChangingDelegationIdentity() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let main = try await session("main",root:root), side = try await session("parent",root:root,parent:main)
        _ = try await side.preserveSide()
        await side.beginPresentedTask("turn")
        var origin = subagentFixtureOrigin()
        let execution = await side.activeTaskPresentation?.executionID
        origin.link.parentExecutionID = try XCTUnwrap(execution)
        try await side.installAdmissionFixturePlan(SubagentPlan(origin:origin,task:"Task",resultMessageID:"result"))
        let child = try AgentSession(id:"child",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
            resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),prepared:nil,subagentOrigin:origin)
        try await child.bindBudgetOwner(side,generation:0)
        await main.setCostLimit(0.5)
        let lifecycle = try await start(child,attempt:"delegated-side-request")
        XCTAssertEqual(lifecycle.scope.budgetOwnerSessionID,"parent")
        XCTAssertEqual(lifecycle.scope.chargeOwnerSessionID,"main")
        XCTAssertEqual(lifecycle.scope.delegation,origin.link)
        try await finish(lifecycle,attempt:"delegated-side-request",cost:0.6)
        for value in [main,side,child] { let spend = await value.spend; XCTAssertEqual(spend.usd,0.6) }
        do { _ = try await start(child,attempt:"blocked-child"); XCTFail("Side subagent must share root limit") }
        catch { XCTAssertEqual((error as? AgentError)?.code,"cost_limit") }
        await child.close(); await side.close(); await main.close()
    }

    func testUnrelatedDamagedSideCannotPreventOpeningMainButRelatedDamageIsNotIgnored() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let main = try await session("main",root:root), unrelated = try await session("unrelated",root:root)
        let side = try await session("side",root:root,parent:unrelated)
        let kept = try await side.keep(whenFinished:false)
        let mainPath = await main.path, unrelatedPath = await unrelated.path
        await side.close(); await unrelated.close(); await main.close()
        let file = try FileHandle(forWritingTo: URL(fileURLWithPath:try XCTUnwrap(kept["path"].text)))
        try file.seekToEnd(); try file.write(contentsOf:Data("{damaged-side-record}\n".utf8)); try file.close()
        let reopened = try await session("main",root:root,path:mainPath)
        let spend = await reopened.spend; XCTAssertEqual(spend.usd,0)
        await reopened.close()
        do {
            let damaged = try await session("unrelated",root:root,path:unrelatedPath)
            await damaged.close(); XCTFail("Related accounting damage must not silently reset a shared budget")
        } catch { }
    }

    func testLegacyMainSeedAndSavedSideHistoryAreAdoptedOnceThroughSessionOpen() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let main = try await session("main",root:root), seed = await main.sideSeed()
        let side = try AgentSession(id:"legacy",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
            resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),seed:seed.messages,parent:seed.info)
        await side.countAttempt(billingObservation(profile:try fixtureProfile(),session:"legacy",attempt:"old-side",cost:0.7))
        _ = try await side.keep(whenFinished:false)
        let held = await main.path, path = try XCTUnwrap(held)
        await side.close(); await main.close()
        for _ in 0..<2 {
            let host = NativeHostService(emit: { _ in })
            _ = try await host.command("workspace.open",sessionID:nil,params:["cwd":JSON(root.path),"directory":JSON(root.path),"resources":["codexHome":JSON(root.appendingPathComponent("codex").path)]])
            _ = try await host.command("session.open",sessionID:"main",params:["profile":try fixtureProfile().raw,"apiKey":"fixture","toolMode":"read-only","path":JSON(path),"costSeed":["usd":0.5,"reported":1,"unreported":0]])
            let snapshot = try await host.command("session.status",sessionID:"main",params:[:])
            XCTAssertEqual(snapshot["cost"]["spentUSD"].double ?? 0,1.2,accuracy:1e-9)
            XCTAssertEqual(snapshot["cost"]["reportedRequests"].int,2)
            await host.shutdown()
        }
    }

    func testLateCaptureCorrectionRepairsRootAndSideWithoutDoubleCounting() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let main = try await session("main",root:root), side = try await session("side",root:root,parent:main)
        let lifecycle = try await start(side,attempt:"unknown")
        let observation = billingObservation(profile:try fixtureProfile(),session:"side",attempt:"unknown",cost:nil)
        try await lifecycle.settleAttempt(AttemptSettlement(scope:lifecycle.scope,observation:observation,dispatched:true))
        let evidence: JSON = ["attemptId":"unknown","sessionId":"side","turnId":"turn","purpose":"turn","outcome":"failed",
            "requestScope":try subagentJSON(lifecycle.scope),"usage":["inputIncludingCache":100,"output":20],"gateway":["cost":["status":"reported","usd":0.7]]]
        for _ in 0..<2 { _ = try await main.reconcileCapturedAccounting([evidence]); try await side.refreshSideCharges() }
        for value in [main,side] {
            let cost = await value.costSnapshot
            XCTAssertEqual(cost["spentUSD"].double,0.7); XCTAssertEqual(cost["reportedRequests"].int,1)
            XCTAssertEqual(cost["unreportedRequests"].int,0); XCTAssertEqual(cost["familyUsage"]["output"].int,20)
        }
        await side.close(); await main.close()
    }

    /// A side bound while the main request (begun before any family ledger)
    /// is on the wire: the side's crossing pauses main at once, cancelling
    /// that request, whose aborted attempt is still counted as unknown.
    func testOpeningASideDuringTheParentsRequestKeepsItsChargeAndPausesIt() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = SideBudgetHeldClient()
        let main = try AgentSession(id:"main",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,
            resources:Resources(cwd:root,home:root),client:client,tools:DisabledTools(),traces:TraceStore(),autoCompaction:false)
        await main.setCostLimit(1)
        _ = try await main.submit(Submission(commandID:"main-command",turnID:"main-turn",text:"Main request"),steer:false)
        try await eventually { await client.started }
        let side = try await session("side",root:root,parent:main)
        let lifecycle = try await start(side,attempt:"side-crosses-limit")
        try await finish(lifecycle,attempt:"side-crosses-limit",cost:1.2)
        try await eventually(timeout:.seconds(2)) { !(await main.isRunning) }
        let state = await main.snapshot(), cost = await main.costSnapshot
        XCTAssertEqual(state["state"].text,"paused","The pre-ledger main request is cut at once")
        XCTAssertEqual(state["costPaused"].flag,true); XCTAssertEqual(state["errorCode"].text,"cost_limit")
        XCTAssertEqual(cost["spentUSD"].double ?? 0,1.2,accuracy:1e-9)
        XCTAssertEqual(cost["reportedRequests"].int,1)
        XCTAssertEqual(cost["unreportedRequests"].int,1,"The aborted request's cost stays unknown, never zero")
        let replies = await main.history.filter { $0.role == "assistant" }.map(\.text)
        XCTAssertFalse(replies.contains("The admitted main request finished"))
        await side.close(); await main.close()
    }

    func testNestedSideSharesRootAndItsImmediateParentsTotals() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let main = try await session("main",root:root)
        let side = try await session("side",root:root,parent:main)
        let nested = try await session("nested",root:root,parent:side)
        await main.setCostLimit(0.5)
        let lifecycle = try await start(nested,attempt:"nested-attempt")
        XCTAssertEqual(lifecycle.scope.sideParents,["side","main"])
        XCTAssertTrue(lifecycle.scope.valid)
        try await finish(lifecycle,attempt:"nested-attempt",cost:0.6)
        for value in [main,side,nested] {
            let spend = await value.spend
            XCTAssertEqual(spend.usd,0.6)
            do { _ = try await start(value,attempt:UUID().uuidString); XCTFail("Every member uses the root limit") }
            catch { XCTAssertEqual((error as? AgentError)?.code,"cost_limit") }
        }
        await nested.close(); await side.close(); await main.close()
    }
}

private extension AgentSession {
    func sideBudgetFixtureReply(_ id: String) throws {
        var row = ChatMessage(role:"assistant",content:[textBlock(id)]); row.id = id
        try append(row); boundary = context
    }
}

private actor SideBudgetHeldClient: ModelClient {
    var started = false, released = false
    func release() { released = true }
    func complete(profile:Profile,apiKey:String,messages:[ChatMessage],instructions:String,tools:[ToolDefinition],sessionID:String,turnID:String,purpose:String,onDelta:@escaping @Sendable(StreamDelta) async throws -> Void) async throws -> ModelReply {
        try await complete(profile:profile,apiKey:apiKey,messages:messages,instructions:instructions,tools:tools,sessionID:sessionID,turnID:turnID,purpose:purpose,onObservation:{ _ in },onDelta:onDelta)
    }
    func complete(profile:Profile,apiKey:String,messages:[ChatMessage],instructions:String,tools:[ToolDefinition],sessionID:String,turnID:String,purpose:String,onObservation:@escaping @Sendable(RequestObservation) async -> Void,onDelta:@escaping @Sendable(StreamDelta) async throws -> Void) async throws -> ModelReply {
        started = true
        do { while !released { try await Task.sleep(for:.milliseconds(2)) }; try Task.checkCancellation() }
        catch {
            // A cut request reports its terminal observation without a cost.
            var cut = billingObservation(profile:profile,session:sessionID,attempt:"main-before-side",cost:nil)
            cut.monitoring["outcome"] = "cancelled"
            await onObservation(cut); throw error
        }
        var observation = billingObservation(profile:profile,session:sessionID,attempt:"main-before-side",cost:0.3)
        observation.fields = ["input":100,"output":20]
        await onObservation(observation)
        return answer("The admitted main request finished")
    }
}

private extension AgentSession {
    func roundSevenPause() { costPaused = true; queuePaused = true; errorCode = AgentSession.costLimitCode }
}
