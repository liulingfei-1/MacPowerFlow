import Combine
import Darwin
import Foundation
import IOKit

struct ActivityProcess: Identifiable, Equatable, Sendable {
    let id: Int
    let name: String
    let cpuPercent: Double
}

/// One secondary rail shown below the residual "other" power branch.
///
/// `basis` deliberately describes the signal used instead of pretending that
/// macOS exposes a sensor which does not exist on every Mac model.
struct OtherPowerComponent: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let powerWatts: Double
    let basis: String
}

nonisolated enum BatteryFlowDirection: Sendable, Equatable {
    case charging
    case supplying
    case idle
    case unknown
    case unavailable
}

nonisolated enum AdministratorSamplingState: Sendable, Equatable {
    case inactive
    case authorizing
    case starting
    case active
    case stopping
    case failed
}

/// Read-only power and thermal model used by the menu-bar UI.
///
/// The HardwareSampler actor serializes AppleSMC / IOReport reads away from the
/// UI thread. This object only publishes completed Sendable snapshots.
@MainActor
final class PowerMonitor: ObservableObject {
    // MARK: - Identity and sampling state

    @Published private(set) var chipName: String
    @Published private(set) var lastUpdated = Date.distantPast
    @Published private(set) var isSampling = false

    // MARK: - Battery

    @Published private(set) var batteryPresent = false
    @Published private(set) var batteryLevel = -1
    @Published private(set) var isCharging = false
    @Published private(set) var isFullyCharged = false
    @Published private(set) var isOnAC = false
    @Published private(set) var batteryTempC = 0.0
    @Published private(set) var batteryTimeText = "等待首次采样"
    @Published private(set) var batteryFlowWatts = 0.0
    @Published private(set) var batteryVoltage = 0.0
    @Published private(set) var batteryCurrent = 0.0
    @Published private(set) var batteryFlowDirection = BatteryFlowDirection.idle
    @Published private(set) var cycleCount = 0
    @Published private(set) var healthPercent = 0
    @Published private(set) var healthIsEstimated = false
    @Published private(set) var currentCapacityMAh = 0
    @Published private(set) var fullCapacityMAh = 0
    @Published private(set) var designCapacityMAh = 0
    @Published private(set) var capacityIsEstimated = false

    // MARK: - Power flow

    @Published private(set) var adapterRatedWatts = 0.0
    @Published private(set) var adapterVoltage = 0.0
    @Published private(set) var adapterCurrent = 0.0
    @Published private(set) var adapterName = ""
    @Published private(set) var adapterInputWatts = 0.0
    @Published private(set) var systemLoadWatts = 0.0
    @Published private(set) var systemLoadIsEstimated = false
    @Published private(set) var adapterEfficiencyLossWatts = 0.0
    @Published private(set) var externalPowerOutWatts = 0.0
    @Published private(set) var processorPowerWatts = 0.0
    @Published private(set) var processorPowerIsEstimated = false
    @Published private(set) var processorPowerIsPartial = false
    @Published private(set) var displayPowerWatts = 0.0
    @Published private(set) var otherPowerWatts = 0.0

    // MARK: - Processor

    @Published private(set) var cpuPowerWatts = 0.0
    @Published private(set) var gpuPowerWatts = 0.0
    @Published private(set) var anePowerWatts = 0.0
    @Published private(set) var dramPowerWatts = 0.0
    @Published private(set) var gpuSRAMPowerWatts = 0.0
    @Published private(set) var mediaPowerWatts = 0.0
    @Published private(set) var ispPowerWatts = 0.0
    @Published private(set) var fabricPowerWatts = 0.0
    @Published private(set) var pciePowerWatts = 0.0
    @Published private(set) var displaySoCPowerWatts = 0.0
    @Published private(set) var displayExternalControllerPowerWatts = 0.0
    @Published private(set) var wifiPowerWatts = 0.0
    @Published private(set) var usbPowerWatts = 0.0
    @Published private(set) var cpuUsagePercent = 0.0
    @Published private(set) var gpuUsagePercent = -1.0
    @Published private(set) var cpuTempC = 0.0
    @Published private(set) var cpuDieHotspotC = 0.0
    @Published private(set) var gpuTempC = 0.0
    @Published private(set) var gpuFrequencyMHz = 0
    @Published private(set) var efficiencyClusterUsagePercent = 0.0
    @Published private(set) var performanceClusterUsagePercent = 0.0
    @Published private(set) var superClusterUsagePercent = 0.0
    @Published private(set) var efficiencyClusterFrequencyMHz = 0
    @Published private(set) var performanceClusterFrequencyMHz = 0
    @Published private(set) var superClusterFrequencyMHz = 0
    @Published private(set) var dramReadBytesPerSecond: Int64 = 0
    @Published private(set) var dramWriteBytesPerSecond: Int64 = 0
    @Published private(set) var fanRPM = 0
    @Published private(set) var fan2RPM = 0

    // These two temperatures are best-effort SMC values. They are not required
    // for the compact UI but make the complete power model available to detail
    // views without inventing utilization percentages that macOS does not
    // expose reliably for ANE or DRAM.
    @Published private(set) var aneTempC = 0.0
    @Published private(set) var dramTempC = 0.0

    // MARK: - System state and activity

    @Published private(set) var thermalStateText = "正常"
    @Published private(set) var lowPowerModeEnabled = false
    @Published private(set) var topProcesses: [ActivityProcess] = []

    // MARK: - SMC capability diagnostics

