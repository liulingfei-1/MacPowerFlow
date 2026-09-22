import Foundation
import Darwin

/// Standalone regression executable: no application launch, root helper,
/// notifications, or persistent system changes are involved.
@main
struct SystemInsightsTests {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    static func counter(
        pid: Int32 = 42, start: UInt64 = 10, micros: UInt64 = 20,
        cpu: UInt64 = 0
    ) -> InsightsProcessCounter {
        InsightsProcessCounter(
            pid: pid, startSeconds: start, startMicroseconds: micros,
            name: "fixture", cpuNanoseconds: cpu, residentBytes: 4096
        )
    }

    static func runBoundaries() throws {
        try require(InsightsDelta.nanoseconds(ticks: 24_000_000, numerator: 125, denominator: 3) == 1_000_000_000, "Apple Silicon Mach timebase")
        try require(InsightsDelta.nanoseconds(ticks: 123, numerator: 1, denominator: 1) == 123, "1:1 timebase")
        try require(InsightsDelta.nanoseconds(ticks: UInt64.max, numerator: 1, denominator: 1) == UInt64.max, "Large time without intermediate overflow")
        try require(InsightsDelta.nanoseconds(ticks: UInt64.max, numerator: 125, denominator: 3) == nil, "Unrepresentable time")
        try require(InsightsDelta.nanoseconds(ticks: 10, numerator: 1, denominator: 0) == nil, "Failed timebase")
        try require(InsightsDelta.rate(current: 5, previous: 5, seconds: 1) == 0, "Valid zero activity")
        try require(InsightsDelta.rate(current: 40, previous: 10, seconds: 2) == 15, "Actual elapsed interval")
        try require(InsightsDelta.rate(current: 1, previous: 5, seconds: 1) == nil, "Counter reset")
        for seconds in [0.0, -1.0, .infinity, .nan, 31.0] {
            try require(InsightsDelta.rate(current: 5, previous: 0, seconds: seconds) == nil, "Invalid/stale interval")
        }
        try require(InsightsDelta.rate(current: UInt64.max, previous: UInt64.max - 2, seconds: 2) == 1, "Subtract before Double conversion")
        try require(InsightsDelta.cpuPercent(current: counter(cpu: 1_000_000_000), previous: nil, seconds: 1) == nil, "First CPU frame unknown")
        try require(InsightsDelta.cpuPercent(current: counter(cpu: 1_000_000_000), previous: counter(), seconds: 1) == 100, "CPU nanoseconds are not Mach ticks")
        try require(InsightsDelta.cpuPercent(current: counter(cpu: 3_000_000_000), previous: counter(), seconds: 1) == 300, "Multi-core process must exceed 100%")
        try require(InsightsDelta.cpuPercent(current: counter(start: 11, cpu: 1_000_000_000), previous: counter(), seconds: 1) == nil, "PID reuse seconds")
        try require(InsightsDelta.cpuPercent(current: counter(micros: 21, cpu: 1_000_000_000), previous: counter(), seconds: 1) == nil, "PID reuse microseconds")
        try require(InsightsDelta.cpuPercent(current: counter(pid: 43, cpu: 1_000_000_000), previous: counter(), seconds: 1) == nil, "Different PID")
        try require(InsightsDelta.cpuPercent(current: counter(cpu: 1), previous: counter(cpu: 10), seconds: 1) == nil, "CPU counter decrease")

        let old = ["a": InsightsIOCounter(read: 100, write: 500)]
        let current = ["a": InsightsIOCounter(read: 120, write: 540)]
        let throughput = InsightsDelta.throughput(current: current, previous: old, seconds: 2)
        try require(throughput.readBytesPerSecond == 10 && throughput.writeBytesPerSecond == 20, "Separate receive/read and send/write rates")
        try require(InsightsDelta.throughput(current: current, previous: nil, seconds: 1).readBytesPerSecond == nil, "First IO frame unknown")
        let changed = ["b": InsightsIOCounter(read: 120, write: 540)]
        try require(InsightsDelta.throughput(current: changed, previous: old, seconds: 1).readBytesPerSecond == nil, "Device/interface replacement")
        try require(InsightsDelta.throughput(current: [:], previous: old, seconds: 1).readBytesPerSecond == nil, "Disappeared IO source")
        let reset = ["a": InsightsIOCounter(read: 99, write: 540)]
        try require(InsightsDelta.throughput(current: reset, previous: old, seconds: 1).writeBytesPerSecond == nil, "Reset invalidates coherent IO window")

        try require(InsightsDelta.assertionKind("UserIsActive") == .userActivity, "User activity is not a generic sleep blocker")
        try require(InsightsDelta.assertionKind("PreventUserIdleSystemSleep") == .systemSleep, "System sleep assertion")
        try require(InsightsDelta.assertionKind("PreventUserIdleDisplaySleep") == .displaySleep, "Display assertion")
        try require(InsightsDelta.assertionKind("BackgroundTask") == .background, "Background assertion")
        try require(InsightsDelta.assertionKind("FutureUnknownType") == .other, "Unknown assertion type remains distinct")
        let active: [String: Any] = ["AssertLevel": NSNumber(value: 255), "AssertType": "UserIsActive", "AssertName": "input event"]
        try require(InsightsDelta.activeAssertion(pid: 42, processName: "fixture", properties: active, index: 0)?.kind == .userActivity, "Active assertion decoding")
        var inactive = active
        inactive["AssertLevel"] = NSNumber(value: 0)
        try require(InsightsDelta.activeAssertion(pid: 42, processName: "fixture", properties: inactive, index: 0) == nil, "Inactive assertions excluded")
        inactive.removeValue(forKey: "AssertLevel")
        try require(InsightsDelta.activeAssertion(pid: 42, processName: "fixture", properties: inactive, index: 0) == nil, "Missing level is not active")
        print("PASS: 34 SystemInsights boundary checks")
    }

