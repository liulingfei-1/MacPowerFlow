#import "PrivilegedMetricsRunner.h"
#import "../Shared/PrivilegedMetricsXPCProtocol.h"

@import Security;

#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>

static NSString * const MPFHelperMachServiceName =
    @"com.llf.MacPowerFlow.PrivilegedHelper";
static NSString * const MPFAppSigningIdentifier =
    @"com.llf.MacPowerFlow";
static NSString * const MPFHelperSigningIdentifier =
    @"com.llf.MacPowerFlow.PrivilegedHelper";
static NSString * const MPFInstallerSigningIdentifier =
    @"com.llf.MacPowerFlow.PrivilegedInstaller";
static NSString * const MPFEmbeddedHelperName =
    @"com.llf.MacPowerFlow.PrivilegedHelper";
static NSString * const MPFEmbeddedInstallerName =
    @"com.llf.MacPowerFlow.PrivilegedInstaller";
static NSString * const MPFInstalledHelperPath =
    @"/Library/PrivilegedHelperTools/com.llf.MacPowerFlow.PrivilegedHelper";
static NSString * const MPFStagedHelperPath =
    @"/Library/PrivilegedHelperTools/.com.llf.MacPowerFlow.PrivilegedHelper.staging";
static NSString * const MPFStagedInstallerPath =
    @"/Library/PrivilegedHelperTools/.com.llf.MacPowerFlow.PrivilegedInstaller.staging";
static const char * const MPFSystemInstallPath = "/usr/bin/install";
static NSTimeInterval const MPFConnectionTimeout = 8.0;
static NSUInteger const MPFMatchingHelperRetryLimit = 15;
static NSUInteger const MPFSamplingStartRetryLimit = 16;
static NSInteger const MPFProtocolVersion = 1;
static NSString * const MPFRetryableSessionBusyMarker =
    @"MPF_RETRY_SESSION_BUSY";

@interface MPFPrivilegedMetricsRunner ()
    <MPFPrivilegedMetricsClientProtocol> {
    dispatch_queue_t _workerQueue;
    MPFPrivilegedMetricsRunnerState _state;
    BOOL _workerActive;
    BOOL _stopRequested;
    BOOL _installAttempted;
    BOOL _allowInstallation;
    BOOL _helperWasCompatible;
    NSUInteger _connectionGeneration;
    NSUInteger _compatibleGeneration;
    NSUInteger _connectionFailureCount;
    NSUInteger _matchingHelperRetryCount;
    NSUInteger _samplingStartRetryCount;
    NSXPCConnection *_connection;
    id<MPFPrivilegedMetricsServiceProtocol> _serviceProxy;
    MPFPrivilegedMetricsDataHandler _dataHandler;
    MPFPrivilegedMetricsStateHandler _stateHandler;
}
@end

@implementation MPFPrivilegedMetricsRunner

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _workerQueue = dispatch_queue_create(
            "com.llf.MacPowerFlow.privileged-service-client",
            DISPATCH_QUEUE_SERIAL
        );
        _state = MPFPrivilegedMetricsRunnerStateIdle;
    }
    return self;
}

- (void)dealloc {
    [_connection invalidate];
}

- (MPFPrivilegedMetricsRunnerState)state {
    @synchronized (self) {
        return _state;
    }
}

- (BOOL)isRunning {
    MPFPrivilegedMetricsRunnerState state = self.state;
    return state == MPFPrivilegedMetricsRunnerStateAuthorizing
        || state == MPFPrivilegedMetricsRunnerStateRunning;
}

- (void)startAllowingInstallation:(BOOL)allowInstallation
                   dataHandler:(MPFPrivilegedMetricsDataHandler)dataHandler
                stateHandler:(MPFPrivilegedMetricsStateHandler)stateHandler {
    NSParameterAssert(dataHandler != nil);
    NSParameterAssert(stateHandler != nil);

    @synchronized (self) {
        if (_workerActive) {
            return;
        }

        _workerActive = YES;
        _stopRequested = NO;
        _installAttempted = NO;
        _allowInstallation = allowInstallation;
        _helperWasCompatible = NO;
        _connectionFailureCount = 0;
        _matchingHelperRetryCount = 0;
        _samplingStartRetryCount = 0;
        _dataHandler = [dataHandler copy];
        _stateHandler = [stateHandler copy];
    }

    [self publishState:MPFPrivilegedMetricsRunnerStateAuthorizing
                message:nil];
    dispatch_async(_workerQueue, ^{
        [self connectToInstalledHelper];
    });
}

- (void)stop {
    BOOL hasWorker = NO;
    @synchronized (self) {
        _stopRequested = YES;
        hasWorker = _workerActive;
    }

    if (!hasWorker) {
        return;
    }

    [self publishState:MPFPrivilegedMetricsRunnerStateStopping message:nil];
    dispatch_async(_workerQueue, ^{
        [self stopConnectedService];
    });
}

#pragma mark - XPC connection