    /// Exposed to diagnostics/support code, not as user-facing sensor labels.
    /// Unknown firmware keys remain metadata only until their meaning has been
    /// independently established for a hardware family.
    @Published private(set) var smcCapabilityCount = 0
    @Published private(set) var smcNumericCapabilityCount = 0
    @Published private(set) var smcKnownReadableKeyCount = 0
    private(set) var smcReadings: [String: SMCReading] = [:]
    private(set) var smcCapabilities: [String: SMCCapability] = [:]

    // MARK: - Persistent privileged sampling

    @Published private(set) var administratorSamplingState =
        AdministratorSamplingState.inactive
    @Published private(set) var administratorErrorMessage = ""
    @Published private(set) var administratorLastUpdated = Date.distantPast
    @Published private(set) var administratorSampleCount = 0
    @Published private(set) var administratorCPUPowerWatts = 0.0
    @Published private(set) var administratorCPUHasValue = false
    @Published private(set) var administratorGPUPowerWatts = 0.0
    @Published private(set) var administratorGPUHasValue = false
    @Published private(set) var administratorANEPowerWatts = 0.0
    @Published private(set) var administratorANEHasValue = false
    @Published private(set) var administratorCombinedPowerWatts = 0.0
    @Published private(set) var administratorCombinedHasValue = false
    @Published private(set) var administratorCPUFrequencyMHz = 0
    @Published private(set) var administratorGPUFrequencyMHz = 0
    @Published private(set) var administratorCPUActivePercent = 0.0
    @Published private(set) var administratorGPUActivePercent = 0.0
    @Published private(set) var administratorThermalPressure =
        PrivilegedThermalPressure.unknown

    private let sampleIntervalNanoseconds: UInt64 = 2_000_000_000
    private let processInterval: TimeInterval = 10
    private let hardwareSampler = HardwareSampler()
    private let privilegedPowerSampler = PrivilegedPowerSampler()

    private var monitoringTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var processTask: Task<Void, Never>?
    private var lastProcessRefresh = Date.distantPast
    private var previousCPUTicks: [[UInt32]] = []
    private var administratorStartupWatchdogTask: Task<Void, Never>?
    private var administratorTerminalError: String?
    private var lastReasonableStandardGPUPowerWatts: Double?
    private var lastReasonableStandardGPUSampleDate = Date.distantPast

    /// SMC, IOReport and powermetrics do not close their sampling windows at
    /// exactly the same instant. Accept a small one-frame overshoot, then clamp
    /// it to the physical budget; a larger overshoot is treated as an invalid
    /// sample rather than being allowed to consume the CPU/other branches.
    private let componentBudgetAbsoluteToleranceWatts = 1.0
    private let componentBudgetRelativeTolerance = 0.10
    private let standardGPUFallbackFreshness: TimeInterval = 8

    init() {
        chipName = Self.sysctlString("machdep.cpu.brand_string")
        if chipName.isEmpty {
            chipName = Self.sysctlString("hw.model")
        }
        if chipName.isEmpty {
            chipName = "Mac"
        }

        updateSystemState()
    }

    deinit {
        monitoringTask?.cancel()
        refreshTask?.cancel()
        processTask?.cancel()
        administratorStartupWatchdogTask?.cancel()
    }

    // MARK: - Lifecycle

