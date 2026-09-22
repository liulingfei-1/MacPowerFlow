import Foundation
import XCTest
@testable import PowerMetricsCore

final class PowerHistoryTests: XCTestCase {
    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
    private func point(_ seconds: Double, watts: Double? = 600,
                       quality: PowerHistoryQuality = .measured,
                       source: String = "SMC", intervalStart: Double? = nil) -> PowerHistoryPoint {
        PowerHistoryPoint(timestamp: date(seconds), windowStart: date(intervalStart ?? seconds),
                          windowEnd: date(seconds), systemWatts: watts, cpuWatts: 4,
                          gpuWatts: 0, signedBatteryWatts: -12, source: source, quality: quality,
                          systemSampling: intervalStart == nil ? .instantaneous : .intervalAverage)
    }
    private func history(maximumPoints: Int = 20_000) -> PowerHistoryCore {
        PowerHistoryCore(now: date(0), maximumPoints: maximumPoints)
    }

    func testWattsTimesActualSecondsConvertsToWattHours() {
        var core = history()
        core.append(point(0)); core.append(point(6))
        let summary = core.summary(since: date(0), until: date(6))
        XCTAssertEqual(summary.energyWh, 1, accuracy: 0.000001)
        XCTAssertEqual(summary.coveredSeconds, 6)
        XCTAssertEqual(summary.averageWatts, 600)
    }

    func testClippedTrapezoidInterpolatesEndpointInsteadOfUsingFullWindowMean() {
        var core = history()
        core.append(point(0, watts: 0)); core.append(point(10, watts: 100))
        let summary = core.summary(since: date(5), until: date(10))
        XCTAssertEqual(summary.energyWh, 75 * 5 / 3600, accuracy: 0.000001)
        XCTAssertEqual(summary.peakWatts, 100)
    }

    func testSleepAndMissingValuesRemainUncoveredInsteadOfCreatingEnergy() {
        var core = history()
        for entry in [point(0), point(6), point(8, watts: nil), point(10), point(100), point(106)] {
            core.append(entry)
        }
        let summary = core.summary(since: date(0), until: date(106))
        XCTAssertEqual(summary.energyWh, 2, accuracy: 0.000001)
        XCTAssertEqual(summary.coveredSeconds, 12)
    }

    func testStaleFramesAndSourceChangesBreakIntegration() {
        var core = history()
        for entry in [point(0), point(2, quality: .stale), point(4), point(6, source: "Battery"), point(8, source: "Battery")] {
            core.append(entry)
        }
        let summary = core.summary(since: date(0), until: date(8))
        XCTAssertEqual(summary.coveredSeconds, 2)
        XCTAssertEqual(summary.energyWh, 1.0 / 3, accuracy: 0.000001)
    }

    func testIntervalAveragesUseTheirOwnWindowsAndDoNotDoubleCountOverlap() {
        var core = history()
        core.append(point(6, intervalStart: 0))
        core.append(point(10, intervalStart: 4))
        let summary = core.summary(since: date(0), until: date(10))
        XCTAssertEqual(summary.coveredSeconds, 10)
        XCTAssertEqual(summary.energyWh, 6000 / 3600.0, accuracy: 0.000001)
    }

    func testExplicitSleepBoundaryBreaksEvenAShortGap() {
        var core = history()
        core.append(point(0))
        var resumed = point(2)
        resumed.startsNewSegment = true
        core.append(resumed)
        core.append(point(4))
        XCTAssertEqual(core.summary(since: date(0), until: date(4)).coveredSeconds, 2)
    }

    func testOversizedIntervalIsNotRescuedByClippingAfterSleep() {
        var core = history()
        core.append(point(60, intervalStart: 0))
        XCTAssertEqual(core.summary(since: date(59), until: date(60)).energyWh, 0)
    }

    func testInvalidPowerSanitizesToMissingAndZeroRemainsMeasured() throws {
        var core = history()
        core.append(point(0, watts: 0))
        core.append(point(2, watts: 0))
        core.append(point(4, watts: .nan))
        core.append(point(6, watts: .infinity))
        core.append(point(8, watts: -1))
        XCTAssertEqual(core.archive.points[0].systemWatts, 0)
        XCTAssertNil(core.archive.points[2].systemWatts)
        XCTAssertNil(core.archive.points[3].systemWatts)
        XCTAssertNil(core.archive.points[4].systemWatts)
        XCTAssertEqual(core.summary(since: date(0), until: date(8)).coveredSeconds, 2)
        XCTAssertNoThrow(try core.jsonData())
    }

    func testReorderedAndInvalidTimestampsCannotCorruptTimeAxis() {
        var core = history()
        XCTAssertTrue(core.append(point(3)))
        XCTAssertFalse(core.append(point(2)))
        XCTAssertFalse(core.append(point(3)))
        XCTAssertFalse(core.append(point(.nan)))
        XCTAssertFalse(core.append(point(4, intervalStart: 5)))
        XCTAssertEqual(core.archive.points.count, 1)
    }

