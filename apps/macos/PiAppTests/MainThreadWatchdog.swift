import Foundation
import XCTest

/// Asks the main queue to answer from a background thread, and notices when it
/// does not. A SwiftUI update that keeps scheduling another update never goes
/// back to the run loop, so nothing on the main queue runs: the window is
/// frozen, and a test awaiting on the main actor would wait for ever.
///
/// On a stall past `limit` the watchdog samples this process into
/// `samplePath` (the stack of the frozen main thread is the evidence), reports
/// through `onStall`, and — when `abortOnStall` — ends the process, so a
/// frozen window fails its test instead of hanging the run.
final class MainThreadWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var sentAt: Double?
    private var stopped = false
    private var reported = false
    private var worst: Double = 0
    private var answers = 0
    let limit: Double
    let samplePath: String?
    let abortOnStall: Bool
    let onStall: (@Sendable (Double) -> Void)?

    init(limit: Double, samplePath: String? = nil, abortOnStall: Bool = true, onStall: (@Sendable (Double) -> Void)? = nil) {
        self.limit = limit; self.samplePath = samplePath; self.abortOnStall = abortOnStall; self.onStall = onStall
    }

    /// The longest the main queue took to answer so far, in seconds.
    var worstStall: Double { lock.withLock { max(worst, sentAt.map { Self.now - $0 } ?? 0) } }
    var answered: Int { lock.withLock { answers } }

    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    func start() {
        let thread = Thread { [self] in
            while true {
                var stall: Double?
                lock.lock()
                if stopped { lock.unlock(); return }
                if let sent = sentAt {
                    let waited = Self.now - sent
                    if waited > limit, !reported { reported = true; stall = waited }
                } else {
                    let sent = Self.now
                    sentAt = sent
                    DispatchQueue.main.async { [self] in
                        lock.withLock {
                            worst = max(worst, Self.now - sent)
                            answers += 1
                            if sentAt == sent { sentAt = nil }
                        }
                    }
                }
                lock.unlock()
                if let stall { report(stall) }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        thread.name = "MainThreadWatchdog"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() { lock.withLock { stopped = true } }

    private func report(_ stall: Double) {
        let message = String(format: "WATCHDOG the main thread has not returned to its run loop for %.1f s", stall)
        print(message)
        if let samplePath {
            let sample = Process()
            sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            sample.arguments = [String(getpid()), "2", "-mayDie", "-file", samplePath]
            sample.standardOutput = FileHandle.nullDevice; sample.standardError = FileHandle.nullDevice
            if (try? sample.run()) != nil { sample.waitUntilExit() }
            print("WATCHDOG sample of the frozen process: " + samplePath)
        }
        onStall?(stall)
        if abortOnStall {
            // Nothing on the main thread can run again: end the run with the
            // evidence rather than wait for the test runner's own timeout.
            fputs(message + "\n", stderr)
            abort()
        }
    }
}
