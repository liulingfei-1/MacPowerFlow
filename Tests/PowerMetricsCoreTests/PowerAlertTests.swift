import XCTest
@testable import PowerMetricsCore

final class PowerAlertTests: XCTestCase {
    private func observation(
        _ seconds: Double,
        watts: Double? = 60,
        battery: Int? = 80,
        onAC: Bool = true,
        signedBattery: Double? = 3,
        thermal: PowerAlertThermalLevel = .nominal
    ) -> PowerAlertObservation {
        PowerAlertObservation(
            date: Date(timeIntervalSince1970: seconds), isOnAC: onAC,
            batteryLevel: battery, signedBatteryWatts: signedBattery,
            systemWatts: watts, thermalLevel: thermal
        )
    }

    func testHighPowerRequiresThirtySecondsOfContinuousSamples() {
        var rules = PowerAlertRules()
        for second in stride(from: 0.0, through: 25, by: 5) {
            XCTAssertTrue(rules.observe(observation(second)).isEmpty)
        }
        let events = rules.observe(observation(30))
        XCTAssertEqual(events.map(\.kind), [.highPower])
        XCTAssertEqual(events.first?.threshold, 50)
        XCTAssertEqual(events.first?.observedValue, 60)
    }

    func testShortSpikeDoesNotAlert() {
        var rules = PowerAlertRules()
        for second in stride(from: 0.0, through: 25, by: 5) {
            XCTAssertTrue(rules.observe(observation(second)).isEmpty)
        }
        XCTAssertTrue(rules.observe(observation(30, watts: 10)).isEmpty)
        for second in stride(from: 35.0, through: 60, by: 5) {
            XCTAssertTrue(rules.observe(observation(second)).isEmpty)
        }
        XCTAssertEqual(rules.observe(observation(65)).map(\.kind), [.highPower])
    }

    func testMissingAndInvalidPowerResetContinuityInsteadOfBecomingZero() {
        for invalid in [nil, Double.nan, .infinity, -1, 2_001] as [Double?] {
            var rules = PowerAlertRules()
            for second in stride(from: 0.0, through: 25, by: 5) {
                _ = rules.observe(observation(second))
            }
            XCTAssertTrue(rules.observe(observation(30, watts: invalid)).isEmpty)
            for second in stride(from: 35.0, through: 60, by: 5) {
                XCTAssertTrue(rules.observe(observation(second)).isEmpty)
            }
        }
    }

    func testLongSamplingGapDoesNotProveSustainedCondition() {
        var rules = PowerAlertRules()
        _ = rules.observe(observation(0))
        XCTAssertTrue(rules.observe(observation(30)).isEmpty)
        XCTAssertTrue(rules.observe(observation(40)).isEmpty)
        XCTAssertTrue(rules.observe(observation(50)).isEmpty)
        XCTAssertEqual(rules.observe(observation(60)).map(\.kind), [.highPower])
    }

    func testBackwardAndDuplicateDatesResetPendingState() {
        for date in [15.0, 20.0] {
            var rules = PowerAlertRules()
            _ = rules.observe(observation(0))
            _ = rules.observe(observation(10))
            _ = rules.observe(observation(20))
            XCTAssertTrue(rules.observe(observation(date)).isEmpty)
            XCTAssertTrue(rules.observe(observation(25)).isEmpty)
            XCTAssertTrue(rules.observe(observation(35)).isEmpty)
            XCTAssertTrue(rules.observe(observation(45)).isEmpty)
            XCTAssertEqual(rules.observe(observation(55)).map(\.kind), [.highPower])
        }
    }

    func testNonfiniteDateNeverTriggers() {
        var rules = PowerAlertRules()
        XCTAssertTrue(rules.observe(observation(.nan)).isEmpty)
        XCTAssertTrue(rules.observe(observation(.infinity)).isEmpty)
        XCTAssertTrue(rules.observe(observation(0)).isEmpty)
    }

    func testCooldownIsAtLeastTenMinutesForEachKind() {
        var rules = PowerAlertRules()
        var triggers: [Double] = []
        for second in stride(from: 0.0, through: 635, by: 5) {
            for event in rules.observe(observation(second)) {
                if event.kind == .highPower { triggers.append(second) }
            }
        }
        XCTAssertEqual(triggers, [30, 630])
    }

