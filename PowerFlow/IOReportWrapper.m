// IOReportWrapper.m
#import "IOReportWrapper.h"
#import "SMC.h"
#import <IOKit/IOKitLib.h>
#import <IOKit/hidsystem/IOHIDEventSystemClient.h>
#import <IOKit/hidsystem/IOHIDServiceClient.h>
#include <string.h>
#include <time.h>

typedef struct IOReportSubscriptionRef *IOReportSubscriptionRef;
#define MPF_WEAK_IMPORT __attribute__((weak_import))

extern CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef group, CFStringRef subgroup, uint64_t a, uint64_t b, uint64_t c) MPF_WEAK_IMPORT;
extern void IOReportMergeChannels(CFDictionaryRef a, CFDictionaryRef b, void *c) MPF_WEAK_IMPORT;
extern IOReportSubscriptionRef IOReportCreateSubscription(void *a, CFMutableDictionaryRef channels, CFMutableDictionaryRef *subsystem, uint64_t b, void *c) MPF_WEAK_IMPORT;
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef sub, CFDictionaryRef channels, void *a) MPF_WEAK_IMPORT;
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef a, CFDictionaryRef b, void *c) MPF_WEAK_IMPORT;
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef item, int32_t idx) MPF_WEAK_IMPORT;
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef item) MPF_WEAK_IMPORT;
extern CFStringRef IOReportChannelGetGroup(CFDictionaryRef item) MPF_WEAK_IMPORT;
extern CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef item) MPF_WEAK_IMPORT;
extern CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef item) MPF_WEAK_IMPORT;
extern int32_t IOReportStateGetCount(CFDictionaryRef item) MPF_WEAK_IMPORT;
extern CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef item, int32_t idx) MPF_WEAK_IMPORT;
extern int64_t IOReportStateGetResidency(CFDictionaryRef item, int32_t idx) MPF_WEAK_IMPORT;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator) MPF_WEAK_IMPORT;
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreateSimpleClient(CFAllocatorRef allocator) MPF_WEAK_IMPORT;
extern void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef matching) MPF_WEAK_IMPORT;
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client) MPF_WEAK_IMPORT;
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef key) MPF_WEAK_IMPORT;
typedef void *IOHIDEventRef;
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timeout) MPF_WEAK_IMPORT;
extern double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field) MPF_WEAK_IMPORT;

#define kHIDPageAppleVendor 0xff00
#define kHIDUsageAppleVendorTemperatureSensor 0x0005
#define kIOHIDEventTypeTemperature 15

@implementation IOReportWrapper

static IOReportSubscriptionRef gSubscription = NULL;
static CFMutableDictionaryRef gChannels = NULL;
static IOHIDEventSystemClientRef gHIDClient = NULL;
static CFDictionaryRef gHIDMatching = NULL;
static uint32_t gGpuFreqs[64];
static int gGpuFreqCount = 0;
static uint32_t gECoreFreqs[64];
static int gECoreFreqCount = 0;
static uint32_t gPCoreFreqs[64];
static int gPCoreFreqCount = 0;
static uint32_t gMCoreFreqs[64];  // M5+ medium cluster
static int gMCoreFreqCount = 0;
static char gCpuTempKeys[64][5];
static int gCpuTempKeyCount = 0;
static char gGpuTempKeys[64][5];
static int gGpuTempKeyCount = 0;

static BOOL ioReportFunctionsAvailable(void) {
    return IOReportCopyChannelsInGroup != NULL
        && IOReportMergeChannels != NULL
        && IOReportCreateSubscription != NULL
        && IOReportCreateSamples != NULL
        && IOReportCreateSamplesDelta != NULL
        && IOReportSimpleGetIntegerValue != NULL
        && IOReportChannelGetChannelName != NULL
        && IOReportChannelGetGroup != NULL
        && IOReportChannelGetSubGroup != NULL
        && IOReportChannelGetUnitLabel != NULL
        && IOReportStateGetCount != NULL
        && IOReportStateGetNameForIndex != NULL
        && IOReportStateGetResidency != NULL;
}

static BOOL hidTemperatureFunctionsAvailable(void) {
    return (IOHIDEventSystemClientCreate != NULL
            || IOHIDEventSystemClientCreateSimpleClient != NULL)
        && IOHIDEventSystemClientCopyServices != NULL
        && IOHIDServiceClientCopyProperty != NULL
        && IOHIDServiceClientCopyEvent != NULL
        && IOHIDEventGetFloatValue != NULL;
}

static BOOL isCFType(CFTypeRef value, CFTypeID expectedType) {
    return value != NULL && CFGetTypeID(value) == expectedType;
}

