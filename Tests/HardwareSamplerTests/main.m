// Deterministic transport fixtures exercise the production IOReport parser.
#import "../../PowerFlow/IOReportWrapper.m"
#include <assert.h>

static BOOL failSubscription = NO;
static BOOL failSample = NO;
static NSArray *fixtureChannels;
static int subscriptionAttempts;
// Independent SMC fixtures prove transport failure cannot erase thermal/fan data.
double SMCGetFloatValue(io_connect_t connection, const char *key) {
    if (!strcmp(key, "Tp0P")) return 55;
    if (!strcmp(key, "Tg0P")) return 66;
    if (!strcmp(key, "TCMz")) return 75;
    if (!strcmp(key, "F0Ac")) return 2100;
    if (!strcmp(key, "F1Ac")) return 1900;
    return 0;
}
int SMCGetKeyCount(io_connect_t connection) { return 0; }
kern_return_t SMCGetKeyFromIndex(io_connect_t connection, int index, char *key) { return kIOReturnNotFound; }
kern_return_t SMCGetKeyInfo(io_connect_t connection, const char *key, SMCKeyData_keyInfo_t *info) { return kIOReturnNotFound; }
CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef group, CFStringRef sub, uint64_t a, uint64_t b, uint64_t c) {
    return CFBridgingRetain(@{@"IOReportChannels": @[]});
}
void IOReportMergeChannels(CFDictionaryRef a, CFDictionaryRef b, void *c) {}
IOReportSubscriptionRef IOReportCreateSubscription(void *a, CFMutableDictionaryRef b, CFMutableDictionaryRef *c, uint64_t d, void *e) {
    subscriptionAttempts++;
    return failSubscription ? NULL : (IOReportSubscriptionRef)CFBridgingRetain(@{});
}
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef a, CFDictionaryRef b, void *c) {
    return failSample ? NULL : CFBridgingRetain(@{@"baseline": @YES});
}
CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef a, CFDictionaryRef b, void *c) {
    return CFBridgingRetain(@{@"IOReportChannels": fixtureChannels ?: @[]});
}
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef item, int32_t idx) { return [((__bridge NSDictionary *)item)[@"value"] longLongValue]; }
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef item) { return (__bridge CFStringRef)((__bridge NSDictionary *)item)[@"name"]; }
CFStringRef IOReportChannelGetGroup(CFDictionaryRef item) { return (__bridge CFStringRef)((__bridge NSDictionary *)item)[@"group"]; }
CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef item) { return CFSTR(""); }
CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef item) { return (__bridge CFStringRef)((__bridge NSDictionary *)item)[@"unit"]; }
int32_t IOReportStateGetCount(CFDictionaryRef item) { return 0; }
CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef item, int32_t idx) { return CFSTR(""); }
int64_t IOReportStateGetResidency(CFDictionaryRef item, int32_t idx) { return 0; }

