import Foundation
import IOKit
import IOKit.ps

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
    var telemetryBatteryPowerWatts = 0.0
    var hasTelemetryBatteryPower = false
    var hasPowerTelemetryBalance = false
    var packBatteryChargeWatts = 0.0
    var systemInputVoltage = 0.0
    var systemInputCurrent = 0.0
    var adapterEfficiencyLossWatts = 0.0
    var externalPowerOutWatts = 0.0

    var adapterRatedWatts = 0.0
    var adapterVoltage = 0.0
    var adapterCurrent = 0.0
    var adapterName = ""

    var timeDescription: String {
        if isCharging {
            return formattedMinutes(timeToFullMinutes)
        }
        if isFullyCharged { return "已充满" }
        if isOnAC { return "已接电源 · 未充电" }
        return formattedMinutes(timeToEmptyMinutes)
    }

    var timeToFullDescription: String {
        formattedMinutes(timeToFullMinutes)
    }

    private func formattedMinutes(_ minutes: Int) -> String {
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
        let powerSource = readPowerSourceState()
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
        let registryLevel = int(property("CurrentCapacity"))
            ?? int(batteryData["CurrentCapacity"])
        result.level = normalizedLevel(
            registryLevel: registryLevel,
            powerSourceCurrent: powerSource.currentCapacity,
            powerSourceMaximum: powerSource.maximumCapacity
        )

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
        let fullCharge = firstInt("FullChargeCapacity")
        let nominal = firstInt("NominalChargeCapacity")
        result.fullCapacityMAh = rawMax > 0
            ? rawMax
            : (fullCharge > 0 ? fullCharge : nominal)
        result.designCapacityMAh = firstInt("DesignCapacity")
        let healthCapacity = nominal > 0 ? nominal : result.fullCapacityMAh
        if result.designCapacityMAh > 0 {
            result.healthPercent = min(
                100,
                Int((Double(healthCapacity) / Double(result.designCapacityMAh) * 100).rounded())
            )
        }

        result.timeToFullMinutes = firstPositiveInt(
            firstInt("AvgTimeToFull"),
            powerSource.timeToFullMinutes
        )
        result.timeToEmptyMinutes = firstPositiveInt(
            firstInt("AvgTimeToEmpty"),
            powerSource.timeToEmptyMinutes
        )
        if result.timeToEmptyMinutes == 0 {
            result.timeToEmptyMinutes = firstInt("TimeRemaining", fallback: [:])
        }

        result.adapterRatedWatts = number(adapter["Watts"])
        result.adapterVoltage = number(adapter["AdapterVoltage"]) / 1000.0
        result.adapterCurrent = number(adapter["Current"]) / 1000.0
        result.adapterName = string(adapter["Name"])
            ?? string(adapter["Description"])
            ?? ""

        let telemetrySystemInputMW = numberValue(telemetry["SystemPowerIn"])
        let telemetrySystemLoadMW = numberValue(telemetry["SystemLoad"])
        result.systemInputWatts = saneWholeSystemPower(
            (telemetrySystemInputMW ?? 0) / 1000.0
        )
        result.systemLoadWatts = saneWholeSystemPower(
            (telemetrySystemLoadMW ?? 0) / 1000.0
        )
        result.systemInputVoltage = number(telemetry["SystemVoltageIn"]) / 1000.0
        result.systemInputCurrent = number(telemetry["SystemCurrentIn"]) / 1000.0
        result.adapterEfficiencyLossWatts = number(telemetry["AdapterEfficiencyLoss"]) / 1000.0

        let telemetryBatteryMW = signedNumber(telemetry["BatteryPower"])
        let signedTelemetryPowerWatts = (telemetryBatteryMW ?? 0) / 1000.0
        if telemetryBatteryMW != nil,
           signedTelemetryPowerWatts.isFinite,
           abs(signedTelemetryPowerWatts) < 200 {
            result.telemetryBatteryPowerWatts = signedTelemetryPowerWatts
            result.hasTelemetryBatteryPower = true
        }
        let telemetryResidual = result.systemInputWatts
            - result.systemLoadWatts
        let telemetryTolerance = max(
            0.25,
            result.systemInputWatts * 0.02
        )
        result.hasPowerTelemetryBalance =
            telemetrySystemInputMW != nil
                && telemetrySystemLoadMW != nil
                && result.hasTelemetryBatteryPower
                && result.systemInputWatts > 0.02
                && result.systemInputWatts >= result.systemLoadWatts
                && abs(
                    telemetryResidual - result.telemetryBatteryPowerWatts
                ) <= telemetryTolerance
        let rawBatteryVoltage = Double(firstInt("Voltage"))
        let rawBatteryCurrent = Double(
            signedInt(property("InstantAmperage"))
                ?? signedInt(property("Amperage"))
                ?? 0
        )
        result.batteryVoltage = rawBatteryVoltage / 1000.0
        result.batteryCurrent = rawBatteryCurrent / 1000.0
        let chargingVoltage = number(chargerData["ChargingVoltage"])
        let chargingCurrent = number(chargerData["ChargingCurrent"])
        let gaugePowerWatts = saneBatteryPower(
            rawBatteryVoltage * rawBatteryCurrent / 1_000_000.0
        )
        let telemetryPowerWatts = saneBatteryPower(
            (telemetryBatteryMW ?? 0) / 1_000.0
        )
        let packBatteryPowerWatts = firstPositive(
            gaugePowerWatts,
            saneBatteryPower(
                rawBatteryVoltage * chargingCurrent / 1_000_000.0
            ),
            saneBatteryPower(
                chargingVoltage * chargingCurrent / 1_000_000.0
            )
        )
        result.packBatteryChargeWatts = packBatteryPowerWatts
        let resolvedState = BatteryStateCore.resolve(
            BatteryStateSignals(
                registryIsCharging: bool(property("IsCharging")) ?? false,
                chargerIsCharging: bool(chargerData["IsCharging"]) ?? false,
                powerSourcesIsCharging: powerSource.isCharging,
                registryFullyCharged: (bool(property("FullyCharged")) ?? false)
                    || (bool(batteryData["FullyCharged"]) ?? false),
                powerSourcesFullyCharged: powerSource.isFullyCharged,
                registryOnAC: bool(property("ExternalConnected")) ?? false,
                rawRegistryOnAC: bool(property("AppleRawExternalConnected"))
                    ?? false,
                powerSourcesOnAC: powerSource.isOnAC,
                chargingCurrentMilliamps: chargingCurrent,
                hasMeasuredBatteryPower: gaugePowerWatts > 0.02
                    || telemetryPowerWatts > 0.02
            )
        )
        result.isCharging = resolvedState.isCharging
        result.isFullyCharged = resolvedState.isFullyCharged
        result.isOnAC = resolvedState.isOnAC

        if result.isCharging {
            result.batteryFlowWatts = firstPositive(
                result.hasPowerTelemetryBalance ? telemetryPowerWatts : 0,
                packBatteryPowerWatts
            )
        } else if !result.isOnAC {
            result.batteryFlowWatts = firstPositive(
                telemetryPowerWatts,
                gaugePowerWatts
            )
        } else {
            result.batteryFlowWatts = 0
        }

        result.externalPowerOutWatts = readExternalPower(property("PowerOutDetails"))
        return result
    }

    private nonisolated struct PowerSourceState {
        var isCharging = false
        var isFullyCharged = false
        var isOnAC = false
        var currentCapacity = 0
        var maximumCapacity = 0
        var timeToFullMinutes = 0
        var timeToEmptyMinutes = 0
    }

    /// IOPowerSources is Apple's public, normalized view of the same battery.
    /// Use it as a second signal because it can update before or after the raw
    /// AppleSmartBattery properties during a charge-state transition.
    nonisolated private static func readPowerSourceState() -> PowerSourceState {
        guard let unmanagedBlob = IOPSCopyPowerSourcesInfo() else {
            return PowerSourceState()
        }
        let blob = unmanagedBlob.takeRetainedValue()
        guard let unmanagedSources = IOPSCopyPowerSourcesList(blob) else {
            return PowerSourceState()
        }
        let sources = unmanagedSources.takeRetainedValue() as Array

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)
                .takeUnretainedValue() as? [String: Any],
                (description["Type"] as? String) == "InternalBattery" else {
                continue
            }

            return PowerSourceState(
                isCharging: bool(description["Is Charging"]) ?? false,
                isFullyCharged: bool(description["Is Charged"]) ?? false,
                isOnAC: (description["Power Source State"] as? String)
                    == "AC Power",
                currentCapacity: int(description["Current Capacity"]) ?? 0,
                maximumCapacity: int(description["Max Capacity"]) ?? 0,
                timeToFullMinutes: int(description["Time to Full Charge"]) ?? 0,
                timeToEmptyMinutes: int(description["Time to Empty"]) ?? 0
            )
        }
        return PowerSourceState()
    }

    nonisolated private static func normalizedLevel(
        registryLevel: Int?,
        powerSourceCurrent: Int,
        powerSourceMaximum: Int
    ) -> Int {
        if let registryLevel, (0...100).contains(registryLevel) {
            return registryLevel
        }
        guard powerSourceCurrent >= 0, powerSourceMaximum > 0 else { return 0 }
        return min(
            100,
            max(0, Int((Double(powerSourceCurrent) / Double(powerSourceMaximum) * 100).rounded()))
        )
    }

    nonisolated private static func firstPositiveInt(_ values: Int...) -> Int {
        values.first { $0 > 0 && $0 < 65_535 } ?? 0
    }

    nonisolated private static func firstPositive(_ values: Double...) -> Double {
        values.first { $0.isFinite && $0 > 0.02 } ?? 0
    }

    nonisolated private static func saneBatteryPower(_ value: Double) -> Double {
        let magnitude = abs(value)
        return magnitude.isFinite && magnitude < 200 ? magnitude : 0
    }

    nonisolated private static func saneWholeSystemPower(
        _ value: Double
    ) -> Double {
        value.isFinite && value >= 0 && value < 1_000 ? value : 0
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

    nonisolated private static func numberValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        return nil
    }

    nonisolated private static func signedNumber(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return Double(number.int64Value) }
        if let value = value as? Int64 { return Double(value) }
        if let value = value as? Int { return Double(value) }
        return nil
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
