import Foundation

nonisolated struct BatteryInsightSample: Codable, Sendable {
    var date: Date
    var isPresent: Bool
    var isOnAC: Bool
    var level: Int?
    var currentCapacityMAh: Int?
    var fullCapacityMAh: Int?
    var designCapacityMAh: Int?
    var cycleCount: Int?
    var temperatureC: Double?
    var voltage: Double?

    func sanitized() -> Self {
        var copy = self
        copy.level = level.flatMap { (0...100).contains($0) ? $0 : nil }
        copy.currentCapacityMAh = currentCapacityMAh.flatMap { (0...100_000).contains($0) ? $0 : nil }
        copy.fullCapacityMAh = fullCapacityMAh.flatMap { (1...100_000).contains($0) ? $0 : nil }
        copy.designCapacityMAh = designCapacityMAh.flatMap { (1...100_000).contains($0) ? $0 : nil }
        copy.cycleCount = cycleCount.flatMap { (0...100_000).contains($0) ? $0 : nil }
        copy.temperatureC = temperatureC.flatMap { $0.isFinite && (-20...100).contains($0) ? $0 : nil }
        copy.voltage = voltage.flatMap { $0.isFinite && (1...30).contains($0) ? $0 : nil }
        return copy
    }
}

nonisolated struct BatteryHealthDay: Codable, Sendable, Identifiable {
    var id: Date { day }
    let day: Date
    var lastObservedAt: Date
    var fullCapacityMAh: Int?
    var designCapacityMAh: Int?
    var cycleCount: Int?
    var estimatedHealthPercent: Double?
    var temperatureMinimumC: Double?
    var temperatureMaximumC: Double?
    var temperatureMeanC: Double?
    var temperatureSampleCount: Int
    /// Capacity ratio is a gauge estimate, never a laboratory health diagnosis.
    var healthIsEstimated: Bool { true }
}

nonisolated enum SleepEnergyQuality: String, Codable, Sendable {
    case endpointEstimate, powerSourceChanged, externalPower, missingData
    case capacityIncreased, tooShort, tooLong, batteryUnavailable
}

nonisolated struct SleepEnergyRecord: Codable, Sendable, Identifiable {
    let id: UUID
    let sleptAt: Date
    let wokeAt: Date
    let durationSeconds: Double
    let beforeLevel: Int?
    let afterLevel: Int?
    let capacityChangeMAh: Int?
    let estimatedEnergyWh: Double?
    let estimatedPercentPerHour: Double?
    let quality: SleepEnergyQuality
    var isEstimated: Bool { true }
}

nonisolated struct EnergyInsightsArchive: Codable, Sendable {
    var schemaVersion = 1
    var timeZoneIdentifier = TimeZone.current.identifier
    var healthDays: [BatteryHealthDay] = []
    var sleepRecords: [SleepEnergyRecord] = []
}

