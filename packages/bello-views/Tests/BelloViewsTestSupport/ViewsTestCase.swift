import XCTest

/// The base of every test class in this package; each test target names it
/// through its own `ViewsTestCase` alias, and checks its classes derive from
/// it with its own guard, such as `FileViewIssueRecordingTests`.
///
/// XCTest (Xcode 16.1) queues an issue raised off the main thread (any
/// assertion after an `await` in a nonisolated test, or in a task, actor or
/// callback) for the main thread, which runs the queue whenever its run loop
/// exits and again inside each issue it records. An issue recorded inside
/// another is taken for that issue's own legacy re-recording and folded into
/// it, so it never reaches the run. The test still fails, since the outer
/// issue counts, but its failures are undercounted and their messages lost.
/// Recording a nested issue once the outer one is done keeps every one, as
/// the helper's HelperTestCase and the app's IssueRecordingGuard.m do.
/// scripts/tests/test_xctest_issue_recording.py runs this against XCTest;
/// docs/validation/a130-asynctests-0.1.130.md has the evidence.
open class ViewsTestCase: XCTestCase {
    private let recording = NSLock()
    /// The issues each thread received while it was already recording one.
    private var deferred: [ObjectIdentifier: [XCTIssue]] = [:]

    open override func record(_ issue: XCTIssue) {
        // Without continuing after a failure XCTest keeps only the first,
        // and may unwind the test from inside this call.
        guard continueAfterFailure else { return super.record(issue) }
        let thread = ObjectIdentifier(Thread.current)
        recording.lock()
        if deferred[thread] != nil {
            deferred[thread]!.append(issue)
            recording.unlock()
            return
        }
        deferred[thread] = []
        recording.unlock()
        var next: XCTIssue? = issue
        while let current = next {
            super.record(current)
            recording.lock()
            if deferred[thread]!.isEmpty { deferred[thread] = nil; next = nil } else { next = deferred[thread]!.removeFirst() }
            recording.unlock()
        }
    }
}
