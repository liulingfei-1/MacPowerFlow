import Foundation

nonisolated struct ProcessorPowerAllocation: Equatable, Sendable {
    let cpuWatts: Double
    let gpuWatts: Double
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

    private static func finiteNonnegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func numberValue(_ value: Any?) -> Double? {
        finiteNonnegative((value as? NSNumber)?.doubleValue)
    }
}
