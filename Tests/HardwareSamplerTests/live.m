#import "../../PowerFlow/IOReportWrapper.m"
#import "../../PowerFlow/SMC.h"
#include <assert.h>
#include <stdio.h>
int main(void) { @autoreleasepool {
    io_connect_t connection = SMCOpen();
    int validCount = 0;
    double cadence = 2.0;
    const char *configured = getenv("MPF_LIVE_INTERVAL");
    if (configured && atof(configured) >= 0.1) cadence = atof(configured);
    for (int i = 0; i < 6; i++) {
        double start = NSProcessInfo.processInfo.systemUptime;
        IOReportData sample = [IOReportWrapper fetchIOReportDataWithSMC:connection];
        double duration = NSProcessInfo.processInfo.systemUptime - start;
        printf("frame=%d status=%d interval=%.4f call=%.4f mask=%llu cpu=%.4f gpu=%.4f temp=%.2f fans=%d,%d\n", i, sample.sampleStatus, sample.sampleDuration, duration, (unsigned long long)sample.powerAvailabilityMask, sample.cpuPower, sample.gpuPower, sample.cpuTemp, sample.fanRPM, sample.fan2RPM);
        if (i == 0) assert(sample.sampleStatus == MPFSampleBaseline || sample.sampleStatus == MPFSampleUnavailable);
        if (sample.hasValidEnergySample) {
            validCount++;
            assert(sample.sampleDuration >= cadence * 0.9);
            assert(sample.sampleEndTime >= sample.sampleStartTime);
        }
        [NSThread sleepForTimeInterval:cadence];
    }
    [IOReportWrapper resetSamplingBaseline];
    IOReportData reset = [IOReportWrapper fetchIOReportDataWithSMC:connection];
    assert(!reset.hasValidEnergySample);
    if (connection != 0) SMCClose(connection);
    printf("LIVE: %d usable continuous frames; explicit reset status=%d\n", validCount, reset.sampleStatus);
    if (validCount == 0) { fputs("No live IOReport frames available; capability not verified.\n", stderr); return 2; }
} return 0; }
