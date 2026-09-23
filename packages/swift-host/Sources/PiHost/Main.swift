import Foundation
import PiAgentCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A bounded writer: a blocked UI cannot cause unbounded protocol buffering.
/// On overflow the helper terminates; the app reconciles durable session state.
///
/// Concurrency: no mutable state of its own. Frames are serialized by `queue`
/// and bounded by `slots`, both of which are thread-safe and immutable here,
/// so the compiler can check the `Sendable` conformance.
final class ProtocolWriter: Sendable {
    let queue=DispatchQueue(label:"pi.native.stdout"), slots=DispatchSemaphore(value:64)
    private let reader=ReaderState()
    /// Standard input reached its end: the app closed its side and is going.
    /// From here a failed write means the reader is gone, not a broken
    /// protocol, and the helper still has a stopped run's partial reply and
    /// final state to write to the journal before it exits.
    func inputEnded() { reader.set(\.inputEnded) }
    func send(_ value:JSON) {
        guard !reader.gone else { return }
        guard slots.wait(timeout:.now()) == .success else { Self.fail("Native host output backpressure limit reached") }
        queue.async { [self] in
            defer { slots.signal() }
            guard !reader.gone else { return }
            do {
                var data=try value.data(); guard data.count<=1048576 else { throw AgentError("frame_limit","Protocol output exceeds frame limit") }
                data.append(10)
                do { try FileHandle.standardOutput.write(contentsOf:data) }
                catch { guard reader.inputEnded else { throw error }; reader.set(\.gone); return }
            } catch { Self.fail("Native host protocol output failed") }
        }
    }
    func drain() { queue.sync {} }
    static func fail(_ message:String) -> Never {
        try? FileHandle.standardError.write(contentsOf:Data((message+"\n").utf8)); exit(70)
    }
}

/// Two flags that only ever turn on, read from the writer queue and set from
/// the reader task. Every access goes through the lock.
final class ReaderState: @unchecked Sendable {
    struct Flags { var inputEnded=false, gone=false }
    private let lock=NSLock()
    private var flags=Flags()
    var inputEnded: Bool { lock.lock(); defer { lock.unlock() }; return flags.inputEnded }
    var gone: Bool { lock.lock(); defer { lock.unlock() }; return flags.gone }
    func set(_ flag: WritableKeyPath<Flags,Bool>) { lock.lock(); flags[keyPath:flag]=true; lock.unlock() }
}

@main struct Main {
    static func main() async {
        signal(SIGPIPE,SIG_IGN)
        if CommandLine.arguments.contains("--version") { print("pi-native-host 1.0.0 (Pi behavior reference 0.85.1)"); return }
        let writer=ProtocolWriter(), service=NativeHostService { writer.send($0) }
        signal(SIGTERM,SIG_IGN); signal(SIGINT,SIG_IGN)
        let term=DispatchSource.makeSignalSource(signal:SIGTERM,queue:.global()), interrupt=DispatchSource.makeSignalSource(signal:SIGINT,queue:.global())
        // A signal handler cannot await. This task is the shutdown itself, so
        // it has no cancellation path by design: it ends the process.
        let shutdown:@Sendable ()->Void = { Task { await service.shutdown(); writer.drain(); exit(0) } }
        term.setEventHandler(handler:shutdown); interrupt.setEventHandler(handler:shutdown); term.resume(); interrupt.resume()
        let reader=Task.detached(priority:.userInitiated) {
            var decoder=NDJSONDecoder()
            while true {
                let data=FileHandle.standardInput.availableData
                if data.isEmpty { break }
                for frame in try decoder.feed(data) { await service.receive(frame) }
            }
            try decoder.finish()
        }
        do { try await reader.value }
        catch { try? FileHandle.standardError.write(contentsOf:Data("Invalid or incomplete host protocol; no input payload logged\n".utf8)) }
        writer.inputEnded()
        await service.shutdown(); writer.drain(); term.cancel(); interrupt.cancel()
    }
}
