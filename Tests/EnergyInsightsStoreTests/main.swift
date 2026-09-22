import Foundation

@main
struct EnergyInsightsStoreTests {
    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("energy-insights-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("insights.json")
        let broken = Data("deliberately damaged archive".utf8)
        try broken.write(to: file)
        let date = Date()
        let store = EnergyInsightsStore(fileURL: file, now: date)
        precondition(store.persistenceError != nil)
        let original = try Data(contentsOf: file)
        precondition(original == broken)
        let sample = BatteryInsightSample(date: date, isPresent: true, isOnAC: false,
            level: 80, currentCapacityMAh: 4000, fullCapacityMAh: 5000,
            designCapacityMAh: 6000, cycleCount: 100, temperatureC: 30, voltage: 12)
        store.record(sample)
        store.flush()
        precondition(store.persistenceError == nil)
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("recovery-") }
        precondition(backups.count == 1)
        let recovered = try Data(contentsOf: backups[0])
        precondition(recovered == broken)
        let archive = try EnergyInsightsCore.decodeArchive(Data(contentsOf: file))
        precondition(archive.healthDays.count == 1)
        let reloaded = EnergyInsightsStore(fileURL: file, now: date.addingTimeInterval(1))
        precondition(reloaded.healthDays.count == 1)
        precondition(reloaded.didWake(sample) == nil)
        // Multiple queued immutable snapshots followed immediately by exit.
        for offset in 1...20 {
            var next = sample
            next.date = date.addingTimeInterval(Double(offset))
            next.cycleCount = 100 + offset
            store.record(next)
            store.saveInBackground()
        }
        var latest = sample
        latest.date = date.addingTimeInterval(21)
        latest.cycleCount = 121
        store.record(latest)
        store.flush()
        let finalArchive = try EnergyInsightsCore.decodeArchive(Data(contentsOf: file))
        precondition(finalArchive.healthDays.last?.cycleCount == 121)
        await Task.yield() // old callbacks cannot replace the flush result
        precondition(store.persistenceError == nil)

        let periodicFile = directory.appendingPathComponent("periodic.json")
        let periodic = EnergyInsightsStore(fileURL: periodicFile, now: date, saveInterval: 1)
        periodic.record(sample)
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: periodicFile.path) { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let periodicArchive = try EnergyInsightsCore.decodeArchive(Data(contentsOf: periodicFile))
        precondition(periodicArchive.healthDays.count == 1)
        periodic.flush()

        precondition(BatteryReader.reportedNonnegativeInteger(nil, nil) == nil)
        precondition(BatteryReader.reportedNonnegativeInteger(0, 4000) == 0)
        precondition(BatteryReader.reportedNonnegativeInteger(nil, 4000) == 4000)
        precondition(BatteryReader.reportedNonnegativeInteger(-1, 120) == 120)
        precondition(BatteryReader.reportedNonnegativeInteger(true, 120) == 120)
        precondition(BatteryReader.reportedNonnegativeInteger(Double.nan, 1.5, 100_001) == nil)
        precondition(BatterySnapshot().reportedCurrentCapacityMAh == nil)
        precondition(BatterySnapshot().reportedCycleCount == nil)
        precondition(BatterySnapshot().reportedLevel == nil)
        precondition(BatteryReader.reportedBatteryLevel(nil, nil) == nil)
        precondition(BatteryReader.reportedBatteryLevel(0, 90) == 0)
        precondition(BatteryReader.reportedBatteryLevel(4000, nil) == nil)
        precondition(BatteryReader.reportedBatteryLevel(-1, 80) == 80)
        precondition(BatteryReader.reportedBatteryLevel(true, nil) == nil)
        let parsed = PowerSettingsReader.parse(capabilities: "Capabilities for AC Power:\n lowpowermode\n sleep", custom: "Battery Power:\n lowpowermode 1\n displaysleep 0\n sleep 5\nAC Power:\n displaysleep 10\n sleep 0", date: date)
        precondition(parsed.lowPowerModeSupported == true)
        precondition(parsed.profiles.count == 2)
        precondition(parsed.profiles[0].displaySleepMinutes == 0)
        precondition(parsed.profiles[0].systemSleepMinutes == 5)
        precondition(parsed.profiles[1].lowPowerMode == nil)
        let unavailable = PowerSettingsReader.parse(capabilities: "unreadable", custom: "", date: date)
        precondition(unavailable.lowPowerModeSupported == nil && unavailable.profiles.isEmpty)
        if CommandLine.arguments.contains("--live") {
            let reader = PowerSettingsReader()
            let live = try await reader.read()
            precondition(!live.profiles.isEmpty)
            let cached = try await reader.read(now: live.observedAt.addingTimeInterval(10))
            precondition(cached.observedAt == live.observedAt)
            let forcedDate = live.observedAt.addingTimeInterval(11)
            let forced = try await reader.read(now: forcedDate, force: true)
            precondition(forced.observedAt == forcedDate)
            let battery = BatteryReader.read()
            precondition(battery.isPresent)
            precondition(battery.reportedCurrentCapacityMAh != nil)
            precondition(battery.reportedCycleCount != nil)
            precondition(battery.reportedLevel != nil)
            print("PASS: raw battery gauge fields present; forced settings refresh bypasses cache")
            print("PASS: read-only pmset profiles \(live.profiles.count), lowpower support \(String(describing: live.lowPowerModeSupported)), 60s cache")
        }
        print("PASS: serial background periodic saves, latest exit snapshot, raw absent/zero/invalid parsing")
        print("PASS: power settings parsing preserves zero and unknown")
        print("PASS: damaged archive preserved, atomic replacement decodes, reload retains day, sleep baseline does not survive restart")
    }
}
