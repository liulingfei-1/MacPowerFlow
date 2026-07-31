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
/// command.
@protocol MPFPrivilegedMetricsServiceProtocol <NSObject>
- (void)protocolVersionWithReply:(void (^)(NSInteger version))reply
    NS_SWIFT_NAME(protocolVersion(withReply:));
- (void)startSamplingWithReply:
    (void (^)(BOOL started, NSString * _Nullable errorMessage))reply
    NS_SWIFT_NAME(startSampling(withReply:));
- (void)stopSamplingWithReply:
    (void (^)(BOOL stopped, NSString * _Nullable errorMessage))reply
    NS_SWIFT_NAME(stopSampling(withReply:));
@end

NS_ASSUME_NONNULL_END
