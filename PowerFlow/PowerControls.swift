import Foundation
import Combine
import Darwin

nonisolated struct PowerSettingsProfile: Sendable, Codable {
    let source: String
    var lowPowerMode: Int?
    var displaySleepMinutes: Int?
    var systemSleepMinutes: Int?
}

nonisolated struct PowerSettingsSnapshot: Sendable, Codable {
    let observedAt: Date
    /// Capabilities apply to the currently selected supply, as reported by pmset.
    let capabilityScope: String?
    let lowPowerModeSupported: Bool?
    let profiles: [PowerSettingsProfile]
}

/// The name denotes the settings area; this component is strictly read-only.
/// Only the two fixed pmset -g invocations below are permitted.
actor PowerSettingsReader {
    private var cache: PowerSettingsSnapshot?
    func read(now: Date = Date(), force: Bool = false) throws -> PowerSettingsSnapshot {
        if !force, let cache, (0..<60).contains(now.timeIntervalSince(cache.observedAt)) { return cache }
        // A failed refresh must not leave an older cached value available to
        // the next non-forced read.
        cache = nil
        let capabilities = try command("cap")
        let custom = try command("custom")
        let snapshot = Self.parse(capabilities: capabilities, custom: custom, date: now)
        cache = snapshot
        return snapshot
    }

    nonisolated static func parse(capabilities: String, custom: String, date: Date) -> PowerSettingsSnapshot {
        let capabilityLines = capabilities.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let validCapabilities = capabilityLines.first?.hasPrefix("Capabilities for ") == true
        var profiles: [PowerSettingsProfile] = []
        for line in custom.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if ["Battery Power:", "AC Power:", "UPS Power:"].contains(trimmed) {
                profiles.append(PowerSettingsProfile(source: String(trimmed.dropLast())))
                continue
            }
            guard !profiles.isEmpty else { continue }
            let fields = trimmed.split(whereSeparator: { $0.isWhitespace })
            guard fields.count == 2, let value = Int(fields[1]), value >= 0 else { continue }
            let index = profiles.count - 1
            switch fields[0] {
            case "lowpowermode": profiles[index].lowPowerMode = value
            case "displaysleep": profiles[index].displaySleepMinutes = value
            case "sleep": profiles[index].systemSleepMinutes = value
            default: break
            }
        }
        return PowerSettingsSnapshot(
            observedAt: date, capabilityScope: validCapabilities ? capabilityLines.first : nil,
            lowPowerModeSupported: validCapabilities ? capabilityLines.contains("lowpowermode") : nil,
            profiles: profiles
        )
    }

    private func command(_ query: String) throws -> String {
        guard query == "cap" || query == "custom" else { throw CocoaError(.executableNotLoadable) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", query]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        process.qualityOfService = .utility
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        // Runs on this actor's executor, never the UI/main actor. The bounded
        // fixed queries emit small output; timeout also handles a stuck tool.
        if finished.wait(timeout: .now() + 3) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 0.2) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            throw CocoaError(.executableRuntimeMismatch)
        }
        guard process.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard data.count < 65_536, let result = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return result
    }
}

@MainActor
final class PowerControls: ObservableObject {
    @Published private(set) var snapshot: PowerSettingsSnapshot?
    @Published private(set) var status = "打开详情后读取系统电源设置"
    @Published private(set) var isRefreshing = false
    private let readSettings: (Bool) async throws -> PowerSettingsSnapshot
    private var pendingForcedRefresh = false

    init(readSettings: ((Bool) async throws -> PowerSettingsSnapshot)? = nil) {
        let reader = PowerSettingsReader()
        self.readSettings = readSettings ?? { force in try await reader.read(force: force) }
    }

    func refreshWhenVisible(_ visible: Bool, force: Bool = false) {
        guard visible else { return }
        guard !isRefreshing else {
            pendingForcedRefresh = pendingForcedRefresh || force
            return
        }
        isRefreshing = true
        status = "正在读取系统电源设置…"
        Task { [weak self] in
            guard let self else { return }
            defer {
                isRefreshing = false
                if pendingForcedRefresh {
                    pendingForcedRefresh = false
                    refreshWhenVisible(true, force: true)
                }
            }
            do {
                snapshot = try await readSettings(force)
                status = "只读系统设置 · 0分钟表示不自动休眠"
            } catch {
                snapshot = nil
                status = "系统电源设置暂不可读取"
            }
        }
    }
}
