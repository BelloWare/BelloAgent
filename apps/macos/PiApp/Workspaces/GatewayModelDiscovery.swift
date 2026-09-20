import Foundation

/// Optional first-run discovery. Credentials are sent to one explicitly chosen
/// gateway; redirects, shared cookies and URL credential storage are disabled.
struct GatewayModelDiscovery: Sendable {
    struct Limits: Sendable {
        /// Idle timeout on each read of the response.
        var timeout: TimeInterval = 8
        /// Deadline for the whole transfer, which the body's own size and the
        /// link's speed both count against.
        var transferTimeout: TimeInterval = 120
        var bodyBytes = 1_048_576
        var modelCount = 4096
    }
    enum Failure: Error, LocalizedError, Equatable {
        case credential, redirected, http(Int), oversized, malformed, timedOut, unavailable
        var errorDescription: String? {
            switch self {
            case .credential: return "Enter the gateway API key to list models."
            case .redirected: return "The gateway redirected model discovery. Use its final URL; the API key was not forwarded."
            case .http(let status): return "The gateway answered HTTP \(status) for model discovery."
            case .oversized: return "The gateway's model list exceeded the supported size."
            case .malformed: return "The gateway's model list was not in the expected format."
            case .timedOut: return "Model discovery timed out."
            case .unavailable: return "The gateway could not be reached for model discovery."
            }
        }
    }

    var limits = Limits()

    /// Reuse the connection validator so a full API route, /v1, and a custom
    /// prefix resolve consistently. A prefix such as /v10 is never truncated.
    static func modelsURL(base: String, api: String) throws -> URL {
        try LiteLLMConfiguration.requireSupportedAPI(api)
        let endpoint = try LiteLLMConfiguration.endpoint(base.trimmingCharacters(in: .whitespacesAndNewlines), api: api)
        return endpoint.deletingLastPathComponent().appendingPathComponent("models")
    }

    static func validKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 16_384 && !key.utf8.contains(where: { $0 < 32 || $0 == 127 })
    }

    func models(base: String, api: String, key: String) async throws -> [String] {
        let url = try Self.modelsURL(base: base, api: api)
        guard Self.validKey(key) else { throw Failure.credential }
        let configuration = URLSessionConfiguration.ephemeral
        // The 8 s budget is an idle timeout on each read, not a deadline on the
        // whole transfer: consuming the body counts against the resource
        // timeout, so a large but perfectly healthy catalog, or an ordinary one
        // on a slow link, reported itself as timed out.
        configuration.timeoutIntervalForRequest = limits.timeout
        configuration.timeoutIntervalForResource = limits.transferTimeout
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
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: RefuseModelDiscoveryRedirects())
            guard let http = response as? HTTPURLResponse else { throw Failure.malformed }
            if (300..<400).contains(http.statusCode) { throw Failure.redirected }
            guard (200..<300).contains(http.statusCode) else { throw Failure.http(http.statusCode) }
            guard response.expectedContentLength <= Int64(limits.bodyBytes) else { throw Failure.oversized }
            var buffer = [UInt8](); buffer.reserveCapacity(min(limits.bodyBytes, 262_144))
            for try await byte in bytes {
                guard buffer.count < limits.bodyBytes else { throw Failure.oversized }
                if buffer.count.isMultiple(of: 4096) { try Task.checkCancellation() }
                buffer.append(byte)
            }
            let body = Data(buffer)
            try Task.checkCancellation()
            return try parse(body)
        } catch let failure as Failure { throw failure }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw error.code == .timedOut ? Failure.timedOut : Failure.unavailable
        } catch { throw Failure.unavailable }
    }

    func parse(_ body: Data) throws -> [String] {
        guard body.count <= limits.bodyBytes else { throw Failure.oversized }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let records = object["data"] as? [[String: Any]], records.count <= limits.modelCount else {
            throw Failure.malformed
        }
        var models = Set<String>()
        for record in records {
            guard let id = record["id"] as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  id.utf8.count <= 256, !id.utf8.contains(where: { $0 < 32 || $0 == 127 }) else { throw Failure.malformed }
            models.insert(id)
        }
        return models.sorted()
    }
}

private final class RefuseModelDiscoveryRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