static BOOL copyCFString(CFTypeRef value, char *buffer, CFIndex capacity) {
    if (!isCFType(value, CFStringGetTypeID()) || buffer == NULL || capacity <= 0) {
        return NO;
    }
    return CFStringGetCString(
        (CFStringRef)value,
        buffer,
        capacity,
        kCFStringEncodingUTF8
    );
}

static CFDictionaryRef copyIOReportChannels(CFStringRef group) {
    if (!ioReportFunctionsAvailable()) {
        return NULL;
    }

    CFDictionaryRef channels = IOReportCopyChannelsInGroup(group, NULL, 0, 0, 0);
    if (!isCFType(channels, CFDictionaryGetTypeID())) {
        if (channels != NULL) {
            CFRelease(channels);
        }
        return NULL;
    }
    return channels;
}

static void mergeIOReportGroup(
    CFMutableDictionaryRef destination,
    CFStringRef group
) {
    if (!isCFType(destination, CFDictionaryGetTypeID())) {
        return;
    }

    CFDictionaryRef source = copyIOReportChannels(group);
    if (source != NULL) {
        IOReportMergeChannels(destination, source, NULL);
        CFRelease(source);
    }
}

static CFArrayRef ioReportChannelArray(CFTypeRef delta) {
    if (!isCFType(delta, CFDictionaryGetTypeID())) {
        return NULL;
    }
    CFTypeRef value = CFDictionaryGetValue(
        (CFDictionaryRef)delta,
        CFSTR("IOReportChannels")
    );
    return isCFType(value, CFArrayGetTypeID()) ? (CFArrayRef)value : NULL;
}

static double monotonicSeconds(void) {
    struct timespec timestamp = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &timestamp) != 0) {
        return 0;
    }
    return (double)timestamp.tv_sec + (double)timestamp.tv_nsec / 1000000000.0;
}

static IOHIDEventSystemClientRef getHIDClient(void) {
    if (!hidTemperatureFunctionsAvailable()) {
        return NULL;
    }

    if (gHIDClient == NULL) {
        if (IOHIDEventSystemClientCreate != NULL) {
            gHIDClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        }
        if (gHIDClient == NULL
                && IOHIDEventSystemClientCreateSimpleClient != NULL) {
            gHIDClient = IOHIDEventSystemClientCreateSimpleClient(
                kCFAllocatorDefault
            );
        }

        if (gHIDClient != NULL
                && IOHIDEventSystemClientSetMatching != NULL
                && gHIDMatching == NULL) {
            const void *keys[2] = {CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage")};
            int page = kHIDPageAppleVendor;
            int usage = kHIDUsageAppleVendorTemperatureSensor;
            CFNumberRef pageNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &page);
            CFNumberRef usageNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usage);
            if (pageNumber != NULL && usageNumber != NULL) {
                const void *values[2] = {pageNumber, usageNumber};
                gHIDMatching = CFDictionaryCreate(
                    kCFAllocatorDefault,
                    keys,
                    values,
                    2,
                    &kCFTypeDictionaryKeyCallBacks,
                    &kCFTypeDictionaryValueCallBacks
                );
            }
            if (pageNumber != NULL) {
                CFRelease(pageNumber);
            }
            if (usageNumber != NULL) {
                CFRelease(usageNumber);
            }
        }
        if (gHIDClient != NULL
                && gHIDMatching != NULL
                && IOHIDEventSystemClientSetMatching != NULL) {
            IOHIDEventSystemClientSetMatching(gHIDClient, gHIDMatching);
        }
    }
    return gHIDClient;
}

static BOOL isTemperatureSMCKey(SMCKeyData_keyInfo_t keyInfo) {
    return keyInfo.dataType == 1718383648   // flt  — IEEE 754 float
        || keyInfo.dataType == 1936734008;  // sp78 — signed fixed-point 7.8 (Apple Silicon temp sensors)
}

static BOOL isValidTemperature(double value) {
    return value > 10.0 && value < 150.0;
}

static void loadTemperatureKeys(io_connect_t smcConn) {
    if (smcConn == 0 || gCpuTempKeyCount > 0 || gGpuTempKeyCount > 0) {
        return;
    }

    int totalKeys = SMCGetKeyCount(smcConn);
    for (int index = 0; index < totalKeys; index++) {
        char key[5] = {0};
        if (SMCGetKeyFromIndex(smcConn, index, key) != kIOReturnSuccess) {
            continue;
        }

        SMCKeyData_keyInfo_t keyInfo;
        if (SMCGetKeyInfo(smcConn, key, &keyInfo) != kIOReturnSuccess || !isTemperatureSMCKey(keyInfo)) {
            continue;
        }

        if (key[0] != 'T') {
            continue;
        }

        if ((key[1] == 'p' || key[1] == 'e' || key[1] == 's') && gCpuTempKeyCount < 64) {
            strcpy(gCpuTempKeys[gCpuTempKeyCount++], key);
        } else if (key[1] == 'g' && gGpuTempKeyCount < 64) {
            strcpy(gGpuTempKeys[gGpuTempKeyCount++], key);
        }
    }
}

