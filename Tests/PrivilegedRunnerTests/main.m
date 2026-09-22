#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "../../PowerFlow/PrivilegedMetricsRunner.h"
#import "../../Shared/PrivilegedMetricsXPCProtocol.h"

// Exercise the production state machine without touching launchd or authd.
@interface MPFPrivilegedMetricsRunner (Testing)
- (void)connectToInstalledHelper;
- (NSString *)exactRequirementForBundledHelper:(NSError **)error;
- (BOOL)codeAtURL:(NSURL *)url matchesExactRequirement:(NSString *)requirement;
- (BOOL)installedConfigurationMatchesCurrentClient;
- (BOOL)runAuthorizedInstaller:(NSError **)error;
- (void)connectionFailedForGeneration:(NSUInteger)generation message:(NSString *)message;
- (void)scheduleConnectionRetryAfter:(NSTimeInterval)delay;
- (void)receivedProtocolVersion:(NSInteger)version generation:(NSUInteger)generation;
- (void)requestSamplingForGeneration:(NSUInteger)generation;
- (id<MPFPrivilegedMetricsClientProtocol>)receiverForGeneration:(NSUInteger)generation;
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

@interface SamplingProxy : NSObject <MPFPrivilegedMetricsServiceProtocol>
@property NSInteger interval;
@property NSUInteger starts;
@property BOOL busy;
@end
@implementation SamplingProxy
- (void)protocolVersionWithReply:(void (^)(NSInteger))reply { reply(2); }
- (void)startSamplingWithReply:(void (^)(BOOL, NSString *))reply { self.starts++; reply(NO, @"Legacy selector must not be used"); }
- (void)startSamplingWithInterval:(NSInteger)seconds reply:(void (^)(BOOL, NSString *))reply {
    self.interval = seconds; self.starts++; reply(!self.busy, self.busy ? @"MPF_RETRY_SESSION_BUSY" : nil);
}
- (void)stopSamplingWithReply:(void (^)(BOOL, NSString *))reply { reply(YES, nil); }
- (void)queryLowPowerModeForSource:(NSInteger)source reply:(void (^)(BOOL, BOOL, NSString *))reply { reply(NO, NO, @"Not expected"); }
- (void)setLowPowerModeForSource:(NSInteger)source enabled:(NSInteger)enabled reply:(void (^)(BOOL, BOOL, NSString *))reply { reply(NO, NO, @"Not expected"); }
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
        for (NSNumber *interval in @[@2, @5, @10]) {
            TestRunner *runner = [TestRunner new];
            require([runner configureSamplingInterval:interval.integerValue], @"allowed cadence accepted");
            require(![runner configureSamplingInterval:3], @"arbitrary cadence rejected");
            start(runner, NO);
            require(![runner configureSamplingInterval:2], @"active runner cannot mutate cadence in place");
            SamplingProxy *proxy = [SamplingProxy new];
            [runner setValue:proxy forKey:@"serviceProxy"];
            dispatch_sync(worker(runner), ^{ [runner receivedProtocolVersion:2 generation:0]; });
            flush(runner);
            require(proxy.starts == 1 && proxy.interval == interval.integerValue, @"selected cadence actually crosses v2 XPC");
            [runner stop]; flush(runner);
        }
        puts("PASS: fixed 2/5/10 second intervals cross XPC; invalid and in-place interval changes rejected");
        TestRunner *oldProtocol = [TestRunner new];
        start(oldProtocol, NO);
        SamplingProxy *oldProxy = [SamplingProxy new];
        [oldProtocol setValue:oldProxy forKey:@"serviceProxy"];
        dispatch_sync(worker(oldProtocol), ^{ [oldProtocol receivedProtocolVersion:1 generation:0]; });
        require(oldProtocol.state == MPFPrivilegedMetricsRunnerStateFailed && oldProxy.starts == 0,
                @"v1 helper rejected before sending unknown v2 selector");
        require(oldProtocol.installations == 0, @"protocol mismatch never authorizes implicitly");
        puts("PASS: v1 helper fails safely before new selector and never auto-installs");
        TestRunner *busy = [TestRunner new];
        start(busy, NO);
        SamplingProxy *busyProxy = [SamplingProxy new]; busyProxy.busy = YES;
        [busy setValue:busyProxy forKey:@"serviceProxy"];
        dispatch_sync(worker(busy), ^{ [busy receivedProtocolVersion:2 generation:0]; });
        flush(busy); [busy stop]; flush(busy);
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
        flush(busy);
        require(busyProxy.starts == 1 && busy.state == MPFPrivilegedMetricsRunnerStateIdle,
                @"pending cadence-start handoff retry cannot undo stop");
        puts("PASS: busy-session start retry stays cancelled after stop");
        TestRunner *invalidPower = [TestRunner new];
        __block BOOL rejected = NO;
        [invalidPower setLowPowerModeForSource:99 enabled:YES completion:^(BOOL success, BOOL actual, NSString *message) {
            rejected = !success && message.length > 0;
        }];
        pauseBriefly();
        require(rejected && invalidPower.connections == 0 && invalidPower.installations == 0,
                @"invalid power source rejected before connection/auth");
        puts("PASS: invalid low-power source never connects or authorizes");
        TestRunner *callbacks = [TestRunner new];
        __block NSUInteger received = 0;
        [callbacks startAllowingInstallation:NO dataHandler:^(NSData *data) { received++; }
                               stateHandler:^(MPFPrivilegedMetricsRunnerState state, NSString *message) {}];
        flush(callbacks);
        id<MPFPrivilegedMetricsClientProtocol> oldReceiver = [callbacks receiverForGeneration:0];
        [callbacks stop]; flush(callbacks);
        [callbacks startAllowingInstallation:NO dataHandler:^(NSData *data) { received++; }
                               stateHandler:^(MPFPrivilegedMetricsRunnerState state, NSString *message) {}];
        flush(callbacks);
        [oldReceiver receiveData:[NSData dataWithBytes:"old" length:3]];
        [oldReceiver serviceDidFail:@"old connection failure"];
        flush(callbacks); pauseBriefly();
        require(received == 0 && callbacks.isRunning, @"old connection cannot deliver to or stop new stream");
        NSUInteger generation = [[callbacks valueForKey:@"connectionGeneration"] unsignedIntegerValue];
        id<MPFPrivilegedMetricsClientProtocol> receiver = [callbacks receiverForGeneration:generation];
        [receiver receiveData:[NSData dataWithBytes:"new" length:3]];
        flush(callbacks); pauseBriefly();
        require(received == 1, @"current connection continues delivering data");
        [receiver serviceDidFail:@"current failure"]; flush(callbacks);
        require(callbacks.state == MPFPrivilegedMetricsRunnerStateFailed, @"current connection failure remains actionable");
        puts("PASS: connection-bound receiver rejects stale data/failure across cadence restart");
        return 0;
    }
}
