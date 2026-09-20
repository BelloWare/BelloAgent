import Foundation

// One connection: its endpoint, model, declared limits and per-turn overrides.

public struct Profile: Sendable {
    public let raw: JSON
    public let id: String, api: String, model: String, provider: String
    public let endpoint: URL
    /// maxOutput is the output budget: the room the local context estimate
    /// reserves for a reply when it decides whether a request still fits and
    /// when a chat compacts. It is metadata; it is never sent as a cap.
    public let contextWindow: Int, maxOutput: Int
    /// The model's declared output ceiling from the catalog, when known. A
    /// conversation request carries this as its output limit.
    public let modelOutputLimit: Int?
    /// An explicit cap for one bounded task request (connection test, title,
    /// compaction summary), sent in place of the ceiling.
    public let outputCap: Int?
    /// The gateway's declared metadata headers and reasoning replay policy,
    /// validated here so no request path has to parse them again.
    let routing: RoutingContract
    public init(_ value: JSON) throws {
        guard value.isObject else { throw AgentError("invalid_profile", "Profile must be an object") }
        id = try required(value["id"], "profile id", maximum: 128)
        api = try required(value["api"], "API")
        guard api == "openai-responses" else { throw AgentError("unsupported_api", "Only the Responses API is supported for new requests. Existing Messages history is preserved; choose or create a Responses connection in Settings.") }
        model = try required(value["modelId"], "model", maximum: 256)
        provider = try required(value["providerId"], "provider", maximum: 128)
        contextWindow = try boundedInt(value["contextWindow"], maximum: 10_000_000)
        maxOutput = try boundedInt(value["maxOutputTokens"], maximum: 1_000_000)
        modelOutputLimit = value["modelOutputLimit"].isNull ? nil : try boundedInt(value["modelOutputLimit"], maximum: 1_000_000)
        outputCap = value["outputCap"].isNull ? nil : try boundedInt(value["outputCap"], maximum: 1_000_000)
        // The budget only has to leave room for input; the ceiling is the
        // model's own figure and may sit above or below the budget.
        guard maxOutput > 0, contextWindow > maxOutput, modelOutputLimit.map({ $0 > 0 }) ?? true, outputCap.map({ $0 > 0 }) ?? true else {
            throw AgentError("invalid_profile", "The positive output budget must fit below context capacity; a model output ceiling must be positive")
        }
        let url = try required(value["baseUrl"], "endpoint")
        guard !url.contains(where: \.isWhitespace) else { throw AgentError("invalid_endpoint", "Endpoint contains whitespace") }
        guard var c = URLComponents(string: url), let host = c.host, ["http", "https"].contains(c.scheme), c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.scheme == "https" || ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host),
              !c.percentEncodedPath.lowercased().contains("%2f"), !c.percentEncodedPath.lowercased().contains("%2e") else { throw AgentError("invalid_endpoint", "Use HTTPS, or loopback HTTP, without URL credentials, query or fragment") }
        var path = c.path; while path.hasSuffix("/") { path.removeLast() }
        let leaf = "/responses"
        let fullRoute = path.hasSuffix(leaf)
        if fullRoute { path.removeLast(leaf.count) }
        guard !path.hasSuffix("/responses"), !path.hasSuffix("/messages"), !path.hasSuffix("/completions"),
              !path.contains("/v1/v1"), !path.contains("//"), !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw AgentError("invalid_endpoint", "Mixed or repeated API routes")
        }
        if !fullRoute && !path.hasSuffix("/v1") { path += "/v1" }
        path += leaf
        c.path = path; guard let endpoint = c.url else { throw AgentError("invalid_endpoint", "Invalid URL") }; self.endpoint = endpoint
        for (key, v) in value["headers"].map {
            guard key.range(of: "^[A-Za-z0-9-]{1,128}$", options: .regularExpression) != nil, let v = v.text, !v.utf8.contains(13), !v.utf8.contains(10), v.utf8.count <= 16384 else { throw AgentError("invalid_profile", "Invalid header") }
        }
        if let level = value["thinkingLevel"].text, !Self.thinkingLevels.contains(level) { throw AgentError("invalid_profile", "Unsupported thinking level") }
        routing = try RoutingContract(value["routing"])
        raw = value
    }
    public static let thinkingLevels = ["default","off","minimal","low","medium","high","xhigh","max"]
    public var binding: JSON { ["api": JSON(api), "model": JSON(model), "provider": JSON(provider), "endpointSHA256": JSON(sha256(Data(endpoint.absoluteString.utf8)))] }
    public var publicValue: JSON { raw.removing(["headers","apiKey","key","token","authorization"]) }
    /// The output limit a request carries: an explicit task cap, else the
    /// model's declared ceiling; nothing when neither is known or the gateway
    /// compatibility setting omits the field. The output budget is never sent.
    public var wireOutputLimit: Int? {
        guard raw["compat"]["supportsMaxOutputTokens"].flag != false else { return nil }
        return outputCap ?? modelOutputLimit
    }
    /// The same profile with an explicit cap for one bounded request.
    public func capped(_ cap: Int) throws -> Profile {
        var value = raw; value["outputCap"] = JSON(max(1, cap)); return try Profile(value)
    }
    /// A per-turn override changes the model, thinking and declared capacity.
    /// A different alias leaves the configured pinned route, so opaque
    /// reasoning produced by that turn is recorded portably rather than replayed
    /// into another model later.
    public func overriding(model: String?, thinkingLevel: String?, contextWindow: Int? = nil, maxOutputTokens: Int? = nil, modelOutputLimit: Int? = nil) throws -> Profile {
        guard model != nil || thinkingLevel != nil || contextWindow != nil || maxOutputTokens != nil || modelOutputLimit != nil else { return self }
        var value = raw
        let capacity=contextWindow ?? self.contextWindow, output=maxOutputTokens ?? maxOutput
        let ceiling = modelOutputLimit ?? (model == nil || model == self.model ? self.modelOutputLimit : nil)
        guard capacity > 0, capacity <= 10_000_000, output > 0, output <= 1_000_000, capacity > output,
              ceiling.map({ $0 > 0 && $0 <= 1_000_000 }) ?? true else {
            throw AgentError("invalid_params", "The turn output budget must be positive and below the context capacity; a model output ceiling must be positive")
        }
        if let contextWindow { value["contextWindow"]=JSON(contextWindow) }
        if let maxOutputTokens { value["maxOutputTokens"]=JSON(maxOutputTokens) }
        if let ceiling { value["modelOutputLimit"] = JSON(ceiling) }
        else { value = value.removing(["modelOutputLimit"]) }
        if let model {
            guard !model.isEmpty, model.utf8.count <= 200, !model.utf8.contains(where: { $0 < 32 || $0 == 127 }) else { throw AgentError("invalid_params", "Invalid model override") }
            value["modelId"] = JSON(model)
            if model != self.model { value=value.removing(["thinkingLevelMap"]) }
            if model != self.model, !value["routing"].isNull { var routing = value["routing"]; routing["replayPolicy"] = "portable"; value["routing"] = routing.removing(["expectedModel","replayContract"]) }
        }
        if let thinkingLevel {
            guard Self.thinkingLevels.contains(thinkingLevel) else { throw AgentError("invalid_params", "Unsupported thinking level override") }
            value["thinkingLevel"] = JSON(thinkingLevel)
            // Explicit choices must not be silently ignored by a profile that
            // omitted reasoning support. Model default omits inherited options.
            value["reasoning"] = JSON(thinkingLevel != "default")
        }
        return try Profile(value)
    }
}
