import Foundation
import Combine
import UserNotifications

@MainActor
protocol PowerNotificationClient {
    func setDelegate(_ delegate: UNUserNotificationCenterDelegate)
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func deliver(_ request: UNNotificationRequest) async throws
}

@MainActor
private final class SystemPowerNotificationClient: PowerNotificationClient {
    private let center = UNUserNotificationCenter.current()
    func setDelegate(_ delegate: UNUserNotificationCenterDelegate) { center.delegate = delegate }
    func authorizationStatus() async -> UNAuthorizationStatus { await center.notificationSettings().authorizationStatus }
    func requestAuthorization() async throws -> Bool { try await center.requestAuthorization(options: [.alert, .sound]) }
    func deliver(_ request: UNNotificationRequest) async throws { try await center.add(request) }
}

/// Optional, local-only notifications. Constructing or observing this object
/// never asks for permission. The user must explicitly call setEnabled(true).
@MainActor
final class PowerAlerts: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var enabled = false
    @Published private(set) var requestedEnabled = false
    @Published private(set) var status = "通知已关闭"
    @Published var highPowerThreshold: Double = 50 {
        didSet {
            let normalized = PowerAlertRules.normalizedThreshold(highPowerThreshold)
            if highPowerThreshold != normalized { highPowerThreshold = normalized }
            rules.setHighPowerThreshold(normalized)
            preferences.set(normalized, forKey: "alerts.highPowerThreshold")
        }
    }

    private let notificationClient: any PowerNotificationClient
    private let preferences: UserDefaults
    private var rules = PowerAlertRules()
    private var authorizationTask: Task<Void, Never>?
    private var authorizationGeneration = 0

    init(preferences: UserDefaults = .standard, notificationClient: (any PowerNotificationClient)? = nil) {
        self.preferences = preferences
        self.notificationClient = notificationClient ?? SystemPowerNotificationClient()
        super.init()
        self.notificationClient.setDelegate(self)
        let stored = preferences.object(forKey: "alerts.highPowerThreshold") as? Double
        highPowerThreshold = PowerAlertRules.normalizedThreshold(stored ?? 50)
        rules.setHighPowerThreshold(highPowerThreshold)
        requestedEnabled = preferences.bool(forKey: "alerts.enabled")
    }

    /// Restore only an explicit saved choice. Reading permission never opens a prompt.
    func restorePreferences() {
        guard authorizationTask == nil else { return }
        authorizationGeneration &+= 1
        let generation = authorizationGeneration
        guard requestedEnabled else { return }
        authorizationTask = Task { [weak self] in
            guard let self else { return }
            let authorization = await notificationClient.authorizationStatus()
            guard !Task.isCancelled, generation == authorizationGeneration else { return }
            authorizationTask = nil
            enabled = authorization == .authorized || authorization == .provisional
            rules.resetPending()
            status = enabled ? "已恢复提醒设置" : "提醒偏好已保存，请在系统设置中允许通知"
        }
    }

    func setEnabled(_ value: Bool) {
        requestedEnabled = value
        preferences.set(value, forKey: "alerts.enabled")
        if !value {
            authorizationGeneration &+= 1
            authorizationTask?.cancel()
            authorizationTask = nil
            enabled = false
            status = "通知已关闭"
            rules.resetPending()
            return
        }
        guard !enabled, authorizationTask == nil else { return }
        authorizationGeneration &+= 1
        let generation = authorizationGeneration
        status = "正在检查通知权限…"
        authorizationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let granted = try await notificationClient.requestAuthorization()
                guard !Task.isCancelled, generation == authorizationGeneration else { return }
                authorizationTask = nil
                rules.resetPending()
                enabled = granted
                status = granted
                    ? "通知已开启 · 持续30秒触发，同类提醒间隔至少10分钟"
                    : "未获通知权限，请在系统设置 → 通知中允许 MacPowerFlow"
            } catch {
                guard !Task.isCancelled, generation == authorizationGeneration else { return }
                authorizationTask = nil
                enabled = false
                status = "无法开启通知，请检查系统通知设置"
            }
        }
    }

    func observe(
        date: Date,
        isOnAC: Bool,
        batteryLevel: Int?,
        signedBatteryWatts: Double?,
        systemWatts: Double?,
        thermalState: ProcessInfo.ThermalState
    ) {
        guard enabled else { return }
        let level: PowerAlertThermalLevel
        switch thermalState {
        case .nominal: level = .nominal
        case .fair: level = .fair
        case .serious: level = .serious
        case .critical: level = .critical
        @unknown default:
            // Unknown future pressure levels must not become a high-temperature alert.
            rules.resetPending()
            return
        }
        let events = rules.observe(PowerAlertObservation(
            date: date, isOnAC: isOnAC, batteryLevel: batteryLevel,
            signedBatteryWatts: signedBatteryWatts, systemWatts: systemWatts,
            thermalLevel: level
        ))
        for event in events { deliver(event) }
    }

    private func deliver(_ event: PowerAlertEvent) {
        let content = UNMutableNotificationContent()
        switch event.kind {
        case .highPower:
            content.title = "整机功耗持续偏高"
            content.body = "功耗已连续30秒达到 \(watts(event.threshold)) W 或以上，当前约 \(watts(event.observedValue)) W。"
        case .lowBattery:
            content.title = "电池电量较低"
            content.body = "当前使用电池供电，电量约 \(Int(event.observedValue ?? 0))%。"
        case .thermal:
            content.title = "系统热压力持续偏高"
            content.body = "macOS 已连续30秒报告较高热压力，可查看高负载进程和散热情况。"
        case .batteryAssist:
            content.title = "接通电源时仍在消耗电池"
            content.body = "电池已连续30秒辅助供电，当前约 \(watts(event.observedValue)) W。可检查充电器、线缆或整机负载。"
        }
        content.sound = .default
        content.threadIdentifier = "MacPowerFlow.PowerAlerts"
        let request = UNNotificationRequest(
            identifier: "MacPowerFlow.\(event.kind.rawValue).\(UUID().uuidString)",
            content: content, trigger: nil
        )
        let generation = authorizationGeneration
        Task { [weak self] in
            guard let self, enabled, generation == authorizationGeneration else { return }
            do {
                try await notificationClient.deliver(request)
            } catch {
                guard enabled, generation == authorizationGeneration else { return }
                status = "提醒未能发送，请检查系统通知设置"
            }
        }
    }

    private func watts(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.1f", value)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
