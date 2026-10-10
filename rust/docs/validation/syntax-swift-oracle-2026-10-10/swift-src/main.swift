import Foundation
// Dumps SyntaxHighlighter.scan tokens for a corpus: [{"language": name, "code": text}].
// Output per case: [[startScalar, endScalar, kind], ...].
let input = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let corpus = try! JSONSerialization.jsonObject(with: input) as! [[String: String]]
var out: [[[Any]]] = []
for case_ in corpus {
    let language = SyntaxHighlighter.Language(rawValue: case_["language"]!)!
    let tokens = SyntaxHighlighter.scan(case_["code"]!, language: language).tokens
    out.append(tokens.map { token in
        let kind: String
        switch token.kind { case .keyword: kind = "keyword"; case .string: kind = "string"; case .number: kind = "number"; case .comment: kind = "comment"; case .title: kind = "title" }
        return [token.range.lowerBound, token.range.upperBound, kind]
    })
}
let data = try! JSONSerialization.data(withJSONObject: out, options: [])
FileManager.default.createFile(atPath: CommandLine.arguments[2], contents: data)