- (void)connectToInstalledHelper {
    @synchronized (self) {
        if (!_workerActive) { return; }
    }
    if ([self isStopRequested]) {
        [self finishStopped];
        return;
    }

    NSError *requirementError = nil;
    NSString *helperRequirement = [self exactRequirementForBundledHelper:
        &requirementError];
    if (helperRequirement == nil) {
        [self finishFailed:
            requirementError.localizedDescription
                ?: @"无法验证内嵌增强服务。"];
        return;
    }

    // Detect upgrades before connecting: the helper and the configured client
    // identity must both match. Only explicit user actions may install/update.
    if (!_installAttempted
            && (![self codeAtURL:
                [NSURL fileURLWithPath:MPFInstalledHelperPath]
                matchesExactRequirement:helperRequirement]
                || ![self installedConfigurationMatchesCurrentClient])) {
        _installAttempted = YES;
        [self installHelperAndReconnect];
        return;
    }

    [self invalidateConnection];
    NSUInteger generation = ++_connectionGeneration;

    NSXPCConnection *connection = [[NSXPCConnection alloc]
        initWithMachServiceName:MPFHelperMachServiceName
                        options:NSXPCConnectionPrivileged];
    connection.exportedInterface = [NSXPCInterface
        interfaceWithProtocol:@protocol(MPFPrivilegedMetricsClientProtocol)];
    connection.exportedObject = self;
    connection.remoteObjectInterface = [NSXPCInterface
        interfaceWithProtocol:@protocol(MPFPrivilegedMetricsServiceProtocol)];

    __weak typeof(self) weakSelf = self;
    connection.interruptionHandler = ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        dispatch_async(strongSelf->_workerQueue, ^{
            [strongSelf connectionFailedForGeneration:generation
                message:@"增强服务连接已中断。"];
        });
    };
    connection.invalidationHandler = ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        dispatch_async(strongSelf->_workerQueue, ^{
            [strongSelf connectionFailedForGeneration:generation
                message:@"无法连接已安装的增强服务。"];
        });
    };

    @try {
        [connection setCodeSigningRequirement:helperRequirement];
    } @catch (NSException *exception) {
        [connection invalidate];
        [self finishFailed:[NSString stringWithFormat:
            @"增强服务签名要求无效：%@", exception.reason ?: @"未知错误"]];
        return;
    }

    _connection = connection;
    [connection activate];

    id<MPFPrivilegedMetricsServiceProtocol> proxy =
        [connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
            typeof(self) strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            dispatch_async(strongSelf->_workerQueue, ^{
                [strongSelf connectionFailedForGeneration:generation
                    message:error.localizedDescription
                        ?: @"增强服务没有响应。"];
            });
        }];
    _serviceProxy = proxy;

    [proxy protocolVersionWithReply:^(NSInteger version) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        dispatch_async(strongSelf->_workerQueue, ^{
            [strongSelf receivedProtocolVersion:version
                generation:generation];
        });
    }];

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)(MPFConnectionTimeout * (double)NSEC_PER_SEC)
        ),
        _workerQueue,
        ^{
            if (generation == self->_connectionGeneration
                    && generation != self->_compatibleGeneration) {
                [self connectionFailedForGeneration:generation
                    message:@"增强服务连接超时。"];
            }
        }
    );
}

- (void)receivedProtocolVersion:(NSInteger)version
                     generation:(NSUInteger)generation {
    if (generation != _connectionGeneration || [self isStopRequested]) {
        return;
    }
    if (version != MPFProtocolVersion) {
        [self connectionFailedForGeneration:generation
            message:@"已安装的增强服务版本需要更新。"];
        return;
    }

    _helperWasCompatible = YES;
    _compatibleGeneration = generation;
    _connectionFailureCount = 0;
    _samplingStartRetryCount = 0;

    [self requestSamplingForGeneration:generation];
}

- (void)requestSamplingForGeneration:(NSUInteger)generation {
    if (generation != _connectionGeneration || [self isStopRequested]) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    [_serviceProxy startSamplingWithReply:^(
        BOOL started,
        NSString *errorMessage
    ) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        dispatch_async(strongSelf->_workerQueue, ^{
            if (generation != strongSelf->_connectionGeneration) {
                return;
            }
            if (strongSelf.isStopRequested) {
                [strongSelf stopConnectedService];
                return;
            }
            if (!started) {
                BOOL isRetryableSessionHandoff =
                    [errorMessage containsString:
                        MPFRetryableSessionBusyMarker]
                    || [errorMessage containsString:
                        @"Another MacPowerFlow connection is already sampling"];
                if (isRetryableSessionHandoff
                        && strongSelf->_samplingStartRetryCount
                            < MPFSamplingStartRetryLimit) {
                    ++strongSelf->_samplingStartRetryCount;
                    NSTimeInterval delay = MIN(
                        1.0,
                        0.25 + 0.1
                            * (double)strongSelf->_samplingStartRetryCount
                    );
                    dispatch_after(
                        dispatch_time(
                            DISPATCH_TIME_NOW,
                            (int64_t)(delay * (double)NSEC_PER_SEC)
                        ),
                        strongSelf->_workerQueue,
                        ^{
                            [strongSelf requestSamplingForGeneration:generation];
                        }
                    );
                    return;
                }
                if (isRetryableSessionHandoff) {
                    [strongSelf finishFailed:
                        @"上一轮增强采样未能及时退出，请稍后重新打开 MacPowerFlow。"];
                    return;
                }
                [strongSelf finishFailed:
                    errorMessage ?: @"增强服务无法启动 powermetrics。"];
                return;
            }
            strongSelf->_samplingStartRetryCount = 0;
            [strongSelf
                publishState:MPFPrivilegedMetricsRunnerStateRunning
                     message:nil];
        });
    }];
}

