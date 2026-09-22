import AppKit
import Combine
import Darwin
import Foundation
import IOKit
import IOKit.ps

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
    let history: PowerHistoryStore
    let diagnostics = AppDiagnostics()
    let alerts: PowerAlerts
    let energyInsights: EnergyInsightsStore
    let powerControls = PowerControls()
    @Published private(set) var fans: [FanSnapshot]?
    @Published private(set) var lowPowerControlMessage = ""
    @Published private(set) var lowPowerControlBusy = false
    @Published private(set) var insights: SystemInsightsSnapshot?
    @Published private(set) var latestBattery: BatterySnapshot?
    @Published private(set) var powerAvailability: Set<String> = []
    @Published private(set) var systemLoadAvailable = false
    @Published private(set) var systemHistoryQuality = PowerHistoryQuality.unavailable
    @Published private(set) var powerSourceLabel = "等待采样"
    @Published private(set) var samplingStatus = "baseline"
    @Published private(set) var sampleDuration: TimeInterval = 0
    @Published private(set) var powerBalanceResidual: Double?
    @Published private(set) var signedBatteryWatts: Double?
    @Published private(set) var panelVisible = false
    private let insightsSampler = SystemInsightsSampler()
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var systemObservers: [NSObjectProtocol] = []
    private var historyObservation: AnyCancellable?
    private var visibleSurfaces = Set<String>()
    private var activityRequested = false
    private var lastHealthRecord = Date.distantPast
    private var wakeEndpointPending = false
    private var observedExternalPower: Bool?
    private var lifecycleGeneration = UUID()
    private var initialActivitySamples = 0
    private var suspended = false
    private var nextEnhancedRetry = Date.distantPast
    private var enhancedRetryCount = 0
    private var automaticEnhancedSampling = true

    var rawCPUWatts: Double? {
        if administratorSampleIsFresh && administratorCPUHasValue { return administratorCPUPowerWatts }
        return powerAvailability.contains("cpu") ? cpuPowerWatts : nil
    }
    var rawGPUWatts: Double? {
        if administratorSampleIsFresh && administratorGPUHasValue { return administratorGPUPowerWatts }
        return powerAvailability.contains("gpu") ? gpuPowerWatts : nil
    }
    var isSupplementingAdapter: Bool { isOnAC && adapterInputWatts > 0.2 && (signedBatteryWatts ?? 0) < -0.2 }
    var flowWasAdjusted: Bool {
        abs((rawCPUWatts ?? 0) - effectiveCPUPowerWatts) > 0.1 ||
        abs((rawGPUWatts ?? 0) - effectiveGPUPowerWatts) > 0.1 ||
        displayPowerWatts - effectiveDisplayPowerWatts > 0.1
    }
    var samplingIntervalSeconds: Double {
        if panelVisible || history.activeSession != nil { return 2 }
        return lowPowerModeEnabled ? 10 : 5
    }
    func setPanelVisible(_ value: Bool, surface: String = "popover") {
        if value { visibleSurfaces.insert(surface) } else { visibleSurfaces.remove(surface) }
        let visible = !visibleSurfaces.isEmpty
        if panelVisible != visible { panelVisible = visible }
        diagnostics.updateState(panelVisible: visible, enhancedSampling: administratorSampleIsFresh)
        synchronizeSamplingInterval()
        if value { refreshNow() }
    }

    func setActivityRequested(_ value: Bool) {
        guard activityRequested != value else { return }
        activityRequested = value
        if value { initialActivitySamples = 0 }
        lastProcessRefresh = .distantPast
        if value { refreshNow() }
    }

    var processDataReady: Bool {
        guard let insights, Date().timeIntervalSince(insights.timestamp) < 25,
              let processes = insights.topProcesses else { return false }
        return processes.isEmpty || processes.contains { $0.cpuPercent != nil }
    }
    var processStatusText: String { processDataReady ? "当前没有可列出的进程" : "正在建立进程采样基线" }
    var processStatusSymbol: String { processDataReady ? "list.bullet" : "clock" }
    var enhancedIntervalSeconds: Int { privilegedPowerSampler.samplingIntervalSeconds }

    private func synchronizeSamplingInterval() {
        let interval = Int(samplingIntervalSeconds)
        guard interval != privilegedPowerSampler.samplingIntervalSeconds else { return }
        administratorLastUpdated = .distantPast
        administratorSampleCount = 0
        administratorWindowStart = nil
        history.breakContinuity()
        _ = privilegedPowerSampler.setSamplingInterval(seconds: interval)
        if isSampling && !suspended { restartMonitoringTimer() }
    }

    func setLowPowerMode(source: LowPowerModeSource, enabled: Bool) {
        guard !lowPowerControlBusy else { return }
        lowPowerControlBusy = true
        lowPowerControlMessage = "正在应用并核对系统设置…"
        privilegedPowerSampler.setLowPowerMode(source: source, enabled: enabled) { [weak self] actual, error in
            guard let self else { return }
            self.lowPowerControlBusy = false
            if let actual {
                self.lowPowerControlMessage = "\(source == .battery ? "使用电池" : "接通电源")时低功耗已\(actual ? "开启" : "关闭")，已回读确认"
            } else {
                self.lowPowerControlMessage = error ?? "未能确认设置，请打开系统电池设置检查"
            }
            self.updateSystemState()
            self.synchronizeSamplingInterval()
            self.powerControls.refreshWhenVisible(true, force: true)
        }
    }

    private func batteryInsight(_ battery: BatterySnapshot) -> BatteryInsightSample {
        BatteryInsightSample(date: battery.observedAt, isPresent: battery.isPresent,
            isOnAC: battery.isOnAC, level: battery.reportedLevel,
            currentCapacityMAh: battery.reportedCurrentCapacityMAh,
            fullCapacityMAh: battery.fullCapacityMAh > 0 ? battery.fullCapacityMAh : nil,
            designCapacityMAh: battery.designCapacityMAh > 0 ? battery.designCapacityMAh : nil,
            cycleCount: battery.reportedCycleCount,
            temperatureC: battery.temperatureC > 0 ? battery.temperatureC : nil,
            voltage: battery.batteryVoltage > 0 ? battery.batteryVoltage : nil)
    }
    private func installLifecycleObservers() {
        guard lifecycleObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        lifecycleObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lifecycleGeneration = UUID()
                self.suspended = true
                self.monitoringTask?.cancel()
                self.monitoringTask = nil
                // Read only the battery at the sleep boundary; a cached UI sample
                // may be up to ten seconds old. No full IOReport/process scan.
                self.energyInsights.willSleep(self.batteryInsight(BatteryReader.read()))
                self.refreshTask?.cancel()
                self.refreshTask = nil
                self.processTask?.cancel()
                self.processTask = nil
                self.history.breakContinuity()
                self.wakeEndpointPending = true
                self.history.saveInBackground()
                self.privilegedPowerSampler.stop()
            }
        })
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            systemObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateSystemState()
                    self?.synchronizeSamplingInterval()
                    self?.refreshNow()
                }
            })
        }
        lifecycleObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let generation = self.lifecycleGeneration
                await self.hardwareSampler.resetBaseline()
                await self.insightsSampler.reset()
                guard !Task.isCancelled, self.isSampling, self.lifecycleGeneration == generation else { return }
                self.history.breakContinuity()
                self.suspended = false
                self.enhancedRetryCount = 0
                self.nextEnhancedRetry = .distantPast
                self.lastProcessRefresh = .distantPast
                self.initialActivitySamples = 0
                self.restartMonitoringTimer()
                self.refreshNow()
            }
        })
    }

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
    @Published private(set) var systemInputVoltage = 0.0
    @Published private(set) var systemInputCurrent = 0.0
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
    private var administratorWindowStart: Date?
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

    private let processInterval: TimeInterval = 10
    private let hardwareSampler = HardwareSampler()
    private let privilegedPowerSampler = PrivilegedPowerSampler()

    private var monitoringTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var processTask: Task<Void, Never>?
    private var lastProcessRefresh = Date.distantPast
    private var previousCPUTicks: [[UInt32]] = []
    private var administratorStartupWatchdogTask: Task<Void, Never>?
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var administratorTerminalError: String?

    init() {
        // Diagnostic launches may opt into a separate local data directory so
        // two app processes never overwrite the user's running history.
        let directory = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--data-directory=") }
            .map { URL(fileURLWithPath: String($0.dropFirst("--data-directory=".count)), isDirectory: true) }
        history = PowerHistoryStore(fileURL: directory?.appendingPathComponent("power-history-v1.json"))
        energyInsights = EnergyInsightsStore(fileURL: directory?.appendingPathComponent("energy-insights-v1.json"))
        alerts = PowerAlerts(preferences: directory == nil ? .standard : UserDefaults(suiteName: "com.llf.MacPowerFlow.preview")!)
        chipName = Self.sysctlString("machdep.cpu.brand_string")
        if chipName.isEmpty {
            chipName = Self.sysctlString("hw.model")
        }
        if chipName.isEmpty {
            chipName = "Mac"
        }

        updateSystemState()
        historyObservation = history.$activeSession.map { $0?.id }.removeDuplicates().dropFirst()
            .receive(on: RunLoop.main).sink { [weak self] _ in
                self?.synchronizeSamplingInterval()
                self?.lastProcessRefresh = .distantPast
                self?.refreshNow()
            }
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
        guard !isSampling else { return }

        automaticEnhancedSampling = automaticallyStartAdministrator
        isSampling = true
        suspended = false
        installLifecycleObservers()
        history.breakContinuity()
        diagnostics.start()
        alerts.restorePreferences()
        synchronizeSamplingInterval()
        installPowerSourceWatcherIfNeeded()
        refreshNow()
        if automaticallyStartAdministrator {
            startAdministratorSampling()
        }

        restartMonitoringTimer()
    }

    private func restartMonitoringTimer() {
        monitoringTask?.cancel()
        guard isSampling, !suspended else { monitoringTask = nil; return }
        monitoringTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64((self?.samplingIntervalSeconds ?? 5) * 1_000_000_000))
                } catch {
                    break
                }
                guard !Task.isCancelled, let self else { break }
                self.refreshNow()
            }
        }
    }

    func stopMonitoring() {
        lifecycleGeneration = UUID()
        monitoringTask?.cancel()
        monitoringTask = nil

        processTask?.cancel()
        processTask = nil

        refreshTask?.cancel()
        refreshTask = nil

        administratorStartupWatchdogTask?.cancel()
        administratorStartupWatchdogTask = nil
        removePowerSourceWatcher()
        lifecycleObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        lifecycleObservers.removeAll()
        systemObservers.forEach { NotificationCenter.default.removeObserver($0) }
        systemObservers.removeAll()
        history.breakContinuity()
        history.flush()
        energyInsights.flush()
        diagnostics.stop()
        privilegedPowerSampler.stop()

        let sampler = hardwareSampler
        Task {
            await sampler.close()
        }
        previousCPUTicks.removeAll(keepingCapacity: true)
        isSampling = false
    }

    /// Deterministic visual fixture used by `--preview-charging`. Keeping the
    /// fixture in the model exercises the same main-panel state as a live read,
    /// rather than tinting only the menu-bar icon.
    func installChargingPreview() {
        systemLoadAvailable = true
        batteryPresent = true
        batteryLevel = 62
        isCharging = true
        isFullyCharged = false
        isOnAC = true
        batteryTempC = 32.8
        batteryTimeText = "1 小时 08 分钟"
        batteryFlowWatts = 18.4
        batteryVoltage = 12.42
        batteryCurrent = 1.48
        batteryFlowDirection = .charging
        cycleCount = 256
        healthPercent = 85
        currentCapacityMAh = 2_995
        fullCapacityMAh = 4_830
        designCapacityMAh = 6_075

        adapterRatedWatts = 100
        adapterVoltage = 20
        adapterCurrent = 5
        systemInputVoltage = 19.3
        systemInputCurrent = 2.59
        adapterName = "USB-C 电源适配器"
        adapterInputWatts = 50
        systemLoadWatts = 31.6
        adapterEfficiencyLossWatts = 1.1
        processorPowerWatts = 14.2
        cpuPowerWatts = 9.8
        gpuPowerWatts = 4.4
        displayPowerWatts = 5.2
        cpuUsagePercent = 38
        gpuUsagePercent = 24
        cpuTempC = 52
        cpuDieHotspotC = 58
        gpuTempC = 49
        gpuFrequencyMHz = 1_020
        lastUpdated = Date()
        isSampling = false
    }

    // MARK: - Administrator sampling

    private func installPowerSourceWatcherIfNeeded() {
        guard powerSourceRunLoopSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let unmanagedSource = IOPSNotificationCreateRunLoopSource(
            { rawContext in
                guard let rawContext else { return }
                let monitor = Unmanaged<PowerMonitor>
                    .fromOpaque(rawContext)
                    .takeUnretainedValue()
                Task { @MainActor in
                    let battery = BatteryReader.read()
                    if let previous = monitor.observedExternalPower, previous != battery.isOnAC {
                        monitor.energyInsights.notePowerSourceChange()
                    }
                    monitor.observedExternalPower = battery.isOnAC
                    monitor.refreshNow()
                }
            },
            context
        ) else {
            return
        }
        let source = unmanagedSource.takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        powerSourceRunLoopSource = source
    }

    private func removePowerSourceWatcher() {
        guard let source = powerSourceRunLoopSource else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        powerSourceRunLoopSource = nil
    }

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
        effectiveProcessorPowerAllocation.cpuWatts
    }

    var effectiveGPUPowerWatts: Double {
        effectiveProcessorPowerAllocation.gpuWatts
    }

    private var effectiveProcessorPowerAllocation: ProcessorPowerAllocation {
        // Only the flow's widths/labels are reconciled. Raw readings and history
        // retain their original values and the detail panel exposes this choice.
        PowerMetricsCore.allocateProcessorPower(
            cpuCandidateWatts: rawCPUWatts ?? 0,
            gpuCandidateWatts: rawGPUWatts ?? 0,
            budgetWatts: availableProcessorPowerBudgetWatts
        )
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
        .filter { component in
            if component.id == "ane", administratorSampleIsFresh && administratorANEHasValue { return true }
            if component.id == "wifi" { return smcReadings["wiPm"]?.status == .available }
            if component.id == "usb" { return ["PUSB", "PUS0", "PUS1", "PUS2"].contains { smcReadings[$0]?.status == .available } }
            return powerAvailability.contains(component.id) && component.powerWatts.isFinite
        }
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

    /// Residual only; no fixed-weight attribution to unmeasured devices.
    var estimatedOtherPowerComponents: [OtherPowerComponent] {
        [OtherPowerComponent(id: "unattributed", label: "未归因功耗",
                             powerWatts: estimatedOtherPowerBudgetWatts,
                             basis: "整机残差，不能独立分配到网络、风扇等设备")]
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

    func startAdministratorSampling(allowInstallation: Bool = false) {
        if allowInstallation { enhancedRetryCount = 0; nextEnhancedRetry = Date().addingTimeInterval(60) }
        guard !privilegedPowerSampler.isRunning,
              privilegedPowerSampler.state != .stopping else { return }
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
            allowInstallation: allowInstallation,
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
        guard administratorSamplingState == .authorizing
                || administratorSamplingState == .starting
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
        administratorWindowStart = sample.windowStart
        enhancedRetryCount = 0
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
            if administratorSampleCount > 0 {
                administratorSamplingState = .active
            } else {
                administratorSamplingState = .authorizing
            }
        case .running:
            // A complete first plist can arrive immediately after the helper
            // spawns, before the start reply is delivered on the main queue.
            // Do not downgrade an already accepted sample back to `.starting`.
            if administratorSampleCount > 0 {
                administratorStartupWatchdogTask?.cancel()
                administratorStartupWatchdogTask = nil
                administratorSamplingState = .active
            } else {
                administratorSamplingState = .starting
                scheduleAdministratorStartupWatchdog()
            }
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
            && age < max(8, Double(privilegedPowerSampler.samplingIntervalSeconds) * 2.5)
    }

    private func scheduleAdministratorStartupWatchdog() {
        administratorStartupWatchdogTask?.cancel()
        administratorStartupWatchdogTask = Task { @MainActor [weak self] in
            do {
                // `powermetrics` may need an extended delta baseline after a
                // cold helper launch. The helper actively requests and flushes
                // initial samples; this remains only a terminal safety net.
                // Steady-state freshness is still checked separately.
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {
                return
            }
            guard let self,
                  self.administratorSamplingState == .starting,
                  self.administratorSampleCount == 0 else {
                return
            }

            let message = "增强服务已启动，但 60 秒内没有收到兼容的 CPU / GPU 数据。"
            self.administratorTerminalError = message
            self.administratorErrorMessage = message
            self.administratorSamplingState = .stopping
            self.privilegedPowerSampler.stop(withError: message)
        }
    }

    func refreshNow() {
        guard isSampling, !suspended, refreshTask == nil else { return }
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
        synchronizeSamplingInterval()
        fans = snapshot.fans
        if wakeEndpointPending {
            wakeEndpointPending = false
            energyInsights.didWake(batteryInsight(snapshot.battery))
        }
        if Date().timeIntervalSince(lastHealthRecord) >= 60 {
            lastHealthRecord = Date()
            energyInsights.record(batteryInsight(snapshot.battery))
        }
        scheduleProcessRefreshIfNeeded()

        lastUpdated = Date()
        if snapshot.processor.sampleStatus == "reset" || snapshot.processor.sampleStatus == "baseline" {
            history.breakContinuity()
        }
        history.record(PowerHistoryPoint(
            timestamp: lastUpdated, windowStart: lastUpdated, windowEnd: lastUpdated,
            systemWatts: systemLoadAvailable ? systemLoadWatts : nil,
            cpuWatts: rawCPUWatts, gpuWatts: rawGPUWatts,
            signedBatteryWatts: signedBatteryWatts,
            source: powerSourceLabel,
            quality: systemHistoryQuality,
            cpuWindowStart: administratorSampleIsFresh && administratorCPUHasValue ? administratorWindowStart : (snapshot.processor.powerAvailability.contains("cpu") ? Date(timeIntervalSince1970: snapshot.processor.samplingWindowStart) : nil),
            cpuWindowEnd: administratorSampleIsFresh && administratorCPUHasValue ? administratorLastUpdated : (snapshot.processor.powerAvailability.contains("cpu") ? Date(timeIntervalSince1970: snapshot.processor.samplingWindowEnd) : nil),
            gpuWindowStart: administratorSampleIsFresh && administratorGPUHasValue ? administratorWindowStart : (snapshot.processor.powerAvailability.contains("gpu") ? Date(timeIntervalSince1970: snapshot.processor.samplingWindowStart) : nil),
            gpuWindowEnd: administratorSampleIsFresh && administratorGPUHasValue ? administratorLastUpdated : (snapshot.processor.powerAvailability.contains("gpu") ? Date(timeIntervalSince1970: snapshot.processor.samplingWindowEnd) : nil),
            cpuSource: rawCPUWatts == nil ? nil : (administratorSampleIsFresh && administratorCPUHasValue ? "powermetrics" : (snapshot.processor.powerAvailability.contains("cpu") ? "IOReport energy model" : "SMC")),
            gpuSource: rawGPUWatts == nil ? nil : (administratorSampleIsFresh && administratorGPUHasValue ? "powermetrics" : (snapshot.processor.powerAvailability.contains("gpu") ? "IOReport energy model" : "SMC")),
            cpuQuality: rawCPUWatts == nil ? .unavailable : .estimated,
            gpuQuality: rawGPUWatts == nil ? .unavailable : .estimated
        ))
        alerts.observe(date: lastUpdated, isOnAC: isOnAC,
                       batteryLevel: batteryPresent ? batteryLevel : nil,
                       signedBatteryWatts: signedBatteryWatts,
                       systemWatts: systemLoadAvailable ? systemLoadWatts : nil,
                       thermalState: ProcessInfo.processInfo.thermalState)
        diagnostics.updateState(panelVisible: panelVisible, enhancedSampling: administratorSampleIsFresh)
        if automaticEnhancedSampling && administratorSamplingState == .active && Date().timeIntervalSince(administratorLastUpdated) > 30 {
            privilegedPowerSampler.stop(withError: "增强数据超过30秒未更新，将静默重试。")
        }
        if automaticEnhancedSampling && (administratorSamplingState == .failed || administratorSamplingState == .inactive) {
            if enhancedRetryCount < 3 && Date() >= nextEnhancedRetry {
                enhancedRetryCount += 1
                nextEnhancedRetry = Date().addingTimeInterval(60 * Double(enhancedRetryCount))
                startAdministratorSampling() // Silent only; never installs on recovery.
            }
        }
    }

    // MARK: - Sampling

    private func updateBattery(
        from snapshot: BatterySnapshot,
        smc: [String: Double]
    ) {
        if let previous = observedExternalPower, previous != snapshot.isOnAC {
            energyInsights.notePowerSourceChange()
        }
        observedExternalPower = snapshot.isOnAC
        batteryPresent = snapshot.isPresent
        batteryLevel = snapshot.isPresent ? snapshot.level : -1
        latestBattery = snapshot
        isCharging = snapshot.isCharging
        isFullyCharged = snapshot.isFullyCharged
        isOnAC = snapshot.isPresent ? snapshot.isOnAC : true
        batteryTempC = validTemperature(snapshot.temperatureC)
            ?? validTemperature(smcTemperature(smc, "TB0T", "TB1T", "TB2T"))
            ?? 0
        batteryTimeText = snapshot.isPresent
            ? (isCharging
                ? snapshot.timeToFullDescription
                : snapshot.timeDescription)
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
        systemInputVoltage = max(0, snapshot.systemInputVoltage)
        systemInputCurrent = max(0, snapshot.systemInputCurrent)
        adapterName = snapshot.adapterName
        adapterEfficiencyLossWatts = nonnegativePower(snapshot.adapterEfficiencyLossWatts)
        externalPowerOutWatts = nonnegativePower(snapshot.externalPowerOutWatts)
        batteryVoltage = max(0, snapshot.batteryVoltage)
        batteryCurrent = snapshot.batteryCurrent

        signedBatteryWatts = snapshot.signedBatteryPowerWatts
        batteryFlowWatts = abs(signedBatteryWatts ?? 0)
        batteryFlowDirection = !snapshot.isPresent ? .unavailable : .unknown
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

        powerAvailability = data.powerAvailability
        samplingStatus = data.sampleStatus
        sampleDuration = data.sampleDuration
        func availableSMC(_ keys: [String], domain: String) -> Double? {
            for key in keys where smcReadings[key]?.status == .available {
                if let value = smc[key], value.isFinite, value >= 0 {
                    powerAvailability.insert(domain)
                    return value
                }
            }
            return nil
        }
        cpuPowerWatts = data.powerAvailability.contains("cpu") ? data.cpuPower :
            (availableSMC(["PCPT", "PCTR", "PCPR", "PCPC", "PC0C"], domain: "cpu") ?? 0)
        gpuPowerWatts = data.powerAvailability.contains("gpu") ? data.gpuPower :
            (availableSMC(["PG0R", "PG0C", "PCPG"], domain: "gpu") ?? 0)
        anePowerWatts = nonnegativePower(data.anePower)
        dramPowerWatts = data.powerAvailability.contains("dram") ? data.dramPower :
            (availableSMC(["PMTR", "PC3C"], domain: "dram") ?? 0)
        gpuSRAMPowerWatts = nonnegativePower(data.gpuSRAMPower)
        mediaPowerWatts = nonnegativePower(data.mediaPower)
        ispPowerWatts = nonnegativePower(data.ispPower)
        fabricPowerWatts = nonnegativePower(data.fabricPower)
        pciePowerWatts = nonnegativePower(data.pciePower)
        displaySoCPowerWatts = nonnegativePower(data.displaySoCPower)
        displayExternalControllerPowerWatts = nonnegativePower(
            data.displayExtPower
        )

        // A failed sensor must not keep an old temperature looking current.
        cpuTempC = 0
        gpuTempC = 0
        aneTempC = 0
        dramTempC = 0
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
        func knownSMC(_ key: String) -> Double? {
            smcReadings[key]?.status == .available ? smc[key] : nil
        }
        let balance = PowerMetricsCore.resolvePowerBalance(
            smcPDTRWatts: knownSMC("PDTR"), smcPSTRWatts: knownSMC("PSTR"),
            telemetrySystemPowerInWatts: battery.hasSystemInputPower ? battery.systemInputWatts : nil,
            telemetrySystemLoadWatts: battery.hasSystemLoadPower ? battery.systemLoadWatts : nil,
            telemetryBatteryPowerWatts: battery.hasTelemetryBatteryPower ? battery.telemetryBatteryPowerWatts : nil,
            signedPackBatteryWatts: battery.packBatteryPowerWatts, isOnAC: isOnAC,
            telemetryIsUsable: battery.telemetryFreshness != .stale
        )
        powerBalanceResidual = balance.residualWatts
        systemLoadAvailable = balance.systemLoadWatts != nil
        systemLoadWatts = balance.systemLoadWatts ?? 0
        adapterInputWatts = balance.adapterInputWatts ?? 0
        signedBatteryWatts = batteryPresent ? balance.signedBatteryWatts : nil
        batteryFlowWatts = abs(signedBatteryWatts ?? 0)
        if !batteryPresent { batteryFlowDirection = .unavailable }
        else if let signed = signedBatteryWatts {
            if signed > 0.2 { batteryFlowDirection = .charging }
            else if signed < -0.2 { batteryFlowDirection = .supplying }
            else { batteryFlowDirection = .idle }
        } else { batteryFlowDirection = .unknown }
        isCharging = batteryFlowDirection == .charging
        isFullyCharged = batteryPresent && battery.isFullyCharged && !isCharging && batteryFlowDirection != .supplying
        switch batteryFlowDirection {
        case .charging: batteryTimeText = battery.timeToFullDescription
        case .supplying: batteryTimeText = isSupplementingAdapter ? "已接电源 · 电池补电" : (isOnAC ? "已接电源 · 电池供电" : battery.timeDescription)
        case .idle: batteryTimeText = isFullyCharged ? "已充满" : "已接电源 · 未充电"
        case .unknown: batteryTimeText = "电池流向待确认"
        case .unavailable: batteryTimeText = "无内置电池"
        }
        systemLoadIsEstimated = balance.source != .powerTelemetry && balance.source != .smcPDTRPSTR
        switch balance.source {
        case .powerTelemetry: powerSourceLabel = "电源遥测（同源三元组）"
        case .smcPDTRPSTR: powerSourceLabel = "SMC 输入 / 整机功率"
        case .adapterAndBattery: powerSourceLabel = "输入与电池推导"
        case .systemAndBattery: powerSourceLabel = "整机与电池推导"
        case .batteryOnly: powerSourceLabel = "电池电压 × 电流"
        case .unavailable: powerSourceLabel = systemLoadAvailable ? "整机功率（电源流向未知）" : "整机功率不可用"
        }

        systemHistoryQuality = !systemLoadAvailable ? .unavailable : (systemLoadIsEstimated ? .estimated : .measured)
        if balance.source == .powerTelemetry && battery.telemetryFreshness != .fresh {
            // A newly read dictionary may already be cached in the driver.
            // Display its value with an age warning, but don't invent Wh.
            systemHistoryQuality = .unavailable
        }

        // PBwo is used by newer Apple Silicon systems; PDBR is present on
        // several M1–M4 MacBook Pro models.
        if smcReadings["PBwo"]?.status == .available {
            displayPowerWatts = nonnegativePower(smc["PBwo"] ?? 0)
        } else {
            displayPowerWatts = nonnegativePower(smcPower(smc, "PDBR"))
        }

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
        let now = Date()
        let interval = activityRequested && initialActivitySamples < 3 ? 2 : processInterval
        guard processTask == nil, now.timeIntervalSince(lastProcessRefresh) >= interval else { return }
        lastProcessRefresh = now
        let sampler = insightsSampler
        processTask = Task { @MainActor [weak self] in
            let result = await sampler.sample(includeDetails: (self?.activityRequested ?? false) || self?.history.activeSession != nil)
            guard !Task.isCancelled, let self else { return }
            self.insights = result
            if self.activityRequested { self.initialActivitySamples += 1 }
            self.topProcesses = (result.topProcesses ?? []).prefix(3).compactMap {
                guard let cpu = $0.cpuPercent else { return nil }
                return ActivityProcess(id: Int($0.pid), name: $0.name, cpuPercent: cpu)
            }
            self.processTask = nil
        }
    }

    // MARK: - Helpers

    #if DEBUG
    /// Local-only integration fixture. Posts app-process notifications; it never
    /// sleeps the computer or changes power settings. Use an isolated data directory.
    func verifyLifecycleForTesting() async throws -> [String] {
        struct CheckFailure: Error { let message: String }
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw CheckFailure(message: message) }
        }
        var checks: [String] = []
        setPanelVisible(true, surface: "test-window")
        setPanelVisible(true)
        setPanelVisible(false)
        try check(panelVisible && samplingIntervalSeconds == 2, "closing popover must keep detail cadence")
        setPanelVisible(false, surface: "test-window")
        try check(!panelVisible && samplingIntervalSeconds >= 5, "last window closed must restore background")
        setPanelVisible(true, surface: "test-window")
        try await Task.sleep(for: .milliseconds(250))
        let first = lastUpdated
        try await Task.sleep(for: .milliseconds(2300))
        try check(lastUpdated > first, "foreground cadence must not inherit old background wait")
        checks.append("window visibility and immediate timer reschedule")
        setPanelVisible(false, surface: "test-window")
        history.startSession(name: "Integration fixture")
        try await Task.sleep(for: .milliseconds(100))
        try check(enhancedIntervalSeconds == 2, "task recording must select 2 seconds")
        history.endSession()
        try await Task.sleep(for: .milliseconds(100))
        try check(enhancedIntervalSeconds >= 5, "ending task must restore background cadence")
        checks.append("task recording cadence")
        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await Task.sleep(for: .milliseconds(50))
        try check(suspended && monitoringTask == nil, "sleep must cancel timer")
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await Task.sleep(for: .milliseconds(250))
        try check(suspended && monitoringTask == nil, "old wake must not undo newer sleep")
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(350))
        try check(!suspended && monitoringTask != nil, "wake must restart sampling")
        checks.append("sleep/wake generation and baseline recovery")
        stopMonitoring()
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        try check(!isSampling && monitoringTask == nil, "stopped monitor must stay stopped")
        checks.append("stop intent survives notifications")
        return checks
    }
    #endif

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
