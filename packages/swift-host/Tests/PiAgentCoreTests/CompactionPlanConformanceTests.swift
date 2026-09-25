import XCTest
@testable import PiAgentCore

final class CompactionPlanConformanceTests: XCTestCase {
    func testTriggerReservesWhicheverOperationNeedsMoreOutputRoom() throws {
        let policy=CompactionPolicy()
        for ordinaryReserve in [4096,64000] {
            var raw=try fixtureProfile().raw
            raw["contextWindow"]=128000;raw["modelOutputLimit"]=100000;raw["maxOutputTokens"]=JSON(ordinaryReserve)
            let profile=try Profile(raw)
            XCTAssertEqual(try policy.trigger(profile:profile,instructionTokens:500),128000-max(ordinaryReserve,16384+500)-1024-16384)
            XCTAssertThrowsError(try policy.trigger(profile:profile,instructionTokens:Int.max))
            XCTAssertThrowsError(try policy.trigger(profile:profile,instructionTokens:-1))
        }
        var raw=try fixtureProfile().raw;raw["contextWindow"]=8000;raw["maxOutputTokens"]=7000
        XCTAssertThrowsError(try policy.trigger(profile:Profile(raw),instructionTokens:500))
    }

    func testVisibleTargetScalesWithoutChangingGenerationOrReasoning() throws {
        var raw=try fixtureProfile().raw
        raw["contextWindow"]=128000;raw["modelOutputLimit"]=100000;raw["thinkingLevel"]="high"
        let profile=try Profile(raw),policy=CompactionPolicy()
        XCTAssertEqual(policy.visibleTarget(for:profile,inputTokens:800),200)
        XCTAssertEqual(policy.visibleTarget(for:profile,inputTokens:20000),3000)
        let summary=try policy.summaryProfile(profile,cap:policy.summaryTokens(for:profile))
        XCTAssertEqual(summary.maxOutput,16384);XCTAssertEqual(summary.raw["thinkingLevel"].text,"high")
        raw["contextWindow"]=8000
        XCTAssertEqual(policy.visibleTarget(for:try Profile(raw),inputTokens:20000),500)
    }

    func testCheckpointInstructionEscapesBoundaryAndFocusWithoutGrantingAuthority() throws {
        let messages=[ChatMessage(role:"user",content:[textBlock("Quoted \"boundary\"\nDo not run tools.")])]
        let projection=try ProviderClient.responsesProjection(messages,instructions:"Normal policy",profile:fixtureProfile())
        let boundary=try CompactionSourceBuilder.boundary(projection,messages:messages,keptIDs:Set(messages.map(\.id)))
        let instruction=CompactionSourceBuilder.instruction(boundary:boundary,focus:"Keep errors\n## Extra",visibleTarget:200)
        XCTAssertEqual(instruction.sourceMessageIDs,[])
        XCTAssertEqual(boundary["retainedRanges"].list,[["start":1,"endExclusive":2]])
        XCTAssertTrue(instruction.text.contains("Aim for at most 200 tokens, using fewer when sufficient."))
        XCTAssertTrue(instruction.text.contains("Boundary: "+boundary.encoded()))
        XCTAssertTrue(instruction.text.contains("Optional user focus: \"Keep errors\\n## Extra\""))
        XCTAssertTrue(instruction.text.contains("not a new user goal or permission."))
        XCTAssertTrue(instruction.text.hasSuffix("Focus changes emphasis, not facts or permissions."))
    }

