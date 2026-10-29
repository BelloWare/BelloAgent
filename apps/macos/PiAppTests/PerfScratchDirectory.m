#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// LaunchServices can replace TMPDIR before a hosted test starts. Route the
// perf fixture's rebuildable HistoryOffsetIndex files into its build root
// too. This file belongs only to the test bundle; ordinary tests fall through.
static NSURL *(*perfOriginalTemporaryDirectory)(id, SEL);

static NSURL *perfTemporaryDirectory(id receiver, SEL selector) {
    const char *root = getenv("TEST_RUNNER_PI_PERF_ROOT") ?: getenv("PI_PERF_ROOT");
    if (root) {
        NSString *path = [[NSString stringWithUTF8String:root] stringByAppendingPathComponent:@"scratch"];
        return [NSURL fileURLWithPath:path isDirectory:YES];
    }
    return perfOriginalTemporaryDirectory(receiver, selector);
}

__attribute__((constructor)) static void installPerfTemporaryDirectory(void) {
    if (!getenv("TEST_RUNNER_PI_PERF_ROOT") && !getenv("PI_PERF_ROOT")) { return; }
    Method method = class_getInstanceMethod(NSFileManager.class, @selector(temporaryDirectory));
    perfOriginalTemporaryDirectory = (void *)method_setImplementation(method, (IMP)perfTemporaryDirectory);
}
