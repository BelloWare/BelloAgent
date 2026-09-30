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
    private let changes=PendingChanges()
    /// Standard input reached its end: the app closed its side and is going.
    /// From here a failed write means the reader is gone, not a broken
    /// protocol, and the helper still has a stopped run's partial reply and
    /// final state to write to the journal before it exits.
    func inputEnded() { reader.set(\.inputEnded) }
    /// A reply the service encoded once goes out as those bytes, under the
    /// same bound and order as every other frame; only a chat's change
    /// notice is ever coalesced.
    func send(_ output: HostOutput) {
        switch output {
        case .frame(let value): send(value)
        case .encoded(let bytes):
            guard !reader.gone else { return }
            guard slots.wait(timeout:.now()) == .success else { Self.fail("Native host output backpressure limit reached") }
            queue.async { [self] in
                defer { slots.signal() }
                guard !reader.gone else { return }
                write(bytes: bytes)
            }
        }
    }
    func send(_ value:JSON) {
        guard !reader.gone else { return }
        // A chat's change notice carries only its latest sequence number, and
        // the app keeps only the latest one per chat. One waiting per chat is
        // enough: while the app is busy reading, a later notice updates the
        // waiting one instead of queueing behind it. Streams no longer pause
        // for the request log, so without this twenty streaming chats filled
        // the queue in a brief stall and the helper stopped itself.
        if value["kind"].text == "event", value["type"].text == "session.changed", let session = value["sessionId"].text {
            guard changes.hold(session, value) else { return }
            queue.async { [self] in
                guard let latest = changes.take(session), !reader.gone else { return }
                write(latest)
            }
            return
        }
        guard slots.wait(timeout:.now()) == .success else { Self.fail("Native host output backpressure limit reached") }
        queue.async { [self] in
            defer { slots.signal() }
            guard !reader.gone else { return }
            write(value)
        }
    }
    /// On the writer queue only.
    private func write(_ value: JSON) {
        guard let data=try? value.data() else { Self.fail("Native host protocol output failed") }
        write(bytes: data)
    }
    /// On the writer queue only: one frame's bytes, without their newline.
    private func write(bytes: Data) {
        do {
            guard bytes.count<=HostProtocol.frameBytes else { throw AgentError("frame_limit","Protocol output exceeds frame limit") }
            var data=bytes; data.append(10)
            do { try FileHandle.standardOutput.write(contentsOf:data) }
            catch { guard reader.inputEnded else { throw error }; reader.set(\.gone); return }
        } catch { Self.fail("Native host protocol output failed") }
    }
    func drain() { queue.sync {} }
    static func fail(_ message:String) -> Never {
        try? FileHandle.standardError.write(contentsOf:Data((message+"\n").utf8)); exit(70)
    }
}

/// The change notice waiting to be written for each chat, at most one.
/// Every access goes through the lock.
final class PendingChanges: @unchecked Sendable {
    private let lock=NSLock()
    private var waiting: [String: JSON] = [:]
    /// Holds `frame` as the chat's waiting notice. True when none was waiting,
    /// so the caller queues one write; false when the waiting one now carries it.
    func hold(_ session: String, _ frame: JSON) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let fresh = waiting[session] == nil
        waiting[session] = frame
        return fresh
    }
    func take(_ session: String) -> JSON? {
        lock.lock(); defer { lock.unlock() }
        return waiting.removeValue(forKey: session)
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
        if CommandLine.arguments.contains("--version") { print("pi-native-host \(HostProtocol.engineVersion) (Pi behavior reference \(HostProtocol.piBehaviorReference))"); return }
        let writer=ProtocolWriter(), service=NativeHostService(output: { writer.send($0) })
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
