import Foundation
@testable import PiAgentCore

/// Journal-only state, independent of the live session projection.
struct RefreshJournalFixture {
    let root: URL, url: URL, profile: Profile, journal: SessionJournal
    static let settledState: JSON = ["active":false, "runStatus":"idle", "queue":[], "steering":[],
        "commands":[["commandId":"c", "turnId":"turn", "status":"completed"]]]

    init(root: URL, profile: Profile, cuts: Bool = false) throws {
        self.root = root; self.profile = profile; url = root.appendingPathComponent("refresh.jsonl")
        journal = try SessionJournal(url:url, id:"refresh", cwd:root, binding:profile.binding, create:true)
        if cuts { try journal.promoteToCodex(managedChild:false) }
        try journal.append(["type":"message", "message":ChatMessage(role:"user", content:[textBlock("Generated question")]).pi], id:"turn")
        try journal.append(["type":"message", "message":ChatMessage(role:"assistant", content:[textBlock("Durable answer")]).pi], id:"answer")
    }
    func state(_ state: JSON) throws { try journal.append(["type":"custom", "customType":JSON(JournalRecordKind.state), "data":state]) }
    func replay() throws -> JournalReplayConsumer {
        try AgentSession.replayConsumer(journal, url:url, id:"refresh", binding:profile.binding, spendTracked:false, resume:false)
    }
    func appendAttempt() throws {
        let scope = RequestScope(sourceSessionID:"refresh", budgetOwnerSessionID:"refresh", turnID:"turn", executionID:"execution", purpose:"turn", ownerGeneration:0, delegation:nil)
        try journal.append(["type":"custom", "customType":JSON(JournalRecordKind.budgetAttempt), "data":["attemptId":"attempt", "sourceSessionId":"refresh", "budgetOwnerSessionId":"refresh", "purpose":"turn", "state":"dispatched", "scope":subagentJSON(scope), "accountingRevision":1]])
    }
    func appendCut(projected: Int) throws {
        try journal.append(["type":"custom", "customType":JSON(JournalRecordKind.familyRun), "ownerID":"refresh", "data":subagentJSON(AgentFamilyRun(epoch:"execution"))])
        try appendAttempt()
        var assistant = ChatMessage(role:"assistant", content:[["type":"toolCall", "id":"call", "name":"bash", "arguments":["command":"never"]]])
        assistant.id = "prefix"; assistant.turn = "turn"; assistant.timestamp = 123
        assistant.requestAttemptIDs = ["attempt"]
        assistant.nativeMailboxCut = ["version":1, "cutId":"cut", "attemptId":"attempt", "responseId":"response", "itemId":"item"]
        var result = ChatMessage(role:"toolResult", content:[textBlock("Not executed: agent message arrived before dispatch.")])
        result.id = "cancelled"; result.turn = "turn"; result.timestamp = 123
        result.toolName = "bash"; result.toolCallId = "call"; result.isError = true
        result.nativeAgentCallCancellation = ["version":1, "cutId":"cut", "reason":"agent_message"]
        let rows = try [assistant, result].map { try ChatMessage(id:$0.id, pi:$0.pi) }
        var preparation: JSON = ["version":1, "cutId":"cut", "attemptId":"attempt", "turnId":"turn", "branchId":"turn", "generation":0,
            "recipientSessionId":"refresh", "eventIds":["mail"], "rows":.array(rows.map { ["id":JSON($0.id), "message":$0.pi] })]
        preparation["digest"] = JSON(MailboxCutJournal.digest(preparation))
        try journal.append(["type":"custom", "customType":JSON(JournalRecordKind.agentCutPrepared), "ownerID":"refresh", "data":preparation])
        if projected >= 0 {
            try journal.promoteToMailboxCut(managedChild:false)
            try journal.append(["type":"custom", "customType":JSON(JournalRecordKind.agentCutCommitted), "ownerID":"refresh", "data":preparation.removing(["turnId", "branchId", "generation", "eventIds", "rows"])])
            for row in rows.prefix(projected) { try journal.append(["type":"message", "message":row.pi], id:row.id) }
        }
        try journal.append(["type":"custom", "customType":JSON(JournalRecordKind.cost), "data":["attemptId":"attempt", "sourceSessionId":"refresh", "budgetOwnerSessionId":"refresh", "usd":0.02, "reported":1, "unreported":0, "accountingRevision":2]])
    }
}
