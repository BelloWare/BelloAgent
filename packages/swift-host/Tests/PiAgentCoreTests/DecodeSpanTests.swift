import XCTest
@testable import PiAgentCore

/// Output speed uses all reported tokens over dispatch → last output. The
/// raw decode span still covers hidden reasoning and excludes a held terminal;
/// TTFT is added before applying the minimum duration and dividing.
final class DecodeSpanTests: XCTestCase {
    /// "reasoner": hidden reasoning for 0.8 s (the reasoning item opens at
    /// once), then a visible reply, and the terminal event 0.06 s later: 860
    /// output tokens, 800 of them reasoning. "burst" sends that in one write.
    ///
    /// "tail": a reasoning item opens at t0, text deltas run to t0 + 1.0 s and
    /// the message completes with the last one, and the gateway holds
    /// `response.completed` until t0 + 3.0 s: 101 output tokens.
    /// "tail-hidden": the same span with no delta at all, only a reasoning item
    /// that opens at t0 and completes at t0 + 1.0 s. "tail-single" reports one
    /// output token; "tail-short" generates for 0.1 s before the held terminal.
    static let gatewayScript = #"""
import http.server, json, pathlib, sys, time
root = pathlib.Path(sys.argv[1])
def frame(value): return b'data: ' + json.dumps(value).encode() + b'\n\n'
def text_delta(text): return frame({'type':'response.output_text.delta','output_index':1,'item_id':'m1','content_index':0,'delta':text})
class Gateway(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))))
        model = body['model']
        reasoning = {'type':'reasoning','id':'rs1','summary':[],'encrypted_content':'opaque'}
        message = {'type':'message','id':'m1','role':'assistant','status':'completed','content':[{'type':'output_text','text':'Done.'}]}
        created = frame({'type':'response.created','response':{'id':'r1','status':'in_progress','output':[]}})
        opens = frame({'type':'response.output_item.added','output_index':0,'item':{'type':'reasoning','id':'rs1','summary':[]}})
        thought = frame({'type':'response.output_item.done','output_index':0,'item':reasoning})
        answer = frame({'type':'response.output_item.added','output_index':1,'item':{'type':'message','id':'m1','role':'assistant','content':[]}})
        answered = frame({'type':'response.output_item.done','output_index':1,'item':message})
        def completed(output, tokens, reasoning_tokens):
            usage = {'input_tokens':10,'output_tokens':tokens,'output_tokens_details':{'reasoning_tokens':reasoning_tokens}}
            return frame({'type':'response.completed','response':{'id':'r1','status':'completed','output':output,'usage':usage}})
        if model in ('reasoner', 'burst'):
            steps = [(created, 0.1), (opens, 0.8), (thought + answer + text_delta('Done.'), 0.06), (completed([reasoning, message], 860, 800), 0)]
        elif model == 'tail-hidden':
            steps = [(created, 0.1), (opens, 1.0), (thought, 2.0), (completed([reasoning], 101, 101), 0)]
        else:
            # Thirteen deltas: the first 0.4 s after the item opens, then one
            # every 50 ms, so the last is at t0 + 1.0 s ("tail-short": three,
            # at once and 50 ms apart, to t0 + 0.1 s). The message completes
            # with its last delta; the terminal waits two seconds more.
            short = model == 'tail-short'
            thinking, count = (0.0, 3) if short else (0.4, 13)
            deltas = [text_delta('Done.' if index == count - 1 else 'x') for index in range(count)]
            steps = [(created, 0.1), (opens, thinking), (thought + answer + deltas[0], 0.05)]
            steps += [(delta, 0.05) for delta in deltas[1:-1]]
            steps += [(deltas[-1] + answered, 2.0), (completed([reasoning, message], 1 if model == 'tail-single' else 101, 50), 0)]
        self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
        if model == 'burst':
            self.wfile.write(b''.join(data for data, _ in steps)); self.wfile.flush(); return
        for data, pause in steps:
            self.wfile.write(data); self.wfile.flush()
            if pause: time.sleep(pause)
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Gateway)
(root / 'ready.tmp').write_text(json.dumps({'port': server.server_address[1]})); (root / 'ready.tmp').replace(root / 'ready.json')
server.serve_forever()
"""#

    /// One gateway, every model's request at once, each through the real
    /// provider path with its own trace store.
    private func attempts(_ models: [String]) async throws -> [String: JSON] {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let gateway = try await PythonGateway.start(source: Self.gatewayScript, root: root); defer { gateway.stop() }
        let port = gateway.port
        let base = try fixtureProfile().raw
        return try await withThrowingTaskGroup(of: (String, JSON).self) { group in
            for model in models {
                var raw = base
                raw["baseUrl"] = JSON("http://127.0.0.1:\(port)/v1"); raw["modelId"] = JSON(model)
                let profile = try Profile(raw)
                group.addTask {
                    let traces = TraceStore(), client = ProviderClient(traces: traces)
                    _ = try await client.complete(profile: profile, apiKey: "fixture", messages: [ChatMessage(role: "user", content: [textBlock("think")])], instructions: "fixture", tools: [], sessionID: "rate", turnID: "t", purpose: "turn", onDelta: { _ in })
                    return (model, await traces.latest("rate"))
                }
            }
            var result: [String: JSON] = [:]
            for try await (model, metadata) in group { result[model] = metadata }
            return result
        }
    }

    func testHiddenReasoningIsInsideTheDecodeSpan() async throws {
        let results = try await attempts(["reasoner"])
        let metadata = try XCTUnwrap(results["reasoner"])
        let timings = metadata["timings"], metrics = metadata["metrics"]
        XCTAssertEqual(metadata["usage"]["output"].int, 860); XCTAssertEqual(metadata["usage"]["reasoning"].int, 800)
        let firstContent = try XCTUnwrap(timings["firstContent"].double), lastContent = try XCTUnwrap(timings["lastContent"].double)
        let complete = try XCTUnwrap(timings["modelComplete"].double)
        let dispatch = try XCTUnwrap(timings["dispatch"].double), firstText = try XCTUnwrap(timings["firstText"].double)
        // Every output token over dispatch → last output, including TTFT.
        let settled = 860 / ((lastContent - dispatch) / 1000)
        print("PERF decode-span reasoning spanMs=\(Int(lastContent - firstContent)) settledTokPerSec=\(Int(settled)) ttftMs=\(Int(firstContent - dispatch)) firstTextMs=\(Int(firstText - dispatch))")
        // Both ends are stamped when the events arrive, so delivery jitter can
        // take a few milliseconds off the fixture's 0.8 s; what matters is that the
        // span covers the hidden reasoning (~800 ms), not only the visible text (~60 ms).
        XCTAssertGreaterThanOrEqual(lastContent - firstContent, 760, "the span covers the 0.8 s of hidden reasoning the output count includes")
        XCTAssertLessThan(settled, 1_100, "860 tokens over ~0.9 s, not over the instant of visible text (~14,000 tok/s)")
        XCTAssertEqual(metrics["decodeTokensPerSecond"].double ?? 0, settled, accuracy: 0.5)
        XCTAssertEqual(metrics["streamDurationMs"].double ?? 0, lastContent - firstContent, accuracy: 0.001, "the stream duration is the decode span")
        XCTAssertLessThan(lastContent, complete)
        XCTAssertLessThan(firstContent - dispatch, firstText - dispatch - 700, "time to first token is the first generated item; the first visible text stays separate")
        XCTAssertEqual(metrics["minimumDecodeSpanMs"].double, 250)
    }

    func testABurstDeliveredReplyBelowTheTotalDurationFloorReportsNoRate() async throws {
        let results = try await attempts(["burst"])
        let metadata = try XCTUnwrap(results["burst"])
        let timings = metadata["timings"], metrics = metadata["metrics"]
        let span = try XCTUnwrap(timings["lastContent"].double) - (try XCTUnwrap(timings["dispatch"].double))
        print("PERF output-duration burst spanMs=\(span)")
        XCTAssertLessThan(span, 250, "one write delivers the whole reply")
        XCTAssertTrue(metrics["decodeTokensPerSecond"].isNull, "below the minimum span a request contributes no rate, never 100,000 tok/s")
        XCTAssertEqual(metrics["minimumDecodeSpanMs"].double, 250, "the minimum travels with the timings, for readers that fold their own rate")
    }

    /// The gateway holds `response.completed` two seconds after the last token.
    /// All 101 tokens use TTFT + one second of generation; the held terminal
    /// must not dilute this rate.
    func testTheDecodeSpanEndsAtTheLastTokenNotAtAHeldTerminalEvent() async throws {
        let results = try await attempts(["tail", "tail-hidden", "tail-single", "tail-short"])
        let tail = try XCTUnwrap(results["tail"])
        let timings = tail["timings"], metrics = tail["metrics"]
        XCTAssertEqual(tail["usage"]["output"].int, 101)
        let first = try XCTUnwrap(timings["firstContent"].double), last = try XCTUnwrap(timings["lastContent"].double)
        let complete = try XCTUnwrap(timings["modelComplete"].double)
        let rate = try XCTUnwrap(metrics["decodeTokensPerSecond"].double)
        let dispatch = try XCTUnwrap(timings["dispatch"].double)
        let diluted = 101 / ((complete - dispatch) / 1000)
        print("PERF decode-span held-terminal spanMs=\(Int(last - first)) tailMs=\(Int(complete - last)) decodeTokPerSec=\(String(format: "%.1f", rate)) dividedToTerminal=\(String(format: "%.1f", diluted))")
        // Sleeps only overrun: the span is the scripted second plus scheduling.
        XCTAssertGreaterThanOrEqual(last - first, 950, "first output item → last delta is the one second the model generated for")
        XCTAssertLessThan(last - first, 1_500)
        XCTAssertGreaterThanOrEqual(complete - last, 1_900, "the held terminal is two seconds after the last token")
        XCTAssertEqual(rate, 101 / ((last - dispatch) / 1000), accuracy: 1e-9, "All tokens over dispatch → last output")
        XCTAssertGreaterThan(rate, 55); XCTAssertLessThanOrEqual(rate, 106, "TTFT included, however late the terminal")
        XCTAssertLessThan(diluted, 40, "A held terminal would dilute the output speed")
        XCTAssertEqual(metrics["streamDurationMs"].double ?? 0, last - first, accuracy: 0.001, "The raw stream span excludes the held terminal")

        // An output item's completion is a token boundary too: hidden
        // reasoning with no delta at all ends when its item completes.
        let hidden = try XCTUnwrap(results["tail-hidden"])
        let hiddenFirst = try XCTUnwrap(hidden["timings"]["firstContent"].double), hiddenLast = try XCTUnwrap(hidden["timings"]["lastContent"].double)
        XCTAssertGreaterThanOrEqual(hiddenLast - hiddenFirst, 950, "the reasoning item's completion ends the span")
        XCTAssertLessThan(hiddenLast - hiddenFirst, 1_500)
        XCTAssertLessThan(hiddenLast, try XCTUnwrap(hidden["timings"]["modelComplete"].double) - 1_900)
        XCTAssertEqual(try XCTUnwrap(hidden["metrics"]["decodeTokensPerSecond"].double), 101 / ((hiddenLast - (try XCTUnwrap(hidden["timings"]["dispatch"].double))) / 1000), accuracy: 1e-9)

        // A single reported output token is inside the measured window.
        let single = try XCTUnwrap(results["tail-single"])
        XCTAssertEqual(single["usage"]["output"].int, 1)
        XCTAssertNotNil(single["timings"]["lastContent"].double)
        XCTAssertEqual(try XCTUnwrap(single["metrics"]["decodeTokensPerSecond"].double), 1 / ((try XCTUnwrap(single["timings"]["lastContent"].double) - (try XCTUnwrap(single["timings"]["dispatch"].double))) / 1000), accuracy: 1e-9)

        // TTFT plus a tenth of a second of generation is below the floor,
        // however long the gateway then holds the terminal.
        let short = try XCTUnwrap(results["tail-short"])
        let shortSpan = try XCTUnwrap(short["timings"]["lastContent"].double) - (short["timings"]["dispatch"].double ?? 0)
        XCTAssertLessThan(shortSpan, 250); XCTAssertGreaterThanOrEqual(shortSpan, 90)
        XCTAssertGreaterThan((short["timings"]["modelComplete"].double ?? 0) - (short["timings"]["firstContent"].double ?? 0), 2_000)
        XCTAssertTrue(short["metrics"]["decodeTokensPerSecond"].isNull, "The total duration is below the floor; the held terminal does not lengthen it")
    }

    /// The same definition on the trace store's own clock, where every stamp
    /// is exact: output opens at 1 s, the last delta is at 2 s, the terminal
    /// arrives at 4 s.
    func testTheTraceStoreDividesAllOutputByDispatchToLastOutput() async throws {
        func metrics(output: JSON, stamps: [Double], terminal: Double = 4_000, outcome: String = "completed") async throws -> JSON {
            let traces = TraceStore()
            let id = await traces.begin(session: "decode", turn: "t", profile: try fixtureProfile(), purpose: "turn", body: Data(), headers: [:])
            await traces.dispatched(id, at: 500)
            for (index, stamp) in stamps.enumerated() { await traces.content(id, text: index > 0, at: stamp) }
            await traces.terminal(id, at: terminal)
            await traces.usage(id, ["output": output])
            await traces.finish(id, outcome: outcome, modelOutcome: outcome == "completed" ? "completed" : "interrupted")
            return await traces.latest("decode")
        }
        let measured = try await metrics(output: 101, stamps: [1_000, 1_500, 2_000])
        XCTAssertEqual(measured["timings"]["firstContent"].double, 1_000)
        XCTAssertEqual(measured["timings"]["lastContent"].double, 2_000)
        XCTAssertEqual(measured["timings"]["modelComplete"].double, 4_000)
        XCTAssertEqual(measured["metrics"]["decodeTokensPerSecond"].double, 101 / 1.5, "All 101 tokens over 500 ms TTFT + 1 s span")
        XCTAssertEqual(measured["metrics"]["streamDurationMs"].double, 1_000, "The stream duration remains first-to-last output")
        XCTAssertNil(measured["metrics"].map["outputTokensPerSecond"], "Only one settled rate is published")
        XCTAssertEqual(measured["metrics"]["observedTTFTms"].double, 500, "time to first token is unchanged: dispatch → first output")
        func rate(output: JSON, stamps: [Double], outcome: String = "completed") async throws -> Double? {
            try await metrics(output: output, stamps: stamps, outcome: outcome)["metrics"]["decodeTokensPerSecond"].double
        }
        let two = try await rate(output: 2, stamps: [1_000, 2_000]), one = try await rate(output: 1, stamps: [1_000, 2_000])
        let none = try await rate(output: 0, stamps: [1_000, 2_000]), brief = try await rate(output: 101, stamps: [1_000, 1_100])
        let floor = try await rate(output: 101, stamps: [1_000, 1_250]), cancelled = try await rate(output: 101, stamps: [1_000, 2_000], outcome: "cancelled")
        XCTAssertEqual(two, 2 / 1.5, "All tokens, including the first")
        XCTAssertEqual(one, 1 / 1.5)
        XCTAssertNil(none)
        XCTAssertEqual(brief, 101 / 0.6, "TTFT brings the total past the floor")
        XCTAssertEqual(floor, 101 / 0.75)
        XCTAssertNil(cancelled, "only a completed request has a rate")

        // An attempt that stamped no last output (an item opened, then only
        // the terminal) ends at the terminal, the only end it has; the archive
        // projects its stream by the same rule.
        let traces = TraceStore()
        let id = await traces.begin(session: "unstamped", turn: "t", profile: try fixtureProfile(), purpose: "turn", body: Data(), headers: [:])
        await traces.dispatched(id, at: 500); await traces.opened(id, at: 1_000); await traces.terminal(id, at: 4_000)
        await traces.usage(id, ["output": 101]); await traces.finish(id, outcome: "completed", modelOutcome: "completed")
        let unstamped = await traces.latest("unstamped")
        XCTAssertTrue(unstamped["timings"]["lastContent"].isNull)
        XCTAssertEqual(unstamped["metrics"]["streamDurationMs"].double, 3_000)
        XCTAssertEqual(try XCTUnwrap(unstamped["metrics"]["decodeTokensPerSecond"].double), 101 / 3.5, accuracy: 1e-9)
        // A stream cut before its terminal event has no span, however much arrived.
        let cut = TraceStore()
        let cutID = await cut.begin(session: "cut", turn: "t", profile: try fixtureProfile(), purpose: "turn", body: Data(), headers: [:])
        await cut.dispatched(cutID, at: 500); await cut.content(cutID, text: true, at: 1_000); await cut.content(cutID, text: true, at: 2_000)
        await cut.finish(cutID, outcome: "cancelled", modelOutcome: "interrupted")
        let interrupted = await cut.latest("cut")
        XCTAssertEqual(interrupted["timings"]["lastContent"].double, 2_000)
        XCTAssertTrue(interrupted["metrics"]["streamDurationMs"].isNull, "no terminal event, no stream duration")
    }
}
