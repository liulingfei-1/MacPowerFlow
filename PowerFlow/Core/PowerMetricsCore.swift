import Foundation

nonisolated struct ProcessorPowerAllocation: Equatable, Sendable {
    let cpuWatts: Double
    let gpuWatts: Double
}

nonisolated enum ChargingPowerBalanceSource: Equatable, Sendable {
    case powerTelemetry
    case smcPDTRPSTR
    case adapterAndBattery
    case systemAndBattery
    case unavailable
}

nonisolated struct ChargingPowerBalance: Equatable, Sendable {
    let adapterInputWatts: Double
    let systemLoadWatts: Double
    let batteryChargeWatts: Double
    let source: ChargingPowerBalanceSource
}

/// Pure power-sample reconciliation shared by the app and regression tests.
///
/// `powermetrics` can publish partial frames and, on some macOS / chip
/// combinations, a transient zero `*_power` while the matching `*_energy`
/// counter is still valid. Keep that platform quirk out of the UI model.
nonisolated enum PowerMetricsCore {
    static let minimumMeaningfulPowerWatts = 0.02

    /// Extracts one powermetrics domain from the plist dictionaries. Current
    /// macOS versions normally nest these fields under `processor`; keeping a
    /// root fallback also supports older output layouts.
    static func resolvedSamplePowerWatts(
        domain: String,
        processor: [String: Any],
        root: [String: Any]
    ) -> Double? {
        func number(_ key: String) -> Double? {
            numberValue(processor[key]) ?? numberValue(root[key])
        }

        return resolvedSamplePowerWatts(
            directMilliwatts: number("\(domain)_power"),
            energyMillijoules: number("\(domain)_energy"),
            elapsedNanoseconds: numberValue(root["elapsed_ns"])
        )
    }

    /// Resolves average watts from the direct mW field, then falls back to the
    /// energy accumulated over the same sampling window.
    static func resolvedSamplePowerWatts(
        directMilliwatts: Double?,
        energyMillijoules: Double?,
        elapsedNanoseconds: Double?
    ) -> Double? {
        let directWatts = finiteNonnegative(directMilliwatts).map { $0 / 1_000 }
        let energyWatts = averagePowerWatts(
            energyMillijoules: energyMillijoules,
            elapsedNanoseconds: elapsedNanoseconds
        )

        if let directWatts,
           directWatts > minimumMeaningfulPowerWatts {
            return directWatts
        }
        if let energyWatts,
           energyWatts > minimumMeaningfulPowerWatts {
            return energyWatts
        }
        return directWatts ?? energyWatts
    }

    /// Converts mJ measured over a nanosecond interval to average watts.
    static func averagePowerWatts(
        energyMillijoules: Double?,
        elapsedNanoseconds: Double?
    ) -> Double? {
        guard let energy = finiteNonnegative(energyMillijoules),
              let elapsed = finiteNonnegative(elapsedNanoseconds),
              elapsed > 0 else {
            return nil
        }

        let watts = energy * 1_000_000 / elapsed
        return watts.isFinite ? watts : nil
    }

    /// Chooses the first useful power source. A zero from a higher-priority
    /// source is treated as an empty partial frame rather than suppressing a
    /// valid lower-priority measurement or estimate.
    static func firstMeaningfulPowerWatts(
        _ candidates: [Double?]
    ) -> Double {
        for candidate in candidates {
            guard let value = finiteNonnegative(candidate) else { continue }
            if value > minimumMeaningfulPowerWatts {
                return value
            }
        }
        return 0
    }

    /// Fits CPU and GPU into their shared processor budget without always
    /// sacrificing the CPU merely because the GPU candidate was evaluated
    /// first. Cross-sampler overshoot is reduced proportionally.
    static func allocateProcessorPower(
        cpuCandidateWatts: Double,
        gpuCandidateWatts: Double,
        budgetWatts: Double
    ) -> ProcessorPowerAllocation {
        let cpu = finiteNonnegative(cpuCandidateWatts) ?? 0
        let gpu = finiteNonnegative(gpuCandidateWatts) ?? 0
        let budget = finiteNonnegative(budgetWatts) ?? 0
        guard budget > minimumMeaningfulPowerWatts else {
            return ProcessorPowerAllocation(cpuWatts: 0, gpuWatts: 0)
        }

        let total = cpu + gpu
        guard total > budget, total > 0 else {
            return ProcessorPowerAllocation(
                cpuWatts: min(cpu, budget),
                gpuWatts: min(gpu, budget)
            )
        }

        let scale = budget / total
        return ProcessorPowerAllocation(
            cpuWatts: cpu * scale,
            gpuWatts: gpu * scale
        )
    }

    /// Produces one internally coherent charging tuple for the energy-flow UI.
    ///
    /// A complete PowerTelemetryData tuple is atomic and therefore wins when
    /// all three values reconcile. PDTR and PSTR provide the faster live
    /// fallback; their difference is the charge branch. PPBR is intentionally
    /// not used: on affected MacBook Pro hardware it is a discharge rail that
    /// stays near 1 W while the pack is accepting tens of watts.
    static func resolveChargingPowerBalance(
        smcPDTRWatts: Double?,
        smcPSTRWatts: Double?,
        smcPPBRWatts: Double?,
        telemetrySystemPowerInWatts: Double?,
        telemetrySystemLoadWatts: Double?,
        telemetryBatteryPowerWatts: Double?,
        packBatteryChargeWatts: Double?
    ) -> ChargingPowerBalance {
        let telemetry = validatedTelemetryChargingBalance(
            inputWatts: telemetrySystemPowerInWatts,
            loadWatts: telemetrySystemLoadWatts,
            batteryWatts: telemetryBatteryPowerWatts
        )
        if let telemetry {
            return telemetry
        }

        let telemetryInput = meaningfulPower(telemetrySystemPowerInWatts)
        let telemetryLoad = meaningfulPower(telemetrySystemLoadWatts)
        let smcInput = meaningfulPower(smcPDTRWatts)
        let smcLoad = meaningfulPower(smcPSTRWatts)
        let packCharge = meaningfulPower(packBatteryChargeWatts)

        if let telemetryInput,
           let telemetryLoad,
           telemetryInput >= telemetryLoad {
            return reconcileInputAndLoad(
                inputWatts: telemetryInput,
                loadWatts: telemetryLoad,
                packChargeWatts: packCharge,
                source: .powerTelemetry
            )
        }

        if let smcInput, let smcLoad, smcInput >= smcLoad {
            return reconcileInputAndLoad(
                inputWatts: smcInput,
                loadWatts: smcLoad,
                packChargeWatts: packCharge,
                source: .smcPDTRPSTR
            )
        }

        // If one whole-system leg is missing, combine the remaining live leg
        // with an independently measured whole-pack charge magnitude and derive
        // the third value. Publishing a derived coherent tuple is preferable to
        // mixing three asynchronous values in the energy-flow diagram.
        if let input = telemetryInput ?? smcInput,
           let packCharge,
           input >= packCharge {
            return ChargingPowerBalance(
                adapterInputWatts: input,
                systemLoadWatts: input - packCharge,
                batteryChargeWatts: packCharge,
                source: .adapterAndBattery
            )
        }
        if let load = telemetryLoad ?? smcLoad, let packCharge {
            return ChargingPowerBalance(
                adapterInputWatts: load + packCharge,
                systemLoadWatts: load,
                batteryChargeWatts: packCharge,
                source: .systemAndBattery
            )
        }

        // Keep PPBR in the API so regression tests can prove that a tempting
        // nonzero value never becomes charging power again.
        _ = smcPPBRWatts
        return ChargingPowerBalance(
            adapterInputWatts: 0,
            systemLoadWatts: 0,
            batteryChargeWatts: 0,
            source: .unavailable
        )
    }

    /// CHCC is allowed to recover a missing boolean only when a second,
    /// direction-aware signal confirms meaningful charging power. A stale
    /// BatteryPower field that no longer reconciles with its own telemetry
    /// tuple is not sufficient evidence.
    static func hasCorroboratedChargingPower(
        telemetrySystemPowerInWatts: Double?,
        telemetrySystemLoadWatts: Double?,
        telemetryBatteryPowerWatts: Double?,
        positivePackPowerWatts: Double?
    ) -> Bool {
        if let telemetry = validatedTelemetryChargingBalance(
            inputWatts: telemetrySystemPowerInWatts,
            loadWatts: telemetrySystemLoadWatts,
            batteryWatts: telemetryBatteryPowerWatts
        ), telemetry.batteryChargeWatts >= 2 {
            return true
        }
        guard let pack = finitePower(positivePackPowerWatts) else {
            return false
        }
        return pack >= 2
    }

    private static func reconcileInputAndLoad(
        inputWatts: Double,
        loadWatts: Double,
        packChargeWatts: Double?,
        source: ChargingPowerBalanceSource
    ) -> ChargingPowerBalance {
        let residual = inputWatts - loadWatts
        if let packChargeWatts,
           packChargeWatts > minimumMeaningfulPowerWatts,
           inputWatts >= packChargeWatts {
            let allowedDrift = max(3, packChargeWatts * 0.35)
            if abs(residual - packChargeWatts) > allowedDrift {
                return ChargingPowerBalance(
                    adapterInputWatts: inputWatts,
                    systemLoadWatts: inputWatts - packChargeWatts,
                    batteryChargeWatts: packChargeWatts,
                    source: .adapterAndBattery
                )
            }
        }
        return ChargingPowerBalance(
            adapterInputWatts: inputWatts,
            systemLoadWatts: loadWatts,
            batteryChargeWatts: residual,
            source: source
        )
    }

    private static func validatedTelemetryChargingBalance(
        inputWatts: Double?,
        loadWatts: Double?,
        batteryWatts: Double?
    ) -> ChargingPowerBalance? {
        guard let input = finitePower(inputWatts),
              let load = finitePower(loadWatts),
              let battery = finitePower(batteryWatts),
              input > minimumMeaningfulPowerWatts,
              input >= load else {
            return nil
        }
        let residual = input - load
        let tolerance = max(0.25, input * 0.02)
        guard abs(residual - battery) <= tolerance else { return nil }
        return ChargingPowerBalance(
            adapterInputWatts: input,
            systemLoadWatts: load,
            batteryChargeWatts: residual,
            source: .powerTelemetry
        )
    }

    private static func finitePower(_ value: Double?) -> Double? {
        guard let value,
              value.isFinite,
              value >= 0,
              value < 1_000 else {
            return nil
        }
        return value
    }

    private static func meaningfulPower(_ value: Double?) -> Double? {
        guard let value = finitePower(value),
              value > minimumMeaningfulPowerWatts else {
            return nil
        }
        return value
    }

    private static func finiteNonnegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func numberValue(_ value: Any?) -> Double? {
        finiteNonnegative((value as? NSNumber)?.doubleValue)
    }
}
