import Foundation
import IOKit

nonisolated struct BatterySnapshot: Sendable {
    var isPresent = false
    var level = 0
    var isCharging = false
    var isFullyCharged = false
    var isOnAC = false

    var temperatureC = 0.0
    var cycleCount = 0
    var currentCapacityMAh = 0
    var fullCapacityMAh = 0
    var designCapacityMAh = 0
    var healthPercent = 0

    var timeToFullMinutes = 0
    var timeToEmptyMinutes = 0

    /// Positive means energy is flowing into or out of the battery, with the
    /// direction described by `isCharging` / `isOnAC`.
    var batteryFlowWatts = 0.0
    var batteryVoltage = 0.0
    var batteryCurrent = 0.0
    var systemLoadWatts = 0.0
    var systemInputWatts = 0.0
    var adapterEfficiencyLossWatts = 0.0
    var externalPowerOutWatts = 0.0

    var adapterRatedWatts = 0.0
    var adapterVoltage = 0.0
    var adapterCurrent = 0.0
    var adapterName = ""

    var timeDescription: String {
        if isFullyCharged { return "已充满" }
        let minutes = isCharging ? timeToFullMinutes : timeToEmptyMinutes
        guard minutes > 0, minutes < 65_535 else { return "正在计算" }
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(remainder) 分钟" }
        if remainder == 0 { return "\(hours) 小时" }
        return "\(hours) 小时 \(remainder) 分钟"
    }
}

enum BatteryReader {
    nonisolated static func read() -> BatterySnapshot {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard service != 0 else { return BatterySnapshot() }
        defer { IOObjectRelease(service) }

        // Fetch properties one at a time. This avoids deserializing unrelated
        // large blobs and mirrors the defensive approach used by WhatBattery.
        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(
                service,
                key as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue()
        }

        let batteryData = property("BatteryData") as? [String: Any] ?? [:]
        let chargerData = property("ChargerData") as? [String: Any] ?? [:]
        let adapter = property("AdapterDetails") as? [String: Any] ?? [:]
        let telemetry = property("PowerTelemetryData") as? [String: Any] ?? [:]

        func firstInt(_ key: String, fallback: [String: Any] = batteryData) -> Int {
            if let value = int(property(key)), value != 0 { return value }
            return int(fallback[key]) ?? 0
        }

        let installed = bool(property("BatteryInstalled"))
            ?? (firstInt("DesignCapacity") > 0)
        guard installed else { return BatterySnapshot() }

        var result = BatterySnapshot()
        result.isPresent = true
        result.level = firstInt("CurrentCapacity")
        result.isCharging = (bool(property("IsCharging")) ?? false)
            || (bool(chargerData["IsCharging"]) ?? false)
        result.isFullyCharged = (bool(property("FullyCharged")) ?? false)
            || (bool(batteryData["FullyCharged"]) ?? false)
        result.isOnAC = (bool(property("ExternalConnected")) ?? false)

        let virtualTemperature = int(property("VirtualTemperature"))
            ?? int(batteryData["VirtualTemperature"])
            ?? 0
        let nestedTemperature = int(batteryData["Temperature"]) ?? 0
        let smartBatteryTemperature = int(property("Temperature")) ?? 0
        if virtualTemperature > 0 {
            // Apple Silicon virtual/nested readings are centi-degrees Celsius.
            result.temperatureC = Double(virtualTemperature) / 100.0
        } else if nestedTemperature > 0 {
            result.temperatureC = Double(nestedTemperature) / 100.0
        } else if smartBatteryTemperature > 0 {
            // The public SmartBattery Temperature key follows the ACPI unit:
            // tenths of Kelvin.
            result.temperatureC = Double(smartBatteryTemperature) / 10.0 - 273.15
        }
        result.cycleCount = firstInt("CycleCount")
        let rawCurrent = firstInt("AppleRawCurrentCapacity")
        result.currentCapacityMAh = rawCurrent > 0
            ? rawCurrent
            : (int(batteryData["RemainingCapacity"]) ?? 0)

        let rawMax = firstInt("AppleRawMaxCapacity")
        let nominal = firstInt("NominalChargeCapacity")
        result.fullCapacityMAh = rawMax > 0 ? rawMax : nominal
        result.designCapacityMAh = firstInt("DesignCapacity")
        let healthCapacity = nominal > 0 ? nominal : result.fullCapacityMAh
        if result.designCapacityMAh > 0 {
            result.healthPercent = min(
                100,
                Int((Double(healthCapacity) / Double(result.designCapacityMAh) * 100).rounded())
            )
        }

        result.timeToFullMinutes = firstInt("AvgTimeToFull")
        result.timeToEmptyMinutes = firstInt("AvgTimeToEmpty")
        if result.timeToEmptyMinutes == 0 {
            result.timeToEmptyMinutes = firstInt("TimeRemaining", fallback: [:])
        }

        result.adapterRatedWatts = number(adapter["Watts"])
        result.adapterVoltage = number(adapter["AdapterVoltage"]) / 1000.0
        result.adapterCurrent = number(adapter["Current"]) / 1000.0
        result.adapterName = string(adapter["Name"])
            ?? string(adapter["Description"])
            ?? ""

        result.systemInputWatts = number(telemetry["SystemPowerIn"]) / 1000.0
        result.systemLoadWatts = number(telemetry["SystemLoad"]) / 1000.0
        result.adapterEfficiencyLossWatts = number(telemetry["AdapterEfficiencyLoss"]) / 1000.0

        let telemetryBatteryMW = signedNumber(telemetry["BatteryPower"])
        let rawBatteryVoltage = Double(firstInt("Voltage"))
        let rawBatteryCurrent = Double(
            signedInt(property("InstantAmperage"))
                ?? signedInt(property("Amperage"))
                ?? 0
        )
        result.batteryVoltage = rawBatteryVoltage / 1000.0
        result.batteryCurrent = rawBatteryCurrent / 1000.0
        if abs(telemetryBatteryMW) > 0.5 {
            result.batteryFlowWatts = abs(telemetryBatteryMW) / 1000.0
        } else if result.isCharging {
            let chargingVoltage = number(chargerData["ChargingVoltage"])
            let chargingCurrent = number(chargerData["ChargingCurrent"])
            result.batteryFlowWatts = abs(chargingVoltage * chargingCurrent) / 1_000_000.0
        } else if !result.isOnAC {
            result.batteryFlowWatts =
                rawBatteryVoltage * abs(rawBatteryCurrent) / 1_000_000.0
        }

        result.externalPowerOutWatts = readExternalPower(property("PowerOutDetails"))
        return result
    }