static double averageSMCTemperature(io_connect_t smcConn, char keys[][5], int keyCount) {
    if (smcConn == 0 || keyCount == 0) {
        return 0;
    }

    double sum = 0;
    int count = 0;
    for (int index = 0; index < keyCount; index++) {
        double value = SMCGetFloatValue(smcConn, keys[index]);
        if (!isValidTemperature(value)) {
            continue;
        }
        sum += value;
        count++;
    }

    return count > 0 ? sum / (double)count : 0;
}

static BOOL isCPUTemperatureService(const char *product) {
    return strstr(product, "PMU tdie") != NULL
        || strstr(product, "eACC") != NULL
        || strstr(product, "pACC") != NULL
        || strstr(product, "sACC") != NULL
        || strstr(product, "mACC") != NULL;
}

static BOOL isGPUTemperatureService(const char *product) {
    return strstr(product, "GPU") != NULL;
}

static double averageHIDTemperature(BOOL gpu) {
    if (!hidTemperatureFunctionsAvailable()) {
        return 0;
    }

    IOHIDEventSystemClientRef client = getHIDClient();
    if (client == NULL) {
        return 0;
    }

    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (!isCFType(services, CFArrayGetTypeID())) {
        if (services != NULL) {
            CFRelease(services);
        }
        return 0;
    }

    double sum = 0;
    int count = 0;
    CFIndex serviceCount = CFArrayGetCount(services);
    for (CFIndex index = 0; index < serviceCount; index++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, index);
        if (service == NULL) {
            continue;
        }

        CFTypeRef productValue = IOHIDServiceClientCopyProperty(
            service,
            CFSTR("Product")
        );
        if (!isCFType(productValue, CFStringGetTypeID())) {
            if (productValue != NULL) {
                CFRelease(productValue);
            }
            continue;
        }

        char product[512] = {0};
        BOOL copiedProduct = copyCFString(
            productValue,
            product,
            (CFIndex)sizeof(product)
        );

        BOOL matches = copiedProduct
            && (gpu
                ? isGPUTemperatureService(product)
                : isCPUTemperatureService(product));
        if (!matches) {
            CFRelease(productValue);
            continue;
        }

        IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0);
        CFRelease(productValue);
        if (event == NULL) {
            continue;
        }

        double value = IOHIDEventGetFloatValue(event, kIOHIDEventTypeTemperature << 16);
        CFRelease(event);
        if (!isValidTemperature(value)) {
            continue;
        }

        sum += value;
        count++;
    }

    CFRelease(services);
    return count > 0 ? sum / (double)count : 0;
}

static double resolveCPUTemperature(io_connect_t smcConn) {
    loadTemperatureKeys(smcConn);
    double value = averageSMCTemperature(smcConn, gCpuTempKeys, gCpuTempKeyCount);
    return value > 0 ? value : averageHIDTemperature(NO);
}

static double resolveGPUTemperature(io_connect_t smcConn) {
    loadTemperatureKeys(smcConn);
    double value = averageSMCTemperature(smcConn, gGpuTempKeys, gGpuTempKeyCount);
    return value > 0 ? value : averageHIDTemperature(YES);
}

static void parseFreqData(CFDataRef data, uint32_t *outFreqs, int *outCount) {
    if (outCount == NULL) {
        return;
    }
    *outCount = 0;
    if (!isCFType(data, CFDataGetTypeID()) || outFreqs == NULL) {
        return;
    }

    const uint8_t *bytes = CFDataGetBytePtr(data);
    CFIndex len = CFDataGetLength(data);
    if (bytes == NULL || len < (CFIndex)sizeof(uint32_t)) {
        return;
    }
    int totalEntries = (int)(len / 8);

    for (int i = 0; i < totalEntries && *outCount < 64; i++) {
        uint32_t raw = 0;
        memcpy(&raw, bytes + (i * 8), sizeof(uint32_t));

        uint32_t mhz = 0;
        if (raw >= 100000000) {
            mhz = raw / 1000000;
        } else if (raw >= 100000) {
            mhz = raw / 1000;
        }

        if (mhz > 0) {
            outFreqs[(*outCount)++] = mhz;
        }
    }
}

