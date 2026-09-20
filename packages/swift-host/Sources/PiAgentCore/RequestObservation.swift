import Foundation

/// A generation response's usage, never a count of the next replayed request.
/// Kept independently of capture retention and the preflight estimator.
public struct RequestObservation: Sendable, Equatable {
    public let sessionID: String, turnID: String, attemptID: String, purpose: String
    public let requestFingerprint: String, requestedModel: String
    public let configuredContextWindow: Int
    var responseID: String?, eventSequence: Int?, effectiveModel: String?
    var fields: JSON = [:], fieldStatus: JSON = [:], fieldPhase: JSON = [:]
    var phase = "awaiting", sourceEvent = "dispatch"
    var receivedAt: Double = nowMS()

    init(sessionID: String, turnID: String, attemptID: String, purpose: String, fingerprint: String, profile: Profile) {
        self.sessionID=sessionID; self.turnID=turnID; self.attemptID=attemptID; self.purpose=purpose
        requestFingerprint=fingerprint; requestedModel=profile.model; configuredContextWindow=profile.contextWindow
    }
    /// Supported Responses lifecycle objects are cumulative snapshots. Nil
    /// fields never become zero; a missing final field stays explicitly interim.
    mutating func consume(_ value: JSON, streaming: Bool, at: Double) -> Bool {
        let event=streaming ? value["type"].text ?? "" : "response.json"
        guard !streaming || ["response.created","response.in_progress","response.completed","response.incomplete","response.failed"].contains(event) else { return false }
        let response=streaming ? value["response"] : value
        if let sequence=value["sequence_number"].int {
            if let previous=eventSequence, sequence<=previous { return false }
            eventSequence=sequence
        }
        let terminal=["response.completed","response.incomplete","response.failed","response.json"].contains(event)
        if phase == "final" || phase == "interrupted" { return false }
        let before=self
        sourceEvent=event; receivedAt=at
        if let id=response["id"].text { responseID=String(id.prefix(512)) }
        if let model=response["router_model_name"].text ?? response["model"].text { effectiveModel=String(model.prefix(512)) }
        phase=terminal ? (event == "response.failed" || event == "response.incomplete" || response["status"].text == "incomplete" || response["status"].text == "failed" ? "interrupted" : "final") : "interim"
        let usage=UsageObservation.normalized(response["usage"],api:"openai-responses")
        for key in ["input","output","cacheRead","cacheWrite","reasoning","total"] {
            let status=usage["status"][key].text ?? "unreported"
            if status != "unreported" {
                fields[key]=usage[key]; fieldStatus[key]=JSON(status); fieldPhase[key]=JSON(phase)
            } else if fields[key].isNull {
                fieldStatus[key]="unreported"; fieldPhase[key]=JSON(phase)
            }
            // Deliberately retain the interim phase when a final object omits it.
        }
        return before.fields != fields || before.fieldStatus != fieldStatus || before.fieldPhase != fieldPhase || before.phase != phase || before.responseID != responseID || before.effectiveModel != effectiveModel
    }
    mutating func interrupt(at: Double) {
        guard phase != "final" else { return }
        phase="interrupted"; sourceEvent="transport.interrupted"; receivedAt=at
    }
    var json: JSON {
        ["sessionID":JSON(sessionID),"turnID":JSON(turnID),"attemptID":JSON(attemptID),"purpose":JSON(purpose),
         "requestFingerprint":JSON(requestFingerprint),"requestedModel":JSON(requestedModel),"contextWindow":JSON(configuredContextWindow),
         "responseID":responseID.map { JSON($0) } ?? .null,"eventSequence":eventSequence.map { JSON($0) } ?? .null,
         "effectiveModel":effectiveModel.map { JSON($0) } ?? .null,"usage":fields,"status":fieldStatus,"fieldPhase":fieldPhase,
         "phase":JSON(phase),"sourceEvent":JSON(sourceEvent),"receivedAt":JSON(receivedAt)]
    }
}

extension AgentSession {
    func beginObservationGeneration(profile boundProfile: Profile? = nil) -> UInt64 {
        observationGeneration &+= 1
        if !publishedObservation.isNull { lastRequestObservation=publishedObservation }
        requestObservation=nil
        observationEstimate=currentContextCount?.json ?? .null
        let bound=boundProfile ?? turnProfile
        publishedObservation=["sessionID":JSON(id),"turnID":JSON(currentTurnID),"purpose":JSON(titleTask ? "title":"turn"),
            "runtimeEpoch":JSON(displayEpoch),"generation":JSON(Int(observationGeneration)),"replayRevision":JSON(Int(contextMutation)),
            "phase":"preparing","requestedModel":JSON(bound.model),"contextWindow":JSON(bound.contextWindow),
            "estimate":observationEstimate,"attemptID":.null,"requestFingerprint":.null]
        observationRevision &+= 1
        event("request.usage")
        return observationGeneration
    }
    func observe(_ observation: RequestObservation, generation: UInt64) {
        guard !closed, generation == observationGeneration, observation.sessionID == id,
              observation.turnID == currentTurnID, observation.purpose == (titleTask ? "title" : "turn") else { return }
        if let current=requestObservation, current.attemptID != observation.attemptID { return }
        if let current=requestObservation {
            if let previous=current.eventSequence, let incoming=observation.eventSequence, incoming<previous { return }
            if ["final","interrupted"].contains(current.phase), !["final","interrupted"].contains(observation.phase) { return }
        }
        requestObservation=observation
        let boundary=observation.phase != "interim"
        if boundary || nowMS()-observationPublishedAt>=250 { publishObservation() }
    }
    func publishObservation() {
        guard let observation=requestObservation else { return }
        var value=observation.json
        value["generation"]=JSON(Int(observationGeneration)); value["contextRevision"]=JSON(displayEpoch)
        value["runtimeEpoch"]=JSON(displayEpoch); value["replayRevision"]=publishedObservation["replayRevision"]
        value["estimate"]=observationEstimate
        guard value != publishedObservation else { return }
        publishedObservation=value; observationRevision &+= 1; observationPublishedAt=nowMS()
        event("request.usage")
    }
    func clearRequestObservation() {
        if !publishedObservation.isNull { lastRequestObservation=publishedObservation }
        observationGeneration &+= 1; requestObservation=nil; publishedObservation = .null
        observationEstimate = .null; observationRevision &+= 1
    }
}