- (void)connectionFailedForGeneration:(NSUInteger)generation
                               message:(NSString *)message {
    if (generation != _connectionGeneration || [self isStopRequested]) {
        return;
    }

    ++_connectionGeneration;
    [self invalidateConnection];

    if (_helperWasCompatible) {
        if (_connectionFailureCount < 3) {
            ++_connectionFailureCount;
            [self scheduleConnectionRetryAfter:0.6];
        } else {
            [self finishFailed:message];
        }
        return;
    }

    if (!_installAttempted) {
        NSError *requirementError = nil;
        NSString *bundledRequirement =
            [self exactRequirementForBundledHelper:&requirementError];
        BOOL installedHelperMatches =
            bundledRequirement != nil
            && [self codeAtURL:
                [NSURL fileURLWithPath:MPFInstalledHelperPath]
                matchesExactRequirement:bundledRequirement];
        if (installedHelperMatches
                && _matchingHelperRetryCount
                    < MPFMatchingHelperRetryLimit) {
            ++_matchingHelperRetryCount;
            NSTimeInterval delay =
                MIN(2.0, 0.35 + 0.25 * (double)_matchingHelperRetryCount);
            [self scheduleConnectionRetryAfter:delay];
            return;
        }

        // A matching helper may still be starting during login. A timeout
        // does not prove an installation is broken; never reinstall it here.
        if (installedHelperMatches) {
            [self finishFailed:@"增强服务暂未响应，当前使用标准采样。可从右键菜单重试增强采样。"];
            return;
        }
        _installAttempted = YES;
        [self installHelperAndReconnect];
        return;
    }

    if (_connectionFailureCount < 10) {
        ++_connectionFailureCount;
        [self scheduleConnectionRetryAfter:0.5];
    } else {
        [self finishFailed:message];
    }
}

- (void)scheduleConnectionRetryAfter:(NSTimeInterval)delay {
    NSUInteger generation = _connectionGeneration;
    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)(delay * (double)NSEC_PER_SEC)
        ),
        _workerQueue,
        ^{
            // stop/failure/new sessions invalidate previously queued work.
            if (generation != self->_connectionGeneration) { return; }
            [self connectToInstalledHelper];
        }
    );
}

- (void)stopConnectedService {
    if (_connection == nil || _serviceProxy == nil) {
        [self finishStopped];
        return;
    }

    NSUInteger generation = _connectionGeneration;
    __weak typeof(self) weakSelf = self;
    [_serviceProxy stopSamplingWithReply:^(
        BOOL stopped,
        NSString *errorMessage
    ) {
        (void)stopped;
        (void)errorMessage;
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        dispatch_async(strongSelf->_workerQueue, ^{
            if (generation == strongSelf->_connectionGeneration) {
                [strongSelf finishStopped];
            }
        });
    }];

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
        _workerQueue,
        ^{
            if (generation == self->_connectionGeneration
                    && self.isStopRequested) {
                [self finishStopped];
            }
        }
    );
}

- (void)invalidateConnection {
    NSXPCConnection *connection = _connection;
    _connection = nil;
    _serviceProxy = nil;
    connection.interruptionHandler = nil;
    connection.invalidationHandler = nil;
    [connection invalidate];
}

#pragma mark - One-time installation

- (void)installHelperAndReconnect {
    if ([self isStopRequested]) {
        [self finishStopped];
        return;
    }

    if (!_allowInstallation) {
        [self finishFailed:@"增强服务需要安装或更新，当前使用标准采样。请从右键菜单选择“启用或更新增强采样…”完成一次授权。"];
        return;
    }

    [self publishState:MPFPrivilegedMetricsRunnerStateAuthorizing
                message:nil];

    NSError *installationError = nil;
    BOOL installed = [self runAuthorizedInstaller:&installationError];
    if (!installed) {
        [self finishFailed:
            installationError.localizedDescription
                ?: @"增强服务安装失败。"];
        return;
    }

    _connectionFailureCount = 0;
    [self scheduleConnectionRetryAfter:0.5];
}

