import Foundation

/// Names and paths shared by the GUI, one-shot installer, and root helper.
///
/// The privileged side deliberately exposes no configurable executable path or
/// command arguments. Every value that controls installation or execution is a
/// compile-time constant or a validated fixed cadence/power-mode choice.
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
    static let protocolVersion = 2
    static let helperVersion = "1.7.0"
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
    static let allowedSamplingIntervals = [2, 5, 10]
    static func samplingArguments(intervalSeconds: Int) -> [String]? {
        guard allowedSamplingIntervals.contains(intervalSeconds) else { return nil }
        var arguments = powermetricsArguments
        arguments[3] = String(intervalSeconds * 1000)
        return arguments
    }
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
        "0",
        "--poweravg",
        "0",
        "--handle-invalid-values",
    ]
}

/// Pure command policy. No user text is ever accepted as an executable or argument.
nonisolated enum MPFLowPowerPolicy {
    static let executable = "/usr/bin/pmset"
    static func arguments(source: Int, enabled: Int) -> [String]? {
        guard (source == 0 || source == 1), (enabled == 0 || enabled == 1) else { return nil }
        return [source == 0 ? "-b" : "-c", "lowpowermode", String(enabled)]
    }
    static func supportsLowPower(_ capabilities: String) -> Bool {
        capabilities.split(whereSeparator: \.isWhitespace).contains("lowpowermode")
    }
    static func configuredValue(source: Int, output: String) -> Bool? {
        guard source == 0 || source == 1 else { return nil }
        let expected = source == 0 ? "Battery Power:" : "AC Power:"
        var selected = false
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix(":") { selected = line == expected; continue }
            if selected {
                let fields = line.split(whereSeparator: \.isWhitespace)
                if fields.count == 2, fields[0] == "lowpowermode" {
                    if fields[1] == "0" { return false }
                    if fields[1] == "1" { return true }
                    return nil
                }
            }
        }
        return nil
    }
}
