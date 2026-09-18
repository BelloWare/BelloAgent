import Foundation

/// Header names come from an explicit deployment contract, never from guessed
/// LiteLLM headers. In particular, a deployment ID is not a model name.
struct RoutingContract: Sendable {
    let raw: JSON
    let policy: String
    init(_ value: JSON) throws {
        raw = value.isNull ? [:] : value
        let allowed: Set<String> = ["reference", "modelHeader", "deploymentHeader", "groupHeader", "cacheHeader", "replayPolicy", "expectedModel", "replayContract"]
        guard raw.isObject, Set(raw.map.keys).isSubset(of: allowed), raw.map.values.allSatisfy({ valid($0.text, maximum: 512) }) else {
            throw AgentError("routing_contract", "Routing settings require bounded text fields from your gateway contract")
        }
        policy = raw["replayPolicy"].text ?? "ask"
        guard ["ask", "portable", "pinned"].contains(policy) else { throw AgentError("routing_contract", "Choose a reasoning replay policy") }
        for field in ["modelHeader", "deploymentHeader", "groupHeader", "cacheHeader"] where !raw[field].isNull {
            let name = raw[field].text!.lowercased()
            guard name.range(of: "^[a-z0-9-]{1,128}$", options: .regularExpression) != nil,
                  !["authorization", "cookie", "token", "secret", "key"].contains(where: { name.contains($0) }),
                  !["host", "location", "set-cookie", "content-type", "content-length", "connection"].contains(name),
                  valid(raw["reference"].text, maximum: 512) else { throw AgentError("routing_contract", "Metadata headers need a deployment reference and cannot expose authentication or transport fields") }
        }
        let headers = ["modelHeader", "deploymentHeader", "groupHeader", "cacheHeader"].compactMap { raw[$0].text?.lowercased() }
        guard Set(headers).count == headers.count else { throw AgentError("routing_contract", "A metadata header cannot represent several different identities") }
        if policy == "pinned" {
            guard valid(raw["expectedModel"].text, maximum: 256), valid(raw["replayContract"].text, maximum: 512) else {
                throw AgentError("routing_contract", "Native state replay requires an expected model and an explicit gateway contract guaranteeing a compatible fixed route")
            }
        }
    }
    var headers: Set<String> { Set(["x-litellm-model-name", "x-litellm-model-group"] + ["modelHeader", "deploymentHeader", "groupHeader", "cacheHeader"].compactMap { raw[$0].text?.lowercased() }) }
    var fingerprint: String { sha256(Data(raw.encoded().utf8)) }
}

private func valid(_ text: String?, maximum: Int = 256) -> Bool {
    guard let text, !text.isEmpty, text.utf8.count <= maximum else { return false }
    return !text.utf8.contains(where: { $0 < 32 || $0 == 127 })
}

/// The owner supplied both `openai/gpt-5.4-mini` and `gpt-5.4-mini` for the
/// same response. This rule is limited to that declared OpenAI namespace.
private func comparableModel(_ value:String) -> String { value.hasPrefix("openai/") ? String(value.dropFirst(7)) : value }