static void loadCpuFrequencies(void) {
    if (gECoreFreqCount > 0 && gPCoreFreqCount > 0) { return; }

    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iterator) != kIOReturnSuccess) {
        return;
    }

    io_object_t entry = 0;
    while ((entry = IOIteratorNext(iterator)) != 0) {
        io_name_t name = {0};
        IORegistryEntryGetName(entry, name);

        if (strcmp(name, "pmgr") == 0) {
            CFMutableDictionaryRef properties = NULL;
            if (IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == kIOReturnSuccess && properties != NULL) {
                // E-cluster frequencies (voltage-states1-sram on M1-M4, voltage-states9-sram on M5+)
                if (gECoreFreqCount == 0) {
                    parseFreqData((CFDataRef)CFDictionaryGetValue(properties, CFSTR("voltage-states1-sram")), gECoreFreqs, &gECoreFreqCount);
                }
                if (gECoreFreqCount == 0) {
                    parseFreqData((CFDataRef)CFDictionaryGetValue(properties, CFSTR("voltage-states9-sram")), gECoreFreqs, &gECoreFreqCount);
                }
                // P-cluster frequencies (voltage-states5-sram primary, voltage-states3-sram fallback)
                if (gPCoreFreqCount == 0) {
                    parseFreqData((CFDataRef)CFDictionaryGetValue(properties, CFSTR("voltage-states5-sram")), gPCoreFreqs, &gPCoreFreqCount);
                }
                if (gPCoreFreqCount == 0) {
                    parseFreqData((CFDataRef)CFDictionaryGetValue(properties, CFSTR("voltage-states3-sram")), gPCoreFreqs, &gPCoreFreqCount);
                }
                // M5+ medium cluster (MCPU) uses voltage-states22-sram; fall back to P-cluster table
                if (gMCoreFreqCount == 0) {
                    parseFreqData((CFDataRef)CFDictionaryGetValue(properties, CFSTR("voltage-states22-sram")), gMCoreFreqs, &gMCoreFreqCount);
                }
                if (gMCoreFreqCount == 0 && gPCoreFreqCount > 0) {
                    memcpy(gMCoreFreqs, gPCoreFreqs, gPCoreFreqCount * sizeof(uint32_t));
                    gMCoreFreqCount = gPCoreFreqCount;
                }
                CFRelease(properties);
            }
        }

        IOObjectRelease(entry);
    }

    IOObjectRelease(iterator);
}

static void loadGpuFrequencies(void) {
    if (gGpuFreqCount > 0) { return; }

    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iterator) != kIOReturnSuccess) {
        return;
    }

    io_object_t entry = 0;
    while ((entry = IOIteratorNext(iterator)) != 0) {
        io_name_t name = {0};
        IORegistryEntryGetName(entry, name);

        if (strcmp(name, "pmgr") == 0 || strcmp(name, "clpc") == 0) {
            CFMutableDictionaryRef properties = NULL;
            if (IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == kIOReturnSuccess && properties != NULL) {
                CFDataRef preferred = (CFDataRef)CFDictionaryGetValue(properties, CFSTR("voltage-states9-sram"));
                if (preferred == NULL) {
                    preferred = (CFDataRef)CFDictionaryGetValue(properties, CFSTR("voltage-states9"));
                }

                if (preferred != NULL) {
                    parseFreqData(preferred, gGpuFreqs, &gGpuFreqCount);
                }

                CFRelease(properties);
            }
        }

        IOObjectRelease(entry);
    }

    IOObjectRelease(iterator);
}

static double energyToWatts(int64_t energy, CFStringRef unitRef, double durationSeconds) {
    if (durationSeconds <= 0 || !isCFType(unitRef, CFStringGetTypeID())) {
        return 0;
    }

    if (CFStringCompare(unitRef, CFSTR("mJ"), 0) == kCFCompareEqualTo) {
        return (double)energy / (1000.0 * durationSeconds);
    }
    if (CFStringCompare(unitRef, CFSTR("uJ"), 0) == kCFCompareEqualTo) {
        return (double)energy / (1000000.0 * durationSeconds);
    }
    if (CFStringCompare(unitRef, CFSTR("nJ"), 0) == kCFCompareEqualTo) {
        return (double)energy / (1000000000.0 * durationSeconds);
    }
    return 0;
}

// Whether AMC Stats produced useful DRAM bandwidth data (probed at init).
// On M5+ chips, AMC Stats channels exist but the kernel blocks them; we use PMP instead.
static BOOL gAmcStatsProducesData = NO;

