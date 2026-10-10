import Foundation

// Engine microbenchmark around the unchanged shipped BelloBox 0.0.77 sources
// (DeveloperJSON.swift; TextTransforms.swift lines 281-332). Not an end-to-end UI test.
let args = CommandLine.arguments
guard args.count == 5 else { fatalError("usage: bench JSON TEXT OUTDIR ITERATIONS") }
let json = try String(contentsOfFile: args[1], encoding: .utf8)
let text = try String(contentsOfFile: args[2], encoding: .utf8)
let outDir = URL(fileURLWithPath: args[3])
let iterations = Int(args[4])!

func ns() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
var report: [String: Any] = [:]
func bench(_ name: String, _ body: () throws -> String) rethrows {
    var output = ""
    for _ in 0..<3 { output = try body() }  // warmup
    var samples: [Double] = []
    for _ in 0..<iterations {
        let t0 = ns(); output = try body(); samples.append(Double(ns() - t0) / 1e6)
    }
    try! output.data(using: .utf8)!.write(to: outDir.appendingPathComponent("swift-\(name).out"))
    let s = samples.sorted()
    func p(_ q: Double) -> Double { s[min(s.count - 1, max(0, Int(ceil(Double(s.count) * q)) - 1))] }
    report[name] = ["n": s.count, "min": s.first!, "p50": p(0.5), "p90": p(0.9), "max": s.last!, "outputBytes": output.utf8.count, "samplesMs": samples]
    print(String(format: "%-14@ p50 %8.2f ms  p90 %8.2f ms  min %8.2f ms  out %d B", name, p(0.5), p(0.9), s.first!, output.utf8.count))
}

try bench("json.pretty") { try DeveloperJSON.parse(json).formatted(pretty: true) }
try bench("json.minify") { try DeveloperJSON.parse(json).formatted(pretty: false) }
bench("text.dedupe") { LineTool.apply(text, .dedupe) }
bench("text.sort") { LineTool.apply(text, .sortAscending) }
bench("text.stats") {
    "\(TextStats.characters(text)) \(TextStats.charactersNoSpaces(text)) \(TextStats.words(text)) \(TextStats.lines(text))"
}
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
try data.write(to: outDir.appendingPathComponent("swift-results.json"))
