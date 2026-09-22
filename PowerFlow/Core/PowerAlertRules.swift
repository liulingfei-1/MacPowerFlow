import Foundation

nonisolated enum PowerAlertKind: String, Sendable, CaseIterable {
    case highPower, lowBattery, thermal, batteryAssist
}

nonisolated enum PowerAlertThermalLevel: Sendable {
    case nominal, fair, serious, critical
}

nonisolated struct PowerAlertObservation: Sendable {
    let date: Date
    let isOnAC: Bool
    let batteryLevel: Int?
    /// Positive = charging; negative = battery supplying power.
    let signedBatteryWatts: Double?
    let systemWatts: Double?
    let thermalLevel: PowerAlertThermalLevel
}

nonisolated struct PowerAlertEvent: Sendable, Equatable {
    let kind: PowerAlertKind
    let date: Date
    let observedValue: Double?
    let threshold: Double?
}

/// Pure, deterministic local alert policy. The notification permission/lifecycle
/// layer is intentionally separate so tests cannot ask for system permission.
nonisolated struct PowerAlertRules: Sendable {
    private(set) var highPowerThreshold: Double
    private let requiredDuration: TimeInterval = 30
    private let cooldown: TimeInterval = 600
    private let maximumSampleGap: TimeInterval = 15
    private var previousDate: Date?
    private var activeSince: [PowerAlertKind: Date] = [:]
    private var lastTriggered: [PowerAlertKind: Date] = [:]

    init(highPowerThreshold: Double = 50) {
        self.highPowerThreshold = Self.normalizedThreshold(highPowerThreshold)
    }

    static func normalizedThreshold(_ value: Double) -> Double {
        value.isFinite ? min(2_000, max(1, value)) : 50
    }

    mutating func setHighPowerThreshold(_ value: Double) {
        let threshold = Self.normalizedThreshold(value)
        guard threshold != highPowerThreshold else { return }
        highPowerThreshold = threshold
        activeSince.removeValue(forKey: .highPower)
    }

    /// Reset continuity when disabled or resumed; preserve cooldown so toggling
    /// or clock changes cannot generate repeated notifications.
    mutating func resetPending() {
        previousDate = nil
        activeSince.removeAll()
    }

    mutating func observe(_ observation: PowerAlertObservation) -> [PowerAlertEvent] {
        let now = observation.date
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            resetPending()
            return []
        }
        if let previousDate {
            let gap = now.timeIntervalSince(previousDate)
            if gap <= 0 {
                // Repeated/out-of-order timestamps do not contribute duration
                // and must not restart an already-fired cooldown.
                resetPending()
                self.previousDate = now
                return []
            }
            if gap > maximumSampleGap {
                activeSince.removeAll()
            }
        }
        previousDate = now

        let systemPower = observation.systemWatts.flatMap {
            $0.isFinite && $0 >= 0 && $0 <= 2_000 ? $0 : nil
        }
        let batteryPower = observation.signedBatteryWatts.flatMap {
            $0.isFinite && abs($0) <= 500 ? $0 : nil
        }
        let batteryLevel = observation.batteryLevel.flatMap {
            (0...100).contains($0) ? $0 : nil
        }
        let thermalHigh = observation.thermalLevel == .serious
            || observation.thermalLevel == .critical
        let conditions: [(PowerAlertKind, Bool, Double?, Double?)] = [
            (.highPower, systemPower.map { $0 >= highPowerThreshold } ?? false,
             systemPower, highPowerThreshold),
            (.lowBattery, !observation.isOnAC && (batteryLevel.map { $0 <= 20 } ?? false),
             batteryLevel.map(Double.init), 20),
            (.thermal, thermalHigh, nil, nil),
            (.batteryAssist, observation.isOnAC && (batteryPower.map { $0 <= -2 } ?? false),
             batteryPower.map { abs($0) }, 2)
        ]
        var events: [PowerAlertEvent] = []
        for (kind, condition, value, threshold) in conditions {
            guard condition else {
                activeSince.removeValue(forKey: kind)
                continue
            }
            let start = activeSince[kind] ?? now
            activeSince[kind] = start
            guard now.timeIntervalSince(start) >= requiredDuration else { continue }
            if let last = lastTriggered[kind], now.timeIntervalSince(last) < cooldown {
                continue
            }
            lastTriggered[kind] = now
            events.append(PowerAlertEvent(kind: kind, date: now, observedValue: value, threshold: threshold))
        }
        return events
    }
}
