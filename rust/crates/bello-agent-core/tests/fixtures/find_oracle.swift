// This is a test runner, not a second implementation of Find/Grep. The Rust test
// fills each SOURCE marker with verbatim declarations or branches from the
// checked-in Swift host before compiling this file in a temporary directory.
// No app, provider, user home, or network configuration is loaded.
import Foundation
import Darwin

/* SOURCE_VALUES */
/* SOURCE_SUPPORT */
/* SOURCE_CANCELLATION */

private enum PiProviderRules {
/* SOURCE_COERCION */
}

/* SOURCE_CONTEXT */
    func invoke(_ call: ToolCall, cancellation: BlockingWorkCancellation) throws -> JSON {
        try cancellation.checkCancellation()
        let p = call.arguments
        switch call.name {
/* SOURCE_FIND */
        default: throw AgentError("tool_unavailable", "Unsupported file tool")
        }
    }
}

private func searchDefinition(_ name: String) -> ToolDefinition {
    let s: JSON = ["type":"string"], n: JSON = ["type":"integer","minimum":1]
    switch name {
    case "find": return /* SOURCE_FIND_DEFINITION */
    case "grep": return /* SOURCE_GREP_DEFINITION */
    default: preconditionFailure("Unsupported oracle tool")
    }
}

private func validate(_ call: ToolCall, definition: ToolDefinition) throws {
/* SOURCE_VALIDATION */
}

private func run(_ request: JSON) -> JSON {
    let name = request["tool"].text!
    let definition = searchDefinition(name)
    let cwd = URL(fileURLWithPath: request["cwd"].text!)
    let roots = request["roots"].list.map { URL(fileURLWithPath: $0.text!) }
    let context = FileToolContext(cwd: cwd, roots: workspaceRoots(primary: cwd, additional: roots))
    let responses = request["cases"].list.map { item -> JSON in
        // SessionTools.piPrepared applies exactly this source coercer with
        // the offered definition before NativeTools performs key validation.
        let prepared = PiProviderRules.coerceArguments(item["arguments"], schema: definition.schema)
        let call = ToolCall(id: "file-search-oracle", name: name, arguments: prepared)
        let cancellation = BlockingWorkCancellation()
        if item["cancelled"].flag == true { cancellation.cancel() }
        var response: JSON = ["prepared": prepared]
        do {
            try cancellation.checkCancellation()
            try validate(call, definition: definition)
            response["outcome"] = ["result": try context.invoke(call, cancellation: cancellation)]
        } catch is CancellationError {
            response["outcome"] = ["cancelled": true]
        } catch let error as AgentError {
            response["outcome"] = ["error": error.json]
        } catch {
            // Unexpected Foundation failures stay visible; the fixture does
            // not invent portable translations of localized OS error text.
            let native = error as NSError
            response["outcome"] = ["nativeError": ["domain": JSON(native.domain), "code": JSON(native.code), "message": JSON(native.localizedDescription)]]
        }
        return response
    }
    return ["definition": ["name": JSON(definition.name), "description": JSON(definition.description), "schema": definition.schema], "cases": .array(responses)]
}

do {
    precondition(CommandLine.arguments.count == 2)
    let input = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    precondition(input.count <= 2 * 1024 * 1024, "Find oracle request exceeds fixture bound")
    let request = try JSON.parse(input)
    let result = run(request)
    FileHandle.standardOutput.write(try result.data())
} catch {
    FileHandle.standardError.write(Data("Find oracle failed: \(error)\n".utf8))
    exit(1)
}
