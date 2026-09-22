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
    private var preserveUnreadableFile = false

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
        self.preserveUnreadableFile = loadError != nil
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

    /// Explicit flush cancels the debounce; safe to call on application termination.
    func flush() {
        scheduledSave?.cancel()
        scheduledSave = nil
        guard dirty else { return }
        do {
            let data = try core.jsonData()
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if preserveUnreadableFile, FileManager.default.fileExists(atPath: fileURL.path) {
                let backup = fileURL.appendingPathExtension("recovery-\(UUID().uuidString)")
                try FileManager.default.copyItem(at: fileURL, to: backup)
                preserveUnreadableFile = false
            }
            try data.write(to: fileURL, options: .atomic)
            dirty = false
            persistenceError = nil
        } catch {
            persistenceError = "历史记录保存失败：\(error.localizedDescription)"
        }
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
            self?.flush()
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
