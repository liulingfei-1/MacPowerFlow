import Foundation
import Combine
import CryptoKit
import MetricKit
import StateReporting

/// System-delivered reports about MacPowerFlow itself. No polling or uploads.
/// An empty report stream is normal: MetricKit chooses when reports arrive.
@MainActor
final class AppDiagnostics: ObservableObject {
    static let shared = AppDiagnostics()

    @Published private(set) var summary = "自诊断尚未启动"
    @Published private(set) var reportCount = 0
    @Published private(set) var metricReportCount = 0
    @Published private(set) var diagnosticReportCount = 0
    @Published private(set) var isEnabled = false
    @Published private(set) var lastReportDate: Date?
    let storageURL: URL

    private let store: DiagnosticsReportStore
    private var session: AnyObject?
    private var generation = UUID()
    private var panelVisible = false
    private var enhancedSampling = false
    private var appliedReportRevision: UInt64 = 0

    init(directory: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        storageURL = directory ?? base.appendingPathComponent("MacPowerFlow/Diagnostics", isDirectory: true)
        store = DiagnosticsReportStore(directory: storageURL)
    }

    func start() {
        guard !isEnabled else { return }
        guard #available(macOS 27.0, *) else {
            summary = "自诊断需要 macOS 27 或更新版本"
            return
        }
        isEnabled = true
        generation = UUID()
        let currentGeneration = generation
        summary = "已启用 · 等待系统报告（通常每日生成）"
        let currentSession = DiagnosticsSession { [weak self] record in
            guard let self, self.isEnabled, self.generation == currentGeneration else { return }
            self.persist(record, generation: currentGeneration)
        }
        session = currentSession
        currentSession.update(panelVisible: panelVisible, enhancedSampling: enhancedSampling)
        let reportStore = store
        Task { @concurrent [weak self] in
            do {
                let counts = try await reportStore.refresh()
                await self?.apply(counts, generation: currentGeneration)
            } catch {
                await self?.storageFailed(generation: currentGeneration)
            }
        }
    }

    func stop() {
        generation = UUID()
        if #available(macOS 27.0, *), let currentSession = session as? DiagnosticsSession {
            currentSession.stop()
        }
        session = nil
        isEnabled = false
        summary = "自诊断已停止 · 本地报告已保留"
    }

    func updateState(panelVisible: Bool, enhancedSampling: Bool) {
        self.panelVisible = panelVisible
        self.enhancedSampling = enhancedSampling
        if #available(macOS 27.0, *), let currentSession = session as? DiagnosticsSession {
            currentSession.update(panelVisible: panelVisible, enhancedSampling: enhancedSampling)
        }
    }

    private func persist(_ record: DiagnosticsRecord, generation currentGeneration: UUID) {
        let reportStore = store
        Task { @concurrent [weak self] in
            do {
                let counts = try await reportStore.save(record)
                await self?.apply(counts, generation: currentGeneration)
            } catch {
                await self?.storageFailed(generation: currentGeneration)
            }
        }
    }

    private func apply(_ counts: DiagnosticsCounts, generation currentGeneration: UUID) {
        guard isEnabled, generation == currentGeneration,
              counts.revision >= appliedReportRevision else { return }
        appliedReportRevision = counts.revision
        metricReportCount = counts.metrics
        diagnosticReportCount = counts.diagnostics
        reportCount = counts.metrics + counts.diagnostics
        lastReportDate = counts.latest
        summary = reportCount == 0
            ? "已启用 · 等待系统报告（通常每日生成）"
            : "仅本地保存 · 性能报告 \(metricReportCount) 份，诊断报告 \(diagnosticReportCount) 份"
    }

    private func storageFailed(generation currentGeneration: UUID) {
        guard isEnabled, generation == currentGeneration else { return }
        summary = "自诊断已启用 · 本地报告保存失败"
    }
}

nonisolated private struct DiagnosticsPoint: Codable, Sendable {
    let name: String
    let value: Double
    let unit: String
}

nonisolated private struct DiagnosticsEntry: Codable, Sendable {
    let aggregation: String
    let state: String
    let durationSeconds: Double
    let metrics: [DiagnosticsPoint]
}

