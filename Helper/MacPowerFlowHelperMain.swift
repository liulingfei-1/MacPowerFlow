import Darwin
import Foundation
import Security

private enum HelperFailure: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(message):
            return message
        }
    }
}

private struct HelperConfiguration {
    let clientCodeSigningRequirement: String
    let allowedClientUID: uid_t?

    static func load() throws -> HelperConfiguration {
        guard geteuid() == 0 else {
            throw HelperFailure.message("The privileged helper must run as root.")
        }

        let executablePath = URL(
            fileURLWithPath: CommandLine.arguments[0]
        ).standardizedFileURL.resolvingSymlinksInPath().path
        guard executablePath == MPFPrivilegedService.installedHelperPath else {
            throw HelperFailure.message(
                "The privileged helper is not running from its installed path."
            )
        }

        var fileStatus = stat()
        guard lstat(
            MPFPrivilegedService.configurationPath,
            &fileStatus
        ) == 0 else {
            throw HelperFailure.message("The helper configuration is missing.")
        }

        guard (fileStatus.st_mode & S_IFMT) == S_IFREG,
              fileStatus.st_uid == 0,
              fileStatus.st_nlink == 1,
              (fileStatus.st_mode & 0o022) == 0 else {
            throw HelperFailure.message(
                "The helper configuration has unsafe ownership or permissions."
            )
        }

        let data = try Data(
            contentsOf: URL(
                fileURLWithPath: MPFPrivilegedService.configurationPath
            ),
            options: [.mappedIfSafe]
        )
        let propertyList = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        guard let dictionary = propertyList as? [String: Any],
              let version = dictionary[
                MPFPrivilegedService.configurationVersionKey
              ] as? Int,
              version == MPFPrivilegedService.configurationVersion,
              let requirement = dictionary[
                MPFPrivilegedService.configurationRequirementKey
              ] as? String,
              !requirement.isEmpty else {
            throw HelperFailure.message("The helper configuration is invalid.")
        }

        var parsedRequirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(
            requirement as CFString,
            SecCSFlags(),
            &parsedRequirement
        )
        guard requirementStatus == errSecSuccess,
              parsedRequirement != nil else {
            throw HelperFailure.message(
                "The configured client code requirement is malformed."
            )
        }

        let allowedUID: uid_t?
        if let number = dictionary[
            MPFPrivilegedService.configurationUIDKey
        ] as? NSNumber {
            let value = number.uint64Value
            guard value <= uid_t.max else {
                throw HelperFailure.message(
                    "The configured client user identifier is invalid."
                )
            }
            allowedUID = uid_t(value)
        } else {
            allowedUID = nil
        }

        return HelperConfiguration(
            clientCodeSigningRequirement: requirement,
            allowedClientUID: allowedUID
        )
    }
}

private final class MetricsCoordinator {
    static let shared = MetricsCoordinator()

    private struct SpawnedProcess {
        let processIdentifier: pid_t
        let outputDescriptor: Int32
        let errorDescriptor: Int32
    }

    private enum StreamKind {
        case output
        case error
    }

    private let queue = DispatchQueue(
        label: "com.llf.MacPowerFlow.Helper.powermetrics"
    )
    private var ownerIdentifier: UUID?
    private var childProcessIdentifier: pid_t?
    private var outputDescriptor: Int32 = -1
    private var errorDescriptor: Int32 = -1
    private var outputSource: DispatchSourceRead?
    private var errorSource: DispatchSourceRead?
    private var processSource: DispatchSourceProcess?
    private var errorBuffer = Data()
    private var requestedStop = false
    private var outputWasObserved = false
    private var sendData: ((Data) -> Void)?
    private var sendFailure: ((String) -> Void)?

    private init() {}

