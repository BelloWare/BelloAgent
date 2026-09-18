import Foundation
import PiAgentCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A bounded writer: a blocked UI cannot cause unbounded protocol buffering.
/// On overflow the helper terminates; the app reconciles durable session state.
final class ProtocolWriter: @unchecked Sendable {
    let queue=DispatchQueue(label:"pi.native.stdout"), slots=DispatchSemaphore(value:64)
    func send(_ value:JSON) {
        guard slots.wait(timeout:.now()) == .success else { Self.fail("Native host output backpressure limit reached") }
        queue.async { [self] in
            defer { slots.signal() }
            do {
                var data=try value.data(); guard data.count<=1048576 else { throw AgentError("frame_limit","Protocol output exceeds frame limit") }
                data.append(10); try FileHandle.standardOutput.write(contentsOf:data)
            } catch { Self.fail("Native host protocol output failed") }
        }
    }
    func drain() { queue.sync {} }
    static func fail(_ message:String) -> Never {
        try? FileHandle.standardError.write(contentsOf:Data((message+"\n").utf8)); exit(70)
    }
}

@main struct Main {
    static func main() async {
        signal(SIGPIPE,SIG_IGN)
        if CommandLine.arguments.contains("--version") { print("pi-native-host 1.0.0 (Pi behavior reference 0.85.1)"); return }
        let writer=ProtocolWriter(), service=NativeHostService { writer.send($0) }
        signal(SIGTERM,SIG_IGN); signal(SIGINT,SIG_IGN)
        let term=DispatchSource.makeSignalSource(signal:SIGTERM,queue:.global()), interrupt=DispatchSource.makeSignalSource(signal:SIGINT,queue:.global())
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
        await service.shutdown(); writer.drain(); term.cancel(); interrupt.cancel()
    }
}
