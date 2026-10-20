#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <pwd.h>
#include <unistd.h>
#if !PI_TEST_ISOLATION_PROBE
#import <AppKit/AppKit.h>
#endif

// Compiled only into PiAppTestHost and PiAppTests. Constructors run before
// the app's Swift main / XCTest discovery, independent of test ordering.
// No UserDefaults, CFPreferences or real plist reads/writes belong here.
static NSString *canonical(NSString *path) {
    return path.stringByStandardizingPath.stringByResolvingSymlinksInPath;
}

static NSString *isolationFailure(NSString *identifier, NSString *effectiveHome,
                                  NSString *realHome, NSString *fixedHome) {
    if (!effectiveHome.isAbsolutePath || !realHome.isAbsolutePath) {
        return @"cannot resolve the effective and account preferences homes";
    }
    // cfprefsd can use the account's preferences folder even with a fixed
    // Foundation home. Never accept the shipping defaults domain, anywhere.
    if ([identifier isEqualToString:@"com.belloware.PiApp"]) {
        return @"com.belloware.PiApp is the real preferences domain";
    }
    if (![identifier isEqualToString:@"com.belloware.PiAppTests.Host"]) {
        return @"the host must be com.belloware.PiAppTests.Host, never the shipping app";
    }
    if ([canonical(effectiveHome) isEqualToString:canonical(realHome)] || !fixedHome.isAbsolutePath ||
        ![canonical(fixedHome) isEqualToString:canonical(effectiveHome)]) {
        return @"CFFIXED_USER_HOME must resolve to an isolated test home, not the account home";
    }
    for (NSString *suffix in @[@"Library", @"Library/Application Support", @"Library/Caches", @".codex"]) {
        if ([canonical([effectiveHome stringByAppendingPathComponent:suffix])
            isEqualToString:canonical([realHome stringByAppendingPathComponent:suffix])]) {
            return @"a test storage directory resolves into the account home";
        }
    }
    return nil;
}

static void refuse(NSString *reason) {
    fprintf(stderr, "Refusing to run PiAppTests: %s. Rebuild with the checked-in PiApp scheme; do not run stale test products.\n", reason.UTF8String);
    // Exit before test discovery, without an exception handler, crash reporter
    // or shutdown callback that could open the rejected defaults domain.
    _exit(78);
}

static NSDictionary<NSString *, NSString *> *testHomeEnvironment;
static void (*setTaskEnvironment)(id, SEL, NSDictionary<NSString *, NSString *> *);

static void testSetTaskEnvironment(id receiver, SEL selector, NSDictionary<NSString *, NSString *> *environment) {
    NSMutableDictionary *isolated = [(environment ?: NSProcessInfo.processInfo.environment) mutableCopy];
    [isolated addEntriesFromDictionary:testHomeEnvironment];
    setTaskEnvironment(receiver, selector, isolated);
}

static void homeIsolationMarker(id receiver, SEL selector) {}

static void installTestHomes(NSString *home) {
    home = canonical(home);
    testHomeEnvironment = @{@"HOME": home, @"CFFIXED_USER_HOME": home,
                            @"CODEX_HOME": [home stringByAppendingPathComponent:@".codex"]};
    for (NSString *key in testHomeEnvironment) {
        if (setenv(key.UTF8String, testHomeEnvironment[key].UTF8String, 1) != 0) refuse(@"cannot isolate the test environment");
    }
    // Explicit Process environments otherwise drop CFFIXED_USER_HOME, and
    // Foundation in the helper resolves the account home despite HOME.
    Class type = [NSTask new].class;
    Method setter = class_getInstanceMethod(type, @selector(setEnvironment:));
    if (!setter) refuse(@"cannot isolate child process homes");
    if (!class_addMethod(type, sel_registerName("belloTestHomeIsolationInstalled"), (IMP)homeIsolationMarker, "v@:")) return;
    setTaskEnvironment = (void *)method_setImplementation(setter, (IMP)testSetTaskEnvironment);
}