    nonisolated private static func readExternalPower(_ value: Any?) -> Double {
        let entries: [[String: Any]]
        if let array = value as? [[String: Any]] {
            entries = array
        } else if let dictionary = value as? [String: Any] {
            entries = [dictionary]
        } else {
            return 0
        }

        return entries.reduce(0) { partial, item in
            // `Watts` is the live value on current Apple Silicon releases.
            // Older/private schemas can expose only `PDPowermW`; do not use it
            // when a present `Watts` field is legitimately zero.
            let raw = number(item["Watts"] ?? item["PDPowermW"])
            return partial + raw / 1000.0
        }
    }

    nonisolated private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let value = value as? Int { return value }
        return nil
    }

    nonisolated private static func signedInt(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return value as? Int
    }

    nonisolated private static func number(_ value: Any?) -> Double {
        if let number = value as? NSNumber { return number.doubleValue }
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        return 0
    }

    nonisolated private static func signedNumber(_ value: Any?) -> Double {
        if let number = value as? NSNumber { return Double(number.int64Value) }
        if let value = value as? Int64 { return Double(value) }
        if let value = value as? Int { return Double(value) }
        return 0
    }

    nonisolated private static func bool(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber { return number.boolValue }
        return value as? Bool
    }

    nonisolated private static func string(_ value: Any?) -> String? {
        let raw: String?
        if let value = value as? String {
            raw = value
        } else if let number = value as? NSNumber {
            raw = number.stringValue
        } else {
            raw = nil
        }
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
