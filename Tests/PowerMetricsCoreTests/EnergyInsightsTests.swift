import XCTest
@testable import PowerMetricsCore

final class EnergyInsightsTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_780_272_000)
    private func sample(_ hours: Double = 0, level: Int? = 80, capacity: Int? = 4000,
                        onAC: Bool = false, voltage: Double? = 12, temperature: Double? = 30) -> BatteryInsightSample {
        BatteryInsightSample(date: epoch.addingTimeInterval(hours * 3600), isPresent: true,
            isOnAC: onAC, level: level, currentCapacityMAh: capacity,
            fullCapacityMAh: 5000, designCapacityMAh: 6000, cycleCount: 100,
            temperatureC: temperature, voltage: voltage)
    }
    func testDailyUpsertKeepsEstimatedRatioAndTemperatureRange() {
        var core = EnergyInsightsCore(now: epoch)
        XCTAssertTrue(core.record(sample()))
        XCTAssertTrue(core.record(sample(0.01, temperature: 40)))
        XCTAssertEqual(core.archive.healthDays.count, 1)
        let day = core.archive.healthDays[0]
        XCTAssertEqual(day.estimatedHealthPercent ?? 0, 83.333333, accuracy: 0.0001)
        XCTAssertTrue(day.healthIsEstimated)
        XCTAssertEqual(day.temperatureMinimumC, 30)
        XCTAssertEqual(day.temperatureMaximumC, 40)
        XCTAssertEqual(day.temperatureMeanC, 35)
        XCTAssertFalse(core.record(sample()))
    }
    func testDailyRetentionIsNinetyDays() {
        var core = EnergyInsightsCore(now: epoch)
        for day in 0..<150 { XCTAssertTrue(core.record(sample(Double(day * 24)))) }
        XCTAssertEqual(core.archive.healthDays.count, 90)
    }
    func testMissingReadDoesNotDestroyEarlierDailyHealth() {
        var core = EnergyInsightsCore(now: epoch)
        _ = core.record(sample())
        var missing = sample(0.01)
        missing.fullCapacityMAh = nil
        missing.designCapacityMAh = nil
        missing.cycleCount = nil
        missing.temperatureC = .nan
        _ = core.record(missing)
        XCTAssertEqual(core.archive.healthDays[0].fullCapacityMAh, 5000)
        XCTAssertEqual(core.archive.healthDays[0].temperatureSampleCount, 1)
    }
    func testBatterySleepUsesCapacityDifferenceNotInstantaneousWatts() throws {
        var core = EnergyInsightsCore(now: epoch)
        core.willSleep(sample())
        let record = try XCTUnwrap(core.didWake(sample(2, level: 78, capacity: 3900)))
        XCTAssertEqual(record.quality, .endpointEstimate)
        XCTAssertEqual(record.capacityChangeMAh, 100)
        XCTAssertEqual(record.estimatedEnergyWh ?? 0, 1.2, accuracy: 0.000001)
        XCTAssertEqual(record.estimatedPercentPerHour, 1)
        XCTAssertTrue(record.isEstimated)
        XCTAssertNil(core.didWake(sample(3)))
    }
    func testPowerSourceChangeSuppressesBothRates() throws {
        var core = EnergyInsightsCore(now: epoch)
        core.willSleep(sample())
        core.notePowerSourceChange()
        let record = try XCTUnwrap(core.didWake(sample(2, level: 70, capacity: 3500)))
        XCTAssertEqual(record.quality, .powerSourceChanged)
        XCTAssertNil(record.estimatedEnergyWh)
        XCTAssertNil(record.estimatedPercentPerHour)
        core.willSleep(sample())
        XCTAssertEqual(core.didWake(sample(2, onAC: true))?.quality, .powerSourceChanged)
    }
    func testExternalPowerNeverGetsBatterySleepEstimate() {
        var core = EnergyInsightsCore(now: epoch)
        core.willSleep(sample(onAC: true))
        let record = core.didWake(sample(2, level: 78, capacity: 3900, onAC: true))
        XCTAssertEqual(record?.quality, .externalPower)
        XCTAssertNil(record?.estimatedEnergyWh)
    }
    func testRecalibrationOrCapacityGrowthIsNotNegativeConsumption() {
        for after in [sample(2, level: 81, capacity: 3900), sample(2, level: 79, capacity: 4100)] {
            var core = EnergyInsightsCore(now: epoch)
            core.willSleep(sample())
            let record = core.didWake(after)
            XCTAssertEqual(record?.quality, .capacityIncreased)
            XCTAssertNil(record?.estimatedEnergyWh)
            XCTAssertNil(record?.estimatedPercentPerHour)
        }
    }
    func testMissingVoltagePreservesPercentOnly() {
        var core = EnergyInsightsCore(now: epoch)
        core.willSleep(sample(voltage: nil))
        let record = core.didWake(sample(2, level: 78, capacity: 3900))
        XCTAssertEqual(record?.estimatedPercentPerHour, 1)
        XCTAssertNil(record?.estimatedEnergyWh)
    }
    func testMissingGaugesStayUnknownAndZeroLossStaysZero() {
        var core = EnergyInsightsCore(now: epoch)
        core.willSleep(sample(level: nil, capacity: nil))
        XCTAssertEqual(core.didWake(sample(2))?.quality, .missingData)
        core.willSleep(sample())
        let same = core.didWake(sample(2))
        XCTAssertEqual(same?.estimatedEnergyWh, 0)
        XCTAssertEqual(same?.estimatedPercentPerHour, 0)
    }
    func testMissingWakeGaugeDoesNotBecomeZeroCapacityOrPercent() {
        var core = EnergyInsightsCore(now: epoch)
        core.willSleep(sample())
        let unknown = core.didWake(sample(2, level: nil, capacity: nil))
        XCTAssertEqual(unknown?.quality, .missingData)
        XCTAssertNil(unknown?.capacityChangeMAh)
        XCTAssertNil(unknown?.estimatedEnergyWh)
        XCTAssertNil(unknown?.estimatedPercentPerHour)
        core.willSleep(sample())
        let empty = core.didWake(sample(2, level: 0, capacity: 0))
        XCTAssertEqual(empty?.quality, .endpointEstimate)
        XCTAssertEqual(empty?.capacityChangeMAh, 4000)
        XCTAssertEqual(empty?.estimatedEnergyWh, 48)
        XCTAssertEqual(empty?.estimatedPercentPerHour, 40)
    }

    func testTimeRollbackShortAndLongWindows() {
        var core = EnergyInsightsCore(now: epoch)
        core.willSleep(sample())
        XCTAssertNil(core.didWake(sample(-1)))
        core.willSleep(sample())
        XCTAssertEqual(core.didWake(sample(0.001))?.quality, .tooShort)
        core.willSleep(sample())
        let long = core.didWake(sample(73))
        XCTAssertEqual(long?.quality, .tooLong)
        XCTAssertNil(long?.estimatedEnergyWh)
    }
    func testArchiveRoundTripAndBadSchema() throws {
        var core = EnergyInsightsCore(now: epoch)
        _ = core.record(sample())
        XCTAssertEqual(try EnergyInsightsCore.decodeArchive(core.jsonData()).healthDays.count, 1)
        XCTAssertThrowsError(try EnergyInsightsCore.decodeArchive(Data("broken".utf8)))
        let invalid = EnergyInsightsArchive(schemaVersion: 99)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        XCTAssertThrowsError(try EnergyInsightsCore.decodeArchive(encoder.encode(invalid)))
    }
    func testSleepRetentionIsBoundedEvenWithFrequentWakeEvents() {
        var core = EnergyInsightsCore(now: epoch)
        for index in 0..<220 {
            let hours = Double(index) * 0.1
            core.willSleep(sample(hours))
            _ = core.didWake(sample(hours + 0.05))
        }
        XCTAssertEqual(core.archive.sleepRecords.count, 180)
    }

    func testSemanticallyCorruptedArchiveIsRejected() throws {
        var core = EnergyInsightsCore(now: epoch)
        _ = core.record(sample())
        var archive = core.archive
        archive.healthDays[0].temperatureSampleCount = -1
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        XCTAssertThrowsError(try EnergyInsightsCore.decodeArchive(encoder.encode(archive)))
        archive = core.archive
        archive.healthDays.append(archive.healthDays[0])
        XCTAssertThrowsError(try EnergyInsightsCore.decodeArchive(encoder.encode(archive)))
    }
}
