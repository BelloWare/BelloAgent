import Foundation

/// Runs outside the main actor: byte assembly and decoding of a large reply
/// must not block scrolling. Only individual bounded requests cross to the
/// supervisor. The caller sees one complete, immutable result.
enum DisplayResultReader {
    static func read(_ result: WireValue, page: @Sendable (String, Int) async throws -> WireValue) async throws -> WireValue {
        guard let marker = result.object, marker["_displayTransfer"]?.number == 1 else { return result }
        guard marker.count == 3, let id = marker["id"]?.string, UUID(uuidString:id) != nil,
              let total = marker["bytes"]?.number.flatMap(Int.init(exactly:)), total > 0, total <= 128 * 1024 * 1024 else {
            throw HostError.failure("Invalid display transfer. Reload the conversation.")
        }
        var data = Data()
        repeat {
            try Task.checkCancellation()
            let value = try await page(id, data.count).object ?? [:]
            try Task.checkCancellation()
            guard value["offset"]?.number == Double(data.count), value["totalBytes"]?.number == Double(total),
                  let base64 = value["data"]?.string, let chunk = Data(base64Encoded:base64),
                  !chunk.isEmpty, chunk.count <= 192 * 1024, chunk.count <= total - data.count else {
                throw HostError.failure("The display transfer is incomplete. Reload the conversation.")
            }
            data.append(chunk)
            guard value["next"] == (data.count == total ? .null : .number(Double(data.count))) else {
                throw HostError.failure("The display transfer has an invalid boundary. Reload the conversation.")
            }
        } while data.count < total
        try Task.checkCancellation()
        return try JSONDecoder().decode(WireValue.self, from:data)
    }
}
