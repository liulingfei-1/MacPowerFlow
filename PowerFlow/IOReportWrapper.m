// IOReportWrapper.m
#import "IOReportWrapper.h"
#import "SMC.h"
#import <IOKit/IOKitLib.h>
#import <IOKit/hidsystem/IOHIDEventSystemClient.h>
#import <IOKit/hidsystem/IOHIDServiceClient.h>
#include <string.h>
#include <time.h>
#include <math.h>
#include <mach/mach_time.h>

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
static BOOL gTemperatureKeysLoaded = NO;
static CFDictionaryRef gPreviousSample = NULL;
static double gPreviousTime = 0, gPreviousWallTime = 0;
static double gPreviousAwakeTime = 0;
static double gNextSubscriptionAttempt = 0;
static unsigned gSubscriptionFailures = 0;
static unsigned gSampleFailures = 0;
static const double kMaximumSampleGap = 30.0;

static void clearBaseline(void) {
    if (gPreviousSample != NULL) CFRelease(gPreviousSample);
    gPreviousSample = NULL;
    gPreviousTime = gPreviousWallTime = gPreviousAwakeTime = 0;
}

static void clearSubscription(void) {
    clearBaseline();
    if (gSubscription != NULL) CFRelease((CFTypeRef)gSubscription);
    if (gChannels != NULL) CFRelease(gChannels);
    gSubscription = NULL;
    gChannels = NULL;
}


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
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    return (double)mach_continuous_time() * timebase.numer / timebase.denom / 1e9;
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
    if (smcConn == 0 || gTemperatureKeysLoaded) {
        return;
    }

    gTemperatureKeysLoaded = YES;
    int totalKeys = MIN(MAX(SMCGetKeyCount(smcConn), 0), 8192);
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
    if (energy < 0 || !isfinite(durationSeconds) || durationSeconds <= 0 || !isCFType(unitRef, CFStringGetTypeID())) {
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

static int32_t validFanRPM(double value) {
    return isfinite(value) && value >= 0 && value < 100000 ? (int32_t)value : 0;
}

static BOOL isUsableSampleWindow(double continuousElapsed, double awakeElapsed) {
    return isfinite(continuousElapsed) && isfinite(awakeElapsed)
        && continuousElapsed >= 0.05 && continuousElapsed <= kMaximumSampleGap
        && fabs(continuousElapsed - awakeElapsed) < 0.25;
}

// Build without a blocking probe. Both bandwidth groups may be subscribed;
// each sample prefers AMC when it actually supplies counters, otherwise PMP.
static BOOL ensureSubscription(void) {
    if (gSubscription != NULL) return YES;
    double now = monotonicSeconds();
    if (now < gNextSubscriptionAttempt || !ioReportFunctionsAvailable()) return NO;
    clearSubscription();
    CFDictionaryRef energy = copyIOReportChannels(CFSTR("Energy Model"));
    if (energy == NULL) energy = copyIOReportChannels(CFSTR("Energy Counters"));
    if (energy != NULL) {
        gChannels = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, energy);
        CFRelease(energy);
    }
    if (gChannels != NULL) {
        mergeIOReportGroup(gChannels, CFSTR("Energy Counters"));
        mergeIOReportGroup(gChannels, CFSTR("GPU Stats"));
        mergeIOReportGroup(gChannels, CFSTR("CPU Stats"));
        mergeIOReportGroup(gChannels, CFSTR("AMC Stats"));
        mergeIOReportGroup(gChannels, CFSTR("PMP"));
        CFMutableDictionaryRef subsystem = NULL;
        gSubscription = IOReportCreateSubscription(NULL, gChannels, &subsystem, 0, NULL);
        if (subsystem != NULL) CFRelease(subsystem);
    }
    if (gSubscription == NULL) {
        clearSubscription();
        gSubscriptionFailures = MIN(gSubscriptionFailures + 1, 5U);
        gNextSubscriptionAttempt = now + MIN(30.0, (double)(1U << gSubscriptionFailures));
        return NO;
    }
    gSubscriptionFailures = gSampleFailures = 0;
    gNextSubscriptionAttempt = 0;
    loadGpuFrequencies();
    loadCpuFrequencies();
    return YES;
}