    func start(
        owner: UUID,
        intervalSeconds: Int = 2,
        sendData: @escaping (Data) -> Void,
        sendFailure: @escaping (String) -> Void,
        reply: @escaping (Bool, String?) -> Void
    ) {
        guard MPFPrivilegedService.allowedSamplingIntervals.contains(intervalSeconds) else {
            reply(false, "采样间隔只能为2、5或10秒。")
            return
        }
        queue.async {
            self.reapFinishedChildIfNeeded()
            guard self.childProcessIdentifier == nil else {
                if self.ownerIdentifier == owner {
                    reply(true, nil)
                } else {
                    reply(
                        false,
                        MPFPrivilegedService.retryableSessionBusyMarker +
                            ": the previous sampling session is still stopping."
                    )
                }
                return
            }

            do {
                let spawnedProcess = try self.spawnPowermetrics(intervalSeconds: intervalSeconds)
                self.ownerIdentifier = owner
                self.childProcessIdentifier =
                    spawnedProcess.processIdentifier
                self.outputDescriptor = spawnedProcess.outputDescriptor
                self.errorDescriptor = spawnedProcess.errorDescriptor
                self.errorBuffer.removeAll(keepingCapacity: true)
                self.requestedStop = false
                self.outputWasObserved = false
                self.sendData = sendData
                self.sendFailure = sendFailure
                self.beginReading(
                    descriptor: spawnedProcess.outputDescriptor,
                    kind: .output,
                    owner: owner
                )
                self.beginReading(
                    descriptor: spawnedProcess.errorDescriptor,
                    kind: .error,
                    owner: owner
                )
                self.beginWatching(
                    for: spawnedProcess.processIdentifier,
                    owner: owner
                )
                self.requestInitialSamples(
                    processIdentifier: spawnedProcess.processIdentifier,
                    owner: owner
                )
                reply(true, nil)
            } catch {
                reply(
                    false,
                    "Unable to launch powermetrics: \(error.localizedDescription)"
                )
            }
        }
    }

    /// Reconciles a process that exited before its dispatch source delivered.
    /// This closes the short handoff race between one app session invalidating
    /// its XPC connection and the next session asking to start.
    private func reapFinishedChildIfNeeded() {
        guard let processIdentifier = childProcessIdentifier,
              let owner = ownerIdentifier else {
            return
        }

        var waitStatus: Int32 = 0
        let result = Darwin.waitpid(processIdentifier, &waitStatus, WNOHANG)
        if result == processIdentifier {
            finish(
                processIdentifier: processIdentifier,
                owner: owner,
                waitStatus: waitStatus,
                waitError: nil
            )
        } else if result == -1, errno == ECHILD {
            // A process source may have reaped the child immediately before
            // this queued start request. Its callback is then harmless because
            // cleanUp clears the tracked PID and owner.
            cleanUp()
        }
    }

    /// powermetrics can spend several seconds establishing its first delta
    /// baseline on recent macOS releases. SIGINFO requests an immediate sample,
    /// while SIGIO flushes any bytes the process still buffered. Several
    /// guarded requests cover cold launches without disturbing a healthy stream.
    private func requestInitialSamples(
        processIdentifier: pid_t,
        owner: UUID
    ) {
        for delay in [0.75, 3.5, 10.0, 20.0] {
            queue.asyncAfter(deadline: .now() + delay) {
                guard self.childProcessIdentifier == processIdentifier,
                      self.ownerIdentifier == owner,
                      !self.requestedStop else {
                    return
                }
                if !self.outputWasObserved {
                    _ = Darwin.kill(processIdentifier, SIGINFO)
                }

                // Flush even after the first bytes arrive: observed output can
                // still be only a partial plist without its NUL delimiter.
                self.queue.asyncAfter(deadline: .now() + 0.25) {
                    guard self.childProcessIdentifier == processIdentifier,
                          self.ownerIdentifier == owner,
                          !self.requestedStop else {
                        return
                    }
                    _ = Darwin.kill(processIdentifier, SIGIO)
                }
            }
        }
    }

