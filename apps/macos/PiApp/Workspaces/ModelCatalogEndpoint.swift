import Foundation
import CoreFoundation

/// One model in the bundled catalog or a connection's custom catalog endpoint.
/// The endpoint is owned by the operator and describes the models the LiteLLM
/// gateway should be used with, including the context the app should assume.
struct ModelDescriptor: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var description: String = ""
    var contextWindow: Int?
    /// The model's supported ceiling, not the budget requested for each response.
    var maxOutputTokens: Int?
    /// nil means unreported; an empty array means no explicit effort is accepted.
    var reasoning: [String]?
    var deprecated = false
    var order: Int?
    /// Optional operator recommendation for inexpensive utility work such as titles.
    /// nil is retained for compatibility with older encoded descriptor snapshots.
    var mini: Bool?
    var displayName: String { name.isEmpty ? id : name }
    var offeredThinkingLevels: [ThinkingLevel] {
        guard let reasoning else { return ThinkingLevel.allCases }
        return ThinkingLevel.allCases.filter { $0 == .profileDefault || $0 == .default || reasoning.contains($0.rawValue) }
    }

    /// Resolves catalog metadata against connection defaults for setup or a chat.
    /// Incomplete metadata must not leave output larger than the context budget.
    func applying(to profile: ProfileRecord) -> ProfileRecord {
        var selected = profile
        selected.modelId = id
        if let contextWindow { selected.contextWindow = contextWindow }
        selected.modelOutputLimit = maxOutputTokens
        selected.maxOutputTokens = min(selected.maxOutputTokens, maxOutputTokens ?? 1_000_000, selected.contextWindow - 1)
        if let reasoning {
            var fields = selected.configuration
            fields["reasoning"] = .bool(!reasoning.isEmpty)
            if reasoning.isEmpty || fields["thinkingLevel"]?.string.map({ $0 != "default" && !reasoning.contains($0) }) == true {
                fields.removeValue(forKey: "thinkingLevel")
            }
            if profile.modelId != id { fields.removeValue(forKey: "thinkingLevelMap") }
            selected.advancedJSON = WireValue.object(fields).pretty
        }
        return selected
    }
    var contextLabel: String? {
        guard let contextWindow else { return nil }
        if contextWindow >= 1_000_000 { return String(format: "%.1fM ctx", Double(contextWindow) / 1_000_000).replacingOccurrences(of: ".0M", with: "M") }
        if contextWindow >= 1_000 { return "\(contextWindow / 1000)k ctx" }
        return "\(contextWindow) ctx"
    }
    var outputLimitLabel: String? {
        maxOutputTokens.map { "up to \($0.formatted()) output" }
    }
}

/// Fetches and parses the operator-defined model catalog (see docs/Model-Catalog.md).
/// Transport hardening mirrors GatewayModelDiscovery: one explicit URL, no
/// redirects, no cookies or cached credentials, bounded body size and count.
struct ModelCatalogEndpoint: Sendable {
    struct Limits: Sendable {
        var timeout: TimeInterval = 8
        var bodyBytes = 2_097_152
        var modelCount = 2048
        var textBytes = 2048
    }
    enum Failure: Error, LocalizedError, Equatable {
        case url, credential, redirected, http(Int), oversized, malformed(String), timedOut, unavailable, bundledUnavailable
        var errorDescription: String? {
            switch self {
            case .url: return "Use an HTTPS catalog URL, or explicit loopback HTTP, without credentials or a fragment."
            case .credential: return "The catalog API key is invalid."
            case .redirected: return "The catalog endpoint redirected. Use its final URL; the API key was not forwarded."
            case .http(let status): return "The catalog endpoint answered HTTP \(status)."
            case .oversized: return "The catalog response exceeded the supported size."
            case .malformed(let reason): return "The catalog response was not in the expected format: \(reason)."
            case .timedOut: return "The catalog request timed out."
            case .unavailable: return "The catalog endpoint could not be reached."
            case .bundledUnavailable: return "The bundled Bello model catalog could not be loaded. Reinstall the app or configure a custom catalog URL."
            }
        }
    }

    var limits = Limits()

    /// The same reviewed file lives in source control and in the signed app.
    /// A missing/corrupt resource is an error, never a reason to query /models.
    static func bundled() throws -> [ModelDescriptor] {
        guard let url = Bundle.main.url(forResource: "bello-agent.models", withExtension: "json"),
              let body = try? Data(contentsOf: url) else { throw Failure.bundledUnavailable }
        return try Self().parse(body)
    }

