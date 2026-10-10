// Oracle: TranscriptMarkdown.parse for each string of a JSON array (argv[1]),
// as JSON blocks with every inline run's text and dress. argv[2]: "prose" or "user".
import AppKit
import Foundation

func spans(_ text: AttributedString, style: MarkdownStyle) -> [[String: Any]] {
    text.runs.map { run in
        let font = run[MarkdownFontAttribute.self]
        var span: [String: Any] = ["text": String(text.characters[run.range])]
        span["size"] = Double(font?.size ?? 0)
        if font?.semibold == true { span["bold"] = true }
        if font?.italic == true { span["italic"] = true }
        if font?.monospaced == true { span["mono"] = true }
        if font?.serif == true { span["serif"] = true }
        if run[MarkdownInlineCodeAttribute.self] == true { span["code"] = true }
        if run.appKit.strikethroughStyle != nil { span["strike"] = true }
        if let link = run.link { span["link"] = link.absoluteString }
        return span
    }
}

func encode(_ block: MarkdownBlock, style: MarkdownStyle) -> [String: Any] {
    switch block {
    case .paragraph(let text): return ["paragraph": spans(text, style: style)]
    case .heading(let level, let text, let plain): return ["heading": level, "spans": spans(text, style: style), "plain": plain]
    case .code(let language, let code): return ["code": code, "language": language ?? NSNull()]
    case .list(let ordered, let start, let items): return ["list": items.map { $0.map { encode($0, style: style) } }, "ordered": ordered, "start": start]
    case .quote(let blocks): return ["quote": blocks.map { encode($0, style: style) }]
    case .table(let alignments, let header, let rows):
        return ["table": rows.map { $0.map { spans($0, style: style) } }, "header": header.map { spans($0, style: style) },
                "alignments": alignments.map { $0 == .left ? "left" : $0 == .center ? "center" : "right" }]
    }
}

let corpus = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String]
let style: MarkdownStyle = CommandLine.arguments[2] == "user" ? .user : .prose
let out = corpus.map { source in TranscriptMarkdown.parse(source, style: style).map { encode($0, style: style) } }
FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .prettyPrinted]))
