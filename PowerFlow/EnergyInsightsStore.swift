import Combine
import Foundation

/// UI-owned, bounded local archive. Only one small save is scheduled at a time;
/// no network, daemon, or power-setting changes. Call flush() before termination.
@MainActor
final class EnergyInsightsStore: ObservableObject {
    @Published private(set) var healthDays: [BatteryHealthDay] = []
    @Published private(set) var sleepRecords: [SleepEnergyRecord] = []
    @Published private(set) var persistenceError: String?
    private var core: EnergyInsightsCore
    private let fileURL: URL
    private let saveInterval: TimeInterval
    private var saveTask: Task<Void, Never>?
    private var dirty = false
    private let writer: EnergyInsightsWriter
    private var revision: UInt64 = 0
    private var completedRevision: UInt64 = 0

    init(fileURL: URL? = nil, now: Date = Date(), saveInterval: TimeInterval = 300) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        self.saveInterval = max(1, saveInterval)
        var archive = EnergyInsightsArchive()
        var errorMessage: String?
        if FileManager.default.fileExists(atPath: self.fileURL.path) {
            do {
                let size = try self.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size < 2 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                archive = try EnergyInsightsCore.decodeArchive(Data(contentsOf: self.fileURL))
            } catch {
                errorMessage = "电池洞察记录读取失败；原文件将保留"
            }
        }
        core = EnergyInsightsCore(archive: archive, now: now)
        persistenceError = errorMessage
        writer = EnergyInsightsWriter(fileURL: self.fileURL, preserveUnreadableFile: errorMessage != nil)
        publish()
    }

    private static var defaultFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("MacPowerFlow", isDirectory: true)
            .appendingPathComponent("energy-insights-v1.json")
    }

    func record(_ sample: BatteryInsightSample) {
        guard core.record(sample) else { return }
        publish(); markDirty()
    }

    func willSleep(_ sample: BatteryInsightSample) {
        core.willSleep(sample)
        // Do not persist a sleep baseline across an app restart: it could
        // represent a shutdown or missed wake instead of a real sleep window.
        saveInBackground()
    }

    func notePowerSourceChange() { core.notePowerSourceChange() }

    @discardableResult
    func didWake(_ sample: BatteryInsightSample) -> SleepEnergyRecord? {
        guard let record = core.didWake(sample) else { return nil }
        publish(); markDirty(); saveInBackground()
        return record
    }

    /// Capture a value snapshot; encoding and atomic writes run on the utility queue.
    func saveInBackground() {
        saveTask?.cancel()
        saveTask = nil
        guard dirty else { return }
        dirty = false
        revision &+= 1
        let submitted = revision
        writer.save(core.archive) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, submitted >= self.completedRevision else { return }
                self.completedRevision = submitted
                self.persistenceError = error
                if error != nil { self.dirty = true }
            }
        }
    }

    /// Termination barrier. Earlier saves finish first, then the latest snapshot.
    /// Only this explicit exit path waits; encoding and disk I/O remain off-main.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        revision &+= 1
        let error = writer.flush(core.archive)
        completedRevision = revision
        dirty = error != nil
        persistenceError = error
    }

    private func publish() {
        healthDays = core.archive.healthDays
        sleepRecords = core.archive.sleepRecords
    }

    private func markDirty() {
        dirty = true
        guard saveTask == nil else { return }
        let interval = saveInterval
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(interval)) }
            catch { return }
            self?.saveInBackground()
        }
    }
}

/// All mutable writer state belongs to queue. Sendable value snapshots enter
/// FIFO, and completion callbacks never access writer state. This GCD bridge
/// allows synchronous app termination without main-thread encoding or writes.
private nonisolated final class EnergyInsightsWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.llf.MacPowerFlow.energy-insights", qos: .utility)
    private let fileURL: URL
    private var preserveUnreadableFile: Bool
    private var lastError: String?

    init(fileURL: URL, preserveUnreadableFile: Bool) {
        self.fileURL = fileURL
        self.preserveUnreadableFile = preserveUnreadableFile
    }

    func save(_ archive: EnergyInsightsArchive, completion: @escaping @Sendable (String?) -> Void) {
        queue.async { completion(self.write(archive)) }
    }

    func flush(_ archive: EnergyInsightsArchive) -> String? {
        // queue.sync could execute on its caller; enqueue first to ensure the
        // termination path also performs disk work on a background thread.
        let item = DispatchWorkItem { _ = self.write(archive) }
        queue.async(execute: item)
        item.wait()
        return queue.sync { self.lastError }
    }

    private func write(_ archive: EnergyInsightsArchive) -> String? {
        dispatchPrecondition(condition: .onQueue(queue))
        precondition(!Thread.isMainThread, "Energy insights writes must remain off the main thread")
        do {
            let data = try EnergyInsightsCore.encodeArchive(archive)
            guard data.count < 2 * 1024 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if preserveUnreadableFile, FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.copyItem(at: fileURL,
                    to: fileURL.appendingPathExtension("recovery-\(UUID().uuidString)"))
                preserveUnreadableFile = false
            }
            try data.write(to: fileURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = "电池洞察记录保存失败：\(error.localizedDescription)"
        }
        return lastError
    }
}