    func stop(
        owner: UUID,
        reply: ((Bool, String?) -> Void)? = nil
    ) {
        queue.async {
            guard let processIdentifier = self.childProcessIdentifier else {
                reply?(true, nil)
                return
            }
            guard self.ownerIdentifier == owner else {
                reply?(false, "This connection does not own the active sample.")
                return
            }

            self.requestedStop = true
            if Darwin.kill(processIdentifier, SIGTERM) != 0,
               errno != ESRCH {
                let code = errno
                reply?(
                    false,
                    "Unable to stop powermetrics: " +
                    "\(String(cString: strerror(code)))"
                )
                return
            }

            self.queue.asyncAfter(deadline: .now() + 2) {
                guard self.childProcessIdentifier == processIdentifier,
                      self.ownerIdentifier == owner else {
                    return
                }
                if Darwin.kill(processIdentifier, SIGKILL) != 0,
                   errno != ESRCH {
                    self.appendErrorText(
                        "Unable to force-stop powermetrics: " +
                        "\(String(cString: strerror(errno)))"
                    )
                }
            }
            reply?(true, nil)
        }
    }

    private func spawnPowermetrics(intervalSeconds: Int) throws -> SpawnedProcess {
        guard let samplingArguments = MPFPrivilegedService.samplingArguments(intervalSeconds: intervalSeconds) else {
            throw HelperFailure.message("采样间隔无效。")
        }
        var outputPipe = [Int32](repeating: -1, count: 2)
        var errorPipe = [Int32](repeating: -1, count: 2)
        guard outputPipe.withUnsafeMutableBufferPointer({
            Darwin.pipe($0.baseAddress!)
        }) == 0 else {
            throw HelperFailure.message(
                "Unable to create the powermetrics output pipe: " +
                "\(String(cString: strerror(errno)))"
            )
        }

        guard errorPipe.withUnsafeMutableBufferPointer({
            Darwin.pipe($0.baseAddress!)
        }) == 0 else {
            let code = errno
            close(outputPipe[0])
            close(outputPipe[1])
            throw HelperFailure.message(
                "Unable to create the powermetrics error pipe: " +
                "\(String(cString: strerror(code)))"
            )
        }

        var descriptorsToClose = Set(outputPipe + errorPipe)
        defer {
            for descriptor in descriptorsToClose where descriptor >= 0 {
                close(descriptor)
            }
        }

        for descriptor in descriptorsToClose {
            try setCloseOnExec(descriptor)
        }
        try setNonBlocking(outputPipe[0])
        try setNonBlocking(errorPipe[0])

        var fileActions: posix_spawn_file_actions_t?
        var status = posix_spawn_file_actions_init(&fileActions)
        guard status == 0 else {
            throw spawnFailure(
                operation: "Initialize posix_spawn file actions",
                code: status
            )
        }
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
        }

        status = "/dev/null".withCString {
            posix_spawn_file_actions_addopen(
                &fileActions,
                STDIN_FILENO,
                $0,
                O_RDONLY,
                0
            )
        }
        try requireSpawnSuccess(
            status,
            operation: "Redirect powermetrics standard input"
        )
        try requireSpawnSuccess(
            posix_spawn_file_actions_adddup2(
                &fileActions,
                outputPipe[1],
                STDOUT_FILENO
            ),
            operation: "Redirect powermetrics standard output"
        )
        try requireSpawnSuccess(
            posix_spawn_file_actions_adddup2(
                &fileActions,
                errorPipe[1],
                STDERR_FILENO
            ),
            operation: "Redirect powermetrics standard error"
        )

        for descriptor in descriptorsToClose {
            try requireSpawnSuccess(
                posix_spawn_file_actions_addclose(
                    &fileActions,
                    descriptor
                ),
                operation: "Close inherited powermetrics pipe descriptor"
            )
        }

        let arguments =
            [MPFPrivilegedService.powermetricsPath] +
            samplingArguments
        let environment = [
            "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG=C",
            "LC_ALL=C",
        ]
        let argumentStorage = try duplicateCStringArray(arguments)
        defer {
            argumentStorage.forEach { free($0) }
        }
        let environmentStorage = try duplicateCStringArray(environment)
        defer {
            environmentStorage.forEach { free($0) }
        }

        var argumentPointers =
            argumentStorage.map { Optional($0) } + [nil]
        var environmentPointers =
            environmentStorage.map { Optional($0) } + [nil]
        var processIdentifier: pid_t = 0