    func startMonitoring(
        automaticallyStartAdministrator: Bool = true
    ) {
        guard monitoringTask == nil else { return }

        isSampling = true
        refreshNow()
        if automaticallyStartAdministrator {
            startAdministratorSampling()
        }

        let interval = sampleIntervalNanoseconds
        monitoringTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    break
                }
                guard !Task.isCancelled, let self else { break }
                self.refreshNow()
            }
        }
    }

    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil

        processTask?.cancel()
        processTask = nil

        refreshTask?.cancel()
        refreshTask = nil

        administratorStartupWatchdogTask?.cancel()
        administratorStartupWatchdogTask = nil
        privilegedPowerSampler.stop()

        let sampler = hardwareSampler
        Task {
            await sampler.close()
        }
        previousCPUTicks.removeAll(keepingCapacity: true)
        lastReasonableStandardGPUPowerWatts = nil
        lastReasonableStandardGPUSampleDate = .distantPast
        isSampling = false
    }

    // MARK: - Administrator sampling

    var effectiveDisplayPowerWatts: Double {
        guard systemLoadWatts.isFinite, systemLoadWatts > 0.02 else {
            return 0
        }
        return min(nonnegativePower(displayPowerWatts), systemLoadWatts)
    }

    private var availableProcessorPowerBudgetWatts: Double {
        guard systemLoadWatts.isFinite, systemLoadWatts > 0.02 else {
            return 0
        }
        return max(0, systemLoadWatts - effectiveDisplayPowerWatts)
    }

    var effectiveCPUPowerWatts: Double {
        let availableCPU = max(
            0,
            availableProcessorPowerBudgetWatts - effectiveGPUPowerWatts
        )
        guard availableCPU > 0.02 else { return 0 }

        let candidate: Double
        if administratorSampleIsFresh && administratorCPUHasValue {
            candidate = administratorCPUPowerWatts
        } else if cpuPowerWatts > 0.02 {
            candidate = cpuPowerWatts
        } else {
            candidate = estimatedCPUPowerWatts
        }
        return min(nonnegativePower(candidate), availableCPU)
    }

    var effectiveGPUPowerWatts: Double {
        let budget = availableProcessorPowerBudgetWatts
        guard budget > 0.02 else { return 0 }

        let standard = min(nonnegativePower(gpuPowerWatts), budget)
        guard administratorSampleIsFresh, administratorGPUHasValue else {
            return standard
        }

        let administrator = nonnegativePower(administratorGPUPowerWatts)
        guard !isClearlyAbovePowerBudget(administrator, budget: budget) else {
            return standard
        }
        return min(administrator, budget)
    }

    var effectiveANEPowerWatts: Double {
        administratorSampleIsFresh && administratorANEHasValue
            ? administratorANEPowerWatts
            : anePowerWatts
    }

    var effectiveOtherPowerWatts: Double {
        max(
            0,
            systemLoadWatts
                - effectiveCPUPowerWatts
                - effectiveGPUPowerWatts
                - effectiveDisplayPowerWatts
        )
    }

    /// Secondary power domains which this Mac currently publishes as watts.
    /// CPU, GPU, displays and GPU SRAM are intentionally excluded because the
    /// main flow already accounts for their parent domains.
    var readableOtherPowerComponents: [OtherPowerComponent] {
        let aneBasis = administratorSampleIsFresh && administratorANEHasValue
            ? "增强通道"
            : "硬件通道"

        return [
            OtherPowerComponent(
                id: "ane",
                label: "ANE",
                powerWatts: effectiveANEPowerWatts,
                basis: aneBasis
            ),
            OtherPowerComponent(
                id: "dram",
                label: "内存",
                powerWatts: dramPowerWatts,
                basis: "IOReport 通道"
            ),
            OtherPowerComponent(
                id: "media",
                label: "媒体引擎",
                powerWatts: mediaPowerWatts,
                basis: "IOReport 通道"
            ),
            OtherPowerComponent(
                id: "isp",
                label: "图像 ISP",
                powerWatts: ispPowerWatts,
                basis: "IOReport 通道"
            ),
            OtherPowerComponent(
                id: "fabric",
                label: "芯片互联",
                powerWatts: fabricPowerWatts,
                basis: "IOReport 通道"
            ),
            OtherPowerComponent(
                id: "pcie",
                label: "PCIe 汇总",
                powerWatts: pciePowerWatts,
                basis: "IOReport 通道"
            ),
            OtherPowerComponent(
                id: "wifi",
                label: "无线网络",
                powerWatts: wifiPowerWatts,
                basis: "SMC wiPm"
            ),
            OtherPowerComponent(
                id: "usb",
                label: "USB 总线",
                powerWatts: usbPowerWatts,
                basis: "SMC USB 功耗轨"
            )
        ]
        .filter { $0.powerWatts > 0.02 && $0.powerWatts.isFinite }
    }

    /// Power left after subtracting directly readable secondary channels from
    /// the residual branch. Direct channels are sampled asynchronously, so
    /// their raw values remain untouched in the UI while this budget is
    /// conservatively clamped to the residual total.
    var estimatedOtherPowerBudgetWatts: Double {
        let directTotal = readableOtherPowerComponents.reduce(0) {
            $0 + $1.powerWatts
        }
        return max(0, effectiveOtherPowerWatts - directTotal)
    }

    /// Honest, activity-shaped allocation of the part of "other" for which no
    /// independent watt channel exists. These are not invented sensors;
    /// provenance remains in `basis` for diagnostics while the UI stays compact.
    ///
    /// Four non-overlapping system buckets are always present. Up to two more
    /// are added only when their corresponding direct channels are absent, so
    /// the expanded card stays within 4...6 compact items.
    var estimatedOtherPowerComponents: [OtherPowerComponent] {
        let directIDs = Set(readableOtherPowerComponents.map(\.id))
        let budget = estimatedOtherPowerBudgetWatts

        // Saturating normalizations avoid model-specific TDP/RPM constants
        // while still reacting smoothly to every two-second hardware sample.
        let loadSignal = saturatingSignal(systemLoadWatts, halfScale: 18)
        let memoryRate = Double(max(0, dramReadBytesPerSecond))
            + Double(max(0, dramWriteBytesPerSecond))
        let memorySignal = saturatingSignal(
            memoryRate,
            halfScale: 8_000_000_000
        )
        let cpuSignal = min(max(cpuUsagePercent / 100, 0), 1)
        let reportedGPUActivity = administratorSampleIsFresh
            && administratorGPUActivePercent >= 0
            ? administratorGPUActivePercent
            : gpuUsagePercent
        let gpuSignal = reportedGPUActivity >= 0
            ? min(max(reportedGPUActivity / 100, 0), 1)
            : 0
        let activitySignal = max(cpuSignal, gpuSignal)
        let activeFanCount = [fanRPM, fan2RPM].filter { $0 > 0 }
        let averageFanRPM = activeFanCount.isEmpty
            ? 0
            : Double(activeFanCount.reduce(0, +))
                / Double(activeFanCount.count)
        let fanSignal = saturatingSignal(averageFanRPM, halfScale: 2_500)

        var seeds: [(id: String, label: String, basis: String, weight: Double)] = []

        let memoryMissing = !directIDs.contains("dram")
        let fabricMissing = !directIDs.contains("fabric")
        if memoryMissing || fabricMissing {
            let label: String
            switch (memoryMissing, fabricMissing) {
            case (true, true):
                label = "内存与芯片互联"
            case (true, false):
                label = "内存活动"
            case (false, true):
                label = "芯片互联"
            case (false, false):
                label = ""
            }
            seeds.append((
                id: "estimated-memory-fabric",
                label: label,
                basis: memoryMissing ? "内存带宽 + 整机活动" : "整机活动",
                weight: 0.45 + 2.6 * memorySignal + 0.65 * loadSignal
            ))
        }

        let mediaMissing = !directIDs.contains("media")
        let ispMissing = !directIDs.contains("isp")
        let pcieMissing = !directIDs.contains("pcie")
        if mediaMissing || ispMissing || pcieMissing {
            let engineMissing = mediaMissing || ispMissing
            let label: String
            switch (engineMissing, pcieMissing) {
            case (true, true):
                label = "媒体、存储与外设"
            case (true, false):
                label = mediaMissing && ispMissing
                    ? "媒体与图像处理"
                    : (mediaMissing ? "媒体引擎" : "图像处理")
            case (false, true):
                label = "存储与高速外设"
            case (false, false):
                label = ""
            }
            seeds.append((
                id: "estimated-media-peripherals",
                label: label,
                basis: "芯片活跃 + 整机活动",
                weight: 0.55 + 1.5 * activitySignal + 0.8 * loadSignal
            ))
        }

        // macOS does not expose portable watt channels for these four groups.
        // They never duplicate the CPU/GPU/display or the direct domains above.
        if !directIDs.contains("wifi") {
            seeds.append((
                id: "estimated-network",
                label: "网络与无线",
                basis: "整机活动代理",
                weight: 0.65 + 0.45 * loadSignal
            ))
        }

        seeds.append(contentsOf: [
            (
                id: "estimated-cooling",
                label: "风扇与散热",
                basis: averageFanRPM > 0 ? "风扇转速" : "散热基线",
                weight: 0.22 + 2.0 * fanSignal
            ),
            (
                id: "estimated-board-conversion",
                label: "板级电源转换",
                basis: "整机负载",
                weight: 0.85 + 1.45 * loadSignal
            ),
            (
                id: "estimated-controllers",
                label: "主板控制器与传感器",
                basis: "基础常驻负载",
                weight: 1.0 + 0.2 * (1 - loadSignal)
            )
        ])

        let totalWeight = seeds.reduce(0) { $0 + max(0, $1.weight) }
        guard totalWeight > 0 else { return [] }

        var allocated = 0.0
        return seeds.enumerated().map { index, seed in
            let power: Double
            if index == seeds.index(before: seeds.endIndex) {
                // Assign the final floating-point remainder to the last row so
                // the estimate sum is exactly the bounded budget.
                power = max(0, budget - allocated)
            } else {
                power = budget * max(0, seed.weight) / totalWeight
                allocated += power
            }
            return OtherPowerComponent(
                id: seed.id,
                label: seed.label,
                powerWatts: power,
                basis: seed.basis
            )
        }
    }

    var estimatedOtherPowerTotalWatts: Double {
        estimatedOtherPowerComponents.reduce(0) { $0 + $1.powerWatts }
    }

    private func saturatingSignal(
        _ value: Double,
        halfScale: Double
    ) -> Double {
        guard value.isFinite, value > 0, halfScale > 0 else { return 0 }
        return min(max(value / (value + halfScale), 0), 1)
    }

    /// Best-effort CPU estimate used while the persistent privileged stream is
    /// connecting, unavailable, or missing a CPU field on this Mac model.
    ///
    /// Prefer a residual from the SoC estimate when one exists. Otherwise
    /// allocate a conservative, utilization-shaped share of whole-system load.
    /// Provenance stays internal so the compact UI does not need a prefix.
    private var estimatedCPUPowerWatts: Double {
        let reconciledGPU = effectiveGPUPowerWatts
        let availableSystemPower = max(
            0,
            availableProcessorPowerBudgetWatts - reconciledGPU
        )
        guard availableSystemPower > 0.02 else { return 0 }

        let knownSoCPower =
            reconciledGPU + anePowerWatts + dramPowerWatts
        let socResidual = processorPowerWatts - knownSoCPower
        if socResidual > 0.02 {
            return min(availableSystemPower, socResidual)
        }

        let utilization = min(max(cpuUsagePercent / 100, 0), 1)
        let cpuShare = 0.06 + 0.44 * sqrt(utilization)
        let usageEstimate = max(0.6, systemLoadWatts * cpuShare)
        return min(availableSystemPower, usageEstimate)
    }

    var effectiveGPUFrequencyMHz: Int {
        administratorSampleIsFresh && administratorGPUFrequencyMHz > 0
            ? administratorGPUFrequencyMHz
            : gpuFrequencyMHz
    }

    var administratorThermalPressureText: String {
        switch administratorThermalPressure {
        case .nominal:
            return "正常"
        case .light:
            return "轻度"
        case .moderate:
            return "中度"
        case .heavy:
            return "较高"
        case .critical:
            return "严重"
        case .unknown:
            return "—"
        }
    }

    private func startAdministratorSampling() {
        administratorStartupWatchdogTask?.cancel()
        administratorStartupWatchdogTask = nil
        administratorTerminalError = nil
        administratorErrorMessage = ""
        administratorSampleCount = 0
        administratorCPUHasValue = false
        administratorGPUHasValue = false
        administratorANEHasValue = false
        administratorCombinedHasValue = false
        administratorSamplingState = .authorizing

        let started = privilegedPowerSampler.start(
            onSample: { [weak self] sample in
                self?.applyAdministratorSample(sample)
            },
            onStateChange: { [weak self] state in
                self?.applyAdministratorState(state)
            },
            completion: { [weak self] errorMessage in
                guard let self, let errorMessage else { return }
                self.administratorTerminalError = errorMessage
                self.administratorErrorMessage = errorMessage
                self.administratorSamplingState = .failed
            }
        )

        if !started {
            administratorErrorMessage = "增强采样已经在运行。"
            administratorSamplingState = .failed
        }
    }

    private func applyAdministratorSample(
        _ sample: PrivilegedPowerSample
    ) {
        guard administratorSamplingState == .starting
                || administratorSamplingState == .active else {
            return
        }

        // Availability is per frame. Do not let an older GPU/ANE field appear
        // fresh merely because a later CPU-only frame refreshed the session
        // timestamp.
        administratorCPUHasValue = sample.cpuPowerWatts != nil
        administratorGPUHasValue = sample.gpuPowerWatts != nil
        administratorANEHasValue = sample.anePowerWatts != nil
        administratorCombinedHasValue = sample.combinedPowerWatts != nil
        administratorCPUPowerWatts = max(0, sample.cpuPowerWatts ?? 0)
        administratorGPUPowerWatts = max(0, sample.gpuPowerWatts ?? 0)
        administratorANEPowerWatts = max(0, sample.anePowerWatts ?? 0)
        administratorCombinedPowerWatts = max(
            0,
            sample.combinedPowerWatts ?? 0
        )
        administratorCPUFrequencyMHz = max(0, sample.cpuFrequencyMHz ?? 0)
        administratorGPUFrequencyMHz = max(0, sample.gpuFrequencyMHz ?? 0)
        administratorCPUActivePercent = sample.cpuActivePercent.map {
            clampedPercent($0)
        } ?? -1
        administratorGPUActivePercent = sample.gpuActivePercent.map {
            clampedPercent($0)
        } ?? -1
        administratorThermalPressure = sample.thermalPressure
        administratorLastUpdated = sample.timestamp
        administratorSampleCount += 1
        administratorStartupWatchdogTask?.cancel()
        administratorStartupWatchdogTask = nil
        administratorSamplingState = .active
    }

    private func applyAdministratorState(
        _ state: PrivilegedPowerSamplerState
    ) {
        switch state {
        case .idle:
            administratorStartupWatchdogTask?.cancel()
            administratorStartupWatchdogTask = nil
            administratorSamplingState =
                administratorTerminalError == nil ? .inactive : .failed
        case .authorizing:
            administratorSamplingState = .authorizing
        case .running:
            administratorSamplingState = .starting
            scheduleAdministratorStartupWatchdog()
        case .stopping:
            administratorSamplingState = .stopping
        case let .failed(message):
            administratorTerminalError = message
            administratorErrorMessage = message
            administratorSamplingState = .failed
        }
    }

    var administratorSampleIsFresh: Bool {
        let age = Date().timeIntervalSince(administratorLastUpdated)
        return administratorSamplingState == .active
            && administratorLastUpdated != Date.distantPast
            && age >= 0
            && age < 8
    }

    private func scheduleAdministratorStartupWatchdog() {
        administratorStartupWatchdogTask?.cancel()
        administratorStartupWatchdogTask = Task { @MainActor [weak self] in
            do {
                // `powermetrics` may need roughly ten seconds to emit its
                // first complete plist after a cold helper launch. Keep this
                // watchdog comfortably above that measured startup latency;
                // steady-state freshness is still checked separately.
                try await Task.sleep(nanoseconds: 25_000_000_000)
            } catch {
                return
            }
            guard let self,
                  self.administratorSamplingState == .starting,
                  self.administratorSampleCount == 0 else {
                return
            }

            let message = "增强服务已启动，但 25 秒内没有收到兼容的 CPU / GPU 数据。"
            self.administratorTerminalError = message
            self.administratorErrorMessage = message
            self.administratorSamplingState = .stopping
            self.privilegedPowerSampler.stop(withError: message)
        }
    }

    func refreshNow() {
        guard refreshTask == nil else { return }
        let sampler = hardwareSampler
        refreshTask = Task { @MainActor [weak self] in
            let snapshot = await sampler.sample()
            guard !Task.isCancelled, let self else { return }
            self.apply(snapshot)
            self.refreshTask = nil
        }
    }

    private func apply(_ snapshot: HardwareSnapshot) {
        smcReadings = snapshot.smcReadings
        smcCapabilities = snapshot.smcCapabilities
        smcCapabilityCount = snapshot.smcCapabilityCount
        smcNumericCapabilityCount = snapshot.smcNumericCapabilityCount
        smcKnownReadableKeyCount = snapshot.smcReadings.values.reduce(0) {
            $0 + ($1.status == .available ? 1 : 0)
        }
        updateBattery(from: snapshot.battery, smc: snapshot.smcValues)
        updateProcessor(from: snapshot.processor, smc: snapshot.smcValues)
        updatePowerFlow(
            battery: snapshot.battery,
            processor: snapshot.processor,
            smc: snapshot.smcValues
        )
        updateSystemState()
        scheduleProcessRefreshIfNeeded()

        lastUpdated = Date()
    }

    // MARK: - Sampling

    private func updateBattery(
        from snapshot: BatterySnapshot,
        smc: [String: Double]
    ) {
        batteryPresent = snapshot.isPresent
        batteryLevel = snapshot.isPresent ? snapshot.level : -1
        isCharging = snapshot.isPresent && snapshot.isCharging
        isFullyCharged = snapshot.isPresent && snapshot.isFullyCharged
        // A desktop Mac has no battery service, but necessarily runs from
        // external power. Keep that state explicit instead of showing 0% and
        // "正在使用电池".
        isOnAC = snapshot.isPresent ? snapshot.isOnAC : true
        batteryTempC = validTemperature(snapshot.temperatureC)
            ?? validTemperature(smcTemperature(smc, "TB0T", "TB1T", "TB2T"))
            ?? batteryTempC
        batteryTimeText = snapshot.isPresent
            ? snapshot.timeDescription
            : "无内置电池"
        cycleCount = snapshot.cycleCount
        healthPercent = snapshot.healthPercent
        healthIsEstimated = snapshot.healthPercent > 0
        fullCapacityMAh = snapshot.fullCapacityMAh
        designCapacityMAh = snapshot.designCapacityMAh
        if snapshot.currentCapacityMAh > 0 {
            currentCapacityMAh = snapshot.currentCapacityMAh
            capacityIsEstimated = false
        } else if fullCapacityMAh > 0, snapshot.level >= 0 {
            // Newer AppleSmartBattery registries can hide RemainingCapacity one
            // level below the service selected by BatteryReader. Preserve a
            // useful display value until that optional raw field is available.
            currentCapacityMAh = Int(
                (Double(fullCapacityMAh) * Double(min(snapshot.level, 100)) / 100)
                    .rounded()
            )
            capacityIsEstimated = true
        } else {
            currentCapacityMAh = 0
            capacityIsEstimated = false
        }
        adapterRatedWatts = nonnegativePower(snapshot.adapterRatedWatts)
        adapterVoltage = max(0, snapshot.adapterVoltage)
        adapterCurrent = max(0, snapshot.adapterCurrent)
        adapterName = snapshot.adapterName
        adapterEfficiencyLossWatts = nonnegativePower(snapshot.adapterEfficiencyLossWatts)
        externalPowerOutWatts = nonnegativePower(snapshot.externalPowerOutWatts)
        batteryVoltage = max(0, snapshot.batteryVoltage)
        batteryCurrent = snapshot.batteryCurrent

        let smcBatteryPower = smcPower(smc, "PPBR")
        // PPBR is the live battery rail on Apple Silicon. The IORegistry
        // BatteryPower value can remain stale after the charging direction
        // changes, so keep the registry figure as the fallback.
        let measuredBatteryFlow = isCharging
            ? firstPositive(snapshot.batteryFlowWatts, smcBatteryPower)
            : firstPositive(smcBatteryPower, snapshot.batteryFlowWatts)
        // Fully charged batteries can expose a sub-2 W balancing/trickle rail
        // even though no meaningful battery-to-system flow exists. Suppress
        // that noise so the diagram does not contradict the AC power balance.
        batteryFlowWatts =
            !snapshot.isPresent
                || (isOnAC && isFullyCharged && !isCharging && measuredBatteryFlow < 2)
                ? 0
                : measuredBatteryFlow

        if !snapshot.isPresent {
            batteryFlowDirection = .unavailable
        } else if isCharging {
            batteryFlowDirection = .charging
        } else if !isOnAC {
            batteryFlowDirection = .supplying
        } else if isFullyCharged || batteryFlowWatts <= 0.02 {
            batteryFlowDirection = .idle
        } else {
            // PPBR is a live battery-rail magnitude, not a direction signal.
            // On AC while charging is paused, do not guess whether the battery
            // is supplementing the adapter.
            batteryFlowDirection = .unknown
        }
    }

    private func updateProcessor(
        from data: ProcessorSnapshot,
        smc: [String: Double]
    ) {
        cpuUsagePercent = sampleCPUUsage()
        gpuUsagePercent = data.gpuUsage > 0 || data.gpuFreqMHz > 0
            ? clampedPercent(data.gpuUsage)
            : -1
        gpuFrequencyMHz = max(0, data.gpuFreqMHz)
        efficiencyClusterUsagePercent = clampedPercent(data.eClusterActive)
        performanceClusterUsagePercent = clampedPercent(data.pClusterActive)
        superClusterUsagePercent = clampedPercent(data.sClusterActive)
        efficiencyClusterFrequencyMHz = max(0, data.eClusterFreqMHz)
        performanceClusterFrequencyMHz = max(0, data.pClusterFreqMHz)
        superClusterFrequencyMHz = max(0, data.sClusterFreqMHz)
        dramReadBytesPerSecond = max(0, data.dramReadBytesPerSecond)
        dramWriteBytesPerSecond = max(0, data.dramWriteBytesPerSecond)
        fanRPM = max(0, data.fanRPM)
        fan2RPM = max(0, data.fan2RPM)

        cpuPowerWatts = firstPositive(
            data.cpuPower,
            smcPower(smc, "PCPT", "PCTR", "PCPR", "PCPC", "PC0C")
        )
        gpuPowerWatts = firstPositive(
            data.gpuPower,
            smcPower(smc, "PG0R", "PG0C", "PCPG")
        )
        anePowerWatts = nonnegativePower(data.anePower)
        dramPowerWatts = firstPositive(
            data.dramPower,
            smcPower(smc, "PMTR", "PC3C")
        )
        gpuSRAMPowerWatts = nonnegativePower(data.gpuSRAMPower)
        mediaPowerWatts = nonnegativePower(data.mediaPower)
        ispPowerWatts = nonnegativePower(data.ispPower)
        fabricPowerWatts = nonnegativePower(data.fabricPower)
        pciePowerWatts = nonnegativePower(data.pciePower)
        displaySoCPowerWatts = nonnegativePower(data.displaySoCPower)
        displayExternalControllerPowerWatts = nonnegativePower(
            data.displayExtPower
        )

        if let temperature = validTemperature(data.cpuTemp) {
            cpuTempC = temperature
        } else if let temperature = validTemperature(smcTemperature(
            smc, "TCMz", "Tp0P", "Tp1P", "Te0P", "Te1P"
        )) {
            cpuTempC = temperature
        }
        if let temperature = validTemperature(data.cpuDieHotspot) {
            cpuDieHotspotC = temperature
        } else {
            cpuDieHotspotC = cpuTempC
        }

        if let temperature = validTemperature(data.gpuTemp) {
            gpuTempC = temperature
        } else if let temperature = validTemperature(smcTemperature(
            smc, "Tg0P", "Tg1P", "Tg0D", "TG0D"
        )) {
            gpuTempC = temperature
        }

        if let temperature = validTemperature(smcTemperature(
            smc, "Ta0P", "Ta1P", "Ta0D", "Ta1D"
        )) {
            aneTempC = temperature
        }
        if let temperature = validTemperature(smcTemperature(
            smc, "Tm0P", "Tm1P", "Tm0D", "Tm1D"
        )) {
            dramTempC = temperature
        }
    }

    private func updatePowerFlow(
        battery: BatterySnapshot,
        processor: ProcessorSnapshot,
        smc: [String: Double]
    ) {
        let smcAdapter = smcPower(smc, "PDTR")
        adapterInputWatts = firstPositive(
            smcAdapter,
            battery.systemInputWatts
        )

        let smcSystem = smcPower(smc, "PSTR")
        let balanceEstimate: Double
        if isOnAC {
            switch batteryFlowDirection {
            case .charging:
                balanceEstimate = adapterInputWatts - batteryFlowWatts
            case .supplying:
                balanceEstimate = adapterInputWatts + batteryFlowWatts
            case .idle, .unknown, .unavailable:
                balanceEstimate = adapterInputWatts
            }
        } else {
            balanceEstimate = batteryFlowWatts
        }

        let measuredSystemLoad = firstPositive(
            smcSystem,
            battery.systemLoadWatts,
            processor.systemPower
        )
        systemLoadIsEstimated = measuredSystemLoad == 0 && balanceEstimate > 0
        systemLoadWatts = firstPositive(measuredSystemLoad, balanceEstimate)

        // PBwo is used by newer Apple Silicon systems; PDBR is present on
        // several M1–M4 MacBook Pro models.
        if smcReadings["PBwo"]?.status == .available {
            displayPowerWatts = nonnegativePower(smc["PBwo"] ?? 0)
        } else {
            displayPowerWatts = nonnegativePower(smcPower(smc, "PDBR"))
        }

        reconcileStandardGPUPowerAgainstCurrentBudget()
        updateProcessorAggregatePower(smc: smc)

        // These rails are used only when an independently known FourCC is
        // present and decodes through a known SMC numeric type. Aggregate wins;
        // per-port keys are fallbacks and are not double-counted.
        wifiPowerWatts = nonnegativePower(smcPower(smc, "wiPm"))
        if smcReadings["PUSB"]?.status == .available {
            // A present aggregate reporting a real 0 W is authoritative; do
            // not replace it with a possibly asynchronous per-port sample.
            usbPowerWatts = nonnegativePower(smc["PUSB"] ?? 0)
        } else {
            usbPowerWatts = smcPowerSum(smc, "PUS0", "PUS1", "PUS2")
        }

        // "Other" is a residual bucket. Keeping it nonnegative prevents
        // asynchronously sampled rails from creating an impossible UI flow.
        let standardCPU = min(
            nonnegativePower(cpuPowerWatts),
            max(0, availableProcessorPowerBudgetWatts - gpuPowerWatts)
        )
        otherPowerWatts = max(
            0,
            systemLoadWatts
                - standardCPU
                - gpuPowerWatts
                - effectiveDisplayPowerWatts
        )
    }

    private func reconcileStandardGPUPowerAgainstCurrentBudget() {
        let candidate = nonnegativePower(gpuPowerWatts)
        guard systemLoadWatts.isFinite, systemLoadWatts > 0.02 else {
            // Preserve the raw standard source for diagnostics when no whole-
            // system budget exists yet. Effective UI values remain zero until
            // the budget is known, so the main diagram cannot become invalid.
            gpuPowerWatts = candidate
            return
        }

        let budget = availableProcessorPowerBudgetWatts
        let now = Date()
        if isClearlyAbovePowerBudget(candidate, budget: budget) {
            let age = now.timeIntervalSince(lastReasonableStandardGPUSampleDate)
            if let previous = lastReasonableStandardGPUPowerWatts,
               age >= 0,
               age <= standardGPUFallbackFreshness {
                gpuPowerWatts = min(previous, budget)
            } else {
                gpuPowerWatts = 0
            }
            return
        }

        // A small cross-sampler overshoot is plausible, but the value rendered
        // in the energy flow must still fit the physical whole-system budget.
        let reconciled = min(candidate, budget)
        gpuPowerWatts = reconciled
        lastReasonableStandardGPUPowerWatts = reconciled
        lastReasonableStandardGPUSampleDate = now
    }

    private func isClearlyAbovePowerBudget(
        _ value: Double,
        budget: Double
    ) -> Bool {
        let safeValue = nonnegativePower(value)
        let safeBudget = nonnegativePower(budget)
        let tolerance = max(
            componentBudgetAbsoluteToleranceWatts,
            safeBudget * componentBudgetRelativeTolerance
        )
        return safeValue > safeBudget + tolerance
    }

    private func updateProcessorAggregatePower(smc: [String: Double]) {
        let componentPower =
            cpuPowerWatts + gpuPowerWatts + anePowerWatts + dramPowerWatts
        // Linux's upstream macsmc driver documents PHPC as the SoC heat
        // dissipation estimate. It is a useful fallback on macOS builds where
        // IOReport temporarily stops publishing per-component energy.
        let socHeatEstimate = smcPower(smc, "PHPC")
        if socHeatEstimate > 0 {
            processorPowerWatts = socHeatEstimate
            processorPowerIsEstimated = true
            processorPowerIsPartial = false
        } else if componentPower > 0 {
            // These four IOReport domains are useful, but they do not represent
            // every SoC rail. Keep both the approximation and partial-data
            // semantics explicit so the UI never presents their sum as a
            // complete package measurement.
            processorPowerWatts = componentPower
            processorPowerIsEstimated = true
            processorPowerIsPartial = true
        } else {
            processorPowerWatts = 0
            processorPowerIsEstimated = false
            processorPowerIsPartial = false
        }
    }

    private func updateSystemState() {
        lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled

        switch ProcessInfo.processInfo.thermalState {
        case .nominal:
            thermalStateText = "正常"
        case .fair:
            thermalStateText = "温热"
        case .serious:
            thermalStateText = "较热"
        case .critical:
            thermalStateText = "过热"
        @unknown default:
            thermalStateText = "未知"
        }
    }

    // MARK: - SMC

    private func smcPower(
        _ values: [String: Double],
        _ keys: String...
    ) -> Double {
        for key in keys {
            let value = values[key] ?? 0
            if value.isFinite, value > 0, value < 2_000 {
                return value
            }
        }
        return 0
    }

    private func smcTemperature(
        _ values: [String: Double],
        _ keys: String...
    ) -> Double {
        var sum = 0.0
        var count = 0
        for key in keys {
            let value = values[key] ?? 0
            if let temperature = validTemperature(value) {
                sum += temperature
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : 0
    }

    private func smcPowerSum(
        _ values: [String: Double],
        _ keys: String...
    ) -> Double {
        let total = keys.reduce(0) { total, key in
            total + smcPower(values, key)
        }
        return nonnegativePower(total)
    }

    // MARK: - CPU host ticks

    private func sampleCPUUsage() -> Double {
        var cpuCount: natural_t = 0
        var rawInfo: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        guard host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &rawInfo,
            &infoCount
        ) == KERN_SUCCESS, let rawInfo else {
            return cpuUsagePercent
        }

        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: rawInfo),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }

        let count = Int(cpuCount)
        var current = [[UInt32]](
            repeating: [0, 0, 0, 0],
            count: count
        )
        for index in 0..<count {
            let offset = index * Int(CPU_STATE_MAX)
            current[index][0] = UInt32(
                bitPattern: rawInfo[offset + Int(CPU_STATE_USER)]
            )
            current[index][1] = UInt32(
                bitPattern: rawInfo[offset + Int(CPU_STATE_SYSTEM)]
            )
            current[index][2] = UInt32(
                bitPattern: rawInfo[offset + Int(CPU_STATE_IDLE)]
            )
            current[index][3] = UInt32(
                bitPattern: rawInfo[offset + Int(CPU_STATE_NICE)]
            )
        }

        guard previousCPUTicks.count == current.count else {
            previousCPUTicks = current
            return cpuUsagePercent
        }

        var usedTicks = 0.0
        var totalTicks = 0.0
        for index in current.indices {
            let previous = previousCPUTicks[index]
            let user = Double(current[index][0] &- previous[0])
            let system = Double(current[index][1] &- previous[1])
            let idle = Double(current[index][2] &- previous[2])
            let nice = Double(current[index][3] &- previous[3])

            usedTicks += user + system + nice
            totalTicks += user + system + idle + nice
        }
        previousCPUTicks = current

        guard totalTicks > 0 else { return cpuUsagePercent }
        return clampedPercent(usedTicks / totalTicks * 100)
    }

    // MARK: - Process activity

    private func scheduleProcessRefreshIfNeeded() {
        guard processTask == nil,
              Date().timeIntervalSince(lastProcessRefresh) >= processInterval
        else {
            return
        }

        lastProcessRefresh = Date()
        processTask = Task { @MainActor [weak self] in
            let output = await Task.detached(priority: .utility) {
                Self.runPS()
            }.value

            guard !Task.isCancelled, let self else { return }
            self.topProcesses = Self.parseProcesses(output)
            self.processTask = nil
        }
    }

    nonisolated private static func runPS() -> String {
        let process = Process()
        let outputPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,%cpu=,comm=", "-r"]
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return ""
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func parseProcesses(_ output: String) -> [ActivityProcess] {
        var result: [ActivityProcess] = []
        result.reserveCapacity(3)

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let fields = rawLine.split(
                maxSplits: 2,
                omittingEmptySubsequences: true,
                whereSeparator: \.isWhitespace
            )
            guard fields.count == 3,
                  let pid = Int(fields[0]),
                  pid > 0,
                  let cpu = Double(fields[1]),
                  cpu.isFinite,
                  cpu >= 0
            else {
                continue
            }

            let command = String(fields[2])
            let name = URL(fileURLWithPath: command).lastPathComponent
            if name == "MacPowerFlow" || name == "kernel_task" {
                continue
            }
            result.append(ActivityProcess(
                id: pid,
                name: name.isEmpty ? command : name,
                cpuPercent: cpu
            ))

            if result.count == 3 { break }
        }
        return result
    }

    // MARK: - Helpers

    private func firstPositive(_ values: Double...) -> Double {
        for value in values {
            let normalized = nonnegativePower(value)
            if normalized > 0 {
                return normalized
            }
        }
        return 0
    }

    private func nonnegativePower(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return max(0, min(value, 2_000))
    }

    private func clampedPercent(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return max(0, min(value, 100))
    }

    private func validTemperature(_ value: Double) -> Double? {
        guard value.isFinite, value > 0, value < 150 else { return nil }
        return value
    }

    private static func sysctlString(_ key: String) -> String {
        var length = 0
        guard sysctlbyname(key, nil, &length, nil, 0) == 0, length > 1 else {
            return ""
        }

        var buffer = [CChar](repeating: 0, count: length)
        let result = buffer.withUnsafeMutableBytes { bytes in
            sysctlbyname(key, bytes.baseAddress, &length, nil, 0)
        }
        guard result == 0 else { return "" }
        return String(cString: buffer)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
