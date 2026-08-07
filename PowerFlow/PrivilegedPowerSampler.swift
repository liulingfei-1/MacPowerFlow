import Foundation

nonisolated enum PrivilegedThermalPressure: String, Sendable, Equatable {
    case nominal
    case light
    case moderate
    case heavy
    case critical
    case unknown

    init(powermetricsValue: String) {
        switch powermetricsValue.lowercased() {
        case "nominal":
            self = .nominal
        case "light":
            self = .light
        case "moderate":
            self = .moderate
        case "heavy", "serious":
            self = .heavy
        case "critical", "trapping":
            self = .critical
        default:
            self = .unknown
        }
    }
}

nonisolated struct PrivilegedPowerSample: Sendable, Equatable {
    let timestamp: Date
    let cpuPowerWatts: Double?
    let gpuPowerWatts: Double?
    let anePowerWatts: Double?
    let combinedPowerWatts: Double?
    let cpuFrequencyMHz: Int?
    let gpuFrequencyMHz: Int?
    let cpuActivePercent: Double?
    let gpuActivePercent: Double?
    let thermalPressure: PrivilegedThermalPressure
}

nonisolated enum PrivilegedPowerSamplerState: Sendable, Equatable {
    case idle
    case authorizing
    case running
    case stopping
    case failed(String)
}

/// Main-actor facade around the Authorization Services runner.
///
/// `PowerMonitor` can own one instance, call `start`, and merge snapshots into
/// its published values without moving Objective-C callbacks across actors.
@MainActor
final class PrivilegedPowerSampler {
    typealias SampleHandler = (PrivilegedPowerSample) -> Void
    typealias StateHandler = (PrivilegedPowerSamplerState) -> Void
    typealias StartCompletion = (String?) -> Void

    private static let maximumBufferBytes = 4 * 1_024 * 1_024

    private let runner = MPFPrivilegedMetricsRunner()
    private var streamDecoder = PowerMetricsFrameDecoder()
    private var wantsSampling = false
    private var parsedSampleCount = 0
    private var pendingTerminalError: String?
    private var sampleHandler: SampleHandler?
    private var stateHandler: StateHandler?
    private var startCompletion: StartCompletion?

    private(set) var state = PrivilegedPowerSamplerState.idle
    private(set) var latestSample: PrivilegedPowerSample?

    var isRunning: Bool {
        switch state {
        case .authorizing, .running:
            return true
        case .idle, .stopping, .failed:
            return false
        }
    }

    /// Starts one powermetrics stream for the current app session.
    ///
    /// Returns `false` when sampling is already active. `completion` is called
    /// once: with `nil` after the privileged stream starts, or with an
    /// error string if authorization/launch fails.
    @discardableResult
    func start(
        onSample: @escaping SampleHandler,
        onStateChange: @escaping StateHandler,
        completion: @escaping StartCompletion
    ) -> Bool {
        guard !wantsSampling, state != .stopping else { return false }

        wantsSampling = true
        parsedSampleCount = 0
        pendingTerminalError = nil
        latestSample = nil
        streamDecoder.reset(keepingCapacity: true)
        sampleHandler = onSample
        stateHandler = onStateChange
        startCompletion = completion
        launchStream()
        return true
    }

    func stop() {
        guard wantsSampling || state != .idle else { return }

        wantsSampling = false
        pendingTerminalError = nil
        runner.stop()
        streamDecoder.reset(keepingCapacity: false)
    }

    /// Cancels the app-session stream and reports a terminal error only after
    /// the privileged runner has actually become idle.
    func stop(withError message: String) {
        guard wantsSampling || state != .idle else {
            setState(.failed(message))
            return
        }

        wantsSampling = false
        pendingTerminalError = message
        runner.stop()
        streamDecoder.reset(keepingCapacity: false)
        setState(.stopping)
    }

    private func launchStream() {
        guard wantsSampling else { return }

        runner.start(
            dataHandler: { [weak self] data in
                self?.consume(data)
            },
            stateHandler: { [weak self] runnerState, message in
                self?.consume(runnerState, message: message)
            }
        )
    }