struct RoutingIdentity: Sendable {
    let alias: String, api: String, contract: RoutingContract
    private var evidence: [JSON] = []
    private var omitted = 0
    init(profile: Profile) {
        alias=profile.model; api=profile.api; contract=try! RoutingContract(profile.raw["routing"])
    }
    private mutating func add(_ value: JSON, source: String, kind: String = "model", excluding credential: (String) -> Bool) {
        guard !value.isNull else { return }
        guard valid(value.text), !(kind == "model" && value.text == "openai/"), !credential(value.text!) else { omitted += 1; return }
        let item:JSON=["value":value,"source":JSON(source),"kind":JSON(kind)]
        guard !evidence.contains(item) else { return }
        guard evidence.count < 32 else { omitted += 1; return }
        evidence.append(item)
    }
    mutating func head(_ headers: [String: String], excluding credential: (String) -> Bool = { _ in false }) {
        // Owner-supplied LiteLLM 1.99.0 response contract. Keep the literal
        // values in evidence, and never promote model-group/deployment IDs.
        let configured = Set(["modelHeader", "deploymentHeader", "groupHeader"].compactMap { contract.raw[$0].text?.lowercased() })
        for (name,kind) in [("x-litellm-model-name","model"),("x-litellm-model-group","group")] where !configured.contains(name) {
            if let value=headers[name] { add(JSON(value),source:"header:"+name,kind:kind,excluding:credential) }
        }
        for (field, kind) in [("modelHeader","model"),("deploymentHeader","deployment"),("groupHeader","group")] {
            if let name=contract.raw[field].text?.lowercased(), let value=headers[name] { add(JSON(value),source:"header:"+name,kind:kind,excluding:credential) }
        }
    }
    mutating func body(_ value: JSON, streaming: Bool, excluding credential: (String) -> Bool = { _ in false }) {
        if !streaming {
            add(value["model"],source:"body.model",excluding:credential)
            if api == "openai-responses" { add(value["router_model_name"],source:"body.router_model_name",excluding:credential) }
            return
        }
        let type=value["type"].text ?? ""
        if api == "openai-responses", ["response.created","response.in_progress","response.completed","response.incomplete","response.failed"].contains(type) {
            add(value["response"]["model"],source:type+".response.model",excluding:credential)
            // LiteLLM may echo the requested alias in model while reporting
            // its selected model separately. Keep both as sourced evidence;
            // distinct non-alias names still produce an explicit conflict.
            add(value["response"]["router_model_name"],source:type+".response.router_model_name",excluding:credential)
        } else if api == "anthropic-messages" {
            if type == "message_start" { add(value["message"]["model"],source:"message_start.message.model",excluding:credential) }
            if type == "message_delta" { add(value["delta"]["model"],source:"message_delta.delta.model",excluding:credential) }
        }
    }
    var json: JSON {
        // Only this explicitly observed namespace is equivalent to its bare
        // model name. Do not strip arbitrary providers or decode opaque IDs.
        let models=Set(evidence.filter { $0["kind"].text == "model" }.compactMap { $0["value"].text }.map(comparableModel).filter { !$0.isEmpty && $0 != comparableModel(alias) }).sorted()
        let state=omitted > 0 ? "incomplete" : models.count > 1 ? "conflict" : models.isEmpty ? "unreported" : "reported"
        return ["requestedAlias":JSON(alias),"status":JSON(state),"effectiveModel":state == "reported" ? JSON(models[0]):.null,
                "reportedModels":.array(models.map { JSON($0) }),"evidence":.array(evidence),"omittedEvidence":JSON(omitted),
                "contractReference":contract.raw["reference"],"replayPolicy":JSON(contract.policy),
                "boundary":"Gateway-reported identity. Alias echoes, deployment IDs and route groups are not an upstream model name; hidden upstream traffic is unavailable."]
    }
}

extension ProviderClient {
    static func replayBinding(_ profile: Profile) throws -> JSON {
        ["profile":profile.binding,"profileId":JSON(profile.id),"configurationRevision":profile.raw["revision"],
         "contractSHA256":JSON(try RoutingContract(profile.raw["routing"]).fingerprint)]
    }
    static func replayItems(_ message: ChatMessage, profile: Profile) throws -> [JSON]? {
        guard let items=message.providerItems else { return nil }
        let contract=try RoutingContract(profile.raw["routing"])
        if contract.policy == "portable" { return nil }
        let portableTypes: Set<String> = profile.api == "openai-responses" ? ["message","function_call"] : ["text","tool_use"]
        let opaque=items.contains { !portableTypes.contains($0["type"].text ?? "") }
        guard opaque else { return items }
        guard contract.policy == "pinned" else { throw AgentError("opaque_replay_policy", "History contains provider-specific reasoning. Choose portable history or configure a compatible fixed gateway route in Settings before continuing. Original history is retained.") }
        let identity=message.providerIdentity ?? .null
        let binding=try replayBinding(profile)
        // A message produced under another alias (a per-turn model override, or
        // the base model seen from an override turn) is outside this pinned
        // route. Replay it portably; its opaque state is retained, not sent.
        if let recorded=message.providerBinding?["profile"]["model"].text, recorded != profile.model { return nil }
        guard valid(profile.raw["revision"].text, maximum:128), message.providerBinding == binding, identity["status"].text == "reported", identity["effectiveModel"].text.map(comparableModel) == contract.raw["expectedModel"].text.map(comparableModel) else {
            throw AgentError("opaque_route_changed", "The recorded route is unknown, conflicting or incompatible with the configured fixed model. Native reasoning was not replayed. Choose portable history or a verified compatible route.")
        }
        return items
    }
}
