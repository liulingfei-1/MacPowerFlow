import Foundation
import UserNotifications

@MainActor final class FakeNotificationClient: PowerNotificationClient {
    var status = UNAuthorizationStatus.denied
    var requests = 0
    var continuation: CheckedContinuation<Bool, Never>?
    func setDelegate(_ delegate: UNUserNotificationCenterDelegate) {}
    func authorizationStatus() async -> UNAuthorizationStatus { status }
    func requestAuthorization() async throws -> Bool {
        requests += 1
        return await withCheckedContinuation { continuation = $0 }
    }
    func deliver(_ request: UNNotificationRequest) async throws {}
}
@main struct Checks {
    @MainActor static func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }
    @MainActor static func main() async {
        let suite = "mpf-alerts-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = FakeNotificationClient()
        let alerts = PowerAlerts(preferences: defaults, notificationClient: client)
        precondition(!alerts.enabled && !alerts.requestedEnabled)
        alerts.restorePreferences()
        await settle()
        precondition(client.requests == 0)
        alerts.highPowerThreshold = 73
        alerts.setEnabled(true)
        await settle()
        precondition(alerts.requestedEnabled && !alerts.enabled && client.requests == 1)
        client.continuation?.resume(returning: false); client.continuation = nil
        await settle()
        precondition(alerts.requestedEnabled && !alerts.enabled)
        alerts.setEnabled(false)
        precondition(!defaults.bool(forKey: "alerts.enabled"))
        alerts.setEnabled(true)
        await settle()
        alerts.setEnabled(false)
        client.continuation?.resume(returning: true); client.continuation = nil
        await settle()
        precondition(!alerts.requestedEnabled && !alerts.enabled, "cancelled permission must not reactivate")
        defaults.set(true, forKey: "alerts.enabled")
        let restored = PowerAlerts(preferences: defaults, notificationClient: client)
        precondition(restored.highPowerThreshold == 73 && restored.requestedEnabled)
        let requestCount = client.requests
        client.status = .authorized
        restored.restorePreferences(); await settle()
        precondition(restored.enabled && client.requests == requestCount)
        client.status = .denied
        restored.restorePreferences(); await settle()
        precondition(!restored.enabled && restored.requestedEnabled)
        restored.setEnabled(false)
        precondition(!restored.requestedEnabled && !defaults.bool(forKey: "alerts.enabled"))
        print("PASS: default off, threshold restore, denied intent can be disabled, cancelled permission ignored, restore never prompts, revocation checked")
    }
}
