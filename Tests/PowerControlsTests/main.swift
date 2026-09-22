import Foundation

@main
struct PowerControlsTests {
    @MainActor static func main() async throws {
        enum Failure: Error { case unavailable }
        var calls: [Bool] = []
        var result: CheckedContinuation<PowerSettingsSnapshot, Error>?
        let controls = PowerControls { force in
            calls.append(force)
            return try await withCheckedThrowingContinuation { result = $0 }
        }
        let sample = PowerSettingsSnapshot(observedAt: Date(), capabilityScope: "AC Power",
            lowPowerModeSupported: true, profiles: [PowerSettingsProfile(source: "AC Power", lowPowerMode: 0)])
        func settle() async { for _ in 0..<20 { await Task.yield() } }

        controls.refreshWhenVisible(false, force: true)
        await settle()
        precondition(calls.isEmpty, "Hidden settings must not start a read")
        controls.refreshWhenVisible(true)
        await settle()
        precondition(calls == [false] && controls.isRefreshing)
        result?.resume(returning: sample)
        await settle()
        precondition(controls.snapshot != nil && !controls.isRefreshing)

        controls.refreshWhenVisible(true, force: true)
        await settle()
        result?.resume(throwing: Failure.unavailable)
        await settle()
        precondition(controls.snapshot == nil && controls.status.contains("暂不可读取"), "Failed read must remove stale values")

        controls.refreshWhenVisible(true)
        await settle()
        controls.refreshWhenVisible(true, force: true)
        controls.refreshWhenVisible(true, force: true)
        precondition(calls == [false, true, false], "Concurrent refreshes must be coalesced")
        result?.resume(returning: sample)
        await settle()
        precondition(calls == [false, true, false, true], "A power change during a read must force one follow-up")
        result?.resume(returning: sample)
        await settle()
        precondition(!controls.isRefreshing && controls.snapshot != nil)
        print("PASS: hidden refresh suppressed, failure clears stale configuration, forced refreshes coalesce and recover")
    }
}
