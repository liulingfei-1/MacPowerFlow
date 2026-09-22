import Foundation

nonisolated enum PowerHistoryQuality: String, Codable, Sendable {
    case measured, estimated, stale, unavailable
    var canIntegrate: Bool { self == .measured || self == .estimated }
}

nonisolated enum PowerHistorySampling: String, Codable, Sendable {
    case instantaneous, intervalAverage
}

/// Raw watts before visual budget reconciliation. A single quality describes
/// the system value; unavailable component readings stay nil, never zero-filled.
nonisolated struct PowerHistoryPoint: Codable, Equatable, Sendable, Identifiable {
    var timestamp: Date
    var windowStart: Date
    var windowEnd: Date
    var systemWatts: Double?
    var cpuWatts: Double?
    var gpuWatts: Double?
    var signedBatteryWatts: Double?
    var source: String
    var quality: PowerHistoryQuality
    var systemSampling: PowerHistorySampling = .instantaneous
    var startsNewSegment = false
    var cpuWindowStart: Date? = nil
    var cpuWindowEnd: Date? = nil
    var gpuWindowStart: Date? = nil
    var gpuWindowEnd: Date? = nil
    var cpuSource: String? = nil
    var gpuSource: String? = nil
    var cpuQuality: PowerHistoryQuality? = nil
    var gpuQuality: PowerHistoryQuality? = nil
    var id: Date { timestamp }

    func sanitized() -> Self? {
        guard [timestamp, windowStart, windowEnd].allSatisfy({ $0.timeIntervalSince1970.isFinite }),
              windowStart <= windowEnd, windowEnd <= timestamp else { return nil }
        func valid(_ watts: Double?, signed: Bool = false) -> Double? {
            guard let watts, watts.isFinite, abs(watts) < 10_000,
                  signed || watts >= 0 else { return nil }
            return watts
        }
        var point = self
        point.systemWatts = valid(systemWatts)
        point.cpuWatts = valid(cpuWatts)
        point.gpuWatts = valid(gpuWatts)
        point.signedBatteryWatts = valid(signedBatteryWatts, signed: true)
        point.source = String(source.prefix(256))
        point.cpuSource = cpuSource.map { String($0.prefix(256)) }
        point.gpuSource = gpuSource.map { String($0.prefix(256)) }
        func validWindow(_ start: Date?, _ end: Date?) -> (Date?, Date?) {
            if let start, !start.timeIntervalSince1970.isFinite || start > timestamp { return (nil, nil) }
            if let end, !end.timeIntervalSince1970.isFinite || end > timestamp { return (nil, nil) }
            if let start, let end, start > end { return (nil, nil) }
            return (start, end)
        }
        (point.cpuWindowStart, point.cpuWindowEnd) = validWindow(cpuWindowStart, cpuWindowEnd)
        (point.gpuWindowStart, point.gpuWindowEnd) = validWindow(gpuWindowStart, gpuWindowEnd)
        return point
    }
}

nonisolated struct PowerHistorySummary: Codable, Equatable, Sendable {
    var energyWh = 0.0
    var coveredSeconds = 0.0
    var peakWatts: Double?
    var includesEstimates = false
    var averageWatts: Double? { coveredSeconds > 0 ? energyWh * 3600 / coveredSeconds : nil }

    mutating func add(_ other: Self) {
        energyWh += other.energyWh
        coveredSeconds += other.coveredSeconds
        if let peak = other.peakWatts { peakWatts = max(peakWatts ?? peak, peak) }
        includesEstimates = includesEstimates || other.includesEstimates
    }
}

nonisolated struct PowerHistorySession: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var name: String
    let startedAt: Date
    var endedAt: Date?
    var summary: PowerHistorySummary
    var elapsedSeconds: TimeInterval? { endedAt.map { max(0, $0.timeIntervalSince(startedAt)) } }
    var coverageFraction: Double? {
        guard let elapsedSeconds, elapsedSeconds > 0 else { return nil }
        return min(1, max(0, summary.coveredSeconds / elapsedSeconds))
    }
}

nonisolated struct PowerHistoryArchive: Codable, Sendable {
    var schemaVersion = 1
    var points: [PowerHistoryPoint] = []
    var sessions: [PowerHistorySession] = []
    var activeSession: PowerHistorySession?
}