nonisolated private struct DiagnosticsRecord: Codable, Sendable {
    var schemaVersion = 1
    let kind: String
    let periodStart: Date
    let periodEnd: Date
    let entries: [DiagnosticsEntry]
    let diagnostic: [DiagnosticsPoint]
    let diagnosticType: String?
}

nonisolated private struct DiagnosticsCounts: Sendable {
    let revision: UInt64
    let metrics: Int
    let diagnostics: Int
    let latest: Date?
}

/// Encoding, file IO and pruning run away from the UI actor and serialize here.
private actor DiagnosticsReportStore {
    private let directory: URL
    private let maximumFiles = 64
    private let maximumBytes = 8 * 1_024 * 1_024
    private let maximumFileBytes = 256 * 1_024
    private let retention: TimeInterval = 30 * 24 * 60 * 60
    private var revision: UInt64 = 0

    init(directory: URL) { self.directory = directory }

    func save(_ record: DiagnosticsRecord) throws -> DiagnosticsCounts {
        guard record.periodEnd >= Date().addingTimeInterval(-retention) else { return try refresh() }
        try prepareDirectory()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        guard data.count <= maximumFileBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        let digest = SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
        let name = "mpf-\(record.kind)-\(digest).json"
        let destination = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try data.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
        return try refresh()
    }

    func refresh() throws -> DiagnosticsCounts {
        try prepareDirectory()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let candidates = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
        var files: [(url: URL, size: Int, date: Date)] = []
        let cutoff = Date().addingTimeInterval(-retention)
        for url in candidates {
            let name = url.lastPathComponent
            guard (name.hasPrefix("mpf-metric-") || name.hasPrefix("mpf-diagnostic-")), url.pathExtension == "json" else { continue }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let date = values.contentModificationDate ?? .distantPast
            let size = values.fileSize ?? 0
            if date < cutoff || size > maximumFileBytes {
                try FileManager.default.removeItem(at: url)
            } else {
                files.append((url, size, date))
            }
        }
        files.sort { $0.date > $1.date }
        var bytes = 0
        var kept: [(url: URL, size: Int, date: Date)] = []
        for file in files {
            if kept.count >= maximumFiles || bytes + file.size > maximumBytes {
                try FileManager.default.removeItem(at: file.url)
            } else {
                bytes += file.size
                kept.append(file)
            }
        }
        revision &+= 1
        return DiagnosticsCounts(
            revision: revision,
            metrics: kept.filter { $0.url.lastPathComponent.hasPrefix("mpf-metric-") }.count,
            diagnostics: kept.filter { $0.url.lastPathComponent.hasPrefix("mpf-diagnostic-") }.count,
            latest: kept.first?.date
        )
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
}

@available(macOS 27.0, *)
@MainActor
private final class DiagnosticsSession {
    private static let domain = "com.macpowerflow.operation"
    private let manager = MetricManager(enabledStateReportingDomains: [StateReportingDomain(rawValue: domain)])
    private let reporter = StateReporter<Never, Never>.reporter(for: domain)
    private var currentState: String?
    private var metricsTask: Task<Void, Never>?
    private var diagnosticsTask: Task<Void, Never>?

    init(receive: @escaping @MainActor @Sendable (DiagnosticsRecord) -> Void) {
        let manager = manager
        metricsTask = Task { @concurrent in
            for await report in manager.metricReports {
                guard !Task.isCancelled else { break }
                let record = Self.record(report)
                await receive(record)
            }
        }
        diagnosticsTask = Task { @concurrent in
            for await report in manager.diagnosticReports {
                guard !Task.isCancelled else { break }
                let record = Self.record(report)
                await receive(record)
            }
        }
    }

    deinit {
        metricsTask?.cancel()
        diagnosticsTask?.cancel()
        reporter.reportTransition(to: nil)
    }

    func update(panelVisible: Bool, enhancedSampling: Bool) {
        let label = (panelVisible ? "panel-" : "menubar-") + (enhancedSampling ? "enhanced" : "standard")
        guard currentState != label else { return }
        currentState = label
        reporter.reportTransition(to: label)
    }

    func stop() {
        metricsTask?.cancel()
        diagnosticsTask?.cancel()
        metricsTask = nil
        diagnosticsTask = nil
        reporter.reportTransition(to: nil)
        currentState = nil
    }

    nonisolated private static func duration(_ value: Double) -> Double {
        value.isFinite && value >= 0 ? value : 0
    }

    nonisolated private static func points(_ values: [MetricResult]) -> [DiagnosticsPoint] {
        values.prefix(128).compactMap { result in
            let point: DiagnosticsPoint
            switch result {
            case .cpuTime(let metric): point = .init(name: "cpuTime", value: metric.value.converted(to: .seconds).value, unit: "seconds")
            case .gpuTime(let metric): point = .init(name: "gpuTime", value: metric.value.converted(to: .seconds).value, unit: "seconds")
            case .logicalDiskWrites(let metric): point = .init(name: "logicalDiskWrites", value: metric.value.converted(to: .bytes).value, unit: "bytes")
            case .cpuInstructionsCount(let metric): point = .init(name: "cpuInstructions", value: Double(metric.value), unit: "count")
            default: return nil
            }
            return point.value.isFinite && point.value >= 0 ? point : nil
        }
    }

    nonisolated private static func label(_ state: MetricManager.ReportedState) -> String? {
        guard state.domain == "com.macpowerflow.operation",
              ["panel-standard", "panel-enhanced", "menubar-standard", "menubar-enhanced"].contains(state.label) else { return nil }
        return state.label
    }

    nonisolated private static func record(_ report: MetricReport) -> DiagnosticsRecord {
        var entries = report.stateEntries.prefix(64).map { entry in
            DiagnosticsEntry(aggregation: "state", state: label(entry.state) ?? "unattributed", durationSeconds: duration(entry.state.duration.converted(to: .seconds).value), metrics: points(entry.values))
        }
        entries += report.intervalEntries.prefix(64).map { entry in
            DiagnosticsEntry(aggregation: "interval", state: entry.states.compactMap(label).first ?? "unattributed", durationSeconds: duration(entry.duration.converted(to: .seconds).value), metrics: points(entry.values))
        }
        return DiagnosticsRecord(kind: "metric", periodStart: report.timeRange.start, periodEnd: report.timeRange.end, entries: entries, diagnostic: [], diagnosticType: nil)
    }

    nonisolated private static func record(_ report: DiagnosticReport) -> DiagnosticsRecord {
        var values: [DiagnosticsPoint] = []
        let type: String
        switch report.result {
        case .crash(let diagnostic):
            type = "crash"
            if let signal = diagnostic.signal { values.append(.init(name: "signal", value: Double(signal), unit: "code")) }
        case .hang(let diagnostic):
            type = "hang"
            values.append(.init(name: "hangDuration", value: diagnostic.hangDuration.converted(to: .seconds).value, unit: "seconds"))
        case .cpuException(let diagnostic):
            type = "cpuException"
            values.append(.init(name: "totalCPUTime", value: diagnostic.totalCPUTime.converted(to: .seconds).value, unit: "seconds"))
            values.append(.init(name: "totalSampledTime", value: diagnostic.totalSampledTime.converted(to: .seconds).value, unit: "seconds"))
        case .diskWriteException(let diagnostic):
            type = "diskWriteException"
            values.append(.init(name: "totalBytesWritten", value: diagnostic.totalBytesWritten.converted(to: .bytes).value, unit: "bytes"))
        case .appLaunch(let diagnostic):
            type = "appLaunch"
            values.append(.init(name: "launchDuration", value: diagnostic.launchDuration.converted(to: .seconds).value, unit: "seconds"))
        @unknown default: type = "unknown"
        }
        let states = report.environment.states.prefix(16).compactMap { state -> DiagnosticsEntry? in
            guard let name = label(state) else { return nil }
            return DiagnosticsEntry(aggregation: "diagnostic-state", state: name, durationSeconds: duration(state.duration.converted(to: .seconds).value), metrics: [])
        }
        return DiagnosticsRecord(kind: "diagnostic", periodStart: report.timeRange.start, periodEnd: report.timeRange.end, entries: states, diagnostic: values.filter { $0.value.isFinite }, diagnosticType: type)
    }
}