    func testRestoredHistoryPreservesFractionalWindowsAndDoesNotBridgeRestartGap() throws {
        var original = history()
        original.append(point(0.125)); original.append(point(6.125))
        original.startSession(name: "Compile", at: date(6.125))
        original.append(point(8.125))
        let archive = try PowerHistoryCore.decodeArchive(original.jsonData())
        var restored = PowerHistoryCore(archive: archive, now: date(100))
        XCTAssertEqual(restored.archive.points.first?.timestamp, date(0.125))
        restored.append(point(100)); restored.append(point(106))
        let finished = try XCTUnwrap(restored.endSession(at: date(106)))
        XCTAssertEqual(finished.summary.energyWh, 600 * 8 / 3600, accuracy: 0.000001)
        XCTAssertEqual(finished.summary.coveredSeconds, 8)
    }

    func testSessionEnergySurvivesHistoryPruning() throws {
        var core = history(maximumPoints: 2)
        core.startSession(name: "  Video export  ", at: date(0))
        for seconds in stride(from: 0.0, through: 30, by: 6) { core.append(point(seconds)) }
        XCTAssertEqual(core.archive.points.count, 2)
        let session = try XCTUnwrap(core.endSession(at: date(30)))
        XCTAssertEqual(session.name, "Video export")
        XCTAssertEqual(session.summary.energyWh, 5, accuracy: 0.000001)
        XCTAssertEqual(session.summary.coveredSeconds, 30)
        XCTAssertNil(core.archive.activeSession)
    }

    func testCSVQuotesCommasQuotesAndNewlinesAndPreservesUnknownFields() throws {
        var core = history()
        core.append(point(0, watts: nil, source: "chip,\"rail\"\nnext"))
        let csv = try XCTUnwrap(String(data: core.csvData(), encoding: .utf8))
        XCTAssertTrue(csv.contains("\"chip,\"\"rail\"\"\nnext\""))
        XCTAssertTrue(csv.contains(",,4.0,0.0,-12.0,"))
        XCTAssertTrue(csv.hasSuffix("\r\n"))
    }

    func testPerDomainMetadataPreservesIndependentMillisecondWindows() throws {
        var core = history()
        var entry = point(10.875)
        entry.cpuWindowStart = date(8.125)
        entry.cpuWindowEnd = date(10.125)
        entry.gpuWindowStart = date(7.250)
        entry.gpuWindowEnd = date(9.250)
        entry.cpuSource = "IOReport"
        entry.gpuSource = "powermetrics"
        entry.cpuQuality = .measured
        entry.gpuQuality = .stale
        core.append(entry)
        let restored = try PowerHistoryCore.decodeArchive(core.jsonData())
        XCTAssertEqual(restored.points.first, entry)
        let csv = try XCTUnwrap(String(data: core.csvData(), encoding: .utf8))
        let rows = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertEqual(rows[0].split(separator: ",", omittingEmptySubsequences: false).count, 19)
        XCTAssertEqual(rows[1].split(separator: ",", omittingEmptySubsequences: false).count, 19)
        XCTAssertTrue(rows[1].contains("1970-01-01T00:00:08.125Z"))
        XCTAssertTrue(rows[1].hasSuffix("\"IOReport\",\"powermetrics\",measured,stale"))
    }

    func testLegacyHistoryWithoutDomainMetadataDecodesAndExportsEmptyColumns() throws {
        var core = history()
        core.append(point(10))
        let data = try core.jsonData()
        let restored = try PowerHistoryCore.decodeArchive(data)
        XCTAssertNil(restored.points[0].cpuWindowStart)
        XCTAssertNil(restored.points[0].gpuSource)
        XCTAssertNil(restored.points[0].cpuQuality)
        let csv = try XCTUnwrap(String(data: core.csvData(), encoding: .utf8))
        let dataRow = csv.components(separatedBy: "\r\n")[1]
        XCTAssertEqual(dataRow.split(separator: ",", omittingEmptySubsequences: false).count, 19)
        XCTAssertTrue(dataRow.hasSuffix(",,,,,,,,"))
    }

    func testInvalidDomainWindowsDoNotDiscardValidPowerOrInventSystemWindow() {
        var core = history()
        var entry = point(10)
        entry.cpuWindowStart = date(.nan)
        entry.cpuWindowEnd = date(9)
        entry.gpuWindowStart = date(10)
        entry.gpuWindowEnd = date(11)
        core.append(entry)
        XCTAssertEqual(core.archive.points[0].cpuWatts, 4)
        XCTAssertNil(core.archive.points[0].cpuWindowStart)
        XCTAssertNil(core.archive.points[0].cpuWindowEnd)
        XCTAssertNil(core.archive.points[0].gpuWindowStart)
        XCTAssertNil(core.archive.points[0].gpuWindowEnd)
    }

    func testCapacityAndRetentionBoundRestoredHistory() {
        let archive = PowerHistoryArchive(points: [point(0), point(86_400), point(86_402), point(86_404)])
        let core = PowerHistoryCore(archive: archive, now: date(86_404), maximumPoints: 2)
        XCTAssertEqual(core.archive.points.map(\.timestamp), [date(86_402), date(86_404)])
    }

    func testEstimatesStayMarkedInSessionSummary() {
        var core = history()
        core.append(point(0, quality: .estimated)); core.append(point(6))
        XCTAssertTrue(core.summary(since: date(0), until: date(6)).includesEstimates)
    }
}
