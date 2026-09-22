import Foundation

/// Independent battery signals do not always change in the same IORegistry
/// transaction. Reconcile them once so every UI surface sees the same state.
nonisolated struct BatteryStateSignals: Equatable, Sendable {
    let registryIsCharging: Bool
    let chargerIsCharging: Bool
    let powerSourcesIsCharging: Bool
    let registryFullyCharged: Bool
    let powerSourcesFullyCharged: Bool
    let registryOnAC: Bool
    let rawRegistryOnAC: Bool
    let powerSourcesOnAC: Bool
    let chargingCurrentMilliamps: Double
    let hasMeasuredBatteryPower: Bool
    /// A coherent telemetry tuple or validated signed pack reading; positive charges.
    var signedBatteryPowerWatts: Double? = nil
}

nonisolated struct ResolvedBatteryState: Equatable, Sendable {
    let isOnAC: Bool
    let isCharging: Bool
    let isFullyCharged: Bool
}

/// Pure battery-state reconciliation shared by the live reader and tests.
///
/// `IsCharging`, IOPowerSources and the charger's current can briefly disagree
/// around cable insertion, optimized charging and charge completion. A real
/// positive charger current is accepted only when AC, a non-full state and a
/// measured positive battery power corroborate it. A validated signed sample
/// takes precedence over lagging charging booleans, including a real idle zero.
nonisolated enum BatteryStateCore {
    static let meaningfulCurrentMilliamps = 20.0

    static func resolve(_ signals: BatteryStateSignals) -> ResolvedBatteryState {
        let explicitChargingSignal = signals.registryIsCharging
            || signals.chargerIsCharging
            || signals.powerSourcesIsCharging
        let preliminaryOnAC = signals.registryOnAC
            || signals.rawRegistryOnAC
            || signals.powerSourcesOnAC
            || explicitChargingSignal
        let reportsFull = signals.registryFullyCharged
            || signals.powerSourcesFullyCharged
        let currentCorroboratesCharging = preliminaryOnAC
            && !reportsFull
            && signals.hasMeasuredBatteryPower
            && signals.chargingCurrentMilliamps
                > meaningfulCurrentMilliamps
        let signedPower = signals.signedBatteryPowerWatts.flatMap {
            $0.isFinite && abs($0) < 200 ? $0 : nil
        }
        let physicallyConnected = signals.registryOnAC
            || signals.rawRegistryOnAC || signals.powerSourcesOnAC
        let isOnAC = signedPower != nil ? physicallyConnected : preliminaryOnAC
        let isCharging = isOnAC && (signedPower.map { $0 > 0.02 }
            ?? (explicitChargingSignal || currentCorroboratesCharging))

        // Active charge wins over a stale full flag. Both flags can coexist for
        // one or more samples while the battery controller changes state.
        let isFullyCharged = !isCharging
            && reportsFull

        return ResolvedBatteryState(
            isOnAC: isOnAC,
            isCharging: isCharging,
            isFullyCharged: isFullyCharged
        )
    }
}
