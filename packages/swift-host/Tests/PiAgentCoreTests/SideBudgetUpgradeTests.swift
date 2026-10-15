import XCTest
@testable import PiAgentCore

final class SideBudgetUpgradeTests: XCTestCase {
    func testMissingLegacyFieldsNeverAuthorizeAConflictingSideIdentity() async throws {
        for field in ["sourceSessionId","budgetOwnerSessionId","delegationId"] {
            for loaded in [false,true] {
                let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
                let f = SideBudgetUpgradeFixture(root:root,shape:.countAttempt127,family:.side,usage:.priced,crash:.afterAll)
                var original = try SideBudgetUpgradeFixture.legacyCost("count-attempt-priced")
                original[field] = "foreign"
                do {
                    let writer = try SessionJournal(url:f.file("side"),id:"side",cwd:root,binding:fixtureProfile().binding,create:true)
                    try writer.append(f.row(JournalRecordKind.sideOrigin,["parentSessionId":"main","relationship":"side"]))
                    try writer.append(f.row(JournalRecordKind.cost,original))
                }
                var cost = try SideBudgetUpgradeFixture.legacyCost("count-attempt-priced")
                cost["sourceSessionId"] = "side"; cost["budgetOwnerSessionId"] = "side"; cost["sideParents"] = ["main"]
                if loaded {
                    let side = try AgentSession(id:"side",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),resumePath:f.file("side").path)
                    do { try await side.mirrorSharedCharge(cost); XCTFail("Accepted conflicting \(field)") }
                    catch { XCTAssertEqual((error as? AgentError)?.code,"accounting_damaged") }
                    await side.close()
                } else {
                    XCTAssertThrowsError(try SideBudgetRecovery.mirrorCapturedCosts([cost],owner:"main",directory:root,loaded:[])) {
                        XCTAssertEqual(($0 as? AgentError)?.code,"accounting_damaged")
                    }
                }
            }
        }
    }

    func testCarriedSeedRemainsExactAcrossSettlementsAndOldCheckpoints() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        var f = SideBudgetUpgradeFixture(root:root,shape:.preCost,family:.side,usage:.priced,crash:.beforeSide)
        try f.write()
        for pass in 0..<2 {
            let host = try await f.host()
            do {
                let main = try await f.open(host,"main"), side = try await f.open(host,"side")
                f.assertTotals(await main.costSnapshot,"seed pass \(pass)")
                f.assertTotals(await side.costSnapshot,"seed pass \(pass)")
            } catch { XCTFail("Seed changed after a mirror: \(error)") }
            await host.shutdown()
        }
        do {
            let writer = try SessionJournal(url:f.file("side"),id:"side",cwd:root,binding:nil,create:false)
            try writer.append(["type":"message","message":["role":"user","content":"Checkpoint fixture"]],id:"kept")
            try writer.append(f.row(JournalRecordKind.context,["ids":["kept"]]))
        }
        let replay = try replaySide(f)
        var checkpoint = try XCTUnwrap(replay.captured), helper = try JSON.parse(Data(checkpoint.helper.utf8))
        helper["accounting"] = helper["accounting"].removing(["unkeyedUSD"])
        checkpoint.helper = helper.encoded(); try checkpoint.write(for:f.file("side"))
        let restored = try replaySide(f,resume:true)
        let seed = SideBudgetRecovery.unkeyedCharge(spend:restored.spend,accounting:restored.accounting,side:"side",parents:["main"])
        XCTAssertEqual(seed?["usd"].double,0.2)
    }
    private func replaySide(_ f: SideBudgetUpgradeFixture, resume: Bool = false) throws -> JournalReplay {
        let journal = try SessionJournal(url:f.file("side"),id:"side",cwd:f.root,binding:nil,create:false,checkpoint:resume ? JournalCheckpoint.read(for:f.file("side")) : nil)
        return try AgentSession.replayConsumer(journal,url:f.file("side"),id:"side",binding:fixtureProfile().binding,spendTracked:false,resume:resume).finished()
    }

    func testUnpricedMirrorsMergeMissingUsageAndRejectConflictingTokens() throws {
        let unknown = try SideBudgetUpgradeFixture.legacyCost("pre-scope-unknown")
        let tokens = try SideBudgetUpgradeFixture.legacyCost("pre-scope-unpriced")
        var accounting = AttemptAccounting(), spend = SessionSpend()
        try accounting.consume(kind:JournalRecordKind.cost,data:unknown,spend:&spend)
        let update = try XCTUnwrap(FamilyCharge.merge(tokens,into:accounting.attempts["charged"],revision:accounting.revision))
        try accounting.consume(kind:update.kind,data:update.data,spend:&spend)
        XCTAssertEqual(accounting.usageTotals["output"],20)
        XCTAssertNil(try FamilyCharge.merge(unknown,into:accounting.attempts["charged"],revision:accounting.revision))
        var conflict = tokens; conflict["usage"]["output"] = 21
        XCTAssertThrowsError(try FamilyCharge.merge(conflict,into:accounting.attempts["charged"],revision:accounting.revision))
        // The existing late priced correction can refine an earlier unknown
        // observation. Compatibility between two unpriced mirrors must not
        // disable that separate authoritative correction path.
        conflict["reported"] = 1; conflict["unreported"] = 0; conflict["usd"] = 0.7
        let priced = try XCTUnwrap(FamilyCharge.merge(conflict,into:accounting.attempts["charged"],revision:accounting.revision))
        XCTAssertEqual(priced.data["usage"]["output"].int,21)
    }

    func testUnmodified127CountAttemptJournalsOpenBindReloadAndDelete() async throws {
        for usage in SideBudgetUpgradeFixture.Usage.allCases {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let f = SideBudgetUpgradeFixture(root:root,shape:.countAttempt127,family:.side,usage:usage,crash:.afterAll)
            let original = try SideBudgetUpgradeFixture.legacy("count-attempt-" + usage.rawValue)
            // Copy the real file bytes, preserving the old missing fields.
            let fixtures = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/SideBudget127")
            try FileManager.default.copyItem(at:fixtures.appendingPathComponent("count-attempt-" + usage.rawValue + ".jsonl"),to:f.file("side"))
            XCTAssertNil(original.last?["data"]["sourceSessionId"].text)
            do { _ = try SessionJournal(url:f.file("main"),id:"main",cwd:root,binding:fixtureProfile().binding,create:true) }
            for pass in 0..<2 {
                let host = try await f.host()
                do {
                    let main = try await f.open(host,"main"), side = try await f.open(host,"side")
                    let total = await main.costSnapshot, local = await side.costSnapshot
                    XCTAssertEqual(total["spentUSD"].double,usage == .priced ? 0.2 : 0)
                    XCTAssertEqual(total["reportedRequests"].int,usage == .priced ? 1 : 0)
                    XCTAssertEqual(total["unreportedRequests"].int,usage == .priced ? 0 : 1)
                    // countAttempt never serialized its observed tokens. Their
                    // absence stays unknown; migration must not invent them.
                    XCTAssertEqual(total["familyUsage"]["unknownRequests"].int,1)
                    XCTAssertEqual(local["spentUSD"],total["spentUSD"])
                    XCTAssertEqual(local["familyUsage"],total["familyUsage"])
                    if pass == 1 { _ = try await host.command("session.forget",sessionID:"main",params:[:]) }
                } catch { XCTFail("Actual 0.1.127 \(usage) journal failed: \(error)") }
                await host.shutdown()
            }
        }
    }

    func testColdNestedMembershipExistsBeforeDescendantRuntimeBinding() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        var f = SideBudgetUpgradeFixture(root:root,shape:.preCost,family:.nestedAgents,usage:.priced,crash:.afterAll)
        try f.write(); let host = try await f.host()
        do {
            _ = try await f.open(host,"main")
            let side = try await f.open(host,"side")
            f.assertTotals(await side.costSnapshot,"cold intermediate")
            let nested = await host.loadedSession("nested"); XCTAssertNil(nested)
        } catch { XCTFail("Persisted nested membership was lost: \(error)") }
        await host.shutdown()
    }

    func testUnpricedTerminalUsageSurvivesLoadedAndColdOwnerDeletion() async throws {
        for loaded in [false,true] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            var f = SideBudgetUpgradeFixture(root:root,shape:.current,family:.agents,usage:.unpriced,crash:.beforeSide)
            try f.write(); let host = try await f.host()
            do {
                if loaded { _ = try await f.open(host,"child"); _ = try await f.open(host,"main"); _ = try await f.open(host,"side") }
                _ = try await host.command("session.forget",sessionID:"main",params:[:])
                try FileManager.default.removeItem(at:f.file("main"))
                let side = try await f.open(host,"side"), child = try await f.open(host,"child")
                f.assertTotals(await side.costSnapshot,"orphan loaded=\(loaded)")
                f.assertTotals(await child.costSnapshot,"child loaded=\(loaded)",child:true)
            } catch { XCTFail("Unpriced terminal mirror failed: \(error)") }
            await host.shutdown()
        }
    }

    func testActualLegacyWritersAcrossFamiliesUsageCrashesLoadingAndOperations() async throws {
        var cases = 0
        for shape in SideBudgetUpgradeFixture.Shape.allCases {
            for family in SideBudgetUpgradeFixture.Family.allCases {
                for usage in SideBudgetUpgradeFixture.Usage.allCases {
                    for crash in SideBudgetUpgradeFixture.Crash.allCases {
                        for sideLoaded in [false,true] {
                            for childLoaded in family.agents ? [false,true] : [false] {
                                for operation in SideBudgetUpgradeFixture.Operation.allCases {
                                    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
                                    var f = SideBudgetUpgradeFixture(root:root,shape:shape,family:family,usage:usage,crash:crash)
                                    try f.write(); var host = try await f.host()
                                    let label = "\(shape)/\(family)/\(usage)/\(crash)/s=\(sideLoaded) c=\(childLoaded)/\(operation)"
                                    do {
                                        if childLoaded { _ = try await f.open(host,"child") }
                                        if sideLoaded {
                                            _ = try await f.open(host,"main")
                                            for id in family.sides { _ = try await f.open(host,id) }
                                        }
                                        if operation == .deleteCold { await host.shutdown(); host = try await f.host() }
                                        switch operation {
                                        case .openMain:
                                            let main = try await f.open(host,"main"); f.assertTotals(await main.costSnapshot,label)
                                        case .openSide,.reconcile:
                                            _ = try await f.open(host,"main")
                                            for id in family.sides { _ = try await f.open(host,id) }
                                            if operation == .reconcile {
                                                for _ in 0..<2 { _ = try await host.command("budget.reconcile",sessionID:family.owner,params:["evidence":.array([f.evidence])]) }
                                            }
                                        case .deleteCold,.deleteWithHelper:
                                            if operation == .deleteWithHelper { _ = try await f.open(host,"main") }
                                            _ = try await host.command("session.forget",sessionID:"main",params:[:])
                                            try FileManager.default.removeItem(at:f.file("main"))
                                        }
                                        for pass in 0..<2 {
                                            if !operation.deletes { let main = try await f.open(host,"main"); f.assertTotals(await main.costSnapshot,label) }
                                            for id in family.sides { let side = try await f.open(host,id); f.assertTotals(await side.costSnapshot,label) }
                                            if family.agents { let child = try await f.open(host,"child"); f.assertTotals(await child.costSnapshot,label,child:true) }
                                            await host.shutdown()
                                            if pass == 0 { host = try await f.host() }
                                        }
                                    } catch { XCTFail("\(label): \(error)") }
                                    await host.shutdown(); cases += 1
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(cases,3600)
    }
}