- (BOOL)runAuthorizedInstaller:(NSError **)error {
    NSURL *bundleURL = NSBundle.mainBundle.bundleURL;
    [self clearCodeSigningDetritusAtURL:bundleURL recursively:YES];

    NSURL *launchServicesURL = [bundleURL
        URLByAppendingPathComponent:@"Contents/Library/LaunchServices"
        isDirectory:YES];
    NSURL *helperURL = [launchServicesURL
        URLByAppendingPathComponent:MPFEmbeddedHelperName
        isDirectory:NO];
    NSURL *installerURL = [[[NSBundle mainBundle] bundleURL]
        URLByAppendingPathComponent:
            [@"Contents/Library/LaunchServices"
                stringByAppendingPathComponent:MPFEmbeddedInstallerName]
        isDirectory:NO];

    NSString *helperRequirement = [self
        exactRequirementForCodeAtURL:helperURL
        expectedIdentifier:MPFHelperSigningIdentifier
        checkNestedCode:NO
        operation:@"内嵌增强服务"
        error:error];
    if (helperRequirement == nil) {
        return NO;
    }
    NSString *installerRequirement = [self
        exactRequirementForCodeAtURL:installerURL
        expectedIdentifier:MPFInstallerSigningIdentifier
        checkNestedCode:NO
        operation:@"内嵌增强服务安装器"
        error:error];
    if (installerRequirement == nil) {
        return NO;
    }
    NSString *clientRequirement = [self
        exactRequirementForCurrentProcess:error];
    if (clientRequirement == nil) {
        return NO;
    }

    AuthorizationRef authorization = NULL;
    OSStatus status = AuthorizationCreate(
        NULL,
        kAuthorizationEmptyEnvironment,
        kAuthorizationFlagDefaults,
        &authorization
    );
    if (status != errAuthorizationSuccess || authorization == NULL) {
        if (error != NULL) {
            *error = [self authorizationErrorWithStatus:status
                prefix:@"无法创建首次安装授权"];
        }
        return NO;
    }

    const char *toolPath = MPFSystemInstallPath;
    AuthorizationItem right = {
        kAuthorizationRightExecute,
        (UInt32)strlen(toolPath),
        (void *)toolPath,
        0,
    };
    AuthorizationRights rights = {1, &right};

    const char *prompt =
        "首次安装 MacPowerFlow 只读增强服务；批准后以后启动无需再次输入密码。";
    AuthorizationItem promptItem = {
        kAuthorizationEnvironmentPrompt,
        (UInt32)strlen(prompt),
        (void *)prompt,
        0,
    };
    AuthorizationEnvironment environment = {1, &promptItem};
    AuthorizationFlags flags =
        kAuthorizationFlagInteractionAllowed
        | kAuthorizationFlagExtendRights
        | kAuthorizationFlagPreAuthorize;
    status = AuthorizationCopyRights(
        authorization,
        &rights,
        &environment,
        flags,
        NULL
    );
    if (status != errAuthorizationSuccess) {
        AuthorizationFree(authorization, kAuthorizationFlagDestroyRights);
        if (error != NULL) {
            *error = [self authorizationErrorWithStatus:status
                prefix:status == errAuthorizationCanceled
                    ? @"已取消首次安装"
                    : @"首次安装授权失败"];
        }
        return NO;
    }

    BOOL completed = [self
        performAuthorizedInstallationWithAuthorization:authorization
        helperURL:helperURL
        helperRequirement:helperRequirement
        installerURL:installerURL
        installerRequirement:installerRequirement
        clientRequirement:clientRequirement
        error:error];
    AuthorizationFree(authorization, kAuthorizationFlagDestroyRights);
    return completed;
}

