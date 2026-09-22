#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The only callbacks a client may export to the root helper.
@protocol MPFPrivilegedMetricsClientProtocol <NSObject>
- (void)receiveData:(NSData *)data NS_SWIFT_NAME(receiveData(_:));
- (void)serviceDidFail:(NSString * _Nullable)message
    NS_SWIFT_NAME(serviceDidFail(_:));
@end

/// Fixed, intentionally narrow root-helper API.
///
/// No method accepts an executable path, environment, command, or command-line
/// arguments. The helper always launches its compile-time fixed powermetrics
/// command with a whitelisted cadence; power settings accept only a source enum
/// and a boolean, mapped to fixed pmset arguments.
@protocol MPFPrivilegedMetricsServiceProtocol <NSObject>
- (void)protocolVersionWithReply:(void (^)(NSInteger version))reply
    NS_SWIFT_NAME(protocolVersion(withReply:));
- (void)startSamplingWithReply:
    (void (^)(BOOL started, NSString * _Nullable errorMessage))reply
    NS_SWIFT_NAME(startSampling(withReply:));
// v2: only 2, 5 or 10 seconds; each start creates a new integration baseline.
- (void)startSamplingWithInterval:(NSInteger)seconds
    reply:(void (^)(BOOL started, NSString * _Nullable errorMessage))reply
    NS_SWIFT_NAME(startSampling(intervalSeconds:withReply:));
// source: 0 = battery, 1 = AC. enabled must be exactly 0 or 1.
- (void)queryLowPowerModeForSource:(NSInteger)source
    reply:(void (^)(BOOL success, BOOL enabled, NSString * _Nullable errorMessage))reply
    NS_SWIFT_NAME(queryLowPowerMode(source:withReply:));
- (void)setLowPowerModeForSource:(NSInteger)source enabled:(NSInteger)enabled
    reply:(void (^)(BOOL success, BOOL actualEnabled, NSString * _Nullable errorMessage))reply
    NS_SWIFT_NAME(setLowPowerMode(source:enabled:withReply:));
- (void)stopSamplingWithReply:
    (void (^)(BOOL stopped, NSString * _Nullable errorMessage))reply
    NS_SWIFT_NAME(stopSampling(withReply:));
@end

NS_ASSUME_NONNULL_END