#if !PI_TEST_ISOLATION_PROBE
// A fixed home cannot isolate the WindowServer's shared pasteboards. Route
// AppKit's standard accessors before any app/test code can read or replace
// the desktop clipboard or drag contents. Custom fixture boards pass through.
static NSPasteboard *(*namedPasteboard)(id, SEL, NSPasteboardName);

static NSPasteboard *testNamedPasteboard(id receiver, SEL selector, NSPasteboardName name) {
    static NSDictionary<NSString *, NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *prefix = [@"com.belloware.PiAppTests.pasteboard." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSMutableDictionary *mapping = [NSMutableDictionary dictionary];
        for (NSString *shared in @[NSPasteboardNameGeneral, NSPasteboardNameDrag, NSPasteboardNameFind,
                                   NSPasteboardNameFont, NSPasteboardNameRuler]) {
            mapping[shared] = [prefix stringByAppendingString:shared];
        }
        names = mapping;
    });
    return namedPasteboard(receiver, selector, names[name] ?: name);
}

static NSPasteboard *testGeneralPasteboard(id receiver, SEL selector) {
    return [NSPasteboard pasteboardWithName:NSPasteboardNameGeneral];
}

static void pasteboardIsolationMarker(id receiver, SEL selector) {}

static void installTestPasteboards(void) {
    // Both Mach-O images contain this guard. Install once per process, even
    // though their C statics are separate. Never call the original general getter.
    Class type = NSPasteboard.class;
    Method general = class_getClassMethod(type, @selector(generalPasteboard));
    Method named = class_getClassMethod(type, @selector(pasteboardWithName:));
    if (!general || !named) refuse(@"cannot isolate shared pasteboards");
    if (!class_addMethod(object_getClass(type), sel_registerName("belloTestPasteboardIsolationInstalled"),
                         (IMP)pasteboardIsolationMarker, "v@:")) return;
    namedPasteboard = (void *)method_setImplementation(named, (IMP)testNamedPasteboard);
    method_setImplementation(general, (IMP)testGeneralPasteboard);
}
#endif

#if PI_TEST_ISOLATION_PROBE
// A policy probe with synthetic arguments, used by scripts/tests. It never
// launches an app and never even constructs the real preferences plist path.
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 5) return 64;
        NSString *reason = isolationFailure(@(argv[1]), @(argv[2]), @(argv[3]), @(argv[4]));
        if (reason) refuse(reason);
        return 0;
    }
}
#elif !PI_TEST_PASTEBOARD_PROBE
__attribute__((constructor)) static void guardTestProcess(void) {
    @autoreleasepool {
        struct passwd *account = getpwuid(getuid());
        if (!account || !account->pw_dir) refuse(@"cannot resolve the account home");
        NSString *identifier = NSBundle.mainBundle.bundleIdentifier;
        NSString *effectiveHome = NSHomeDirectory();
        NSString *fixedHome = NSProcessInfo.processInfo.environment[@"CFFIXED_USER_HOME"];
        NSString *reason = isolationFailure(identifier, effectiveHome, @(account->pw_dir), fixedHome);
        if (reason) refuse(reason);
        installTestHomes(effectiveHome);
        installTestPasteboards();
        // Also protect plain test invocations that removed the scheme's old
        // opt-out flag: test hosts can never start normal application services.
        setenv("PI_APP_TESTING", "1", 1);
        NSError *error = nil;
        if (![NSFileManager.defaultManager createDirectoryAtPath:effectiveHome withIntermediateDirectories:YES attributes:nil error:&error]) {
            refuse([@"cannot create isolated test home: " stringByAppendingString:error.localizedDescription]);
        }
        fprintf(stderr, "PiAppTests isolation verified: defaults=%s; data home=%s\n", identifier.UTF8String, effectiveHome.UTF8String);
    }
}
#endif
