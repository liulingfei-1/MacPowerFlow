import Foundation

/// Names and paths shared by the GUI, one-shot installer, and root helper.
///
/// The privileged side deliberately exposes no configurable executable path or
/// command arguments. Every value that controls installation or execution is a
/// compile-time constant.
enum MPFPrivilegedService {
    static let serviceLabel = "com.llf.MacPowerFlow.PrivilegedHelper"
    static let machServiceName = "com.llf.MacPowerFlow.PrivilegedHelper"

    static let appSigningIdentifier = "com.llf.MacPowerFlow"
    static let helperSigningIdentifier =
        "com.llf.MacPowerFlow.PrivilegedHelper"
    static let installerSigningIdentifier =
        "com.llf.MacPowerFlow.PrivilegedInstaller"

    static let embeddedHelperExecutableName =
        "com.llf.MacPowerFlow.PrivilegedHelper"
    static let embeddedInstallerExecutableName =
        "com.llf.MacPowerFlow.PrivilegedInstaller"
    static let protocolVersion = 1
    static let helperVersion = "1.5.0"
    static let retryableSessionBusyMarker = "MPF_RETRY_SESSION_BUSY"

    static let installedHelperPath =
        "/Library/PrivilegedHelperTools/" +
        "com.llf.MacPowerFlow.PrivilegedHelper"
    static let stagedHelperPath =
        "/Library/PrivilegedHelperTools/" +
        ".com.llf.MacPowerFlow.PrivilegedHelper.staging"
    static let stagedInstallerPath =
        "/Library/PrivilegedHelperTools/" +
        ".com.llf.MacPowerFlow.PrivilegedInstaller.staging"
    static let launchDaemonPlistPath =
        "/Library/LaunchDaemons/" +
        "com.llf.MacPowerFlow.PrivilegedHelper.plist"
    static let configurationDirectoryPath =
        "/Library/Application Support/com.llf.MacPowerFlow"
    static let configurationPath =
        "/Library/Application Support/com.llf.MacPowerFlow/helper-config.plist"

    static let configurationRequirementKey = "ClientCodeSigningRequirement"
    static let configurationUIDKey = "AllowedClientUID"
    static let configurationVersionKey = "ConfigurationVersion"
    static let configurationVersion = 1

    static let powermetricsPath = "/usr/bin/powermetrics"
    static let powermetricsArguments = [
        "--samplers",
        "cpu_power,gpu_power,ane_power,thermal",
        "--sample-rate",
        "2000",
        "--sample-count",
        "-1",
        "--format",
        "plist",
        "--buffer-size",
        "1",
        "--poweravg",
        "0",
        "--handle-invalid-values",
    ]
}
