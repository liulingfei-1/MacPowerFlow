import Foundation
import IOKit

/// Pure Swift copy of the Objective-C IOReport result. Keeping the C struct
/// inside the sampler actor avoids moving an imported non-Sendable value across
/// an isolation boundary.
nonisolated struct ProcessorSnapshot: Sendable {
    let cpuPower: Double
    let gpuPower: Double
    let anePower: Double
    let dramPower: Double
    let gpuSRAMPower: Double
    let mediaPower: Double
    let ispPower: Double
    let fabricPower: Double
    let pciePower: Double
    let displaySoCPower: Double
    let displayExtPower: Double
    let systemPower: Double
    let cpuTemp: Double
    let cpuDieHotspot: Double
    let gpuTemp: Double
    let gpuUsage: Double
    let gpuFreqMHz: Int
    let eClusterActive: Double
    let pClusterActive: Double
    let sClusterActive: Double
    let eClusterFreqMHz: Int
    let pClusterFreqMHz: Int
    let sClusterFreqMHz: Int
    let dramReadBytesPerSecond: Int64
    let dramWriteBytesPerSecond: Int64
    let fanRPM: Int
    let fan2RPM: Int
}

nonisolated struct HardwareSnapshot: Sendable {
    let battery: BatterySnapshot
    let processor: ProcessorSnapshot
    let smcValues: [String: Double]
}

/// Owns the process-wide IOReport sampling sequence and AppleSMC connection.
/// Actor isolation guarantees that the two IOReport samples never overlap.
actor HardwareSampler {
    private var smcConnection: io_connect_t = 0

    private let smcKeys = [
        "PPBR", "PDTR", "PSTR", "PHPC", "PDBR", "PBwo",
        "PCPT", "PCTR", "PCPR", "PCPC", "PC0C",
        "PG0R", "PG0C", "PCPG", "PMTR", "PC3C",
        "TB0T", "TB1T", "TB2T",
        "TCMz", "Tp0P", "Tp1P", "Te0P", "Te1P",
        "Tg0P", "Tg1P", "Tg0D", "TG0D",
        "Ta0P", "Ta1P", "Ta0D", "Ta1D",
        "Tm0P", "Tm1P", "Tm0D", "Tm1D"
    ]

    func sample() -> HardwareSnapshot {
        if smcConnection == 0 {
            smcConnection = SMCOpen()
        }

        let battery = BatteryReader.read()
        let report = IOReportWrapper.fetchIOReportData(withSMC: smcConnection)

        var values: [String: Double] = [:]
        values.reserveCapacity(smcKeys.count)
        if smcConnection != 0 {
            for key in smcKeys {
                let value = SMCGetFloatValue(smcConnection, key)
                if value.isFinite {
                    values[key] = value
                }
            }
        }

        let processor = ProcessorSnapshot(
            cpuPower: report.cpuPower,
            gpuPower: report.gpuPower,
            anePower: report.anePower,
            dramPower: report.dramPower,
            gpuSRAMPower: report.gpuSRAMPower,
            mediaPower: report.mediaPower,
            ispPower: report.ispPower,
            fabricPower: report.fabricPower,
            pciePower: report.pciePower,
            displaySoCPower: report.displaySoCPower,
            displayExtPower: report.displayExtPower,
            systemPower: report.systemPower,
            cpuTemp: report.cpuTemp,
            cpuDieHotspot: report.cpuDieHotspot,
            gpuTemp: report.gpuTemp,
            gpuUsage: report.gpuUsage,
            gpuFreqMHz: Int(report.gpuFreqMHz),
            eClusterActive: report.eClusterActive,
            pClusterActive: report.pClusterActive,
            sClusterActive: report.sClusterActive,
            eClusterFreqMHz: Int(report.eClusterFreqMHz),
            pClusterFreqMHz: Int(report.pClusterFreqMHz),
            sClusterFreqMHz: Int(report.sClusterFreqMHz),
            dramReadBytesPerSecond: report.dramReadBytes,
            dramWriteBytesPerSecond: report.dramWriteBytes,
            fanRPM: Int(report.fanRPM),
            fan2RPM: Int(report.fan2RPM)
        )
        return HardwareSnapshot(
            battery: battery,
            processor: processor,
            smcValues: values
        )
    }

    func close() {
        if smcConnection != 0 {
            SMCClose(smcConnection)
            smcConnection = 0
        }
    }
}
