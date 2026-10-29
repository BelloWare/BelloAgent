import Foundation
import PiAgentCore

/// Shared by the opt-in XCTest and a standalone Release executable. Some
/// unrelated helper test classes require DEBUG-only probes, so the latter
/// links the actual Release PiAgentCore objects without building those tests.
enum JSONParserBenchmark {
    struct Measurement {
        let checksum: Int
    }

    static func run(path: String, environment env: [String: String]) throws -> [Measurement] {
        let reference = env["PI_JSON_BENCHMARK_PARSER"] == "reference"
        let iterations = max(1, env["PI_JSON_BENCHMARK_ITERATIONS"].flatMap(Int.init) ?? 3)
        let all = try Data(contentsOf: URL(fileURLWithPath: path)).split(separator: 0x0A).map { Data($0) }
        // Filtering uses the frozen parser and happens before either timer.
        let tool = try all.filter { try ReferenceJSONByteParser.parse($0)["message"]["role"].text == "toolResult" }
        if let path = env["TEST_RUNNER_PI_PERF_PID_FILE"] {
            let data = try JSONSerialization.data(withJSONObject: ["benchmark": ProcessInfo.processInfo.processIdentifier])
            try data.write(to: URL(fileURLWithPath: path))
        }
        emit("JSON_BENCHMARK_START")
        var measurements: [Measurement] = []
        for (name, lines) in [("all", all), ("tool", tool)] {
            guard !lines.isEmpty else { throw AgentError("benchmark_input", "Empty \(name) corpus") }
            let bytes = lines.reduce(0) { $0 + $1.count } * iterations
            var checksum = 0
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iterations {
                for line in lines {
                    let value = try reference ? ReferenceJSONByteParser.parse(line) : JSON.parse(line)
                    checksum &+= value.map.count
                }
            }
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            emit("JSON_BENCHMARK parser=\(reference ? "reference" : "optimized") corpus=\(name) lines=\(lines.count) iterations=\(iterations) bytes=\(bytes) seconds=\(seconds) MiBps=\(Double(bytes) / 1048576 / seconds) checksum=\(checksum)")
            measurements.append(Measurement(checksum: checksum))
        }
        return measurements
    }

    private static func emit(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }
}

#if JSON_PARSER_BENCHMARK_MAIN
@main private enum JSONParserBenchmarkMain {
    static func main() throws {
        guard !_isDebugAssertConfiguration() else { fatalError("Build the benchmark in Release") }
        let env = ProcessInfo.processInfo.environment
        guard let path = env["PI_JSON_BENCHMARK_JOURNAL"] else {
            throw AgentError("benchmark_input", "Set PI_JSON_BENCHMARK_JOURNAL to a generated journal")
        }
        _ = try JSONParserBenchmark.run(path: path, environment: env)
    }
}
#endif