    private func consume(
        _ runnerState: MPFPrivilegedMetricsRunnerState,
        message: String?
    ) {
        switch runnerState {
        case .idle:
            let wasSampling = wantsSampling
            let terminalError = pendingTerminalError
            wantsSampling = false
            pendingTerminalError = nil

            if let terminalError {
                setState(.failed(terminalError))
                finishStart(terminalError)
            } else if wasSampling && parsedSampleCount == 0 {
                let errorMessage =
                    "powermetrics 已结束，但没有返回可解析的 CPU / GPU 样本。"
                setState(.failed(errorMessage))
                finishStart(errorMessage)
            } else {
                setState(.idle)
                finishStart(nil)
            }

            clearSessionCallbacks()
        case .authorizing:
            setState(.authorizing)
        case .running:
            setState(.running)
            finishStart(nil)
        case .stopping:
            setState(.stopping)
        case .failed:
            if !wantsSampling {
                if let pendingTerminalError {
                    self.pendingTerminalError = nil
                    setState(.failed(pendingTerminalError))
                    finishStart(pendingTerminalError)
                } else {
                    setState(.idle)
                    finishStart(nil)
                }
                clearSessionCallbacks()
                return
            }
            wantsSampling = false
            let errorMessage = message ?? "管理员采样发生未知错误。"
            setState(.failed(errorMessage))
            finishStart(errorMessage)
            clearSessionCallbacks()
        @unknown default:
            wantsSampling = false
            let errorMessage = "管理员采样返回了未知状态。"
            setState(.failed(errorMessage))
            finishStart(errorMessage)
            clearSessionCallbacks()
        }
    }

    private func consume(_ data: Data) {
        guard wantsSampling else { return }

        guard let propertyListFrames = streamDecoder.append(
            data,
            maximumFrameBytes: Self.maximumBufferBytes
        ) else {
            stop(withError: "powermetrics 输出超过安全缓冲区限制。")
            return
        }

        for propertyListData in propertyListFrames {
            guard !propertyListData.isEmpty,
                  let sample = Self.parse(propertyListData) else {
                continue
            }

            latestSample = sample
            parsedSampleCount += 1
            sampleHandler?(sample)
        }
    }

    private func setState(_ newState: PrivilegedPowerSamplerState) {
        guard state != newState else { return }
        state = newState
        stateHandler?(newState)
    }

    private func finishStart(_ errorMessage: String?) {
        guard let completion = startCompletion else { return }
        startCompletion = nil
        completion(errorMessage)
    }

    private func clearSessionCallbacks() {
        streamDecoder.reset(keepingCapacity: false)
        sampleHandler = nil
        stateHandler = nil
        startCompletion = nil
    }

    private static func parse(_ rawData: Data) -> PrivilegedPowerSample? {
        let data: Data
        if let xmlStart = rawData.range(of: Data("<?xml".utf8))?.lowerBound {
            data = Data(rawData[xmlStart...])
        } else if let plistStart = rawData.range(
            of: Data("<plist".utf8)
        )?.lowerBound {
            data = Data(rawData[plistStart...])
        } else {
            data = rawData
        }

        guard let propertyList = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ),
        let root = propertyList as? [String: Any],
        !isInvalid(root) else {
            return nil
        }

        let processor = root["processor"] as? [String: Any] ?? [:]
        let processorIsValid = !isInvalid(processor)

        let cpuPower = PowerMetricsCore.resolvedSamplePowerWatts(
            domain: "cpu",
            processor: processorIsValid ? processor : [:],
            root: root
        )
        let gpuPower = PowerMetricsCore.resolvedSamplePowerWatts(
            domain: "gpu",
            processor: processorIsValid ? processor : [:],
            root: root
        )
        let anePower = PowerMetricsCore.resolvedSamplePowerWatts(
            domain: "ane",
            processor: processorIsValid ? processor : [:],
            root: root
        )
        let combinedPower = PowerMetricsCore.resolvedSamplePowerWatts(
            domain: "combined",
            processor: processorIsValid ? processor : [:],
            root: root
        )