- (BOOL)performAuthorizedInstallationWithAuthorization:
            (AuthorizationRef)authorization
        helperURL:(NSURL *)helperURL
        helperRequirement:(NSString *)helperRequirement
        installerURL:(NSURL *)installerURL
        installerRequirement:(NSString *)installerRequirement
        clientRequirement:(NSString *)clientRequirement
        error:(NSError **)error {
    if (![self ensureStagingDirectoryWithAuthorization:authorization
                                                 error:error]) {
        return NO;
    }

    char * const helperCopyArguments[] = {
        "-o",
        "root",
        "-g",
        "wheel",
        "-m",
        "0555",
        (char *)helperURL.fileSystemRepresentation,
        (char *)MPFStagedHelperPath.fileSystemRepresentation,
        NULL,
    };
    if (![self executeAuthorizedTool:MPFSystemInstallPath
                       authorization:authorization
                           arguments:helperCopyArguments
                              output:NULL
                    operationPrefix:@"无法暂存增强服务"
                               error:error]) {
        return NO;
    }
    if (![self validateStagedToolAtPath:MPFStagedHelperPath
                    expectedIdentifier:MPFHelperSigningIdentifier
                   expectedRequirement:helperRequirement
                             operation:@"暂存增强服务"
                                 error:error]) {
        return NO;
    }

    char * const installerCopyArguments[] = {
        "-o",
        "root",
        "-g",
        "wheel",
        "-m",
        "0555",
        (char *)installerURL.fileSystemRepresentation,
        (char *)MPFStagedInstallerPath.fileSystemRepresentation,
        NULL,
    };
    if (![self executeAuthorizedTool:MPFSystemInstallPath
                       authorization:authorization
                           arguments:installerCopyArguments
                              output:NULL
                    operationPrefix:@"无法暂存增强服务安装器"
                               error:error]) {
        return NO;
    }
    if (![self validateStagedToolAtPath:MPFStagedInstallerPath
                    expectedIdentifier:MPFInstallerSigningIdentifier
                   expectedRequirement:installerRequirement
                             operation:@"暂存增强服务安装器"
                                 error:error]) {
        return NO;
    }

    NSString *userIdentifier = [NSString stringWithFormat:
        @"%u", (unsigned int)getuid()];
    char * const installerArguments[] = {
        (char *)clientRequirement.UTF8String,
        (char *)userIdentifier.UTF8String,
        NULL,
    };
    NSData *output = nil;
    if (![self executeAuthorizedTool:
                MPFStagedInstallerPath.fileSystemRepresentation
                       authorization:authorization
                           arguments:installerArguments
                              output:&output
                    operationPrefix:@"增强服务安装程序启动失败"
                               error:error]) {
        return NO;
    }

    NSString *result = [[NSString alloc]
        initWithData:output ?: NSData.data
            encoding:NSUTF8StringEncoding];
    if ([result containsString:@"MPF_INSTALL_OK"]) {
        return YES;
    }

    if (error != NULL) {
        NSString *detail = [result
            stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
        *error = [NSError errorWithDomain:@"com.llf.MacPowerFlow.Installation"
                                     code:1
                                 userInfo:@{
            NSLocalizedDescriptionKey: detail.length > 0
                ? [@"增强服务安装失败：" stringByAppendingString:detail]
                : @"增强服务安装失败；安装程序没有返回成功标记。",
        }];
    }
    return NO;
}

- (BOOL)ensureStagingDirectoryWithAuthorization:
            (AuthorizationRef)authorization
        error:(NSError **)error {
    NSString *directoryPath =
        MPFStagedHelperPath.stringByDeletingLastPathComponent;
    struct stat fileStatus = {0};
    if (lstat(directoryPath.fileSystemRepresentation, &fileStatus) != 0) {
        if (errno != ENOENT) {
            if (error != NULL) {
                *error = [self posixErrorWithCode:errno
                    operation:@"无法检查增强服务暂存目录"];
            }
            return NO;
        }

        char * const directoryArguments[] = {
            "-d",
            "-o",
            "root",
            "-g",
            "wheel",
            "-m",
            "0755",
            (char *)directoryPath.fileSystemRepresentation,
            NULL,
        };
        if (![self executeAuthorizedTool:MPFSystemInstallPath
                           authorization:authorization
                               arguments:directoryArguments
                                  output:NULL
                        operationPrefix:@"无法创建增强服务暂存目录"
                                   error:error]) {
            return NO;
        }
        if (lstat(directoryPath.fileSystemRepresentation, &fileStatus) != 0) {
            if (error != NULL) {
                *error = [self posixErrorWithCode:errno
                    operation:@"增强服务暂存目录创建后无法读取"];
            }
            return NO;
        }
    }

    BOOL isSafeDirectory =
        S_ISDIR(fileStatus.st_mode)
        && fileStatus.st_uid == 0
        && fileStatus.st_gid == 0
        && (fileStatus.st_mode & 0022) == 0;
    if (!isSafeDirectory && error != NULL) {
        *error = [NSError errorWithDomain:@"com.llf.MacPowerFlow.Installation"
                                     code:2
                                 userInfo:@{
            NSLocalizedDescriptionKey:
                @"增强服务暂存目录的所有者或权限不安全。",
        }];
    }
    return isSafeDirectory;
}

- (BOOL)executeAuthorizedTool:(const char *)toolPath
                authorization:(AuthorizationRef)authorization
                    arguments:(char * const *)arguments
                       output:(NSData * _Nullable * _Nullable)output
             operationPrefix:(NSString *)operationPrefix
                        error:(NSError **)error {
    FILE *communicationsPipe = NULL;
    OSStatus status = errAuthorizationSuccess;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    status = AuthorizationExecuteWithPrivileges(
        authorization,
        toolPath,
        kAuthorizationFlagDefaults,
        arguments,
        &communicationsPipe
    );
#pragma clang diagnostic pop

    if (status != errAuthorizationSuccess || communicationsPipe == NULL) {
        if (communicationsPipe != NULL) {
            fclose(communicationsPipe);
        }
        if (error != NULL) {
            *error = [self authorizationErrorWithStatus:status
                prefix:operationPrefix];
        }
        return NO;
    }

    NSMutableData *capturedOutput = [NSMutableData data];
    uint8_t buffer[4 * 1024];
    while (true) {
        size_t count = fread(buffer, 1, sizeof(buffer), communicationsPipe);
        if (count > 0) {
            NSUInteger remainingCapacity =
                capturedOutput.length < 64 * 1024
                    ? 64 * 1024 - capturedOutput.length
                    : 0;
            NSUInteger capturedCount = MIN((NSUInteger)count, remainingCapacity);
            if (capturedCount > 0) {
                [capturedOutput appendBytes:buffer length:capturedCount];
            }
        }
        if (count < sizeof(buffer)) {
            if (feof(communicationsPipe)) {
                break;
            }
            if (ferror(communicationsPipe)) {
                break;
            }
        }
    }
    fclose(communicationsPipe);
    if (output != NULL) {
        *output = [capturedOutput copy];
    }
    return YES;
}

- (NSError *)authorizationErrorWithStatus:(OSStatus)status
                                    prefix:(NSString *)prefix {
    NSError *underlying = [NSError errorWithDomain:NSOSStatusErrorDomain
                                               code:status
                                           userInfo:nil];
    return [NSError errorWithDomain:@"com.llf.MacPowerFlow.Authorization"
                               code:status
                           userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:
            @"%@：%@", prefix, underlying.localizedDescription],
        NSUnderlyingErrorKey: underlying,
    }];
}