static void advanceBaseline(void) {
    gPreviousTime = monotonicSeconds() - 2;
    gPreviousAwakeTime = NSProcessInfo.processInfo.systemUptime - 2;
    gPreviousWallTime = NSDate.date.timeIntervalSince1970 - 2;
}
static NSDictionary *channel(NSString *name, int64_t value, NSString *unit) {
    return @{@"group": @"Energy Model", @"name": name, @"value": @(value), @"unit": unit};
}
int main(void) { @autoreleasepool {
    assert(validFanRPM(NAN) == 0 && validFanRPM(INFINITY) == 0 && validFanRPM(2100) == 2100);
    assert(isUsableSampleWindow(2, 2));
    assert(!isUsableSampleWindow(0.001, 0.001));
    assert(!isUsableSampleWindow(31, 31));
    assert(!isUsableSampleWindow(2, 0.1));
    assert(!isUsableSampleWindow(NAN, 2));
    assert(energyToWatts(4000, CFSTR("mJ"), 2) == 2);
    assert(energyToWatts(4000000, CFSTR("uJ"), 2) == 2);
    assert(energyToWatts(4000000000LL, CFSTR("nJ"), 2) == 2);
    assert(energyToWatts(-4000, CFSTR("mJ"), 2) == 0);

    fixtureChannels = @[channel(@"CPU Energy", 4000, @"mJ"), channel(@"GPU Energy", 0, @"mJ")];
    IOReportData first = [IOReportWrapper fetchIOReportData];
    assert(first.sampleStatus == MPFSampleBaseline && !first.hasValidEnergySample);
    advanceBaseline();
    IOReportData valid = [IOReportWrapper fetchIOReportData];
    assert(valid.hasValidEnergySample && valid.sampleStatus == MPFSampleAvailable);
    assert((valid.powerAvailabilityMask & (MPFPowerCPU | MPFPowerGPU)) == (MPFPowerCPU | MPFPowerGPU));
    assert(valid.gpuPower == 0 && fabs(valid.cpuPower - 2) < 0.1);
    assert(!(valid.powerAvailabilityMask & MPFPowerANE));
    assert(valid.sampleDuration > 1.9 && valid.sampleEndTime > valid.sampleStartTime);

    fixtureChannels = @[channel(@"CPU Energy", -10, @"mJ"), channel(@"GPU Energy", 3000, @"mJ")];
    advanceBaseline();
    IOReportData negative = [IOReportWrapper fetchIOReportData];
    assert(negative.sampleStatus == MPFSampleReset && !negative.hasValidEnergySample);
    assert(negative.powerAvailabilityMask == 0 && negative.gpuPower == 0);

    fixtureChannels = @[channel(@"CPU Energy", 1, @"unknown"), channel(@"ANE Energy", INT64_MIN, @"mJ"), channel(@"GPU Energy", 0, @"mJ")];
    advanceBaseline();
    IOReportData unknown = [IOReportWrapper fetchIOReportData];
    assert(!(unknown.powerAvailabilityMask & MPFPowerCPU));
    assert(unknown.powerAvailabilityMask & MPFPowerGPU);
    assert(unknown.hasValidEnergySample && !(unknown.powerAvailabilityMask & MPFPowerANE));

    advanceBaseline(); gPreviousTime -= 31;
    assert([IOReportWrapper fetchIOReportData].sampleStatus == MPFSampleReset);
    advanceBaseline(); gPreviousAwakeTime += 1;
    assert([IOReportWrapper fetchIOReportData].sampleStatus == MPFSampleReset);
    [IOReportWrapper resetSamplingBaseline];
    assert([IOReportWrapper fetchIOReportData].sampleStatus == MPFSampleBaseline);

    [IOReportWrapper configureTemperatureKeys:@[@"Tp0P", @"Tg0P"]];
    failSample = YES;
    for (int i = 0; i < 3; ++i) {
        IOReportData failed = [IOReportWrapper fetchIOReportDataWithSMC:1];
        assert(failed.sampleStatus == MPFSampleUnavailable);
        assert(failed.cpuTemp == 55 && failed.gpuTemp == 66 && failed.cpuDieHotspot == 75);
        assert(failed.fanRPM == 2100 && failed.fan2RPM == 1900);
    }
    assert(gSubscription == NULL && gPreviousSample == NULL);
    failSample = NO; failSubscription = YES; gNextSubscriptionAttempt = 0;
    [IOReportWrapper fetchIOReportData];
    int attempts = subscriptionAttempts;
    [IOReportWrapper fetchIOReportData];
    assert(subscriptionAttempts == attempts); // retry backoff, not a tight rebuild loop
    failSubscription = NO; gNextSubscriptionAttempt = 0;
    assert([IOReportWrapper fetchIOReportData].sampleStatus == MPFSampleBaseline);
    advanceBaseline();
    assert([IOReportWrapper fetchIOReportData].hasValidEnergySample);
    clearSubscription();
    puts("PASS: continuous windows, units, zero versus absent, negative reset, unknown unit, long gap, sleep boundary, explicit reset, failure recovery/backoff, independent temperatures/fans");
} return 0; }
