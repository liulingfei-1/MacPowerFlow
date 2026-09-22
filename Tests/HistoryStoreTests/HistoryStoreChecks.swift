import Foundation

@main struct HistoryStoreChecks {
    static func tryPowerCount(_ data: Data) -> Int { (try? PowerHistoryCore.decodeArchive(data).points.count) ?? -1 }
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mpf-history-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.json")
        let store = PowerHistoryStore(fileURL: file, now: Date(timeIntervalSince1970: 0), saveInterval: 100)
        for index in 0..<100 {
            let date = Date(timeIntervalSince1970: Double(index))
            store.record(PowerHistoryPoint(timestamp: date, windowStart: date, windowEnd: date,
                systemWatts: Double(index), cpuWatts: nil, gpuWatts: nil, signedBatteryWatts: nil,
                source: "fixture", quality: .measured))
            store.saveInBackground()
        }
        store.flush()
        let archive = try PowerHistoryCore.decodeArchive(Data(contentsOf: file))
        precondition(archive.points.count == 100 && archive.points.last?.systemWatts == 99,
                     "An older queued snapshot replaced the final flush")
        try await Task.sleep(for: .milliseconds(20))
        precondition(store.persistenceError == nil)
        let jsonExport = try await store.jsonDataAsync()
        let csvExport = await store.csvDataAsync()
        precondition(tryPowerCount(jsonExport) == 100)
        precondition(String(data: csvExport, encoding: .utf8)?.contains("timestamp,window_start") == true)
        let compact = try Data(contentsOf: file)
        precondition(!compact.contains(10), "Persistence unexpectedly uses pretty JSON")

        // A path whose parent is a file fails, then succeeds after the obstacle is removed.
        let obstruction = directory.appendingPathComponent("obstruction")
        try Data("block".utf8).write(to: obstruction)
        let recovering = PowerHistoryStore(fileURL: obstruction.appendingPathComponent("history.json"))
        recovering.startSession(name: "failure recovery")
        recovering.flush()
        precondition(recovering.persistenceError != nil)
        try FileManager.default.removeItem(at: obstruction)
        recovering.flush()
        precondition(recovering.persistenceError == nil)

        try Data("broken JSON".utf8).write(to: file)
        let corrupt = PowerHistoryStore(fileURL: file)
        precondition(corrupt.persistenceError != nil)
        corrupt.startSession(name: "recovery")
        corrupt.saveInBackground()
        corrupt.flush()
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".recovery-") }
        precondition(backups.count == 1)
        let recoveredText = try String(contentsOf: backups[0], encoding: .utf8)
        precondition(recoveredText == "broken JSON")
        print("PASS: 100 asynchronous snapshots + exit barrier ordering, compact JSON, write recovery, one preserved corrupt backup")
    }
}