#pragma mark - Code-signing verification

- (nullable NSString *)exactRequirementForBundledHelper:
    (NSError **)error {
    NSURL *helperURL = [[[NSBundle mainBundle] bundleURL]
        URLByAppendingPathComponent:
            [@"Contents/Library/LaunchServices"
                stringByAppendingPathComponent:MPFEmbeddedHelperName]
        isDirectory:NO];
    [self clearCodeSigningDetritusAtURL:helperURL recursively:NO];
    return [self exactRequirementForCodeAtURL:helperURL
                           expectedIdentifier:MPFHelperSigningIdentifier
                              checkNestedCode:NO
                                    operation:@"内嵌增强服务"
                                        error:error];
}

- (nullable NSString *)exactRequirementForCurrentProcess:
    (NSError **)error {
    SecCodeRef code = NULL;
    OSStatus status = SecCodeCopySelf(kSecCSDefaultFlags, &code);
    if (status != errSecSuccess || code == NULL) {
        if (error != NULL) {
            *error = [self securityErrorWithStatus:status
                operation:@"无法读取当前应用签名"];
        }
        return nil;
    }

    SecRequirementRef identifierRequirement = NULL;
    NSString *identifierText = [NSString stringWithFormat:
        @"identifier \"%@\"", MPFAppSigningIdentifier];
    status = SecRequirementCreateWithString(
        (__bridge CFStringRef)identifierText,
        kSecCSDefaultFlags,
        &identifierRequirement
    );
    if (status == errSecSuccess && identifierRequirement != NULL) {
        status = SecCodeCheckValidity(
            code,
            kSecCSStrictValidate,
            identifierRequirement
        );
    }
    if (identifierRequirement != NULL) {
        CFRelease(identifierRequirement);
    }
    if (status != errSecSuccess) {
        CFRelease(code);
        if (error != NULL) {
            *error = [self securityErrorWithStatus:status
                operation:@"当前应用运行签名无效"];
        }
        return nil;
    }

    CFDictionaryRef signingInformation = NULL;
    status = SecCodeCopySigningInformation(
        code,
        kSecCSDefaultFlags,
        &signingInformation
    );
    CFRelease(code);
    if (status != errSecSuccess || signingInformation == NULL) {
        if (error != NULL) {
            *error = [self securityErrorWithStatus:status
                operation:@"无法读取当前应用签名哈希"];
        }
        return nil;
    }

    NSDictionary *information = CFBridgingRelease(signingInformation);
    return [self exactRequirementFromSigningInformation:information
                                    expectedIdentifier:MPFAppSigningIdentifier
                                             operation:@"当前应用"
                                                 error:error];
}

- (nullable NSString *)exactRequirementForCodeAtURL:(NSURL *)codeURL
        expectedIdentifier:(NSString *)expectedIdentifier
        checkNestedCode:(BOOL)checkNestedCode
        operation:(NSString *)operation
        error:(NSError **)error {
    SecStaticCodeRef staticCode = NULL;
    OSStatus status = SecStaticCodeCreateWithPath(
        (__bridge CFURLRef)codeURL,
        kSecCSDefaultFlags,
        &staticCode
    );
    if (status != errSecSuccess || staticCode == NULL) {
        if (error != NULL) {
            *error = [self securityErrorWithStatus:status
                operation:[NSString stringWithFormat:
                    @"无法读取%@签名", operation]];
        }
        return nil;
    }

    SecRequirementRef identifierRequirement = NULL;
    NSString *requirementText = [NSString stringWithFormat:
        @"identifier \"%@\"", expectedIdentifier];
    status = SecRequirementCreateWithString(
        (__bridge CFStringRef)requirementText,
        kSecCSDefaultFlags,
        &identifierRequirement
    );
    if (status == errSecSuccess && identifierRequirement != NULL) {
        SecCSFlags validationFlags =
            kSecCSStrictValidate | kSecCSCheckAllArchitectures;
        if (checkNestedCode) {
            validationFlags |= kSecCSCheckNestedCode;
        }
        status = SecStaticCodeCheckValidity(
            staticCode,
            validationFlags,
            identifierRequirement
        );
    }
    if (identifierRequirement != NULL) {
        CFRelease(identifierRequirement);
    }
    if (status != errSecSuccess) {
        CFRelease(staticCode);
        if (error != NULL) {
            *error = [self securityErrorWithStatus:status
                operation:[NSString stringWithFormat:
                    @"%@签名无效", operation]];
        }
        return nil;
    }

    CFDictionaryRef signingInformation = NULL;
    status = SecCodeCopySigningInformation(
        staticCode,
        kSecCSDefaultFlags,
        &signingInformation
    );
    CFRelease(staticCode);
    if (status != errSecSuccess || signingInformation == NULL) {
        if (error != NULL) {
            *error = [self securityErrorWithStatus:status
                operation:[NSString stringWithFormat:
                    @"无法读取%@签名哈希", operation]];
        }
        return nil;
    }

    NSDictionary *information = CFBridgingRelease(signingInformation);
    return [self exactRequirementFromSigningInformation:information
                                    expectedIdentifier:expectedIdentifier
                                             operation:operation
                                                 error:error];
}