    func testDisabledResetKeepsCooldownButDropsPendingState() {
        var rules = PowerAlertRules()
        for second in stride(from: 0.0, through: 30, by: 5) {
            _ = rules.observe(observation(second))
        }
        rules.resetPending()
        for second in stride(from: 40.0, through: 100, by: 5) {
            XCTAssertTrue(rules.observe(observation(second)).isEmpty)
        }
    }

    func testACSupplementNeedsSignedDischargeAndAvoidsTinyNoise() {
        for signed in [nil, Double.nan, 2, -1.99, -501] as [Double?] {
            var rules = PowerAlertRules()
            for second in stride(from: 0.0, through: 40, by: 5) {
                XCTAssertTrue(rules.observe(observation(second, watts: 10, signedBattery: signed)).isEmpty)
            }
        }
        var rules = PowerAlertRules()
        var events: [PowerAlertEvent] = []
        for second in stride(from: 0.0, through: 30, by: 5) {
            events += rules.observe(observation(second, watts: 10, signedBattery: -2))
        }
        XCTAssertEqual(events.map(\.kind), [.batteryAssist])
        XCTAssertEqual(events.first?.observedValue, 2)
    }

    func testOrdinaryBatteryDischargeIsNotACSupplement() {
        var rules = PowerAlertRules()
        for second in stride(from: 0.0, through: 40, by: 5) {
            XCTAssertTrue(rules.observe(observation(second, watts: 10, onAC: false, signedBattery: -10)).isEmpty)
        }
    }

    func testLowBatteryOnlyWhileUsingBatteryAndIncludesTrueZero() {
        for level in [0, 20] {
            var rules = PowerAlertRules()
            var events: [PowerAlertEvent] = []
            for second in stride(from: 0.0, through: 30, by: 5) {
                events += rules.observe(observation(second, watts: 10, battery: level, onAC: false))
            }
            XCTAssertEqual(events.map(\.kind), [.lowBattery])
        }
        for level in [nil, -1, 21, 101] as [Int?] {
            var rules = PowerAlertRules()
            for second in stride(from: 0.0, through: 40, by: 5) {
                XCTAssertTrue(rules.observe(observation(second, watts: 10, battery: level, onAC: false)).isEmpty)
            }
        }
        var pluggedIn = PowerAlertRules()
        for second in stride(from: 0.0, through: 40, by: 5) {
            XCTAssertTrue(pluggedIn.observe(observation(second, watts: 10, battery: 10, onAC: true)).isEmpty)
        }
    }

    func testThermalSeriousAndCriticalShareContinuousWindow() {
        var rules = PowerAlertRules()
        for second in stride(from: 0.0, through: 25, by: 5) {
            XCTAssertTrue(rules.observe(observation(second, watts: nil, thermal: .serious)).isEmpty)
        }
        XCTAssertEqual(rules.observe(observation(30, watts: nil, thermal: .critical)).map(\.kind), [.thermal])
    }

    func testFairThermalPressureDoesNotAlert() {
        var rules = PowerAlertRules()
        for second in stride(from: 0.0, through: 40, by: 5) {
            XCTAssertTrue(rules.observe(observation(second, watts: 10, thermal: .fair)).isEmpty)
        }
    }

    func testKindsHaveIndependentCooldowns() {
        var rules = PowerAlertRules()
        for second in stride(from: 0.0, through: 30, by: 5) { _ = rules.observe(observation(second)) }
        var next: [PowerAlertEvent] = []
        for second in stride(from: 35.0, through: 65, by: 5) {
            next += rules.observe(observation(second, thermal: .serious))
        }
        XCTAssertEqual(next.map(\.kind), [.thermal])
    }

    func testThresholdChangeRestartsOnlyHighPowerPendingWindow() {
        var rules = PowerAlertRules()
        for second in stride(from: 0.0, through: 25, by: 5) { _ = rules.observe(observation(second)) }
        rules.setHighPowerThreshold(55)
        XCTAssertTrue(rules.observe(observation(30)).isEmpty)
        for second in stride(from: 35.0, through: 55, by: 5) { XCTAssertTrue(rules.observe(observation(second)).isEmpty) }
        XCTAssertEqual(rules.observe(observation(60)).first?.threshold, 55)
        rules.setHighPowerThreshold(.nan)
        XCTAssertEqual(rules.highPowerThreshold, 50)
        rules.setHighPowerThreshold(-1)
        XCTAssertEqual(rules.highPowerThreshold, 1)
    }
}
