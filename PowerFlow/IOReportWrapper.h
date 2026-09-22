// IOReportWrapper.h
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>

// Bits correspond to the documented domain order below, including real 0 W.
typedef NS_OPTIONS(uint64_t, MPFPowerAvailability) {
    MPFPowerCPU = 1ULL << 0, MPFPowerGPU = 1ULL << 1,
    MPFPowerANE = 1ULL << 2, MPFPowerDRAM = 1ULL << 3,
    MPFPowerGPUSRAM = 1ULL << 4, MPFPowerMedia = 1ULL << 5,
    MPFPowerISP = 1ULL << 6, MPFPowerFabric = 1ULL << 7,
    MPFPowerPCIe = 1ULL << 8, MPFPowerDisplaySoC = 1ULL << 9,
    MPFPowerDisplayExt = 1ULL << 10
};
typedef NS_ENUM(int32_t, MPFSampleStatus) {
    MPFSampleUnavailable = 0, MPFSampleBaseline = 1,
    MPFSampleAvailable = 2, MPFSampleReset = 3
};

typedef struct {
    uint64_t powerAvailabilityMask;
    double sampleStartTime; // Date epoch seconds, for display/export only
    double sampleEndTime;
    double sampleDuration; // Actual monotonic energy integration interval
    BOOL hasValidEnergySample;
    int32_t sampleStatus;

    double cpuPower;        // Watts — aggregate CPU Energy (E+P cores)
    double gpuPower;        // Watts — GPU Energy
    double anePower;        // Watts — Neural Engine Energy
    double dramPower;       // Watts — DRAM Energy
    double gpuSRAMPower;    // Watts — GPU SRAM Energy
    double mediaPower;      // Watts — AVE/MSR media engines
    double ispPower;        // Watts — Image Signal Processor
    double fabricPower;     // Watts — AMCC/DCS/FAB/AFR interconnect
    double pciePower;       // Watts — aggregate PCIe controllers/ports
    double displaySoCPower; // Watts — SoC display controller
    double displayExtPower; // Watts — external display controller
    double systemPower;     // Watts — total board power (SMC PSTR)
    double cpuTemp;         // Celsius — average across CPU core sensors (SMC Tp*/Te*)
    double cpuDieHotspot;   // Celsius — absolute hottest CPU die point (SMC TCMz)
    double gpuTemp;         // Celsius — average across GPU sensors (SMC Tg*)
    double gpuUsage;        // Percent (0-100)
    int    gpuFreqMHz;
    double eClusterActive;  // Percent (0-100) — Efficiency cluster
    double pClusterActive;  // Percent (0-100) — Performance cluster (M1-M4) or Medium tier (M5+)
    int    eClusterFreqMHz;
    int    pClusterFreqMHz;
    double sClusterActive;  // Percent (0-100) — Super cluster (M5+ only)
    int    sClusterFreqMHz;
    int64_t dramReadBytes;  // Bytes per second — DRAM read bandwidth
    int64_t dramWriteBytes; // Bytes per second — DRAM write bandwidth
    int32_t fanRPM;         // RPM — Fan 0 actual speed (SMC F0Ac); 0 on fanless models
    int32_t fan2RPM;        // RPM — Fan 1 actual speed (SMC F1Ac); 0 when absent
} IOReportData;

@interface IOReportWrapper : NSObject
// Serialized by HardwareSampler, just like sampling. Clears cross-sleep deltas.
+ (void)resetSamplingBaseline;
// Reuses HardwareSampler's discovery; no second complete SMC enumeration.
+ (void)configureTemperatureKeys:(NSArray<NSString *> *)keys;
+ (IOReportData)fetchIOReportData;
+ (IOReportData)fetchIOReportDataWithSMC:(io_connect_t)smcConn;
@end
