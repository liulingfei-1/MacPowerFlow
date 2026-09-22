import Combine
import Foundation

/// Main-actor owner of the bounded raw history. Persistence is deferred and
/// atomic; shutdown callers should flush() before the app exits.
@MainActor
final class PowerHistoryStore: ObservableObject {
    @Published private(set) var points: [PowerHistoryPoint] = []
    @Published private(set) var sessions: [PowerHistorySession] = []
    @Published private(set) var activeSession: PowerHistorySession?
    @Published private(set) var persistenceError: String?
    private var core: PowerHistoryCore
    private let fileURL: URL
    private let saveInterval: TimeInterval
    private var scheduledSave: Task<Void, Never>?
    private var dirty = false
    private var pendingBreak = false
    private let writer: PowerHistoryWriter
    private var revision: UInt64 = 0
    private var completedRevision: UInt64 = 0

    init(fileURL: URL? = nil, now: Date = Date(), saveInterval: TimeInterval = 30,
         maximumGapSeconds: TimeInterval = 12) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        self.saveInterval = max(1, saveInterval)
        var archive = PowerHistoryArchive()
        var loadError: String?
        if FileManager.default.fileExists(atPath: self.fileURL.path) {
            do {
                let size = try self.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size < 32 * 1024 * 1024 else { throw HistoryStoreError.oversizedFile }
                archive = try PowerHistoryCore.decodeArchive(Data(contentsOf: self.fileURL))
                guard archive.schemaVersion == 1 else { throw HistoryStoreError.unsupportedSchema }
            } catch {
                loadError = "历史记录读取失败：\(error.localizedDescription)"
            }
        }
        self.core = PowerHistoryCore(archive: archive, now: now, maximumGapSeconds: maximumGapSeconds)
        self.pendingBreak = !self.core.archive.points.isEmpty
        self.persistenceError = loadError
        self.writer = PowerHistoryWriter(fileURL: self.fileURL, preserveUnreadableFile: loadError != nil)
        publish()
    }

    private static var defaultFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("MacPowerFlow", isDirectory: true)
            .appendingPathComponent("power-history-v1.json")
    }

    func record(_ point: PowerHistoryPoint) {
        var next = point
        next.startsNewSegment = next.startsNewSegment || pendingBreak
        guard core.append(next) else { return }
        pendingBreak = false
        publish(); markDirty()
    }

    /// Call on sleep/wake or sampler restart, including gaps shorter than the timeout.
    func breakContinuity() { pendingBreak = true }

    func startSession(name: String, at date: Date = Date()) {
        core.startSession(name: name, at: date)
        publish(); markDirty()
    }

    @discardableResult
    func endSession(at date: Date = Date()) -> PowerHistorySession? {
        let result = core.endSession(at: date)
        publish(); markDirty()
        return result
    }

    func summary(since: Date, until: Date = Date()) -> PowerHistorySummary {
        core.summary(since: since, until: until)
    }

    func jsonData() throws -> Data { try core.jsonData() }
    func csvData() -> Data { core.csvData() }

    /// Use these for interactive export; legacy synchronous helpers remain for tests/tools.
    func jsonDataAsync() async throws -> Data {
        let snapshot = core.archive
        return try await withCheckedThrowingContinuation { continuation in
            writer.encode(snapshot) { continuation.resume(with: $0) }
        }
    }

    func csvDataAsync() async -> Data {
        let snapshot = core
        return await withCheckedContinuation { continuation in
            writer.csv(snapshot) { continuation.resume(returning: $0) }
        }
    }

    /// Normal persistence: capture an immutable value snapshot and enqueue it.
    /// JSON encoding and filesystem work never run on the main actor.
    func saveInBackground() {
        scheduledSave?.cancel()
        scheduledSave = nil
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

    /// Shutdown barrier: enqueue after every earlier save and wait for completion.
    /// The serial queue performs encoding/write; only this explicit exit path waits.
    func flush() {
        scheduledSave?.cancel()
        scheduledSave = nil
        revision &+= 1
        let error = writer.flush(core.archive)
        completedRevision = revision
        dirty = error != nil
        persistenceError = error
    }

    func chartPoints(since: Date, until: Date = Date(), targetCount: Int = 400) -> [PowerHistoryPoint] {
        PowerHistoryCore.chartPoints(points: points.filter { $0.timestamp >= since && $0.timestamp <= until },
                                     targetCount: targetCount, maximumGapSeconds: core.maximumGapSeconds)
    }

    private func publish() {
        points = core.archive.points
        sessions = core.archive.sessions
        activeSession = core.archive.activeSession
    }

    private func markDirty() {
        dirty = true
        guard scheduledSave == nil else { return }
        let interval = saveInterval
        scheduledSave = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(interval)) }
            catch { return }
            self?.saveInBackground()
        }
    }

    private enum HistoryStoreError: LocalizedError {
        case oversizedFile, unsupportedSchema
        var errorDescription: String? {
            switch self {
            case .oversizedFile: "文件超过历史记录大小上限"
            case .unsupportedSchema: "历史记录格式版本不受支持"
            }
        }
    }
}

/// Queue ownership invariant: preserveUnreadableFile is accessed only on queue.
/// Immutable archive snapshots cross the boundary; callbacks never touch this
/// state. This small GCD bridge supports the synchronous app-termination barrier
/// on macOS 13. Replace with an actor once termination becomes fully async.
private nonisolated final class PowerHistoryWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.llf.MacPowerFlow.history", qos: .utility)
    private let fileURL: URL
    private var preserveUnreadableFile: Bool

    init(fileURL: URL, preserveUnreadableFile: Bool) {
        self.fileURL = fileURL
        self.preserveUnreadableFile = preserveUnreadableFile
    }

    func save(_ archive: PowerHistoryArchive, completion: @escaping @Sendable (String?) -> Void) {
        queue.async { completion(self.write(archive)) }
    }

    func encode(_ archive: PowerHistoryArchive, completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        queue.async { completion(Result { try PowerHistoryCore.encodeArchive(archive) }) }
    }

    func csv(_ core: PowerHistoryCore, completion: @escaping @Sendable (Data) -> Void) {
        queue.async { completion(core.csvData()) }
    }

    func flush(_ archive: PowerHistoryArchive) -> String? {
        // sync may execute work on the caller. A work item scheduled async first
        // guarantees that even shutdown encoding happens on the writer queue.
        let item = DispatchWorkItem { _ = self.write(archive) }
        // Use a second queue barrier to retrieve the last result without sharing
        // mutable storage outside queue ownership.
        queue.async(execute: item)
        item.wait()
        return queue.sync { self.lastError }
    }

    private var lastError: String?
    private func write(_ archive: PowerHistoryArchive) -> String? {
        dispatchPrecondition(condition: .onQueue(queue))
        precondition(!Thread.isMainThread, "History encoding and writes must remain off the main thread")
        do {
            let data = try PowerHistoryCore.encodeArchive(archive)
            guard data.count < 32 * 1024 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
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
            lastError = "历史记录保存失败：\(error.localizedDescription)"
        }
        return lastError
    }
}
