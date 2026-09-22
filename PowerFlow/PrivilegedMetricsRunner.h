#ifndef PrivilegedMetricsRunner_h
#define PrivilegedMetricsRunner_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MPFPrivilegedMetricsRunnerState) {
    MPFPrivilegedMetricsRunnerStateIdle = 0,
    MPFPrivilegedMetricsRunnerStateAuthorizing,
    MPFPrivilegedMetricsRunnerStateRunning,
    MPFPrivilegedMetricsRunnerStateStopping,
    MPFPrivilegedMetricsRunnerStateFailed,
};

typedef void (^MPFPrivilegedMetricsDataHandler)(NSData *data);
typedef void (^MPFPrivilegedMetricsStateHandler)(
    MPFPrivilegedMetricsRunnerState state,
    NSString * _Nullable message
);

/// Connects to MacPowerFlow's launchd-managed metrics and restricted power helper.
///
/// Only an explicit user action may allow installation. Automatic launches
/// connect silently. When allowed, a new app build requests one
/// Authorization Services grant to install the fixed helper. Later launches
/// connect over a code-signing-constrained XPC service without requesting a
/// password. No password is exposed to the app or added to sudoers. Both
/// callbacks are delivered on the main queue.
@interface MPFPrivilegedMetricsRunner : NSObject

@property (atomic, readonly) MPFPrivilegedMetricsRunnerState state;
@property (atomic, readonly, getter=isRunning) BOOL running;

- (void)startAllowingInstallation:(BOOL)allowInstallation
                   dataHandler:(MPFPrivilegedMetricsDataHandler)dataHandler
                stateHandler:(MPFPrivilegedMetricsStateHandler)stateHandler;

/// Applied to the next stream. Invalid intervals are rejected without side effects.
- (BOOL)configureSamplingInterval:(NSInteger)seconds;

/// Fixed pmset operation via an already installed v2 helper. Never installs/prompts.
- (void)queryLowPowerModeForSource:(NSInteger)source
    completion:(void (^)(BOOL success, BOOL enabled, NSString * _Nullable message))completion
    NS_SWIFT_NAME(queryLowPowerMode(source:completion:));
- (void)setLowPowerModeForSource:(NSInteger)source enabled:(BOOL)enabled
    completion:(void (^)(BOOL success, BOOL actualEnabled, NSString * _Nullable message))completion
    NS_SWIFT_NAME(setLowPowerMode(source:enabled:completion:));

/// Stops only the current powermetrics stream and closes the XPC connection.
/// The launchd registration remains installed so the next app launch is
/// password-free.
- (void)stop;

@end

NS_ASSUME_NONNULL_END

#endif
