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
    case batteryOnly
    case unavailable
}

nonisolated struct ChargingPowerBalance: Equatable, Sendable {
    let adapterInputWatts: Double
    let systemLoadWatts: Double
    let batteryChargeWatts: Double
    let source: ChargingPowerBalanceSource
}

/// Positive battery power means charging, negative means supplying the system.
/// Optional legs retain the distinction between a measured idle zero and no data.
nonisolated struct PowerBalance: Equatable, Sendable {
    let adapterInputWatts: Double?
    let systemLoadWatts: Double?
    let signedBatteryWatts: Double?
    let source: ChargingPowerBalanceSource

    /// Unreconciled watts from independently sampled input/load/pack legs.
    /// Keeping this visible avoids silently changing a measured idle pack to
    /// charging merely to force the diagram to add up.
    var residualWatts: Double? {
        guard let input = adapterInputWatts, let load = systemLoadWatts,
              let battery = signedBatteryWatts else { return nil }
        return input - load - battery
    }

    var isCoherent: Bool {
        guard let input = adapterInputWatts, let load = systemLoadWatts,
              let battery = signedBatteryWatts else { return false }
        return abs(input - load - battery) <= max(0.25, max(input, load) * 0.02)
    }
    var isSupplementingAdapter: Bool {
        (adapterInputWatts ?? 0) > 0.02 && (signedBatteryWatts ?? 0) < -0.02
    }
}

nonisolated enum TelemetryFreshness: String, Equatable, Sendable {
    case unverified, fresh, stale, unavailable
}

