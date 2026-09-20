import XCTest
@testable import PiAgentCore

/// The content digest identities and the character-safe paging every
/// on-demand read is cut with.
final class DigestAndPagingTests: XCTestCase {
    func testSHA256Vectors() {
        XCTAssertEqual(sha256(Data()),"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(sha256(Data("abc".utf8)),"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(sha256(Data(repeating:97,count:1000000)),"cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }
    func testJSONAndUTF16Pages() throws {
        let json:JSON=["boolean":true,"a":[1,"汉字🙂"],"null":.null]
        XCTAssertEqual(try JSON.parse(json.data()),json)
        let value=try textPage("a🙂b",offset:1)
        XCTAssertEqual(value["text"].text,"🙂b")
        XCTAssertThrowsError(try textPage("a🙂b",offset:2))
    }
}