        // No POSIX_SPAWN_SETPGROUP flag is used. powermetrics intentionally
        // inherits the helper's process group so lifecycle signals remain
        // scoped to the exact PID tracked below.
        status = MPFPrivilegedService.powermetricsPath.withCString { path in
            argumentPointers.withUnsafeMutableBufferPointer { arguments in
                environmentPointers.withUnsafeMutableBufferPointer {
                    environment in
                    posix_spawn(
                        &processIdentifier,
                        path,
                        &fileActions,
                        nil,
                        arguments.baseAddress!,
                        environment.baseAddress!
                    )
                }
            }
        }
        try requireSpawnSuccess(status, operation: "Spawn powermetrics")

        close(outputPipe[1])
        descriptorsToClose.remove(outputPipe[1])
        close(errorPipe[1])
        descriptorsToClose.remove(errorPipe[1])

        descriptorsToClose.remove(outputPipe[0])
        descriptorsToClose.remove(errorPipe[0])
        return SpawnedProcess(
            processIdentifier: processIdentifier,
            outputDescriptor: outputPipe[0],
            errorDescriptor: errorPipe[0]
        )
    }

    private func beginReading(
        descriptor: Int32,
        kind: StreamKind,
        owner: UUID
    ) {
        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.drain(
                descriptor: descriptor,
                kind: kind,
                owner: owner
            )
        }
        switch kind {
        case .output:
            outputSource = source
        case .error:
            errorSource = source
        }
        source.activate()
    }

    private func drain(
        descriptor: Int32,
        kind: StreamKind,
        owner: UUID
    ) {
        guard ownerIdentifier == owner,
              currentDescriptor(for: kind) == descriptor else {
            return
        }

        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(
                    descriptor,
                    bytes.baseAddress!,
                    bytes.count
                )
            }

            if count > 0 {
                let data = Data(buffer.prefix(count))
                switch kind {
                case .output:
                    outputWasObserved = true
                    sendData?(data)
                case .error:
                    appendErrorOutput(data)
                }
                continue
            }

            if count == 0 {
                closeStream(kind, expectedDescriptor: descriptor)
                return
            }

            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            }

            appendErrorText(
                "Unable to read powermetrics " +
                "\(kind == .output ? "output" : "error output"): " +
                "\(String(cString: strerror(errno)))"
            )
            closeStream(kind, expectedDescriptor: descriptor)
            return
        }
    }

    private func beginWatching(for processIdentifier: pid_t, owner: UUID) {
        let source = DispatchSource.makeProcessSource(
            identifier: processIdentifier,
            eventMask: .exit,
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.reap(processIdentifier: processIdentifier, owner: owner)
        }
        processSource = source
        source.activate()
    }

    private func reap(processIdentifier: pid_t, owner: UUID) {
        guard childProcessIdentifier == processIdentifier,
              ownerIdentifier == owner else {
            return
        }

        var waitStatus: Int32 = 0
        var result: pid_t
        repeat {
            result = Darwin.waitpid(processIdentifier, &waitStatus, 0)
        } while result == -1 && errno == EINTR

        let waitError = result == -1 ? errno : nil
        finish(
            processIdentifier: processIdentifier,
            owner: owner,
            waitStatus: result == processIdentifier ? waitStatus : nil,
            waitError: waitError
        )
    }

    private func finish(
        processIdentifier: pid_t,
        owner: UUID,
        waitStatus: Int32?,
        waitError: Int32?
    ) {
        guard childProcessIdentifier == processIdentifier,
              ownerIdentifier == owner else {
            return
        }

        // The child has closed its pipe writers. Drain buffered tail data
        // before canceling the read sources and reporting termination.
        if outputDescriptor >= 0 {
            drain(
                descriptor: outputDescriptor,
                kind: .output,
                owner: owner
            )
        }
        if errorDescriptor >= 0 {
            drain(
                descriptor: errorDescriptor,
                kind: .error,
                owner: owner
            )
        }

        let wasRequested = requestedStop
        let errorText = String(
            data: errorBuffer.suffix(2_048),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines)

        let terminalMessage: String?
        if wasRequested {
            terminalMessage = nil
        } else if let waitError {
            terminalMessage =
                "Unable to reap powermetrics: " +
                "\(String(cString: strerror(waitError)))"
        } else if let errorText, !errorText.isEmpty {
            terminalMessage =
                "powermetrics stopped (\(describe(waitStatus))): \(errorText)"
        } else {
            terminalMessage = "powermetrics stopped (\(describe(waitStatus)))."
        }

        let callback = sendFailure
        cleanUp()
        if let terminalMessage {
            callback?(terminalMessage)
        }
    }

    private func describe(_ waitStatus: Int32?) -> String {
        guard let waitStatus else {
            return "unknown status"
        }

        let terminationSignal = waitStatus & 0x7f
        if terminationSignal == 0 {
            return "exit \((waitStatus >> 8) & 0xff)"
        }
        if terminationSignal != 0x7f {
            return "signal \(terminationSignal)"
        }
        return "status \(waitStatus)"
    }

    private func currentDescriptor(for kind: StreamKind) -> Int32 {
        switch kind {
        case .output:
            return outputDescriptor
        case .error:
            return errorDescriptor
        }
    }

    private func closeStream(
        _ kind: StreamKind,
        expectedDescriptor: Int32
    ) {
        guard currentDescriptor(for: kind) == expectedDescriptor else {
            return
        }
        switch kind {
        case .output:
            outputSource?.cancel()
            outputSource = nil
            outputDescriptor = -1
        case .error:
            errorSource?.cancel()
            errorSource = nil
            errorDescriptor = -1
        }
        close(expectedDescriptor)
    }

    private func appendErrorText(_ text: String) {
        if !errorBuffer.isEmpty {
            errorBuffer.append(Data("\n".utf8))
        }
        appendErrorOutput(Data(text.utf8))
    }

    private func setCloseOnExec(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFD)
        guard flags >= 0,
              fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
            throw HelperFailure.message(
                "Unable to secure a powermetrics pipe descriptor: " +
                "\(String(cString: strerror(errno)))"
            )
        }
    }

    private func setNonBlocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw HelperFailure.message(
                "Unable to configure a powermetrics pipe descriptor: " +
                "\(String(cString: strerror(errno)))"
            )
        }
    }

    private func duplicateCStringArray(
        _ strings: [String]
    ) throws -> [UnsafeMutablePointer<CChar>] {
        var result: [UnsafeMutablePointer<CChar>] = []
        result.reserveCapacity(strings.count)
        for string in strings {
            guard let copy = strdup(string) else {
                result.forEach { free($0) }
                throw HelperFailure.message(
                    "Unable to allocate powermetrics arguments."
                )
            }
            result.append(copy)
        }
        return result
    }

    private func requireSpawnSuccess(
        _ status: Int32,
        operation: String
    ) throws {
        guard status == 0 else {
            throw spawnFailure(operation: operation, code: status)
        }
    }

    private func spawnFailure(
        operation: String,
        code: Int32
    ) -> HelperFailure {
        HelperFailure.message(
            "\(operation) failed: \(String(cString: strerror(code)))"
        )
    }

    private func appendErrorOutput(_ data: Data) {
        let maximumErrorBytes = 64 * 1_024
        errorBuffer.append(data)
        if errorBuffer.count > maximumErrorBytes {
            errorBuffer.removeFirst(errorBuffer.count - maximumErrorBytes)
        }
    }

    private func cleanUp() {
        processSource?.cancel()
        processSource = nil
        if outputDescriptor >= 0 {
            closeStream(.output, expectedDescriptor: outputDescriptor)
        } else {
            outputSource?.cancel()
            outputSource = nil
        }
        if errorDescriptor >= 0 {
            closeStream(.error, expectedDescriptor: errorDescriptor)
        } else {
            errorSource?.cancel()
            errorSource = nil
        }

        ownerIdentifier = nil
        childProcessIdentifier = nil
        errorBuffer.removeAll(keepingCapacity: false)
        requestedStop = false
        outputWasObserved = false
        sendData = nil
        sendFailure = nil
    }
}