- (nullable NSString *)exactRequirementFromSigningInformation:
            (NSDictionary *)information
        expectedIdentifier:(NSString *)expectedIdentifier
        operation:(NSString *)operation
        error:(NSError **)error {
    NSData *cdHash = information[(__bridge NSString *)kSecCodeInfoUnique];
    NSString *identifier =
        information[(__bridge NSString *)kSecCodeInfoIdentifier];
    if (![identifier isEqualToString:expectedIdentifier]
            || cdHash.length == 0) {
        if (error != NULL) {
            *error = [NSError
                errorWithDomain:@"com.llf.MacPowerFlow.CodeSigning"
                           code:1
                       userInfo:@{
                NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:
                        @"%@缺少精确签名身份。", operation],
            }];
        }
        return nil;
    }

    const uint8_t *bytes = cdHash.bytes;
    NSMutableString *hash = [NSMutableString
        stringWithCapacity:cdHash.length * 2];
    for (NSUInteger index = 0; index < cdHash.length; ++index) {
        [hash appendFormat:@"%02x", bytes[index]];
    }
    return [NSString stringWithFormat:
        @"identifier \"%@\" and cdhash H\"%@\"",
        expectedIdentifier,
        hash];
}

- (BOOL)codeAtURL:(NSURL *)codeURL
        matchesExactRequirement:(NSString *)exactRequirement {
    SecRequirementRef requirement = NULL;
    OSStatus status = SecRequirementCreateWithString(
        (__bridge CFStringRef)exactRequirement,
        kSecCSDefaultFlags,
        &requirement
    );
    if (status != errSecSuccess || requirement == NULL) {
        if (requirement != NULL) {
            CFRelease(requirement);
        }
        return NO;
    }

    SecStaticCodeRef staticCode = NULL;
    status = SecStaticCodeCreateWithPath(
        (__bridge CFURLRef)codeURL,
        kSecCSDefaultFlags,
        &staticCode
    );
    if (status == errSecSuccess && staticCode != NULL) {
        status = SecStaticCodeCheckValidity(
            staticCode,
            kSecCSStrictValidate | kSecCSCheckAllArchitectures,
            requirement
        );
    }
    if (staticCode != NULL) {
        CFRelease(staticCode);
    }
    CFRelease(requirement);
    return status == errSecSuccess;
}

- (BOOL)installedConfigurationMatchesCurrentClient {
    NSString *path = @"/Library/Application Support/com.llf.MacPowerFlow/helper-config.plist";
    struct stat metadata = {0};
    if (lstat(path.fileSystemRepresentation, &metadata) != 0
            || !S_ISREG(metadata.st_mode) || metadata.st_uid != 0
            || metadata.st_nlink != 1 || (metadata.st_mode & 0022) != 0) {
        return NO;
    }
    NSDictionary *configuration = [NSDictionary dictionaryWithContentsOfURL:
        [NSURL fileURLWithPath:path]];
    NSError *error = nil;
    NSString *requirement = [self exactRequirementForCurrentProcess:&error];
    return requirement != nil
        && [configuration[@"ConfigurationVersion"] isEqual:@1]
        && [configuration[@"AllowedClientUID"] isEqual:@(getuid())]
        && [configuration[@"ClientCodeSigningRequirement"] isEqual:requirement];
}

