import XCTest
import Combine
@testable import PiApp

/// Search over a captured body and its headers, as the Inspector's Raw tab
/// runs it. Moved from the Turn Info popup's tests when the popup went.
final class PayloadSearchTests: XCTestCase {
    func testSearchFindsCaseInsensitiveUnicodeAndEndOfLargeBody() throws {
        let text = String(repeating: "ordinary payload ", count: 50_000) + "🌍 CACHED-token 🌍 cached-TOKEN"
        let result = try PayloadSearchResult.find(text: text, query: "cached-token")
        XCTAssertEqual(result.matches.count, 2)
        XCTAssertEqual((text as NSString).substring(with: result.matches[1]), "cached-TOKEN")
        XCTAssertTrue(try PayloadSearchResult.find(text: text, query: "missing-query").matches.isEmpty)
        let capped = try PayloadSearchResult.find(text: String(repeating: "a", count: 100), query: "a", limit: 3)
        XCTAssertEqual(capped.matches.count, 3); XCTAssertTrue(capped.limited)
    }
    @MainActor func testSearchIncludesHeadersNestedJSONAndCombinedStreamingResponse() async throws {
        let bytes = Data("event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"model\":\"gpt-5.4-mini\",\"output\":[{\"content\":[{\"text\":\"deeply nested answer\"}]}]}}\n\n".utf8)
        let descriptor = CapturedBodyMetadata(body: ["state": .string("complete"), "retainedBytes": .number(Double(bytes.count))], hash: nil)
        let document = try CapturedBodyDocument.parse(bytes: bytes, metadata: descriptor)
        let controller = PayloadSearchController()
        let headers: [String: WireValue] = ["x-litellm-model-name": .string("openai/gpt-5.4-mini"), "authorization": .string("Bearer ********-key")]
        await controller.search(document: document, format: .combined, headers: headers, kind: "response", query: "LITELLM")
        XCTAssertEqual(controller.result?.matches.count, 1)
        await controller.search(document: document, format: .combined, headers: headers, kind: "response", query: "deeply nested answer")
        XCTAssertEqual(controller.result?.matches.count, 1)
        XCTAssertTrue(controller.result?.text.contains("Response headers") == true)
        XCTAssertTrue(controller.result?.text.contains("Response body") == true)
        await controller.search(document: nil, format: .json, headers: headers, kind: "request", query: "authorization")
        XCTAssertEqual(controller.result?.matches.count, 1, "Headers remain searchable when the body expired")
    }
    /// Refining a search ("a", then "an") removed the results, which tore
    /// down the text view, and rendered the whole body text again although it
    /// does not depend on the query.
    @MainActor func testRefiningASearchKeepsItsResultsAndRendersTheBodyOnce() async throws {
        let bytes = Data((0..<200).map { "event: message\ndata: {\"text\":\"answer \($0)\"}\n\n" }.joined().utf8)
        let descriptor = CapturedBodyMetadata(body: ["state": .string("complete"), "retainedBytes": .number(Double(bytes.count))], hash: nil)
        let document = try CapturedBodyDocument.parse(bytes: bytes, metadata: descriptor, combine: false)
        let controller = PayloadSearchController()
        var blanks = 0
        let observer = controller.$result.dropFirst().sink { if $0 == nil { blanks += 1 } }
        defer { observer.cancel() }
        await controller.search(document: document, format: .json, headers: [:], kind: "response", query: "a")
        let first = try XCTUnwrap(controller.result)
        await controller.search(document: document, format: .json, headers: [:], kind: "response", query: "an")
        let refined = try XCTUnwrap(controller.result)
        XCTAssertEqual(blanks, 0, "The previous results stay on screen while the refined query runs")
        XCTAssertEqual(controller.renders, 1, "The body text is rendered once for both queries")
        XCTAssertEqual(refined.textID, first.textID, "The text view keeps its text and swaps only the highlights")
        XCTAssertGreaterThanOrEqual(refined.matches.count, 200)
        XCTAssertLessThan(refined.matches.count, first.matches.count, "The refined query found fewer matches")
    }
}