static void recordSampleFailure(void) {
    clearBaseline();
    if (++gSampleFailures >= 3) {
        clearSubscription();
        gNextSubscriptionAttempt = monotonicSeconds() + 2.0;
    }
}

+ (void)resetSamplingBaseline {
    clearBaseline();
}

+ (void)configureTemperatureKeys:(NSArray<NSString *> *)keys {
    gCpuTempKeyCount = gGpuTempKeyCount = 0;
    gTemperatureKeysLoaded = YES;
    for (NSString *name in keys) {
        const char *key = name.UTF8String;
        if (strlen(key) != 4 || key[0] != 'T') continue;
        if ((key[1] == 'p' || key[1] == 'e' || key[1] == 's') && gCpuTempKeyCount < 64) {
            strcpy(gCpuTempKeys[gCpuTempKeyCount++], key);
        } else if (key[1] == 'g' && gGpuTempKeyCount < 64) {
            strcpy(gGpuTempKeys[gGpuTempKeyCount++], key);
        }
    }
}

+ (IOReportData)fetchIOReportData {
    return [self fetchIOReportDataWithSMC:0];
}

+ (IOReportData)fetchIOReportDataWithSMC:(io_connect_t)smcConn {
    IOReportData data = {0};
    // SMC/HID is independent of IOReport permission, subscription and frames.
    data.cpuTemp = resolveCPUTemperature(smcConn);
    data.gpuTemp = resolveGPUTemperature(smcConn);
    data.cpuDieHotspot = data.cpuTemp;
    if (smcConn != 0) {
        double hotspot = SMCGetFloatValue(smcConn, "TCMz");
        if (isValidTemperature(hotspot)) data.cpuDieHotspot = hotspot;
        data.fanRPM = validFanRPM(SMCGetFloatValue(smcConn, "F0Ac"));
        data.fan2RPM = validFanRPM(SMCGetFloatValue(smcConn, "F1Ac"));
    }
    data.sampleStatus = MPFSampleUnavailable;
    if (!ensureSubscription()) return data;

    CFDictionaryRef current = IOReportCreateSamples(gSubscription, gChannels, NULL);
    const double now = monotonicSeconds();
    const double awake = NSProcessInfo.processInfo.systemUptime;
    const double wall = NSDate.date.timeIntervalSince1970;
    if (!isCFType(current, CFDictionaryGetTypeID())) {
        if (current != NULL) CFRelease(current);
        recordSampleFailure();
        return data;
    }
    const double sampleSeconds = now - gPreviousTime;
    const double awakeSeconds = awake - gPreviousAwakeTime;
    const BOOL hadBaseline = gPreviousSample != NULL;
    const BOOL usableWindow = hadBaseline
        && isUsableSampleWindow(sampleSeconds, awakeSeconds);
    CFDictionaryRef delta = usableWindow
        ? IOReportCreateSamplesDelta(gPreviousSample, current, NULL) : NULL;
    const double startWall = gPreviousWallTime;
    clearBaseline();
    gPreviousSample = current;
    gPreviousTime = now;
    gPreviousAwakeTime = awake;
    gPreviousWallTime = wall;
    data.sampleStartTime = usableWindow ? startWall : wall;
    data.sampleEndTime = wall;
    if (!usableWindow) {
        data.sampleStatus = hadBaseline ? MPFSampleReset : MPFSampleBaseline;
        return data;
    }
    CFArrayRef channels = ioReportChannelArray(delta);
    if (channels == NULL) {
        if (delta != NULL) CFRelease(delta);
        recordSampleFailure();
        return data;
    }
    gSampleFailures = 0;
    data.sampleDuration = sampleSeconds;
    data.sampleStatus = MPFSampleAvailable;
    data.hasValidEnergySample = YES;
    BOOL hasInvalidCounter = NO;

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
            CFStringRef unit = IOReportChannelGetUnitLabel(channel);
            if (value == INT64_MIN) continue; // IOReport unsupported-accessor sentinel
            if (value < 0) { hasInvalidCounter = YES; continue; }
            if (!isCFType(unit, CFStringGetTypeID())
                || (!CFEqual(unit, CFSTR("mJ")) && !CFEqual(unit, CFSTR("uJ"))
                    && !CFEqual(unit, CFSTR("nJ")))) continue;
            double watts = energyToWatts(value, unit, sampleSeconds);
            BOOL isTypedCPU =
                strstr(chn, "ECPU Energy") != NULL ||
                strstr(chn, "PCPU Energy") != NULL ||
                strstr(chn, "MCPU Energy") != NULL ||
                strstr(chn, "eCPUs Energy") != NULL ||
                strstr(chn, "pCPUs Energy") != NULL ||
                strstr(chn, "mCPUs Energy") != NULL;
            if (isTypedCPU) {
                data.powerAvailabilityMask |= MPFPowerCPU;
                cpuTypedEnergyW += watts;
            } else if (strstr(chn, "CPU Energy") != NULL) {
                data.powerAvailabilityMask |= MPFPowerCPU;
                cpuTotalEnergyW += watts;
            } else if (strcmp(chn, "GPU Energy") == 0) {
                data.powerAvailabilityMask |= MPFPowerGPU;
                data.gpuPower += watts;
            } else if (strncmp(chn, "ANE", 3) == 0) {
                data.powerAvailabilityMask |= MPFPowerANE;
                data.anePower += watts;
            } else if (strncmp(chn, "DRAM", 4) == 0) {
                data.powerAvailabilityMask |= MPFPowerDRAM;
                data.dramPower += watts;
            } else if (strncmp(chn, "GPU SRAM", 8) == 0) {
                data.powerAvailabilityMask |= MPFPowerGPUSRAM;
                data.gpuSRAMPower += watts;
            } else if (strncmp(chn, "ISP", 3) == 0) {
                data.powerAvailabilityMask |= MPFPowerISP;
                data.ispPower += watts;
            } else if (strncmp(chn, "DISPEXT", 7) == 0) {
                data.powerAvailabilityMask |= MPFPowerDisplayExt;
                data.displayExtPower += watts;
            } else if (strncmp(chn, "DISP", 4) == 0) {
                data.powerAvailabilityMask |= MPFPowerDisplaySoC;
                data.displaySoCPower += watts;
            } else if (strncmp(chn, "AVE", 3) == 0
                    || strncmp(chn, "MSR", 3) == 0) {
                data.powerAvailabilityMask |= MPFPowerMedia;
                data.mediaPower += watts;
            } else if (strncmp(chn, "PCIe Port", 9) == 0
                    || strncmp(chn, "apciec", 6) == 0) {
                data.powerAvailabilityMask |= MPFPowerPCIe;
                data.pciePower += watts;
            } else if (strncmp(chn, "AMCC", 4) == 0
                    || strncmp(chn, "DCS", 3) == 0
                    || strncmp(chn, "FAB", 3) == 0
                    || strncmp(chn, "AFR", 3) == 0) {
                data.powerAvailabilityMask |= MPFPowerFabric;
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
                    if (residency == INT64_MIN) continue;
                    if (residency < 0) { hasInvalidCounter = YES; continue; }
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
                if (residency == INT64_MIN) continue;
                if (residency < 0) { hasInvalidCounter = YES; continue; }
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
            if (value == INT64_MIN) continue;
            if (value < 0) { hasInvalidCounter = YES; continue; }
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
            if (strcmp(sub, "DRAM BW") != 0 || value == INT64_MIN) continue;
            if (value < 0) { hasInvalidCounter = YES; continue; }
            if (value > 0) {
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

    if (hasInvalidCounter) {
        // A reset/wrapped counter must not turn into negative or huge watts.
        // Retain this frame only as the next baseline; suppress all energy.
        data.powerAvailabilityMask = 0;
        data.hasValidEnergySample = NO;
        data.sampleStatus = MPFSampleReset;
        data.cpuPower = data.gpuPower = data.anePower = data.dramPower = 0;
        data.gpuSRAMPower = data.mediaPower = data.ispPower = data.fabricPower = 0;
        data.pciePower = data.displaySoCPower = data.displayExtPower = 0;
        data.dramReadBytes = data.dramWriteBytes = 0;
    }

    data.hasValidEnergySample = data.hasValidEnergySample && data.powerAvailabilityMask != 0;
    CFRelease(delta);
    return data;
}

@end