/// Tracks observations, not a nonexistent hardware timestamp. An unchanged
/// counter fingerprint eventually becomes stale even when read() keeps running.
nonisolated struct TelemetryFreshnessState: Sendable {
    private var fingerprint: String?
    private var lastChangeUptime: Double?
    private var hasObservedAdvance = false
    private(set) var lastChangedAt: Date?

    mutating func observe(fingerprint next: String?, uptime: Double,
                          date: Date, staleAfter: Double = 10) -> TelemetryFreshness {
        guard let next else {
            fingerprint = nil; lastChangeUptime = nil
            lastChangedAt = nil; hasObservedAdvance = false
            return .unavailable
        }
        guard uptime.isFinite else { return .unverified }
        if fingerprint != next || lastChangeUptime.map({ uptime < $0 }) == true {
            hasObservedAdvance = fingerprint != nil && lastChangeUptime.map({ uptime >= $0 }) == true
            fingerprint = next; lastChangeUptime = uptime; lastChangedAt = date
        }
        guard let lastChangeUptime else { return .unverified }
        if uptime - lastChangeUptime >= staleAfter { return .stale }
        return hasObservedAdvance ? .fresh : .unverified
    }
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

    /// Selects the first available measurement, preserving a legitimate zero.
    static func firstAvailablePowerWatts(_ candidates: [Double?]) -> Double? {
        candidates.compactMap(finiteNonnegative).first
    }

    /// Reconciles signed flow without treating discharge as charge. The atomic
    /// telemetry tuple wins; asynchronous SMC/pack fallbacks remain derived.
    static func resolvePowerBalance(
        smcPDTRWatts: Double?, smcPSTRWatts: Double?,
        telemetrySystemPowerInWatts: Double?, telemetrySystemLoadWatts: Double?,
        telemetryBatteryPowerWatts: Double?, signedPackBatteryWatts: Double?,
        isOnAC: Bool, telemetryIsUsable: Bool = true
    ) -> PowerBalance {
        let input = telemetryIsUsable ? finitePower(telemetrySystemPowerInWatts) : nil
        let load = telemetryIsUsable ? finitePower(telemetrySystemLoadWatts) : nil
        let battery = telemetryIsUsable ? finiteSignedBatteryPower(telemetryBatteryPowerWatts) : nil
        let pack = finiteSignedBatteryPower(signedPackBatteryWatts)
        if let input, let load, let battery,
           isOnAC || input <= minimumMeaningfulPowerWatts {
            let tuple = PowerBalance(adapterInputWatts: input, systemLoadWatts: load,
                                     signedBatteryWatts: battery, source: .powerTelemetry)
            if tuple.isCoherent { return tuple }
        }
        if !isOnAC {
            // Reject a positive pack sample carried across cable removal.
            if let pack, pack <= 0 {
                return PowerBalance(adapterInputWatts: 0, systemLoadWatts: -pack,
                                    signedBatteryWatts: pack, source: .batteryOnly)
            }
            return PowerBalance(adapterInputWatts: 0, systemLoadWatts: nil,
                                signedBatteryWatts: nil, source: .unavailable)
        }
        let smcInput = finitePower(smcPDTRWatts)
        let smcLoad = finitePower(smcPSTRWatts)
        // Without all three matching telemetry legs, prefer the live SMC pair.
        let chosenInput = smcInput ?? input
        let chosenLoad = smcLoad ?? load
        if let chosenInput, let chosenLoad {
            let residual = chosenInput - chosenLoad
            // Preserve both independently measured legs, even if their windows
            // disagree strongly. A signed pack reading (including zero) supplies
            // direction; only a missing pack falls back to the residual. Never
            // rewrite an available system reading to make the diagram add up.
            return PowerBalance(adapterInputWatts: chosenInput, systemLoadWatts: chosenLoad,
                                signedBatteryWatts: pack ?? finiteSignedBatteryPower(residual),
                                source: smcInput != nil && smcLoad != nil ? .smcPDTRPSTR : .adapterAndBattery)
        }
        if let chosenInput, let pack, chosenInput - pack >= 0 {
            return PowerBalance(adapterInputWatts: chosenInput, systemLoadWatts: chosenInput - pack,
                                signedBatteryWatts: pack, source: .adapterAndBattery)
        }
        if let chosenLoad, let pack, chosenLoad + pack >= 0 {
            return PowerBalance(adapterInputWatts: chosenLoad + pack, systemLoadWatts: chosenLoad,
                                signedBatteryWatts: pack, source: .systemAndBattery)
        }
        return PowerBalance(adapterInputWatts: chosenInput, systemLoadWatts: chosenLoad,
                            signedBatteryWatts: pack, source: .unavailable)
    }

    static func finiteSignedBatteryPower(_ value: Double?) -> Double? {
        guard let value, value.isFinite, abs(value) < 200 else { return nil }
        return value
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
        _ = smcPPBRWatts // PPBR is not the pack charging rail.
        let balance = resolvePowerBalance(
            smcPDTRWatts: smcPDTRWatts, smcPSTRWatts: smcPSTRWatts,
            telemetrySystemPowerInWatts: telemetrySystemPowerInWatts,
            telemetrySystemLoadWatts: telemetrySystemLoadWatts,
            telemetryBatteryPowerWatts: telemetryBatteryPowerWatts,
            signedPackBatteryWatts: finitePower(packBatteryChargeWatts), isOnAC: true
        )
        // Compatibility only for the old positive-charge API. Live history and
        // current monitoring use resolvePowerBalance and retain the raw load.
        if balance.source != .powerTelemetry,
           let input = balance.adapterInputWatts, let load = balance.systemLoadWatts,
           let pack = finitePower(packBatteryChargeWatts), pack > minimumMeaningfulPowerWatts,
           abs(input - load - pack) > max(3, pack * 0.35), input >= pack {
            return ChargingPowerBalance(adapterInputWatts: input, systemLoadWatts: input - pack,
                                        batteryChargeWatts: pack, source: .adapterAndBattery)
        }
        guard balance.isCoherent, let input = balance.adapterInputWatts,
              let load = balance.systemLoadWatts, let charge = balance.signedBatteryWatts,
              charge >= 0 else {
            return ChargingPowerBalance(adapterInputWatts: 0, systemLoadWatts: 0,
                                        batteryChargeWatts: 0, source: .unavailable)
        }
        return ChargingPowerBalance(adapterInputWatts: input, systemLoadWatts: load,
                                    batteryChargeWatts: charge, source: balance.source)
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