/// Separately serialized, narrow power-mode operation; never shares arbitrary
/// commands or client-controlled paths with the sampling process launcher.
private final class LowPowerCoordinator {
    static let shared = LowPowerCoordinator()
    private let queue = DispatchQueue(label: "com.llf.MacPowerFlow.Helper.lowpower")
    private let execute: ([String]) throws -> String
    init(execute: @escaping ([String]) throws -> String = LowPowerCoordinator.run) {
        self.execute = execute
    }

    func perform(source: Int, setting: Int?, isAuthorized: @escaping () -> Bool,
                 reply: @escaping (Bool, Bool, String?) -> Void) {
        guard MPFLowPowerPolicy.arguments(source: source, enabled: setting ?? 0) != nil else {
            reply(false, false, "电源目标或低功耗设置值无效。"); return
        }
        queue.async {
            do {
                guard isAuthorized() else { throw HelperFailure.message("请求连接已关闭，未修改设置。") }
                let capabilities = try self.execute(["-g", "cap"])
                guard MPFLowPowerPolicy.supportsLowPower(capabilities) else {
                    throw HelperFailure.message("本机不支持低功耗模式。")
                }
                let before = try self.execute(["-g", "custom"])
                guard let previous = MPFLowPowerPolicy.configuredValue(source: source, output: before) else {
                    throw HelperFailure.message("无法确认此电源类型的低功耗设置，未修改设置。")
                }
                if let setting {
                    guard isAuthorized(), let arguments = MPFLowPowerPolicy.arguments(source: source, enabled: setting) else {
                        throw HelperFailure.message("请求已取消，未修改设置。")
                    }
                    if previous != (setting == 1) { _ = try self.execute(arguments) }
                }
                let after = try self.execute(["-g", "custom"])
                guard let actual = MPFLowPowerPolicy.configuredValue(source: source, output: after) else {
                    throw HelperFailure.message("无法回读低功耗设置，请在系统电池设置中确认。")
                }
                if let setting, actual != (setting == 1) {
                    reply(false, actual, "系统回读值与请求不一致，请在系统电池设置中确认。")
                } else { reply(true, actual, nil) }
            } catch { reply(false, false, error.localizedDescription) }
        }
    }