    static func selfCPUTime() -> UInt64? {
        var info = proc_taskallinfo()
        let size = MemoryLayout<proc_taskallinfo>.size
        guard proc_pidinfo(getpid(), PROC_PIDTASKALLINFO, 0, &info, Int32(size)) == size else { return nil }
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS else { return nil }
        return InsightsDelta.nanoseconds(
            ticks: info.ptinfo.pti_total_user + info.ptinfo.pti_total_system,
            numerator: timebase.numer, denominator: timebase.denom
        )
    }

    static func runSmoke() async throws {
        let sampler = SystemInsightsSampler()
        let first = await sampler.sample()
        try require(first.memory != nil, "Native memory snapshot unavailable")
        try require(first.memory?.swapInBytesPerSecond == nil, "First memory rate must be unknown")
        try require(first.network?.readBytesPerSecond == nil, "First network rate must be unknown")
        try require(first.disk?.readBytesPerSecond == nil, "First disk rate must be unknown")
        try require(first.topProcesses?.allSatisfy { $0.cpuPercent == nil } == true, "First process CPU rates must be unknown")

        let before = selfCPUTime()
        let start = ProcessInfo.processInfo.systemUptime
        // A short, single-core CPU window checks actual kernel time units.
        // No external processes, files, screen capture, or GPU work is started.
        var accumulator: UInt64 = 1
        while ProcessInfo.processInfo.systemUptime - start < 0.25 {
            for _ in 0..<2048 { accumulator = accumulator &* 6364136223846793005 &+ 1 }
        }
        let duration = ProcessInfo.processInfo.systemUptime - start
        let after = selfCPUTime()
        guard let before, let after, let cpuRate = InsightsDelta.rate(
            current: after, previous: before, seconds: duration
        ) else { throw Failure(message: "Self CPU unit check unavailable") }
        let selfCPUPercent = cpuRate / 1_000_000_000 * 100
        try require(selfCPUPercent > 20 && selfCPUPercent < 250, "Kernel CPU units calibration: \(selfCPUPercent)%")
        let second = await sampler.sample()
        try require(second.memory?.swapInBytesPerSecond != nil, "Second memory rate should be available")
        try require(second.topProcesses?.contains { $0.cpuPercent != nil } == true, "Second process window should contain comparable counters")
        if let memory = second.memory {
            try require(memory.totalBytes > 0 && memory.usedBytes <= memory.totalBytes, "Memory bounds")
        }
        if let network = second.network {
            try require(network.sourceCount > 0, "Physical network interface inventory")
        }
        if let disk = second.disk {
            try require(disk.sourceCount > 0, "Disk driver inventory")
        }
        let lightStart = ProcessInfo.processInfo.systemUptime
        let light = await sampler.sample(includeDetails: false)
        let lightMilliseconds = (ProcessInfo.processInfo.systemUptime - lightStart) * 1000
        try require(light.memory != nil, "Light sampling retains memory")
        try require(light.memory?.swapInBytesPerSecond != nil, "Light sampling preserves memory baseline")
        try require(light.topProcesses == nil && light.topGPUProcesses == nil, "Light sampling skips process and GPU detail")
        try require(light.powerAssertions == nil && light.network == nil && light.disk == nil, "Light sampling skips assertions and IO details")
        try require(!light.gpuActivityAvailable, "Light sampling does not claim fresh GPU availability")
        let resumed = await sampler.sample(includeDetails: true)
        try require(resumed.memory?.swapInBytesPerSecond != nil, "Detail resume preserves memory continuity")
        try require(resumed.topProcesses?.allSatisfy { $0.cpuPercent == nil } == true, "Detail resume reestablishes CPU baseline")
        try require(resumed.topGPUProcesses?.isEmpty != false, "Detail resume reestablishes GPU baseline")
        try require(resumed.network?.readBytesPerSecond == nil, "Detail resume reestablishes network baseline")
        try require(resumed.disk?.readBytesPerSecond == nil, "Detail resume reestablishes disk baseline")
        await sampler.reset()
        let reset = await sampler.sample()
        try require(reset.memory?.swapInBytesPerSecond == nil, "Explicit reset removes memory baseline")
        try require(reset.topProcesses?.allSatisfy { $0.cpuPercent == nil } == true, "Explicit reset removes PID baselines")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        // Assertions are summarized by type to keep arbitrary app-supplied
        // reason strings out of test logs (they may contain document names).
        let sanitized = SystemInsightsSnapshot(
            timestamp: second.timestamp, memory: second.memory,
            powerAssertions: second.powerAssertions?.map {
                PowerAssertionInsight(id: $0.id, pid: $0.pid, name: $0.name,
                    reason: "[redacted in smoke log]", type: $0.type, kind: $0.kind)
            },
            topProcesses: second.topProcesses, topGPUProcesses: second.topGPUProcesses,
            network: second.network, disk: second.disk,
            gpuActivityAvailable: second.gpuActivityAvailable
        )
        let data = try encoder.encode(sanitized)
        print("PASS: native read-only smoke; self CPU \(String(format: "%.1f", selfCPUPercent))%, page size \(sysconf(_SC_PAGESIZE)), checksum \(accumulator)")
        print("PASS: light sampling and detail baseline restart; memory-only call \(String(format: "%.3f", lightMilliseconds)) ms")
        print(String(decoding: data, as: UTF8.self))
    }

    static func main() async throws {
        try runBoundaries()
        if CommandLine.arguments.contains("--smoke") { try await runSmoke() }
    }
}