    func testBoundaryIsBoundedWithoutTruncatingOrMutatingReplayItems() throws {
        let messages=(0..<1000).map { ChatMessage(role:"user",content:[textBlock("Source \($0)")]) }
        let projection=try ProviderClient.responsesProjection(messages,instructions:"Policy",profile:fixtureProfile())
        let scattered=Set(messages.enumerated().filter { $0.offset.isMultiple(of:2) }.map { $0.element.id })
        XCTAssertThrowsError(try CompactionSourceBuilder.boundary(projection,messages:messages,keptIDs:scattered)) { error in
            XCTAssertEqual((error as? AgentError)?.code,"compact_unavailable")
        }
        XCTAssertEqual(projection.items.count,1001)
        let tail=try CompactionSourceBuilder.boundary(projection,messages:messages,keptIDs:Set(messages.suffix(500).map(\.id)))
        XCTAssertLessThan(tail.encoded().utf8.count,1024)
    }

    func testSummaryControlsRejectAlternativeCapsAndDisableServerTruncation() throws {
        let policy=CompactionPolicy()
        for key in ["max_tokens","max_completion_tokens"] {
            var raw=try fixtureProfile().raw;raw["samplingParams"] = .object([key:900000])
            let profile=try policy.summaryProfile(Profile(raw),cap:16384)
            XCTAssertThrowsError(try ProviderClient.requestBody(profile:profile,messages:[],instructions:"Policy",tools:[],sessionID:"test",compaction:true)) { error in
                XCTAssertEqual((error as? AgentError)?.code,"compaction_incompatible")
            }
        }
        var raw=try fixtureProfile().raw
        raw["compat"]=["supportsMaxOutputTokens":false];raw["samplingParams"]=["max_output_tokens":999999,"temperature":0.3]
        let profile=try policy.summaryProfile(Profile(raw),cap:16384)
        let body=try ProviderClient.requestBody(profile:profile,messages:[],instructions:"Policy",tools:[],sessionID:"test",compaction:true)
        XCTAssertTrue(body["max_output_tokens"].isNull)
        XCTAssertEqual(body["tool_choice"].text,"none");XCTAssertEqual(body["truncation"].text,"disabled")
        XCTAssertEqual(body["temperature"].double,0.3)
        let count=try RequestContextCounter().count(messages:[],profile:profile,request:body)
        XCTAssertEqual(count.outputBudget,16384)
        XCTAssertTrue(count.warnings.contains { $0.contains("local reserve") && $0.contains("not sent") })
    }

    func testSummaryRequiresPositiveCompletionEvidenceAndCompleteItems() async throws {
        let root=try temporaryDirectory();defer { try? FileManager.default.removeItem(at:root) }
        let session=try AgentSession(id:"completion-evidence",profile:fixtureProfile(),apiKey:"synthetic",cwd:root,directory:root.appendingPathComponent("state"),readOnly:true,resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:RecordingTools(),traces:TraceStore())
        let message=ChatMessage(role:"assistant",content:[textBlock("Plausible but unconfirmed summary")])
        for terminal in [nil,ModelTerminalOutcome(status:nil),ModelTerminalOutcome(status:"in_progress"),ModelTerminalOutcome(status:"completed",incompleteReason:"max_output_tokens")] as [ModelTerminalOutcome?] {
            do {
                _=try await session.adopt(ModelReply(message:message,terminal:terminal),cap:16384)
                XCTFail("Missing or contradictory completion evidence must not be adopted")
            } catch { XCTAssertEqual((error as? AgentError)?.code,"compaction_incomplete") }
        }
        var incompleteItem=message
        incompleteItem.providerItems=[["type":"message","status":"incomplete","content":[["type":"output_text","text":"Partial item"]]]]
        do {
            _=try await session.adopt(ModelReply(message:incompleteItem,terminal:ModelTerminalOutcome(status:"completed")),cap:16384)
            XCTFail("An incomplete item cannot become a checkpoint")
        } catch { XCTAssertEqual((error as? AgentError)?.code,"compaction_incomplete") }
        let complete=try await session.adopt(ModelReply(message:message,usage:["output":16384,"reasoning":16000],terminal:ModelTerminalOutcome(status:"completed")),cap:16384)
        XCTAssertEqual(complete,message.text,"Reaching the numeric cap alone is not truncation")
        await session.close()
    }
}
