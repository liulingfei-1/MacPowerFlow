#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "../../PowerFlow/PrivilegedMetricsRunner.h"

// Exercise the production state machine without touching launchd or authd.
@interface MPFPrivilegedMetricsRunner (Testing)
- (void)connectToInstalledHelper;
- (NSString *)exactRequirementForBundledHelper:(NSError **)error;
- (BOOL)codeAtURL:(NSURL *)url matchesExactRequirement:(NSString *)requirement;
- (BOOL)installedConfigurationMatchesCurrentClient;
- (BOOL)runAuthorizedInstaller:(NSError **)error;
- (void)connectionFailedForGeneration:(NSUInteger)generation message:(NSString *)message;
- (void)scheduleConnectionRetryAfter:(NSTimeInterval)delay;
@end

@interface TestRunner : MPFPrivilegedMetricsRunner
@property BOOL helperMatches;
@property BOOL clientMatches;
@property BOOL preflight;
@property BOOL scheduleRetries;
@property NSUInteger connections;
@property NSUInteger installations;
@end
@implementation TestRunner
- (NSString *)exactRequirementForBundledHelper:(NSError **)error { return @"test"; }
- (BOOL)codeAtURL:(NSURL *)url matchesExactRequirement:(NSString *)requirement { return self.helperMatches; }
- (BOOL)installedConfigurationMatchesCurrentClient { return self.clientMatches; }
- (BOOL)runAuthorizedInstaller:(NSError **)error {
    self.installations++;
    *error = [NSError errorWithDomain:@"Test" code:1 userInfo:nil];
    return NO;
}
- (void)connectToInstalledHelper {
    self.connections++;
    if (self.preflight) { [super connectToInstalledHelper]; }
}
- (void)scheduleConnectionRetryAfter:(NSTimeInterval)delay {
    if (self.scheduleRetries) { [super scheduleConnectionRetryAfter:delay]; }
}
@end

static void require(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static dispatch_queue_t worker(TestRunner *runner) {
    return object_getIvar(runner, class_getInstanceVariable(MPFPrivilegedMetricsRunner.class, "_workerQueue"));
}
static void flush(TestRunner *runner) { dispatch_sync(worker(runner), ^{}); }
static void start(TestRunner *runner, BOOL allow) {
    [runner startAllowingInstallation:allow dataHandler:^(NSData *data) {}
                         stateHandler:^(MPFPrivilegedMetricsRunnerState state, NSString *message) {}];
    flush(runner);
}
static void pauseBriefly(void) {
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.08]];
}
int main(void) {
    @autoreleasepool {
        for (NSNumber *allow in @[@NO, @YES]) {
            TestRunner *runner = [TestRunner new]; runner.preflight = YES;
            start(runner, allow.boolValue);
            require(runner.installations == (allow.boolValue ? 1 : 0), @"missing helper respects explicit installation permission");
            require(runner.state == MPFPrivilegedMetricsRunnerStateFailed, @"unavailable helper exits startup cleanly");
        }
        puts("PASS: missing helper never prompts automatically; explicit action can install");
        for (NSNumber *allow in @[@NO, @YES]) {
            TestRunner *runner = [TestRunner new]; runner.preflight = YES; runner.helperMatches = YES;
            start(runner, allow.boolValue);
            require(runner.installations == (allow.boolValue ? 1 : 0), @"outdated client identity respects explicit installation permission");
        }
        puts("PASS: changed client identity is recognized even when helper binary matches");
        TestRunner *slow = [TestRunner new]; slow.helperMatches = YES; slow.clientMatches = YES;
        start(slow, YES);
        dispatch_sync(worker(slow), ^{
            for (int i = 0; i < 16; i++) {
                NSUInteger generation = [[slow valueForKey:@"connectionGeneration"] unsignedIntegerValue];
                [slow connectionFailedForGeneration:generation message:@"cold boot timeout"];
            }
        });
        require(slow.installations == 0, @"matching helper timeouts never trigger reinstall");
        require(slow.state == MPFPrivilegedMetricsRunnerStateFailed, @"cold boot retries are bounded");
        puts("PASS: 16 matching-helper timeouts end without reinstall or a password prompt");
        TestRunner *stopped = [TestRunner new]; stopped.scheduleRetries = YES;
        start(stopped, NO);
        dispatch_sync(worker(stopped), ^{ [stopped scheduleConnectionRetryAfter:0.04]; });
        [stopped stop]; flush(stopped); pauseBriefly(); flush(stopped);
        require(stopped.connections == 1, @"stopped session ignores pending reconnect");
        require(stopped.state == MPFPrivilegedMetricsRunnerStateIdle, @"stop stays idle");
        puts("PASS: delayed retry cannot reconnect after stop");
        TestRunner *restarted = [TestRunner new]; restarted.scheduleRetries = YES;
        start(restarted, NO);
        dispatch_sync(worker(restarted), ^{ [restarted scheduleConnectionRetryAfter:0.04]; });
        [restarted stop]; flush(restarted); start(restarted, NO);
        pauseBriefly(); flush(restarted);
        require(restarted.connections == 2, @"old retry cannot enter the new session");
        [restarted stop]; flush(restarted);
        puts("PASS: stop/start ignores previous session retry");
        return 0;
    }
}
