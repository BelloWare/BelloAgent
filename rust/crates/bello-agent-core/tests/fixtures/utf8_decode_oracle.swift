// Independent source oracle: the build script substitutes Tools.swift's exact
// String(data:encoding:) expression. It never imports or calls the Rust bridge.
import Foundation

struct Input: Decodable { let `case`: String; let input: String }
let bytes = FileHandle.standardInput.readDataToEndOfFile()
precondition(bytes.count <= 8192)
let inputs = try JSONDecoder().decode([Input].self, from: bytes)
precondition(inputs.count <= 32)
let rows: [[String: Any]] = inputs.map { row in
    let hex = Array(row.input.utf8)
    precondition(hex.count % 2 == 0 && hex.count <= 1024)
    let decoded = stride(from: 0, to: hex.count, by: 2).map { index in
        UInt8(String(bytes: hex[index..<index + 2], encoding: .utf8)!, radix: 16)!
    }
    let data = Data(decoded)
    let text = /* SOURCE_DECODE */
    let result: Any = text.map { value in
        value.utf8.map { String(format: "%02x", $0) }.joined()
    } as Any? ?? NSNull()
    return ["case": row.case, "input": row.input, "output": result]
}
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]))