    static func url(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= 8192, !trimmed.contains(where: \.isWhitespace),
              !trimmed.utf8.contains(where: { $0 < 32 || $0 == 127 }),
              let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              scheme == "https" || ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased()),
              components.user == nil, components.password == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              let url = components.url else { throw Failure.url }
        return url
    }

    /// A gateway credential belongs only to that origin, including its port.
    static func usesGatewayCredential(_ url: URL, base: String, api: String) -> Bool {
        guard let gateway = try? LiteLLMConfiguration.endpoint(base.trimmingCharacters(in: .whitespacesAndNewlines), api: api),
              url.scheme?.lowercased() == gateway.scheme?.lowercased(), url.host?.lowercased() == gateway.host?.lowercased() else { return false }
        return (url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)) ==
               (gateway.port ?? (gateway.scheme?.lowercased() == "https" ? 443 : 80))
    }

    /// Downloads one validated URL. Callers supply a key only for the gateway origin.
    func fetch(url: URL, key: String) async throws -> [ModelDescriptor] {
        let url = try Self.url(url.absoluteString)
        guard key.isEmpty || GatewayModelDiscovery.validKey(key) else { throw Failure.credential }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = limits.timeout
        configuration.timeoutIntervalForResource = limits.timeout
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, timeoutInterval: limits.timeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Local caching is disabled above; intermediaries must also revalidate
        // so an explicit Refresh can observe changed catalog bytes immediately.
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: RefuseCatalogRedirects())
            guard let http = response as? HTTPURLResponse else { throw Failure.malformed("not an HTTP response") }
            if (300..<400).contains(http.statusCode) { throw Failure.redirected }
            guard (200..<300).contains(http.statusCode) else { throw Failure.http(http.statusCode) }
            guard response.expectedContentLength <= Int64(limits.bodyBytes) else { throw Failure.oversized }
            var body = Data()
            for try await byte in bytes {
                guard body.count < limits.bodyBytes else { throw Failure.oversized }
                if body.count.isMultiple(of: 1024) { try Task.checkCancellation() }
                body.append(byte)
            }
            try Task.checkCancellation()
            return try parse(body)
        } catch let failure as Failure { throw failure }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw error.code == .timedOut ? Failure.timedOut : Failure.unavailable
        } catch { throw Failure.unavailable }
    }

    /// Accepts `{"version": 1, "models": [...]}` or a bare array. Entries keep
    /// their array position unless `order` says otherwise; ids are unique.
    func parse(_ body: Data) throws -> [ModelDescriptor] {
        guard body.count <= limits.bodyBytes else { throw Failure.oversized }
        let root = try? JSONSerialization.jsonObject(with: body)
        let records: [[String: Any]]
        if let object = root as? [String: Any] {
            if let version = object["version"], integer(version) != 1 { throw Failure.malformed("unsupported version (expected 1)") }
            guard let list = object["models"] as? [[String: Any]] else { throw Failure.malformed("missing models array") }
            records = list
        } else if let list = root as? [[String: Any]] { records = list }
        else { throw Failure.malformed("expected an object with a models array") }
        guard records.count <= limits.modelCount else { throw Failure.oversized }
        var seen = Set<String>(), models: [(Int, ModelDescriptor)] = []
        for (position, record) in records.enumerated() {
            guard let id = clean(record["id"]), id.utf8.count <= 200 else { throw Failure.malformed("model \(position + 1) has no id") }
            guard seen.insert(id).inserted else { throw Failure.malformed("duplicate model id") }
            var descriptor = ModelDescriptor(id: id, name: boundedText(clean(record["name"]) ?? ""))
            if let text = record["description"] as? String { descriptor.description = boundedText(text) }
            descriptor.contextWindow = try tokens(record["contextWindow"] ?? record["context_window"] ?? record["context"], range: 2...10_000_000)
            descriptor.maxOutputTokens = try tokens(record["maxOutputTokens"] ?? record["max_output_tokens"] ?? record["maxOutput"], range: 1...1_000_000)
            if let efforts = record["reasoning"] as? [String] {
                descriptor.reasoning = supportedEfforts(efforts)
            } else if let reasoning = record["reasoning"] as? [String: Any], let levels = reasoning["efforts"] as? [String] {
                descriptor.reasoning = supportedEfforts(levels)
            } else if record["reasoning"] != nil { throw Failure.malformed("reasoning must contain an efforts array") }
            if let deprecated = record["deprecated"] {
                guard let number = deprecated as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw Failure.malformed("deprecated must be a boolean") }
                descriptor.deprecated = number.boolValue
            }
            if let mini = record["mini"] {
                guard let number = mini as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw Failure.malformed("mini must be a boolean") }
                descriptor.mini = number.boolValue
            }
            if let order = record["order"] {
                guard let value = integer(order) else { throw Failure.malformed("order must be an integer") }
                descriptor.order = value
            }
            models.append((position, descriptor))
        }
        return models.sorted {
            switch ($0.1.order, $1.1.order) {
            case let (left?, right?) where left != right: return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.0 < $1.0
            }
        }.map(\.1)
    }

    private func clean(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              !text.utf8.contains(where: { $0 < 32 || $0 == 127 }) else { return nil }
        return text
    }
    private func integer(_ value: Any) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        if let integer = value as? Int { return integer }
        return Int(exactly: number.doubleValue)
    }
    private func tokens(_ value: Any?, range: ClosedRange<Int>) throws -> Int? {
        guard let value else { return nil }
        guard let number = integer(value), range.contains(number) else { throw Failure.malformed("token limits must be supported positive integers") }
        return number
    }
    private func supportedEfforts(_ levels: [String]) -> [String] {
        ThinkingLevel.allCases.filter { $0 != .profileDefault && $0 != .default && levels.contains($0.rawValue) }.map(\.rawValue)
    }
    private func boundedText(_ text: String) -> String {
        var bytes = Data(text.utf8.prefix(limits.textBytes))
        while let _ = bytes.last {
            if let result = String(data: bytes, encoding: .utf8) { return result }
            bytes.removeLast()
        }
        return ""
    }
}

private final class RefuseCatalogRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