    /// Fixed executable, clean locale, bounded output/time. No shell is used.
    private static func run(_ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: MPFLowPowerPolicy.executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        try process.run()
        pipe.fileHandleForWriting.closeFile()
        defer { pipe.fileHandleForReading.closeFile() }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                output.append(contentsOf: buffer.prefix(count))
                if output.count > 65536 {
                    _ = kill(process.processIdentifier, SIGKILL); process.waitUntilExit()
                    throw HelperFailure.message("系统电源设置输出超过限制。")
                }
                continue
            }
            if !process.isRunning {
                if count <= 0 { break }
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                _ = kill(process.processIdentifier, SIGKILL); process.waitUntilExit()
                throw HelperFailure.message("系统电源设置请求超时，请在系统设置中确认。")
            }
            usleep(10000)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw HelperFailure.message("系统电源命令失败（状态\(process.terminationStatus)）。")
        }
        return String(decoding: output, as: UTF8.self)
    }
}

private final class MetricsConnectionService:
    NSObject,
    MPFPrivilegedMetricsServiceProtocol
{
    let ownerIdentifier = UUID()
    private let connectionLock = NSLock()
    private var connection: NSXPCConnection?

    init(connection: NSXPCConnection) {
        self.connection = connection
        super.init()
    }

    func protocolVersion(withReply reply: @escaping (Int) -> Void) {
        reply(MPFPrivilegedService.protocolVersion)
    }

    func startSampling(withReply reply: @escaping (Bool, String?) -> Void) {
        startSampling(intervalSeconds: 2, withReply: reply)
    }

    func startSampling(intervalSeconds: Int, withReply reply: @escaping (Bool, String?) -> Void) {
        guard currentConnection() != nil else {
            reply(false, "The XPC connection is no longer available.")
            return
        }

        let owner = ownerIdentifier
        MetricsCoordinator.shared.start(
            owner: owner,
            intervalSeconds: intervalSeconds,
            sendData: { [weak self] data in
                self?.send(data)
            },
            sendFailure: { [weak self] message in
                self?.sendFailure(message)
            },
            reply: reply
        )
    }

    func queryLowPowerMode(source: Int, withReply reply: @escaping (Bool, Bool, String?) -> Void) {
        guard currentConnection() != nil else { reply(false, false, "连接已关闭。"); return }
        LowPowerCoordinator.shared.perform(source: source, setting: nil, isAuthorized: { [weak self] in
            self?.currentConnection() != nil
        }, reply: reply)
    }

    func setLowPowerMode(source: Int, enabled: Int, withReply reply: @escaping (Bool, Bool, String?) -> Void) {
        guard currentConnection() != nil else { reply(false, false, "连接已关闭。"); return }
        LowPowerCoordinator.shared.perform(source: source, setting: enabled, isAuthorized: { [weak self] in
            self?.currentConnection() != nil
        }, reply: reply)
    }

    func stopSampling(
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        MetricsCoordinator.shared.stop(
            owner: ownerIdentifier,
            reply: reply
        )
    }

    func connectionWasInvalidated() {
        MetricsCoordinator.shared.stop(owner: ownerIdentifier)
        connectionLock.lock()
        connection = nil
        connectionLock.unlock()
    }

    private func currentConnection() -> NSXPCConnection? {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        return connection
    }

    private func clientProxy() -> MPFPrivilegedMetricsClientProtocol? {
        guard let connection = currentConnection() else { return nil }
        return connection.remoteObjectProxyWithErrorHandler(
            { _ in }
        ) as? MPFPrivilegedMetricsClientProtocol
    }

    private func send(_ data: Data) {
        clientProxy()?.receiveData(data)
    }

    private func sendFailure(_ message: String) {
        clientProxy()?.serviceDidFail(message)
    }
}

