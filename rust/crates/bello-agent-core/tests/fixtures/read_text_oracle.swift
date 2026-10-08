// Text-only oracle: the acquisition and text branches are verbatim Tools.swift.
// Inputs are generated non-image bytes. Image processing is outside this suite.
import Foundation
import Darwin
/* SOURCE_VALUES */
/* SOURCE_CANCELLATION */
/* SOURCE_CONTEXT */
    func invoke(_ call: ToolCall, cancellation: BlockingWorkCancellation) throws -> JSON {
        try cancellation.checkCancellation()
        let p = call.arguments
/* SOURCE_ACQUIRE */
/* SOURCE_TEXT */
    }
}
do {
    let input = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    precondition(input.count <= 4096)
    let request = try JSON.parse(input)
    let root = URL(fileURLWithPath: request["root"].text!)
    let files = FileToolContext(cwd: root, roots: [root])
    var response: JSON
    do { response = ["result": try files.invoke(ToolCall(id:"fixture", name:"read", arguments:request["arguments"]), cancellation:BlockingWorkCancellation())] }
    catch let error as AgentError { response = ["error":error.json] }
    catch { let native=error as NSError; response=["nativeError":["domain":JSON(native.domain),"code":JSON(native.code)]] }
    FileHandle.standardOutput.write(try response.data())
} catch {
    FileHandle.standardError.write(Data("Text read oracle failed: \(error)\n".utf8))
    exit(1)
}