nonisolated struct PowerHistoryCore: Sendable {
    private(set) var archive: PowerHistoryArchive
    let retentionSeconds: TimeInterval
    let maximumPoints: Int
    let maximumGapSeconds: TimeInterval
    let maximumSessions: Int

    init(archive: PowerHistoryArchive = PowerHistoryArchive(),
         now: Date = Date(), retentionSeconds: TimeInterval = 86_400,
         maximumPoints: Int = 20_000, maximumGapSeconds: TimeInterval = 12,
         maximumSessions: Int = 100) {
        self.retentionSeconds = max(1, retentionSeconds)
        self.maximumPoints = max(1, maximumPoints)
        self.maximumGapSeconds = max(0.1, maximumGapSeconds)
        self.maximumSessions = max(1, maximumSessions)
        self.archive = archive.schemaVersion == 1 ? archive : PowerHistoryArchive()
        let sanitized = self.archive.points.compactMap { $0.sanitized() }.sorted { $0.timestamp < $1.timestamp }
        self.archive.points = []
        for point in sanitized where self.archive.points.last?.timestamp != point.timestamp {
            self.archive.points.append(point)
        }
        prune(now: now)
    }

    /// Returns false for invalid timestamps or duplicate/out-of-order samples.
    /// Keeping stale/missing frames records explicit gaps in charts and exports.
    @discardableResult
    mutating func append(_ raw: PowerHistoryPoint) -> Bool {
        guard let point = raw.sanitized(),
              archive.points.last.map({ point.timestamp > $0.timestamp }) ?? true else { return false }
        let previous = archive.points.last
        if var active = archive.activeSession {
            active.summary.add(segment(previous: previous, current: point,
                                       since: active.startedAt, until: point.timestamp))
            archive.activeSession = active
        }
        archive.points.append(point)
        prune(now: point.timestamp)
        return true
    }

    mutating func startSession(name: String, at date: Date = Date()) {
        guard date.timeIntervalSince1970.isFinite else { return }
        if archive.activeSession != nil, endSession(at: date) == nil { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        archive.activeSession = PowerHistorySession(
            id: UUID(), name: trimmed.isEmpty ? "能耗记录" : String(trimmed.prefix(200)),
            startedAt: date, endedAt: nil, summary: PowerHistorySummary())
    }

    @discardableResult
    mutating func endSession(at date: Date = Date()) -> PowerHistorySession? {
        guard var session = archive.activeSession, date >= session.startedAt,
              date.timeIntervalSince1970.isFinite else { return nil }
        // A sample after the requested end cannot be un-integrated reliably from
        // an incremental session, so ending is only accepted at/after the last sample.
        guard archive.points.last.map({ date >= $0.timestamp }) ?? true else { return nil }
        session.endedAt = date
        archive.activeSession = nil
        archive.sessions.append(session)
        if archive.sessions.count > maximumSessions {
            archive.sessions.removeFirst(archive.sessions.count - maximumSessions)
        }
        return session
    }

    func summary(since: Date, until: Date = Date()) -> PowerHistorySummary {
        guard since < until else { return PowerHistorySummary() }
        var total = PowerHistorySummary()
        var previous: PowerHistoryPoint?
        for point in archive.points {
            total.add(segment(previous: previous, current: point, since: since, until: until))
            previous = point
        }
        return total
    }

    /// Each segment is integrated once. Instantaneous samples use trapezoids;
    /// interval averages use only their actual window, clipped at overlap/gaps.
    private func segment(previous: PowerHistoryPoint?, current: PowerHistoryPoint,
                         since: Date, until: Date) -> PowerHistorySummary {
        guard !current.startsNewSegment, current.quality.canIntegrate,
              let endWatts = current.systemWatts else { return .init() }
        let start: Date
        let end: Date
        let startWatts: Double
        let estimated: Bool
        switch current.systemSampling {
        case .instantaneous:
            guard let previous, previous.quality.canIntegrate,
                  previous.source == current.source, let watts = previous.systemWatts else { return .init() }
            start = previous.timestamp; end = current.timestamp; startWatts = watts
            estimated = previous.quality == .estimated || current.quality == .estimated
        case .intervalAverage:
            guard current.windowEnd.timeIntervalSince(current.windowStart) <= maximumGapSeconds else { return .init() }
            start = max(current.windowStart, previous?.windowEnd ?? current.windowStart)
            end = current.windowEnd; startWatts = endWatts
            estimated = current.quality == .estimated
        }
        let duration = end.timeIntervalSince(start)
        guard duration > 0, duration <= maximumGapSeconds else { return .init() }
        let clippedStart = max(start, since), clippedEnd = min(end, until)
        let seconds = clippedEnd.timeIntervalSince(clippedStart)
        guard seconds > 0 else { return .init() }
        let first = startWatts + (endWatts - startWatts) * clippedStart.timeIntervalSince(start) / duration
        let last = startWatts + (endWatts - startWatts) * clippedEnd.timeIntervalSince(start) / duration
        return PowerHistorySummary(energyWh: (first + last) * 0.5 * seconds / 3600,
                                   coveredSeconds: seconds, peakWatts: max(first, last),
                                   includesEstimates: estimated)
    }

    private mutating func prune(now: Date) {
        let earliest = now.addingTimeInterval(-retentionSeconds)
        archive.points.removeAll { $0.timestamp < earliest || $0.timestamp > now }
        if archive.points.count > maximumPoints {
            archive.points.removeFirst(archive.points.count - maximumPoints)
        }
        if archive.sessions.count > maximumSessions {
            archive.sessions.removeFirst(archive.sessions.count - maximumSessions)
        }
    }

    func jsonData() throws -> Data { try Self.encodeArchive(archive) }

    static func encodeArchive(_ archive: PowerHistoryArchive) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(archive)
    }

    /// Keep segment boundaries and both extrema of each chronological bucket.
    /// The target is soft: preserving many discontinuities can exceed it.
    static func chartPoints(points: [PowerHistoryPoint], targetCount: Int = 400,
                            maximumGapSeconds: TimeInterval = 12) -> [PowerHistoryPoint] {
        var annotated = points
        var mandatory = Set<Int>()
        var segments: [[Int]] = []
        var current: [Int] = []
        func closeSegment() {
            if !current.isEmpty { segments.append(current); current = [] }
        }
        for index in points.indices {
            let point = points[index]
            let available = point.quality.canIntegrate && point.systemWatts.map { $0.isFinite && $0 >= 0 } == true
            guard available else {
                closeSegment()
                // One representative per missing run preserves a visible break.
                if index == 0 || (points[index - 1].quality.canIntegrate && points[index - 1].systemWatts != nil) {
                    mandatory.insert(index)
                }
                continue
            }
            if let previous = current.last,
               point.startsNewSegment || point.source != points[previous].source ||
                point.timestamp.timeIntervalSince(points[previous].timestamp) > maximumGapSeconds {
                closeSegment()
            }
            current.append(index)
        }
        closeSegment()
        for segment in segments {
            if let first = segment.first {
                mandatory.insert(first)
                annotated[first].startsNewSegment = true
            }
            if let last = segment.last { mandatory.insert(last) }
        }
        // Continuity is determined from the original full-rate sequence. The UI
        // must not reapply the timeout to the now naturally farther-apart points.
        guard points.count > max(2, targetCount) else { return annotated }
        let remaining = max(0, targetCount - mandatory.count)
        let total = max(1, segments.reduce(0) { $0 + $1.count })
        for segment in segments where segment.count > 2 {
            // At least one extrema pair per segment, even below the soft budget.
            let buckets = max(1, remaining * segment.count / total / 2)
            let bucketSize = max(1, Int(ceil(Double(segment.count) / Double(buckets))))
            for start in stride(from: 0, to: segment.count, by: bucketSize) {
                let bucket = segment[start..<min(start + bucketSize, segment.count)]
                if let minimum = bucket.min(by: { points[$0].systemWatts! < points[$1].systemWatts! }) { mandatory.insert(minimum) }
                if let maximum = bucket.max(by: { points[$0].systemWatts! < points[$1].systemWatts! }) { mandatory.insert(maximum) }
            }
        }
        return mandatory.sorted().map { annotated[$0] }
    }

    static func decodeArchive(_ data: Data) throws -> PowerHistoryArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(PowerHistoryArchive.self, from: data)
    }

    func csvData() -> Data {
        let dateFormat = ISO8601DateFormatter()
        dateFormat.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func escaped(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        func watts(_ value: Double?) -> String { value.map(String.init(describing:)) ?? "" }
        func optionalDate(_ value: Date?) -> String { value.map(dateFormat.string(from:)) ?? "" }
        var rows = ["timestamp,window_start,window_end,system_w,cpu_w,gpu_w,battery_signed_w,source,quality,system_sampling,starts_new_segment,cpu_window_start,cpu_window_end,gpu_window_start,gpu_window_end,cpu_source,gpu_source,cpu_quality,gpu_quality"]
        for point in archive.points {
            rows.append([
                dateFormat.string(from: point.timestamp), dateFormat.string(from: point.windowStart),
                dateFormat.string(from: point.windowEnd), watts(point.systemWatts), watts(point.cpuWatts),
                watts(point.gpuWatts), watts(point.signedBatteryWatts), escaped(point.source),
                point.quality.rawValue, point.systemSampling.rawValue, String(point.startsNewSegment),
                optionalDate(point.cpuWindowStart), optionalDate(point.cpuWindowEnd),
                optionalDate(point.gpuWindowStart), optionalDate(point.gpuWindowEnd),
                point.cpuSource.map(escaped) ?? "", point.gpuSource.map(escaped) ?? "",
                point.cpuQuality?.rawValue ?? "", point.gpuQuality?.rawValue ?? ""
            ].joined(separator: ","))
        }
        return Data((rows.joined(separator: "\r\n") + "\r\n").utf8)
    }
}