- (BOOL)validateStagedToolAtPath:(NSString *)path
        expectedIdentifier:(NSString *)expectedIdentifier
        expectedRequirement:(NSString *)expectedRequirement
        operation:(NSString *)operation
        error:(NSError **)error {
    struct stat fileStatus = {0};
    if (lstat(path.fileSystemRepresentation, &fileStatus) != 0) {
        if (error != NULL) {
            *error = [self posixErrorWithCode:errno
                operation:[NSString stringWithFormat:
                    @"无法检查%@", operation]];
        }
        return NO;
    }

    BOOL hasSafeMetadata =
        S_ISREG(fileStatus.st_mode)
        && fileStatus.st_uid == 0
        && fileStatus.st_gid == 0
        && fileStatus.st_nlink == 1
        && (fileStatus.st_mode & 07777) == 0555;
    if (!hasSafeMetadata) {
        if (error != NULL) {
            *error = [NSError
                errorWithDomain:@"com.llf.MacPowerFlow.Installation"
                           code:3
                       userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:
                    @"%@的所有者或权限不安全。", operation],
            }];
        }
        return NO;
    }

    NSString *stagedRequirement = [self
        exactRequirementForCodeAtURL:[NSURL fileURLWithPath:path]
        expectedIdentifier:expectedIdentifier
        checkNestedCode:NO
        operation:operation
        error:error];
    if (stagedRequirement == nil) {
        return NO;
    }
    if (![stagedRequirement isEqualToString:expectedRequirement]) {
        if (error != NULL) {
            *error = [NSError
                errorWithDomain:@"com.llf.MacPowerFlow.CodeSigning"
                           code:2
                       userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:
                    @"%@与授权前验签的文件不一致，已拒绝执行。", operation],
            }];
        }
        return NO;
    }
    return YES;
}

- (void)clearCodeSigningDetritusAtURL:(NSURL *)url
                          recursively:(BOOL)recursively {
    NSArray<NSString *> *attributeNames = @[
        @"com.apple.FinderInfo",
        @"com.apple.ResourceFork",
    ];
    void (^clearAttributes)(NSURL *) = ^(NSURL *targetURL) {
        for (NSString *attributeName in attributeNames) {
            (void)removexattr(
                targetURL.fileSystemRepresentation,
                attributeName.UTF8String,
                XATTR_NOFOLLOW
            );
        }
    };

    clearAttributes(url);
    if (!recursively) {
        return;
    }

    NSDirectoryEnumerator<NSURL *> *enumerator =
        [NSFileManager.defaultManager
            enumeratorAtURL:url
            includingPropertiesForKeys:nil
            options:0
            errorHandler:^BOOL(NSURL *failedURL, NSError *enumerationError) {
                (void)failedURL;
                (void)enumerationError;
                return YES;
            }];
    for (NSURL *childURL in enumerator) {
        clearAttributes(childURL);
    }
}

- (NSError *)posixErrorWithCode:(int)code
                       operation:(NSString *)operation {
    NSError *underlying = [NSError errorWithDomain:NSPOSIXErrorDomain
                                               code:code
                                           userInfo:nil];
    return [NSError errorWithDomain:@"com.llf.MacPowerFlow.Installation"
                               code:code
                           userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:
            @"%@：%@", operation, underlying.localizedDescription],
        NSUnderlyingErrorKey: underlying,
    }];
}

- (NSError *)securityErrorWithStatus:(OSStatus)status
                            operation:(NSString *)operation {
    NSError *underlying = [NSError errorWithDomain:NSOSStatusErrorDomain
                                               code:status
                                           userInfo:nil];
    return [NSError errorWithDomain:@"com.llf.MacPowerFlow.CodeSigning"
                               code:status
                           userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:
            @"%@：%@", operation, underlying.localizedDescription],
        NSUnderlyingErrorKey: underlying,
    }];
}

#pragma mark - Helper callbacks

- (void)receiveData:(NSData *)data {
    MPFPrivilegedMetricsDataHandler handler = nil;
    @synchronized (self) {
        if (!_workerActive || _stopRequested) {
            return;
        }
        handler = [_dataHandler copy];
    }
    if (handler == nil) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        handler(data);
    });
}

- (void)serviceDidFail:(nullable NSString *)message {
    dispatch_async(_workerQueue, ^{
        if (![self isStopRequested]) {
            [self finishFailed:
                message ?: @"增强服务中的 powermetrics 意外停止。"];
        }
    });
}

#pragma mark - Completion

- (void)finishFailed:(NSString *)message {
    ++_connectionGeneration;
    [self invalidateConnection];
    @synchronized (self) {
        if (!_workerActive) {
            return;
        }
        _workerActive = NO;
        _stopRequested = NO;
        _dataHandler = nil;
    }
    [self publishState:MPFPrivilegedMetricsRunnerStateFailed
                message:message];
    @synchronized (self) {
        _stateHandler = nil;
    }
}

- (void)finishStopped {
    ++_connectionGeneration;
    [self invalidateConnection];
    @synchronized (self) {
        if (!_workerActive) {
            return;
        }
        _workerActive = NO;
        _stopRequested = NO;
        _dataHandler = nil;
    }
    [self publishState:MPFPrivilegedMetricsRunnerStateIdle message:nil];
    @synchronized (self) {
        _stateHandler = nil;
    }
}

- (BOOL)isStopRequested {
    @synchronized (self) {
        return _stopRequested;
    }
}

- (void)publishState:(MPFPrivilegedMetricsRunnerState)state
              message:(nullable NSString *)message {
    MPFPrivilegedMetricsStateHandler handler = nil;
    @synchronized (self) {
        _state = state;
        handler = [_stateHandler copy];
    }
    if (handler == nil) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        handler(state, message);
    });
}

@end