        let clusters = processorIsValid
            ? processor["clusters"] as? [[String: Any]] ?? []
            : []
        let cpuActivity = cpuActivity(from: clusters)
        let gpu = root["gpu"] as? [String: Any]
        let gpuIsValid = gpu.map { !isInvalid($0) } ?? false
        let gpuIdleRatio = gpuIsValid
            ? clampedRatio(number(gpu?["idle_ratio"]))
            : nil
        let gpuFrequency = gpuIsValid
            ? frequencyMHz(number(gpu?["freq_hz"]))
            : 0
        let thermalText = root["thermal_pressure"] as? String ?? ""

        guard cpuPower != nil || gpuPower != nil else {
            return nil
        }

        return PrivilegedPowerSample(
            timestamp: root["timestamp"] as? Date ?? Date(),
            cpuPowerWatts: cpuPower,
            gpuPowerWatts: gpuPower,
            anePowerWatts: anePower,
            combinedPowerWatts: combinedPower,
            cpuFrequencyMHz: cpuActivity.frequencyMHz > 0
                ? cpuActivity.frequencyMHz
                : nil,
            gpuFrequencyMHz: gpuFrequency > 0 ? gpuFrequency : nil,
            cpuActivePercent: cpuActivity.hasActivity
                ? cpuActivity.activePercent
                : nil,
            gpuActivePercent: gpuIdleRatio.map {
                clampedPercent((1 - $0) * 100)
            },
            thermalPressure: PrivilegedThermalPressure(
                powermetricsValue: thermalText
            )
        )
    }

    private static func cpuActivity(
        from clusters: [[String: Any]]
    ) -> (
        frequencyMHz: Int,
        activePercent: Double,
        hasActivity: Bool
    ) {
        var totalCoreWeight = 0.0
        var totalActiveCoreWeight = 0.0
        var weightedFrequency = 0.0

        for cluster in clusters where !isInvalid(cluster) {
            guard let idleRatio = clampedRatio(number(
                cluster["idle_ratio"]
            )) else {
                continue
            }

            let onlineRatio = clampedRatio(number(
                cluster["online_ratio"]
            )) ?? 1
            let coreCount = max(
                1,
                (cluster["cpus"] as? [[String: Any]])?.count ?? 1
            )
            let coreWeight = Double(coreCount) * onlineRatio
            let activeWeight = coreWeight * (1 - idleRatio)
            let frequency = Double(frequencyMHz(number(
                cluster["freq_hz"]
            )))

            totalCoreWeight += coreWeight
            totalActiveCoreWeight += activeWeight
            weightedFrequency += frequency * activeWeight
        }

        let activePercent: Double
        if totalCoreWeight > 0 {
            activePercent = clampedPercent(
                totalActiveCoreWeight / totalCoreWeight * 100
            )
        } else {
            activePercent = 0
        }

        let averageFrequency: Int
        if totalActiveCoreWeight > 0 {
            averageFrequency = Int(
                (weightedFrequency / totalActiveCoreWeight).rounded()
            )
        } else {
            averageFrequency = 0
        }

        return (
            averageFrequency,
            activePercent,
            totalCoreWeight > 0
        )
    }

    private static func isInvalid(_ dictionary: [String: Any]) -> Bool {
        (dictionary["invalid"] as? NSNumber)?.boolValue == true
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber else { return nil }
        let result = value.doubleValue
        return result.isFinite && result >= 0 ? result : nil
    }

    private static func clampedRatio(_ value: Double?) -> Double? {
        value.map { min(1, max(0, $0)) }
    }

    private static func clampedPercent(_ value: Double) -> Double {
        min(100, max(0, value))
    }

    /// Older Apple Silicon releases put MHz in `gpu.freq_hz`, while CPU
    /// clusters use true Hz. Accept both encodings.
    private static func frequencyMHz(_ value: Double?) -> Int {
        guard let value, value > 0 else { return 0 }
        let mhz = value > 100_000 ? value / 1_000_000 : value
        return Int(mhz.rounded())
    }
}
