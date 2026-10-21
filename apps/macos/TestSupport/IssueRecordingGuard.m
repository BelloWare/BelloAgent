#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// Compiled only into PiAppTests, whose image loads with XCTest. XCTest
// (Xcode 16.1) queues an issue raised off the main thread (any assertion
// after an `await` in a nonisolated test, or in a task, actor or callback)
// for the main thread, which runs the queue whenever its run loop exits and
// again inside each issue it records. An issue recorded inside another is
// taken for that issue's own legacy re-recording and folded into it, so it
// never reaches the run: the test still fails, but its failures are
// undercounted and their messages lost. This records a nested issue once the
// outer one is done, as HelperTestCase does for the helper's tests.
// scripts/tests/test_xctest_issue_recording.py runs it against XCTest;
// docs/validation/a130-asynctests-0.1.130.md has the evidence.
static void (*recordIssue)(id, SEL, id);

static void recordIssuesOneAtATime(id testCase, SEL selector, id issue) {
    // XCTest marks the issue in progress per test and thread; so does this.
    NSMutableDictionary *threadState = NSThread.currentThread.threadDictionary;
    NSString *key = [NSString stringWithFormat:@"com.belloware.PiAppTests.deferredIssues.%p", testCase];
    NSMutableArray *deferred = threadState[key];
    if (deferred) {
        [deferred addObject:issue];
        return;
    }
    deferred = [NSMutableArray array];
    threadState[key] = deferred;
    @try {
        recordIssue(testCase, selector, issue);
        while (deferred.count) {
            id next = deferred.firstObject;
            [deferred removeObjectAtIndex:0];
            recordIssue(testCase, selector, next);
        }
    } @finally {
        [threadState removeObjectForKey:key];
    }
}

static void issueRecordingMarker(id receiver, SEL selector) {}

__attribute__((constructor)) static void keepNestedIssues(void) {
    Class testCase = objc_getClass("XCTestCase");
    Method method = testCase ? class_getInstanceMethod(testCase, sel_registerName("recordIssue:")) : NULL;
    // The marker installs once per process; IssueRecordingGuardTests checks it.
    if (!method || !class_addMethod(testCase, sel_registerName("belloTestIssueRecordingInstalled"),
                                    (IMP)issueRecordingMarker, "v@:")) return;
    recordIssue = (void *)method_setImplementation(method, (IMP)recordIssuesOneAtATime);
}
