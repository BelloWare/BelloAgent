// oracle corpus.json > swift-tool-rows.json
import Foundation

struct Corpus: Codable {
    var tools: [ToolView]
    var summaries: [Summary]
    struct Summary: Codable { var reasoned: Bool; var rows: [TranscriptMessage] }
}
struct Row: Codable {
    var icon, title, summary: String
    var suffix: String?
    var state: String
    var trailing: String?
    var help: String
    var linksSummary: Bool
    var kind, verb, object: String
    var path: String?
    var outcome: String
    var filePath: String?
    var fileLines: [Int]?
}
struct Output: Codable { var rows: [Row]; var summaries: [String?] }

let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
let rows = corpus.tools.map { tool -> Row in
    let m = TranscriptToolRow.model(of: tool)
    return Row(icon: m.icon, title: m.title, summary: m.summary, suffix: m.suffix, state: m.state.rawValue, trailing: m.trailing,
               help: m.help, linksSummary: m.linksSummary, kind: m.description.kind.rawValue, verb: m.description.verb,
               object: m.description.object, path: m.description.path, outcome: m.outcome.rawValue,
               filePath: m.file?.path, fileLines: m.file?.lines.map { [$0.lowerBound, $0.upperBound] })
}
let summaries = corpus.summaries.map { ToolCallSummary(rows: $0.rows).label(reasoned: $0.reasoned) }
let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
FileHandle.standardOutput.write(try encoder.encode(Output(rows: rows, summaries: summaries)))
FileHandle.standardOutput.write("\n".data(using: .utf8)!)