+ (void)initialize {
    if (self != [IOReportWrapper class] || gChannels != NULL) {
        return;
    }
    if (!ioReportFunctionsAvailable()) {
        return;
    }

    CFDictionaryRef energyChannels = copyIOReportChannels(
        CFSTR("Energy Model")
    );
    if (energyChannels == NULL) {
        energyChannels = copyIOReportChannels(CFSTR("Energy Counters"));
        if (energyChannels == NULL) {
            return;
        }
    }

    gChannels = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, CFDictionaryGetCount(energyChannels), energyChannels);
    CFRelease(energyChannels);

    if (gChannels == NULL) {
        return;
    }

    // macOS 27 starts migrating some power channels to "Energy Counters".
    // Merge the successor group when available while retaining compatibility
    // with the classic "Energy Model" channels.
    mergeIOReportGroup(gChannels, CFSTR("Energy Counters"));
    mergeIOReportGroup(gChannels, CFSTR("GPU Stats"));
    mergeIOReportGroup(gChannels, CFSTR("CPU Stats"));

    // Subscribe AMC Stats first to probe if it produces data on this chip.
    // On M5+ the kernel blocks AMC Stats; we then fall through to PMP.
    mergeIOReportGroup(gChannels, CFSTR("AMC Stats"));

    CFMutableDictionaryRef subsystem = NULL;
    gSubscription = IOReportCreateSubscription(NULL, gChannels, &subsystem, 0, NULL);
    if (subsystem != NULL) { CFRelease(subsystem); }

    // Probe AMC Stats with a 50 ms sample to see if it actually delivers data.
    // If it does, we trust AMC directly. If not (M5+), merge PMP channels in.
    if (gSubscription != NULL) {
        CFDictionaryRef probe1 = IOReportCreateSamples(gSubscription, gChannels, NULL);
        [NSThread sleepForTimeInterval:0.05];
        CFDictionaryRef probe2 = IOReportCreateSamples(gSubscription, gChannels, NULL);

        if (isCFType(probe1, CFDictionaryGetTypeID())
                && isCFType(probe2, CFDictionaryGetTypeID())) {
            CFDictionaryRef delta = IOReportCreateSamplesDelta(probe1, probe2, NULL);
            if (delta != NULL) {
                CFArrayRef channels = ioReportChannelArray(delta);
                if (channels != NULL) {
                    CFIndex n = CFArrayGetCount(channels);
                    for (CFIndex i = 0; i < n && !gAmcStatsProducesData; i++) {
                        CFTypeRef channelValue = CFArrayGetValueAtIndex(
                            channels,
                            i
                        );
                        if (!isCFType(channelValue, CFDictionaryGetTypeID())) {
                            continue;
                        }
                        CFDictionaryRef ch = (CFDictionaryRef)channelValue;
                        CFStringRef grpRef = IOReportChannelGetGroup(ch);
                        char grp[64] = {0};
                        if (!copyCFString(grpRef, grp, (CFIndex)sizeof(grp))) {
                            continue;
                        }
                        if (strcmp(grp, "AMC Stats") == 0) {
                            int64_t v = IOReportSimpleGetIntegerValue(ch, 0);
                            if (v > 0) { gAmcStatsProducesData = YES; }
                        }
                    }
                }
                CFRelease(delta);
            }
        }
        if (probe1 != NULL) CFRelease(probe1);
        if (probe2 != NULL) CFRelease(probe2);
    }

    // If AMC Stats is blocked (M5+), subscribe to PMP for DRAM bandwidth instead.
    if (!gAmcStatsProducesData) {
        CFDictionaryRef pmpChannels = copyIOReportChannels(CFSTR("PMP"));
        if (pmpChannels != NULL) {
            IOReportMergeChannels(gChannels, pmpChannels, NULL);
            CFRelease(pmpChannels);
            // Re-create subscription with PMP included.
            // (IOReport subscriptions are not re-subscribable after the fact.)
            if (gSubscription != NULL) {
                CFRelease((CFTypeRef)gSubscription);
                gSubscription = NULL;
            }
            CFMutableDictionaryRef sub2 = NULL;
            gSubscription = IOReportCreateSubscription(
                NULL,
                gChannels,
                &sub2,
                0,
                NULL
            );
            if (sub2 != NULL) CFRelease(sub2);
        }
    }

    loadGpuFrequencies();
    loadCpuFrequencies();
}

+ (IOReportData)fetchIOReportData {
    return [self fetchIOReportDataWithSMC:0];
}

