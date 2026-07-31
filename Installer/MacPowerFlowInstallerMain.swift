import Darwin
import Foundation
import Security

private enum InstallerFailure: LocalizedError {
    case message(String)
    case osStatus(String, OSStatus)
    case posix(String, Int32)

    var errorDescription: String? {
        switch self {
        case let .message(message):
            return message
        case let .osStatus(operation, status):
            let detail = SecCopyErrorMessageString(status, nil) as String?
            return "\(operation) failed (\(status)): \(detail ?? "unknown error")"
        case let .posix(operation, code):
            return "\(operation) failed (\(code)): \(String(cString: strerror(code)))"
        }
    }
}

private struct InstallerInvocation {
    let clientRequirement: String
    let invokingUID: uid_t

    static func parse() throws -> InstallerInvocation {
        guard CommandLine.arguments.count == 3 else {
            throw InstallerFailure.message(
                "Expected an exact client requirement and invoking UID."
            )
        }

        let clientRequirement = try parseClientRequirement(
            CommandLine.arguments[1]
        )
        let invokingUID = try parseInvokingUID(CommandLine.arguments[2])
        return InstallerInvocation(
            clientRequirement: clientRequirement,
            invokingUID: invokingUID
        )
    }

    private static func parseClientRequirement(
        _ value: String
    ) throws -> String {
        let prefix =
            "identifier \"\(MPFPrivilegedService.appSigningIdentifier)\" " +
            "and cdhash H\""
        guard value.hasPrefix(prefix), value.hasSuffix("\"") else {
            throw InstallerFailure.message(
                "The client code requirement has an invalid format."
            )
        }

        let hashStart = value.index(
            value.startIndex,
            offsetBy: prefix.count
        )
        let hashEnd = value.index(before: value.endIndex)
        let hash = value[hashStart..<hashEnd]
        guard hash.utf8.count == 40,
              hash.utf8.allSatisfy({
                  ($0 >= 48 && $0 <= 57)
                      || ($0 >= 65 && $0 <= 70)
                      || ($0 >= 97 && $0 <= 102)
              }) else {
            throw InstallerFailure.message(
                "The client code requirement must contain one 20-byte cdhash."
            )
        }

        var parsedRequirement: SecRequirement?
        let status = SecRequirementCreateWithString(
            value as CFString,
            SecCSFlags(),
            &parsedRequirement
        )
        guard status == errSecSuccess, parsedRequirement != nil else {
            throw InstallerFailure.osStatus(
                "Parse client code requirement",
                status
            )
        }
        return value
    }

    private static func parseInvokingUID(_ value: String) throws -> uid_t {
        guard !value.isEmpty,
              value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let rawValue = UInt32(value),
              rawValue > 0,
              rawValue != UInt32.max else {
            throw InstallerFailure.message(
                "The invoking UID is invalid."
            )
        }
        return uid_t(rawValue)
    }
}

private enum CodeSigningVerifier {
    static func verify(
        at url: URL,
        expectedIdentifier: String
    ) throws {
        var staticCode: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(
            url as CFURL,
            SecCSFlags(),
            &staticCode
        )
        guard status == errSecSuccess, let staticCode else {
            throw InstallerFailure.osStatus(
                "Create static code for \(url.lastPathComponent)",
                status
            )
        }

        var requirement: SecRequirement?
        status = SecRequirementCreateWithString(
            "identifier \"\(expectedIdentifier)\"" as CFString,
            SecCSFlags(),
            &requirement
        )
        guard status == errSecSuccess, let requirement else {
            throw InstallerFailure.osStatus(
                "Create code requirement for \(expectedIdentifier)",
                status
            )
        }

        let validationFlags =
            kSecCSCheckAllArchitectures | kSecCSStrictValidate
        var validationError: Unmanaged<CFError>?
        status = SecStaticCodeCheckValidityWithErrors(
            staticCode,
            SecCSFlags(rawValue: validationFlags),
            requirement,
            &validationError
        )
        guard status == errSecSuccess else {
            let detail = validationError?.takeRetainedValue()
            if let detail {
                throw InstallerFailure.message(
                    "Code validation failed for \(url.lastPathComponent): " +
                    "\(detail.localizedDescription)"
                )
            }
            throw InstallerFailure.osStatus(
                "Validate \(url.lastPathComponent)",
                status
            )
        }

        var information: CFDictionary?
        status = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        guard status == errSecSuccess,
              let dictionary = information as? [CFString: Any],
              let signingIdentifier =
                dictionary[kSecCodeInfoIdentifier] as? String,
              signingIdentifier == expectedIdentifier else {
            if status != errSecSuccess {
                throw InstallerFailure.osStatus(
                    "Read signing information for \(url.lastPathComponent)",
                    status
                )
            }
            throw InstallerFailure.message(
                "Signing information for \(url.lastPathComponent) is incomplete."
            )
        }
    }
}

