// Prints Swift's copy targets (`TranscriptCopy.targets`, TranscriptCopy.swift
// unchanged) for every document of a corpus: `targets <corpus.json>`.
import Foundation

let corpus = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String]
let output: [[String: Any]] = corpus.map { source in
    let targets: [[String]] = TranscriptCopy.targets(in: source).map { target in
        let kind: String
        switch target.kind {
        case .introduction: kind = "introduction"
        case .whole: kind = "whole"
        case .section(let level): kind = "section\(level)"
        case .code: kind = "code"
        }
        return [kind, target.label, target.text]
    }
    return ["source": source, "targets": targets]
}
let data = try! JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
