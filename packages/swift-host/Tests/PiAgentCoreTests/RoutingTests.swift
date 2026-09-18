import XCTest
@testable import PiAgentCore

final class RoutingTests: XCTestCase {
    func testAliasEchoLateAndConflictingIdentityNeverGuessDeployment() throws {
        var raw=try fixtureProfile().raw
        raw["routing"]=["reference":"Fixture v1","modelHeader":"x-fixture-model","deploymentHeader":"x-fixture-deployment"]
        var identity=RoutingIdentity(profile:try Profile(raw))
        identity.head(["x-fixture-deployment":"opaque-id"])
        identity.body(["type":"response.created","response":["model":"fixture-model"]],streaming:true)
        XCTAssertEqual(identity.json["status"].text,"unreported"); XCTAssertTrue(identity.json["effectiveModel"].isNull)
        identity.body(["type":"response.completed","response":["model":"actual-a"]],streaming:true)
        XCTAssertEqual(identity.json["effectiveModel"].text,"actual-a")
        identity.head(["x-fixture-model":"actual-b"])
        XCTAssertEqual(identity.json["status"].text,"conflict"); XCTAssertTrue(identity.json["effectiveModel"].isNull)
        XCTAssertEqual(identity.json["reportedModels"],["actual-a","actual-b"])
        identity.body(["type":"response.output_text.delta","delta":"I am actual-c","model":"actual-c"],streaming:true)
        XCTAssertEqual(identity.json["reportedModels"],["actual-a","actual-b"])
    }
    func testHeaderContractsRejectSecretsAmbiguityAndMissingReference() throws {
        for name in ["authorization","x-api-key","set-cookie","x-secret-value","location"] {
            XCTAssertThrowsError(try RoutingContract(["reference":"fixture","modelHeader":JSON(name)]))
        }
        XCTAssertThrowsError(try RoutingContract(["modelHeader":"x-model"]))
        XCTAssertThrowsError(try RoutingContract(["reference":"fixture","modelHeader":"x-model","deploymentHeader":"X-Model"]))
        XCTAssertThrowsError(try RoutingContract(["replayPolicy":"pinned","expectedModel":"actual"]))
        _ = try RoutingContract(["reference":"fixture","deploymentHeader":"x-litellm-model-id"])
    }
    func testPortableResponsesHistoryKeepsToolPairsAndOriginalNativeItemsFromEitherAPI() throws {
        for api in ["openai-responses","anthropic-messages"] {
            var raw=try fixtureProfile().raw; raw["routing"]=["replayPolicy":"portable"]
            var assistant=toolReply(["read"]).message
            assistant.content.insert(textBlock("Visible answer"),at:0)
            let opaque:JSON=api == "openai-responses" ? ["type":"reasoning","encrypted_content":"opaque"] : ["type":"thinking","thinking":"summary","signature":"opaque"]
            assistant.providerItems!.insert(opaque,at:0)
            var result=ChatMessage(role:"toolResult",content:[textBlock("file")]);result.toolCallId="call-0"
            let body=try ProviderClient.requestBody(profile:Profile(raw),messages:[assistant,result],instructions:"",tools:[],sessionID:"s")
            XCTAssertEqual(body["model"].text,"fixture-model")
            XCTAssertFalse(body.encoded().contains("opaque")); XCTAssertTrue(body.encoded().contains("Visible answer"))
            let blocks=body["input"].list
            XCTAssertTrue(blocks.contains { $0["call_id"].text == "call-0" })
            XCTAssertTrue(blocks.contains { $0["type"].text == "function_call_output" })
            let restored=try ChatMessage(id:assistant.id,pi:assistant.pi)
            XCTAssertEqual(restored.providerItems?.first,opaque)
        }
    }
    func testOpaqueReplayRequiresRecordedCompatibleFixedRouteAndRetainsBinding() throws {
        var raw=try fixtureProfile().raw
        var message=ChatMessage(role:"assistant",content:[textBlock("answer")]);message.providerItems=[["type":"reasoning","encrypted_content":"opaque"]]
        XCTAssertThrowsError(try ProviderClient.replayItems(message,profile:Profile(raw)))
        raw["routing"]=["replayPolicy":"pinned","expectedModel":"actual-a","replayContract":"Gateway fixes compatible upstream"]
        let profile=try Profile(raw)
        message.providerIdentity=["status":"reported","effectiveModel":"actual-a"]
        message.providerBinding=try ProviderClient.replayBinding(profile)
        let restored=try ChatMessage(id:message.id,pi:message.pi)
        XCTAssertEqual(try ProviderClient.replayItems(restored,profile:profile),message.providerItems)
        var changed=raw; changed["revision"]="2"; changed["headers"]=["x-route":"another"]
        XCTAssertThrowsError(try ProviderClient.replayItems(restored,profile:Profile(changed)))
        for identity: JSON in [["status":"unreported"],["status":"conflict"],["status":"reported","effectiveModel":"actual-b"]] {
            message.providerIdentity=identity
            XCTAssertThrowsError(try ProviderClient.replayItems(message,profile:profile))
        }
    }
    func testUnboundedOrMalformedIdentityIsExplicitlyIncomplete() throws {
        var identity=RoutingIdentity(profile:try fixtureProfile())
        identity.body(["model":JSON(String(repeating:"x",count:257))],streaming:false)
        XCTAssertEqual(identity.json["status"].text,"incomplete"); XCTAssertTrue(identity.json["effectiveModel"].isNull)
        XCTAssertEqual(identity.json["omittedEvidence"].int,1)
    }
}
