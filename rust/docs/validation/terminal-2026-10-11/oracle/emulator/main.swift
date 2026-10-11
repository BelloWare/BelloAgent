import Foundation

// Feeds each case of a corpus to the unchanged Swift 0.1.122 TerminalEmulator
// and prints what it holds afterwards, for the Rust port to match.
// Usage: oracle cases.json > expected.json

func colour(_ c: TerminalColor) -> String {
    switch c.kind {
    case .standard: return "s"
    case .indexed(let i): return "i\(i)"
    case .rgb(let r, let g, let b): return String(format: "r%02x%02x%02x", r, g, b)
    }
}
func style(_ s: CellStyle) -> String {
    var out = colour(s.foreground) + "/" + colour(s.background)
    if s.bold { out += "B" }
    if s.dim { out += "D" }
    if s.italic { out += "I" }
    if s.underline { out += "U" }
    if s.inverse { out += "R" }
    if s.strikethrough { out += "S" }
    if s.hidden { out += "H" }
    return out
}
/// A line's cells: text, width and style, runs of equal cells joined.
func cells(_ line: [TerminalCell]) -> [[Any]] {
    var runs: [[Any]] = []
    for cell in line {
        let key: [Any] = [cell.text, Int(cell.width), style(cell.style), cell.combiningTruncated]
        if let last = runs.last, (last[0] as! String) == cell.text, (last[1] as! Int) == Int(cell.width),
           (last[2] as! String) == style(cell.style), (last[3] as! Bool) == cell.combiningTruncated {
            runs[runs.count - 1][4] = (last[4] as! Int) + 1
        } else { runs.append(key + [1]) }
    }
    return runs
}
func dump(_ e: TerminalEmulator, replies: Data, bells: Int, titles: [String], dirs: [String]) -> [String: Any] {
    var lines: [[[Any]]] = []
    for index in 0..<e.lineCount { lines.append(cells(e.line(at: index))) }
    let shape: String
    switch e.cursorShape { case .block: shape = "block"; case .underline: shape = "underline"; case .bar: shape = "bar" }
    return [
        "columns": e.columns, "rows": e.rows,
        "screenText": e.screenText,
        "texts": (0..<e.lineCount).map { e.text(atLine: $0) },
        "lines": lines,
        "scrollback": e.scrollback.count, "trimmed": e.trimmedLines,
        "cursor": [e.cursor.x, e.cursor.y], "cursorVisible": e.cursorVisible, "cursorShape": shape,
        "title": e.title, "directory": e.currentDirectory ?? NSNull(),
        "modes": [
            "applicationCursorKeys": e.applicationCursorKeys, "applicationKeypad": e.applicationKeypad,
            "bracketedPaste": e.bracketedPaste, "focusReporting": e.focusReporting, "alternateScreen": e.alternateScreen,
            "mouseReporting": e.mouseReporting, "originMode": e.originMode, "autowrap": e.autowrap,
            "insertMode": e.insertMode, "newlineMode": e.newlineMode,
        ],
        "scrollRegion": [e.scrollTop, e.scrollBottom],
        "style": style(e.style),
        "replies": String(decoding: replies, as: UTF8.self),
        "bells": bells, "titles": titles, "directories": dirs,
    ]
}

let input = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let cases = try! JSONSerialization.jsonObject(with: input) as! [[String: Any]]
var results: [String: Any] = [:]
for item in cases {
    let name = item["name"] as! String
    let e = TerminalEmulator(columns: item["columns"] as? Int ?? 20, rows: item["rows"] as? Int ?? 6,
                             scrollbackLimit: item["scrollback"] as? Int ?? 10_000)
    if let cell = item["cellPixelSize"] as? [Double] { e.cellPixelSize = (cell[0], cell[1]) }
    var replies = Data(), bells = 0, titles: [String] = [], dirs: [String] = []
    e.onOutput = { replies.append($0) }
    e.onBell = { bells += 1 }
    e.onTitleChange = { titles.append($0) }
    e.onDirectoryChange = { dirs.append($0 ?? "<nil>") }
    var dirty: [Any] = []
    for step in item["steps"] as! [[String: Any]] {
        if let text = step["text"] as? String { e.feed(text) }
        if let hex = step["hex"] as? String {
            var bytes: [UInt8] = []; var index = hex.startIndex
            while index < hex.endIndex { let next = hex.index(index, offsetBy: 2); bytes.append(UInt8(hex[index..<next], radix: 16)!); index = next }
            // Byte by byte when asked, as a pty can split a sequence anywhere.
            if step["split"] as? Bool == true { for byte in bytes { e.feed(Data([byte])) } } else { e.feed(Data(bytes)) }
        }
        if let size = step["resize"] as? [Int] { e.resize(columns: size[0], rows: size[1]) }
        if step["clearDirty"] as? Bool == true { e.clearDirty() }
        if step["dirty"] as? Bool == true { dirty.append(e.dirtyRows.map { Array($0).sorted() } ?? "all") }
        if step["reset"] as? Bool == true { e.reset() }
    }
    var result = dump(e, replies: replies, bells: bells, titles: titles, dirs: dirs)
    result["dirty"] = dirty
    results[name] = result
}
let output = try! JSONSerialization.data(withJSONObject: results, options: [.sortedKeys, .prettyPrinted])
FileHandle.standardOutput.write(output)
FileHandle.standardOutput.write("\n".data(using: .utf8)!)