private enum SecureFilesystem {
    static func currentExecutableURL() throws -> URL {
        var requiredSize: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &requiredSize)
        guard requiredSize > 1 else {
            throw InstallerFailure.message(
                "Unable to determine the installer executable path."
            )
        }

        var buffer = [CChar](repeating: 0, count: Int(requiredSize))
        guard _NSGetExecutablePath(&buffer, &requiredSize) == 0 else {
            throw InstallerFailure.message(
                "Unable to read the installer executable path."
            )
        }

        let executablePath = String(cString: buffer)
        guard let resolvedPath = realpath(executablePath, nil) else {
            throw InstallerFailure.posix(
                "Resolve installer executable path",
                errno
            )
        }
        defer { free(resolvedPath) }

        let resolvedURL = URL(
            fileURLWithPath: String(cString: resolvedPath),
            isDirectory: false
        )
        guard resolvedURL.path ==
                MPFPrivilegedService.stagedInstallerPath else {
            throw InstallerFailure.message(
                "The installer is not running from the fixed staging path."
            )
        }
        return resolvedURL
    }

    static func requireRootOwnedExecutable(_ url: URL) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw InstallerFailure.posix(
                "Inspect \(url.lastPathComponent)",
                errno
            )
        }
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              status.st_uid == 0,
              status.st_gid == 0,
              (status.st_mode & 0o022) == 0,
              (status.st_mode & S_IXUSR) != 0 else {
            throw InstallerFailure.message(
                "\(url.lastPathComponent) must be a root-owned, " +
                "non-writable executable."
            )
        }
    }

    static func ensureRootDirectory(
        _ path: String,
        mode: mode_t
    ) throws {
        var status = stat()
        var wasCreated = false
        if lstat(path, &status) != 0 {
            guard errno == ENOENT else {
                throw InstallerFailure.posix("Inspect \(path)", errno)
            }
            do {
                try FileManager.default.createDirectory(
                    atPath: path,
                    withIntermediateDirectories: false
                )
            } catch {
                throw InstallerFailure.message(
                    "Create \(path) failed: \(error.localizedDescription)"
                )
            }
            guard lstat(path, &status) == 0 else {
                throw InstallerFailure.posix("Inspect \(path)", errno)
            }
            wasCreated = true
        }

        if wasCreated {
            guard chown(path, 0, 0) == 0 else {
                throw InstallerFailure.posix(
                    "Set ownership on \(path)",
                    errno
                )
            }
            guard chmod(path, mode) == 0 else {
                throw InstallerFailure.posix(
                    "Set permissions on \(path)",
                    errno
                )
            }
            guard lstat(path, &status) == 0 else {
                throw InstallerFailure.posix("Inspect \(path)", errno)
            }
        }
        guard (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == 0,
              status.st_gid == 0,
              (status.st_mode & 0o022) == 0 else {
            throw InstallerFailure.message(
                "\(path) has unsafe ownership or permissions."
            )
        }
    }

    static func atomicInstall(
        sourceURL: URL,
        targetPath: String,
        mode: mode_t,
        validateStagedCode: ((URL) throws -> Void)? = nil
    ) throws {
        try requireRootOwnedExecutable(sourceURL)

        let sourceDescriptor = open(
            sourceURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard sourceDescriptor >= 0 else {
            throw InstallerFailure.posix(
                "Open \(sourceURL.lastPathComponent)",
                errno
            )
        }
        defer { close(sourceDescriptor) }

        let temporaryPath =
            "\(targetPath).installing.\(getpid()).\(UUID().uuidString)"
        let targetDescriptor = open(
            temporaryPath,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard targetDescriptor >= 0 else {
            throw InstallerFailure.posix(
                "Create installation staging file",
                errno
            )
        }

        var targetIsOpen = true
        defer {
            if targetIsOpen {
                close(targetDescriptor)
            }
            unlink(temporaryPath)
        }

        var buffer = [UInt8](repeating: 0, count: 128 * 1_024)
        while true {
            let count = read(sourceDescriptor, &buffer, buffer.count)
            if count == 0 {
                break
            }
            guard count > 0 else {
                if errno == EINTR {
                    continue
                }
                throw InstallerFailure.posix(
                    "Read \(sourceURL.lastPathComponent)",
                    errno
                )
            }

            var written = 0
            while written < count {
                let result = buffer.withUnsafeBytes { bytes in
                    write(
                        targetDescriptor,
                        bytes.baseAddress!.advanced(by: written),
                        count - written
                    )
                }
                guard result >= 0 else {
                    if errno == EINTR {
                        continue
                    }
                    throw InstallerFailure.posix(
                        "Write installation staging file",
                        errno
                    )
                }
                written += result
            }
        }

        guard fchown(targetDescriptor, 0, 0) == 0 else {
            throw InstallerFailure.posix(
                "Set staging file ownership",
                errno
            )
        }
        guard fchmod(targetDescriptor, mode) == 0 else {
            throw InstallerFailure.posix(
                "Set staging file permissions",
                errno
            )
        }
        guard fsync(targetDescriptor) == 0 else {
            throw InstallerFailure.posix("Sync staging file", errno)
        }
        guard close(targetDescriptor) == 0 else {
            targetIsOpen = false
            throw InstallerFailure.posix("Close staging file", errno)
        }
        targetIsOpen = false

        let temporaryURL = URL(fileURLWithPath: temporaryPath)
        try validateStagedCode?(temporaryURL)

        guard rename(temporaryPath, targetPath) == 0 else {
            throw InstallerFailure.posix(
                "Commit \(URL(fileURLWithPath: targetPath).lastPathComponent)",
                errno
            )
        }
        try verifyInstalledFile(
            atPath: targetPath,
            mode: mode,
            executable: true
        )
        try syncParentDirectory(of: targetPath)
    }

    static func atomicWrite(
        data: Data,
        targetPath: String,
        mode: mode_t
    ) throws {
        let temporaryPath =
            "\(targetPath).installing.\(getpid()).\(UUID().uuidString)"
        let descriptor = open(
            temporaryPath,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw InstallerFailure.posix(
                "Create installation staging file",
                errno
            )
        }

        var descriptorIsOpen = true
        defer {
            if descriptorIsOpen {
                close(descriptor)
            }
            unlink(temporaryPath)
        }

        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let result = write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: written),
                    bytes.count - written
                )
                guard result >= 0 else {
                    if errno == EINTR {
                        continue
                    }
                    throw InstallerFailure.posix(
                        "Write installation staging file",
                        errno
                    )
                }
                written += result
            }
        }

        guard fchown(descriptor, 0, 0) == 0 else {
            throw InstallerFailure.posix(
                "Set staging file ownership",
                errno
            )
        }
        guard fchmod(descriptor, mode) == 0 else {
            throw InstallerFailure.posix(
                "Set staging file permissions",
                errno
            )
        }
        guard fsync(descriptor) == 0 else {
            throw InstallerFailure.posix("Sync staging file", errno)
        }
        guard close(descriptor) == 0 else {
            descriptorIsOpen = false
            throw InstallerFailure.posix("Close staging file", errno)
        }
        descriptorIsOpen = false

        guard rename(temporaryPath, targetPath) == 0 else {
            throw InstallerFailure.posix(
                "Commit \(URL(fileURLWithPath: targetPath).lastPathComponent)",
                errno
            )
        }
        try verifyInstalledFile(
            atPath: targetPath,
            mode: mode,
            executable: false
        )
        try syncParentDirectory(of: targetPath)
    }

    static func removeStagingFiles() {
        for path in [
            MPFPrivilegedService.stagedHelperPath,
            MPFPrivilegedService.stagedInstallerPath,
        ] {
            if unlink(path) != 0, errno != ENOENT {
                let message =
                    "Unable to remove staging file \(path): " +
                    "\(String(cString: strerror(errno)))\n"
                FileHandle.standardError.write(Data(message.utf8))
            }
        }
    }

    private static func verifyInstalledFile(
        atPath path: String,
        mode: mode_t,
        executable: Bool
    ) throws {
        var status = stat()
        guard lstat(path, &status) == 0 else {
            throw InstallerFailure.posix("Inspect \(path)", errno)
        }
        let permissions = status.st_mode & 0o777
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              status.st_uid == 0,
              status.st_gid == 0,
              permissions == mode,
              !executable || (status.st_mode & S_IXUSR) != 0 else {
            throw InstallerFailure.message(
                "\(path) has unsafe ownership or permissions."
            )
        }
    }

    private static func syncParentDirectory(of path: String) throws {
        let parentPath = URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .path
        let descriptor = open(parentPath, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw InstallerFailure.posix(
                "Open parent directory for \(path)",
                errno
            )
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw InstallerFailure.posix(
                "Sync parent directory for \(path)",
                errno
            )
        }
    }
}