private final class HelperListenerDelegate:
    NSObject,
    NSXPCListenerDelegate
{
    private let allowedClientUID: uid_t?
    private let lock = NSLock()
    private var services: [ObjectIdentifier: MetricsConnectionService] = [:]

    init(allowedClientUID: uid_t?) {
        self.allowedClientUID = allowedClientUID
        super.init()
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        if let allowedClientUID,
           newConnection.effectiveUserIdentifier != allowedClientUID {
            return false
        }

        let service = MetricsConnectionService(connection: newConnection)
        let identifier = ObjectIdentifier(newConnection)

        newConnection.exportedInterface = NSXPCInterface(
            with: MPFPrivilegedMetricsServiceProtocol.self
        )
        newConnection.exportedObject = service
        newConnection.remoteObjectInterface = NSXPCInterface(
            with: MPFPrivilegedMetricsClientProtocol.self
        )

        lock.lock()
        services[identifier] = service
        lock.unlock()

        newConnection.invalidationHandler = { [weak self, weak service] in
            service?.connectionWasInvalidated()
            self?.lock.lock()
            self?.services.removeValue(forKey: identifier)
            self?.lock.unlock()
        }
        newConnection.interruptionHandler = { [weak service] in
            service?.connectionWasInvalidated()
        }
        newConnection.activate()
        return true
    }
}

@main
private enum MacPowerFlowHelperMain {
    private static var retainedListener: NSXPCListener?
    private static var retainedDelegate: HelperListenerDelegate?

    static func main() {
        do {
            let configuration = try HelperConfiguration.load()
            let listener = NSXPCListener(
                machServiceName: MPFPrivilegedService.machServiceName
            )
            listener.setConnectionCodeSigningRequirement(
                configuration.clientCodeSigningRequirement
            )
            let delegate = HelperListenerDelegate(
                allowedClientUID: configuration.allowedClientUID
            )
            listener.delegate = delegate
            retainedListener = listener
            retainedDelegate = delegate
            listener.activate()
            dispatchMain()
        } catch {
            let message =
                "MacPowerFlow helper failed: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(EXIT_FAILURE)
        }
    }
}