nonisolated struct EnergyInsightsCore: Sendable {
    private(set) var archive: EnergyInsightsArchive
    private var pendingSleep: BatteryInsightSample?
    private var powerChangedDuringSleep = false
    private var calendar: Calendar

    init(archive: EnergyInsightsArchive = EnergyInsightsArchive(), now: Date = Date()) {
        self.archive = archive
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: archive.timeZoneIdentifier) ?? .current
        self.calendar = calendar
        prune(now: now)
    }

    @discardableResult
    mutating func record(_ input: BatteryInsightSample) -> Bool {
        guard input.isPresent, input.date.timeIntervalSinceReferenceDate.isFinite else { return false }
        let sample = input.sanitized()
        if let last = archive.healthDays.last, sample.date < last.lastObservedAt { return false }
        let day = calendar.startOfDay(for: sample.date)
        let health: Double? = {
            guard let full = sample.fullCapacityMAh, let design = sample.designCapacityMAh else { return nil }
            let ratio = Double(full) / Double(design) * 100
            return ratio <= 150 ? ratio : nil
        }()
        if let index = archive.healthDays.firstIndex(where: { $0.day == day }) {
            var entry = archive.healthDays[index]
            guard sample.date > entry.lastObservedAt else { return false }
            entry.lastObservedAt = sample.date
            // A missing latest gauge reading does not erase the day's last valid one.
            if let full = sample.fullCapacityMAh, let design = sample.designCapacityMAh {
                entry.fullCapacityMAh = full
                entry.designCapacityMAh = design
                entry.estimatedHealthPercent = health
            }
            if let cycles = sample.cycleCount { entry.cycleCount = cycles }
            if let temperature = sample.temperatureC {
                entry.temperatureMinimumC = min(entry.temperatureMinimumC ?? temperature, temperature)
                entry.temperatureMaximumC = max(entry.temperatureMaximumC ?? temperature, temperature)
                let count = min(entry.temperatureSampleCount, 100_000)
                entry.temperatureMeanC = (entry.temperatureMeanC ?? temperature)
                    + (temperature - (entry.temperatureMeanC ?? temperature)) / Double(count + 1)
                entry.temperatureSampleCount = count + 1
            }
            archive.healthDays[index] = entry
        } else {
            archive.healthDays.append(BatteryHealthDay(
                day: day, lastObservedAt: sample.date,
                fullCapacityMAh: sample.fullCapacityMAh, designCapacityMAh: sample.designCapacityMAh,
                cycleCount: sample.cycleCount, estimatedHealthPercent: health,
                temperatureMinimumC: sample.temperatureC, temperatureMaximumC: sample.temperatureC,
                temperatureMeanC: sample.temperatureC, temperatureSampleCount: sample.temperatureC == nil ? 0 : 1
            ))
        }
        prune(now: sample.date)
        return true
    }

    /// The caller must supply a fresh battery snapshot, not a stale UI estimate.
    mutating func willSleep(_ sample: BatteryInsightSample) {
        pendingSleep = sample.date.timeIntervalSinceReferenceDate.isFinite ? sample.sanitized() : nil
        powerChangedDuringSleep = false
    }

    mutating func notePowerSourceChange() {
        if pendingSleep != nil { powerChangedDuringSleep = true }
    }

    @discardableResult
    mutating func didWake(_ input: BatteryInsightSample) -> SleepEnergyRecord? {
        guard let before = pendingSleep else { return nil }
        pendingSleep = nil
        defer { powerChangedDuringSleep = false }
        let after = input.sanitized()
        let duration = after.date.timeIntervalSince(before.date)
        guard duration.isFinite, duration > 0 else { return nil }
        let capacityLoss = before.currentCapacityMAh.flatMap { old in
            after.currentCapacityMAh.map { old - $0 }
        }
        let percentLoss = before.level.flatMap { old in after.level.map { old - $0 } }
        let quality: SleepEnergyQuality
        if !before.isPresent || !after.isPresent { quality = .batteryUnavailable }
        else if powerChangedDuringSleep || before.isOnAC != after.isOnAC { quality = .powerSourceChanged }
        else if before.isOnAC || after.isOnAC { quality = .externalPower }
        else if duration < 60 { quality = .tooShort }
        else if duration > 72 * 3600 { quality = .tooLong }
        else if (capacityLoss ?? 0) < 0 || (percentLoss ?? 0) < 0 { quality = .capacityIncreased }
        else if percentLoss == nil && capacityLoss == nil { quality = .missingData }
        else { quality = .endpointEstimate }
        var energy: Double?
        var percentRate: Double?
        if quality == .endpointEstimate {
            percentRate = percentLoss.map { Double($0) / (duration / 3600) }
            if let loss = capacityLoss, let startV = before.voltage, let endV = after.voltage,
               abs(startV - endV) / max(startV, endV) <= 0.2 {
                energy = Double(loss) / 1000 * (startV + endV) / 2
            }
        }
        let record = SleepEnergyRecord(
            id: UUID(), sleptAt: before.date, wokeAt: after.date, durationSeconds: duration,
            beforeLevel: before.level, afterLevel: after.level,
            capacityChangeMAh: capacityLoss, estimatedEnergyWh: energy,
            estimatedPercentPerHour: percentRate, quality: quality
        )
        archive.sleepRecords.append(record)
        prune(now: after.date)
        return record
    }

    mutating func prune(now: Date) {
        guard now.timeIntervalSinceReferenceDate.isFinite else { return }
        let oldest = calendar.date(byAdding: .day, value: -89, to: calendar.startOfDay(for: now)) ?? now
        archive.healthDays = Array(archive.healthDays.filter {
            $0.day >= oldest && $0.day <= now && $0.lastObservedAt <= now
        }.sorted { $0.day < $1.day }.suffix(90))
        archive.sleepRecords = Array(archive.sleepRecords.filter {
            $0.wokeAt >= oldest && $0.wokeAt <= now && $0.durationSeconds.isFinite && $0.durationSeconds > 0
        }.sorted { $0.wokeAt < $1.wokeAt }.suffix(180))
    }

    func jsonData() throws -> Data { try Self.encodeArchive(archive) }

    static func encodeArchive(_ archive: EnergyInsightsArchive) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(archive)
    }

    static func decodeArchive(_ data: Data) throws -> EnergyInsightsArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(EnergyInsightsArchive.self, from: data)
        func finite(_ value: Double?, range: ClosedRange<Double>) -> Bool {
            value.map { $0.isFinite && range.contains($0) } ?? true
        }
        guard archive.schemaVersion == 1,
              TimeZone(identifier: archive.timeZoneIdentifier) != nil,
              archive.healthDays.count <= 90, archive.sleepRecords.count <= 180,
              Set(archive.healthDays.map(\.day)).count == archive.healthDays.count,
              Set(archive.sleepRecords.map(\.id)).count == archive.sleepRecords.count,
              archive.healthDays.allSatisfy({ day in
                  day.day <= day.lastObservedAt
                      && (0...100_001).contains(day.temperatureSampleCount)
                      && finite(day.estimatedHealthPercent, range: 0...150)
                      && finite(day.temperatureMinimumC, range: -20...100)
                      && finite(day.temperatureMaximumC, range: -20...100)
                      && finite(day.temperatureMeanC, range: -20...100)
              }),
              archive.sleepRecords.allSatisfy({ record in
                  record.durationSeconds.isFinite && record.durationSeconds > 0
                      && record.wokeAt > record.sleptAt
                      && abs(record.wokeAt.timeIntervalSince(record.sleptAt) - record.durationSeconds) < 1.01
                      && finite(record.estimatedEnergyWh, range: 0...3000)
                      && finite(record.estimatedPercentPerHour, range: 0...6000)
                      && (record.quality == .endpointEstimate
                          || (record.estimatedEnergyWh == nil && record.estimatedPercentPerHour == nil))
              }) else { throw CocoaError(.coderReadCorrupt) }
        return archive
    }
}