private enum LaunchDaemonController {
    static func reload() throws {
        _ = try runLaunchctl(
            arguments: [
                "bootout",
                "system/\(MPFPrivilegedService.serviceLabel)",
            ],
            allowFailure: true
        )

        _ = try runLaunchctl(
            arguments: [
                "bootstrap",
                "system",
                MPFPrivilegedService.launchDaemonPlistPath,
            ],
            allowFailure: false
        )
    }

    private static func runLaunchctl(
        arguments: [String],
        allowFailure: Bool
    ) throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "C",
            "LC_ALL": "C",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            throw InstallerFailure.message(
                "launchctl could not start: \(error.localizedDescription)"
            )
        }
        process.waitUntilExit()
        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus != 0, !allowFailure {
            throw InstallerFailure.message(
                "launchctl \(arguments.first ?? "") failed " +
                "(\(process.terminationStatus)): \(output)"
            )
        }
        return output
    }
}

private enum Installer {
    static func run() throws {
        guard geteuid() == 0 else {
            throw InstallerFailure.message(
                "The installer must be authorized to run as root."
            )
        }

        let installerURL = try SecureFilesystem.currentExecutableURL()
        defer {
            SecureFilesystem.removeStagingFiles()
        }

        let helperURL = URL(
            fileURLWithPath: MPFPrivilegedService.stagedHelperPath,
            isDirectory: false
        )
        let invocation = try InstallerInvocation.parse()

        try SecureFilesystem.requireRootOwnedExecutable(installerURL)
        try SecureFilesystem.requireRootOwnedExecutable(helperURL)
        try CodeSigningVerifier.verify(
            at: installerURL,
            expectedIdentifier: MPFPrivilegedService
                .installerSigningIdentifier
        )
        try CodeSigningVerifier.verify(
            at: helperURL,
            expectedIdentifier: MPFPrivilegedService.helperSigningIdentifier
        )

        try SecureFilesystem.ensureRootDirectory(
            "/Library/PrivilegedHelperTools",
            mode: 0o755
        )
        try SecureFilesystem.ensureRootDirectory(
            "/Library/LaunchDaemons",
            mode: 0o755
        )
        try SecureFilesystem.ensureRootDirectory(
            MPFPrivilegedService.configurationDirectoryPath,
            mode: 0o755
        )

        try SecureFilesystem.atomicInstall(
            sourceURL: helperURL,
            targetPath: MPFPrivilegedService.installedHelperPath,
            mode: 0o555,
            validateStagedCode: { stagedURL in
                try CodeSigningVerifier.verify(
                    at: stagedURL,
                    expectedIdentifier: MPFPrivilegedService
                        .helperSigningIdentifier
                )
            }
        )

        let configuration: [String: Any] = [
            MPFPrivilegedService.configurationVersionKey:
                MPFPrivilegedService.configurationVersion,
            MPFPrivilegedService.configurationRequirementKey:
                invocation.clientRequirement,
            MPFPrivilegedService.configurationUIDKey:
                NSNumber(value: invocation.invokingUID),
        ]
        let configurationData =
            try PropertyListSerialization.data(
                fromPropertyList: configuration,
                format: .xml,
                options: 0
            )
        try SecureFilesystem.atomicWrite(
            data: configurationData,
            targetPath: MPFPrivilegedService.configurationPath,
            mode: 0o444
        )

        let launchDaemon: [String: Any] = [
            "Label": MPFPrivilegedService.serviceLabel,
            "ProgramArguments": [
                MPFPrivilegedService.installedHelperPath,
            ],
            "MachServices": [
                MPFPrivilegedService.machServiceName: true,
            ],
            "ProcessType": "Background",
        ]
        let launchDaemonData =
            try PropertyListSerialization.data(
                fromPropertyList: launchDaemon,
                format: .xml,
                options: 0
            )
        try SecureFilesystem.atomicWrite(
            data: launchDaemonData,
            targetPath: MPFPrivilegedService.launchDaemonPlistPath,
            mode: 0o444
        )

        try LaunchDaemonController.reload()
    }
}

@main
private enum MacPowerFlowInstallerMain {
    static func main() {
        do {
            try Installer.run()
            FileHandle.standardOutput.write(
                Data("MPF_INSTALL_OK\n".utf8)
            )
        } catch {
            let message =
                "MacPowerFlow helper installation failed: " +
                "\(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(EXIT_FAILURE)
        }
    }
}
