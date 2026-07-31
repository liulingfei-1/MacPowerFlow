// IOReportWrapper.h
#import <Foundation/Foundation.h>

typedef struct {
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
+ (IOReportData)fetchIOReportData;
+ (IOReportData)fetchIOReportDataWithSMC:(io_connect_t)smcConn;
@end