+ (IOReportData)fetchIOReportDataWithSMC:(io_connect_t)smcConn {
    IOReportData data = {0};
    if (!ioReportFunctionsAvailable()
            || gSubscription == NULL
            || !isCFType(gChannels, CFDictionaryGetTypeID())) {
        return data;
    }

    // A 100 ms window is too short for the Energy Model counters on recent
    // macOS releases: the GPU channel can occasionally report an empty frame
    // or turn a very short burst into a misleading one-frame power spike.
    // Average over 500 ms instead. This remains comfortably below the app's
    // two-second refresh cadence while matching the stability expected from a
    // user-facing power meter.
    const double interval = 0.5;

    CFDictionaryRef sample1 = IOReportCreateSamples(gSubscription, gChannels, NULL);
    if (!isCFType(sample1, CFDictionaryGetTypeID())) {
        if (sample1 != NULL) {
            CFRelease(sample1);
        }
        return data;
    }
    double sample1Time = monotonicSeconds();

    [NSThread sleepForTimeInterval:interval];

    CFDictionaryRef sample2 = IOReportCreateSamples(gSubscription, gChannels, NULL);
    double sample2Time = monotonicSeconds();
    if (!isCFType(sample2, CFDictionaryGetTypeID())) {
        CFRelease(sample1);
        if (sample2 != NULL) {
            CFRelease(sample2);
        }
        return data;
    }

    double sampleSeconds = interval;
    if (sample1Time > 0 && sample2Time > sample1Time) {
        sampleSeconds = sample2Time - sample1Time;
    }

    CFDictionaryRef delta = IOReportCreateSamplesDelta(sample1, sample2, NULL);
    CFRelease(sample1);
    CFRelease(sample2);

    if (delta == NULL) {
        return data;
    }

    CFArrayRef channels = ioReportChannelArray(delta);
    if (channels == NULL) {
        CFRelease(delta);
        return data;
    }

    // Accumulators for M5+ medium cluster (MCPU0, MCPU1 …)
    double mClusterActiveSum = 0;
    int    mClusterFreqMax   = 0;
    int    mClusterCount     = 0;
    // PCPU on M5+ is the Super cluster; on M1-M4 it's the Performance cluster.
    double pcpuActive        = 0;
    int    pcpuFreq          = 0;
    BOOL   hasPCPU           = NO;
    // PMP DRAM bandwidth (M5+ fallback)
    int64_t pmpDramReadBytes  = 0;
    int64_t pmpDramWriteBytes = 0;
    // Newer systems expose per-cluster CPU energy names such as
    // "eCPUs Energy" / "pCPUs Energy" instead of a single "CPU Energy".
    // Keep aggregate and typed buckets separate to avoid double counting.
    double cpuTotalEnergyW = 0;
    double cpuTypedEnergyW = 0;

    CFIndex count = CFArrayGetCount(channels);
    for (CFIndex i = 0; i < count; i++) {
        CFTypeRef channelValue = CFArrayGetValueAtIndex(channels, i);
        if (!isCFType(channelValue, CFDictionaryGetTypeID())) {
            continue;
        }
        CFDictionaryRef channel = (CFDictionaryRef)channelValue;

        CFStringRef groupRef = IOReportChannelGetGroup(channel);
        CFStringRef nameRef  = IOReportChannelGetChannelName(channel);

        // Use C strings in the hot path — avoids repeated ObjC bridge allocations.
        char grp[64]  = {0};
        char chn[256] = {0};
        if (!copyCFString(groupRef, grp, (CFIndex)sizeof(grp))
                || !copyCFString(nameRef, chn, (CFIndex)sizeof(chn))) {
            continue;
        }

        int64_t value = IOReportSimpleGetIntegerValue(channel, 0);

        if (strcmp(grp, "Energy Model") == 0 || strcmp(grp, "Energy Counters") == 0) {
            double watts = energyToWatts(value, IOReportChannelGetUnitLabel(channel), sampleSeconds);
            BOOL isTypedCPU =
                strstr(chn, "ECPU Energy") != NULL ||
                strstr(chn, "PCPU Energy") != NULL ||
                strstr(chn, "MCPU Energy") != NULL ||
                strstr(chn, "eCPUs Energy") != NULL ||
                strstr(chn, "pCPUs Energy") != NULL ||
                strstr(chn, "mCPUs Energy") != NULL;
            if (isTypedCPU) {
                cpuTypedEnergyW += watts;
            } else if (strstr(chn, "CPU Energy") != NULL) {
                cpuTotalEnergyW += watts;
            } else if (strcmp(chn, "GPU Energy") == 0) {
                data.gpuPower += watts;
            } else if (strncmp(chn, "ANE", 3) == 0) {
                data.anePower += watts;
            } else if (strncmp(chn, "DRAM", 4) == 0) {
                data.dramPower += watts;
            } else if (strncmp(chn, "GPU SRAM", 8) == 0) {
                data.gpuSRAMPower += watts;
            } else if (strncmp(chn, "ISP", 3) == 0) {
                data.ispPower += watts;
            } else if (strncmp(chn, "DISPEXT", 7) == 0) {
                data.displayExtPower += watts;
            } else if (strncmp(chn, "DISP", 4) == 0) {
                data.displaySoCPower += watts;
            } else if (strncmp(chn, "AVE", 3) == 0
                    || strncmp(chn, "MSR", 3) == 0) {
                data.mediaPower += watts;
            } else if (strncmp(chn, "PCIe Port", 9) == 0
                    || strncmp(chn, "apciec", 6) == 0) {
                data.pciePower += watts;
            } else if (strncmp(chn, "AMCC", 4) == 0
                    || strncmp(chn, "DCS", 3) == 0
                    || strncmp(chn, "FAB", 3) == 0
                    || strncmp(chn, "AFR", 3) == 0) {
                data.fabricPower += watts;
            }
            // Note: systemPower comes from SMC "PSTR" key, not from IOReport.

        } else if (strcmp(grp, "GPU Stats") == 0) {
            CFStringRef subgroupRef = IOReportChannelGetSubGroup(channel);
            char sub[64] = {0};
            if (!copyCFString(subgroupRef, sub, (CFIndex)sizeof(sub))) {
                continue;
            }

            if (strcmp(sub, "GPU Performance States") == 0 && strcmp(chn, "GPUPH") == 0) {
                int32_t stateCount = IOReportStateGetCount(channel);
                if (stateCount <= 0 || stateCount > 1024) {
                    continue;
                }
                int64_t totalTime  = 0;
                int64_t activeTime = 0;
                double  weightedFreq    = 0;
                int     activeStateIdx  = 0;

                for (int32_t s = 0; s < stateCount; s++) {
                    int64_t residency = IOReportStateGetResidency(channel, s);
                    totalTime += residency;

                    CFStringRef snRef = IOReportStateGetNameForIndex(channel, s);
                    char sn[32] = {0};
                    if (!copyCFString(snRef, sn, (CFIndex)sizeof(sn))) {
                        activeStateIdx++;
                        continue;
                    }

                    if (strcmp(sn, "OFF") == 0 || strcmp(sn, "IDLE") == 0 || strcmp(sn, "DOWN") == 0) {
                        continue;
                    }
                    activeTime += residency;
                    if (activeStateIdx < gGpuFreqCount) {
                        weightedFreq += (double)gGpuFreqs[activeStateIdx] * residency;
                    }
                    activeStateIdx++;
                }

                if (totalTime > 0) {
                    data.gpuUsage = 100.0 * (double)activeTime / (double)totalTime;
                }
                if (activeTime > 0 && gGpuFreqCount > 0) {
                    data.gpuFreqMHz = (int)(weightedFreq / (double)activeTime);
                }
            }

        } else if (strcmp(grp, "CPU Stats") == 0) {
            CFStringRef subgroupRef = IOReportChannelGetSubGroup(channel);
            char sub[64] = {0};
            if (!copyCFString(subgroupRef, sub, (CFIndex)sizeof(sub))) {
                continue;
            }
            if (strcmp(sub, "CPU Complex Performance States") != 0) continue;

            // Guard MCPU before testing CPU0/CPU1 — "MCPU0" contains "CPU0" and would
            // falsely match the E-cluster on M5+ chips if we checked CPU0 first.
            BOOL isMCluster = (strstr(chn, "MCPU") != NULL);
            BOOL isSCluster = (strstr(chn, "SCPU") != NULL);
            BOOL isECluster = (strstr(chn, "ECPU") != NULL) || (!isMCluster && strcmp(chn, "CPU0") == 0);
            BOOL isPCluster = (strstr(chn, "PCPU") != NULL) || (!isMCluster && strcmp(chn, "CPU1") == 0);

            if (!isECluster && !isPCluster && !isMCluster && !isSCluster) continue;

            int32_t stateCount = IOReportStateGetCount(channel);
            if (stateCount <= 0 || stateCount > 1024) {
                continue;
            }
            int64_t totalTime  = 0;
            int64_t activeTime = 0;
            double  weightedFreq = 0;

            for (int32_t s = 0; s < stateCount; s++) {
                int64_t residency = IOReportStateGetResidency(channel, s);
                totalTime += residency;

                CFStringRef snRef = IOReportStateGetNameForIndex(channel, s);
                char sn[64] = {0};
                if (!copyCFString(snRef, sn, (CFIndex)sizeof(sn))) {
                    continue;
                }
                if (strcmp(sn, "OFF") == 0 || strcmp(sn, "IDLE") == 0) continue;

                activeTime += residency;

                // Parse voltage table index from state name (format "V0", "V1", …)
                int vIdx = -1;
                if (sn[0] == 'V') { sscanf(sn + 1, "%d", &vIdx); }

                int freqMHz = 0;
                if (vIdx >= 0) {
                    if (isECluster && vIdx < gECoreFreqCount) {
                        freqMHz = (int)gECoreFreqs[vIdx];
                    } else if (isMCluster && vIdx < gMCoreFreqCount) {
                        freqMHz = (int)gMCoreFreqs[vIdx];
                    } else if ((isPCluster || isSCluster) && vIdx < gPCoreFreqCount) {
                        freqMHz = (int)gPCoreFreqs[vIdx];
                    }
                }

                if (freqMHz > 0) { weightedFreq += (double)freqMHz * residency; }
            }

            if (totalTime > 0) {
                double activePct = 100.0 * (double)activeTime / (double)totalTime;
                int    avgFreq   = activeTime > 0 ? (int)(weightedFreq / (double)activeTime) : 0;

                if (isECluster) {
                    // Take max across multi-die chips (ECPU0, ECPU1)
                    if (activePct > data.eClusterActive)  { data.eClusterActive  = activePct; }
                    if (avgFreq   > data.eClusterFreqMHz) { data.eClusterFreqMHz = avgFreq;   }
                } else if (isMCluster) {
                    // M5+ medium cluster — accumulate; assign after loop
                    mClusterActiveSum += activePct;
                    mClusterCount++;
                    if (avgFreq > mClusterFreqMax) { mClusterFreqMax = avgFreq; }
                } else if (isPCluster) {
                    // On M1-M4 → Performance cluster; on M5+ → Super cluster
                    if (activePct > pcpuActive) { pcpuActive = activePct; }
                    if (avgFreq   > pcpuFreq)   { pcpuFreq   = avgFreq;   }
                    hasPCPU = YES;
                } else if (isSCluster) {
                    if (activePct > data.sClusterActive)  { data.sClusterActive  = activePct; }
                    if (avgFreq   > data.sClusterFreqMHz) { data.sClusterFreqMHz = avgFreq;   }
                }
            }

        } else if (strcmp(grp, "AMC Stats") == 0) {
            // Skip DCS channels — they are a subset of the total; counting them
            // would double-count bandwidth already captured by other channels.
            if (strstr(chn, "DCS") != NULL) continue;
            if (strstr(chn, "RD") != NULL)  { data.dramReadBytes  += value; }
            else if (strstr(chn, "WR") != NULL) { data.dramWriteBytes += value; }

        } else if (strcmp(grp, "PMP") == 0) {
            // PMP provides DRAM bandwidth on M5+ where AMC Stats is blocked.
            CFStringRef subgroupRef = IOReportChannelGetSubGroup(channel);
            char sub[64] = {0};
            if (!copyCFString(subgroupRef, sub, (CFIndex)sizeof(sub))) {
                continue;
            }
            if (strcmp(sub, "DRAM BW") == 0 && value > 0) {
                if (strstr(chn, "RD") != NULL)       { pmpDramReadBytes  += value; }
                else if (strstr(chn, "WR") != NULL)  { pmpDramWriteBytes += value; }
            }
        }
    }

    // Post-loop: assign accumulated cluster metrics.
    data.cpuPower = cpuTotalEnergyW > 0 ? cpuTotalEnergyW : cpuTypedEnergyW;
    // M5+: MCPU → pCluster (Performance tier), PCPU → sCluster (Super tier).
    // M1-M4: PCPU → pCluster (no mCluster).
    if (mClusterCount > 0) {
        // M5+ chip
        data.pClusterActive  = mClusterActiveSum / (double)mClusterCount;
        data.pClusterFreqMHz = mClusterFreqMax;
        if (hasPCPU) {
            // PCPU on M5+ is the Super cluster
            data.sClusterActive  = pcpuActive;
            data.sClusterFreqMHz = pcpuFreq;
        }
    } else if (hasPCPU) {
        // M1-M4: PCPU is the Performance cluster
        data.pClusterActive  = pcpuActive;
        data.pClusterFreqMHz = pcpuFreq;
    }

    // Use PMP DRAM bytes when AMC Stats produced nothing (M5+).
    if (data.dramReadBytes == 0 && data.dramWriteBytes == 0) {
        data.dramReadBytes  = pmpDramReadBytes;
        data.dramWriteBytes = pmpDramWriteBytes;
    }
    if (sampleSeconds > 0) {
        data.dramReadBytes = (int64_t)((double)data.dramReadBytes / sampleSeconds);
        data.dramWriteBytes = (int64_t)((double)data.dramWriteBytes / sampleSeconds);
    }

    data.cpuTemp = resolveCPUTemperature(smcConn);
    data.gpuTemp = resolveGPUTemperature(smcConn);

    // CPU die hotspot — TCMz is the fastest-reacting Apple Silicon thermal sensor.
    // It reflects the actual hottest point on the CPU die regardless of which cores are active.
    // Falls back to cpuTemp if SMC key is unavailable (non-Apple-Silicon or permissions issue).
    if (smcConn != 0) {
        double hotspot = SMCGetFloatValue(smcConn, "TCMz");
        data.cpuDieHotspot = (hotspot > 10.0 && hotspot < 150.0) ? hotspot : data.cpuTemp;

        // Fan speed — F0Ac = Fan 0 Actual RPM.
        // Returns 0 on fanless models (e.g. MacBook Air). Check F1Ac for a second fan
        // if the hardware has dual fans (Mac Pro / Mac Studio / MacBook Pro 16").
        double fan0 = SMCGetFloatValue(smcConn, "F0Ac");
        data.fanRPM = (fan0 > 0) ? (int32_t)fan0 : 0;
        double fan1 = SMCGetFloatValue(smcConn, "F1Ac");
        data.fan2RPM = (fan1 > 0) ? (int32_t)fan1 : 0;
    }

    CFRelease(delta);
    return data;
}

@end
