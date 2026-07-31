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

/// Read outcome for one semantically known SMC key. A zero value is still
/// `.available`; keeping status separate prevents a missing key from being
/// mistaken for a real zero-watt sensor.
nonisolated enum SMCReadingStatus: UInt8, Sendable {
    case available
    case missing
    case unsupportedType
    case failed
}

nonisolated struct SMCReading: Sendable {
    let value: Double?
    let dataType: String
    let dataSize: Int
    let status: SMCReadingStatus
}

/// Firmware capability discovered through #KEY. Unknown keys remain in this
/// diagnostic inventory only; a key is never assigned a UI meaning merely
/// because its payload happens to decode as a number.
nonisolated struct SMCCapability: Sendable {
    let key: String
    let dataType: String
    let dataSize: Int
    let isNumeric: Bool
}

nonisolated struct HardwareSnapshot: Sendable {
    let battery: BatterySnapshot
    let processor: ProcessorSnapshot
    let smcValues: [String: Double]
    let smcReadings: [String: SMCReading]
    let smcCapabilities: [String: SMCCapability]
    let smcCapabilityCount: Int
    let smcNumericCapabilityCount: Int
}

/// Owns the process-wide IOReport sampling sequence and AppleSMC connection.
/// Actor isolation guarantees that the two IOReport samples never overlap.
actor HardwareSampler {
    private var smcConnection: io_connect_t = 0
    private var smcDiscoveryCompleted = false
    private var smcCapabilities: [String: SMCCapability] = [:]
    private var smcEnumeratedKeys: Set<String> = []
    private var smcReportedKeyCount = 0
    private var smcNumericCapabilityCount = 0
    private var smcMissingKeyShortCircuitIsSafe = false

    private let smcKeys = [
        "PPBR", "PDTR", "PSTR", "PHPC", "PDBR", "PBwo",
        "PCPT", "PCTR", "PCPR", "PCPC", "PC0C", "PCAM",
        "PC0R", "PC0G", "PCEC",
        "PG0R", "PG0C", "PG1R", "PCPG", "PCGC", "PCGM",
        "PMTR", "PC3C",
        // macpow and Stats both use these published rail names. PUSB is the
        // preferred aggregate; the PUS per-port keys are conservative
        // fallbacks and are never summed with an available aggregate.
        "wiPm", "PUSB", "PUS0", "PUS1", "PUS2",
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
        if smcConnection != 0, !smcDiscoveryCompleted {
            discoverSMCCapabilities()
        }

        let battery = BatteryReader.read()
        let report = IOReportWrapper.fetchIOReportData(withSMC: smcConnection)

        var values: [String: Double] = [:]
        var readings: [String: SMCReading] = [:]
        values.reserveCapacity(smcKeys.count)
        readings.reserveCapacity(smcKeys.count)
        if smcConnection != 0 {
            for key in smcKeys {
                if smcMissingKeyShortCircuitIsSafe,
                   !smcEnumeratedKeys.contains(key) {
                    readings[key] = SMCReading(
                        value: nil,
                        dataType: "",
                        dataSize: 0,
                        status: .missing
                    )
                    continue
                }

                let capability = smcCapabilities[key]
                if let capability, !capability.isNumeric {
                    readings[key] = SMCReading(
                        value: nil,
                        dataType: capability.dataType,
                        dataSize: capability.dataSize,
                        status: .unsupportedType
                    )
                    continue
                }

                var rawValue = SMCNumericValue_t()
                let result = key.withCString {
                    SMCReadNumericValue(smcConnection, $0, &rawValue)
                }
                let dataType = rawValue.dataType != 0
                    ? fourCCString(rawValue.dataType)
                    : (capability?.dataType ?? "")
                let dataSize = rawValue.dataSize > 0
                    ? Int(rawValue.dataSize)
                    : (capability?.dataSize ?? 0)

                if result == kIOReturnSuccess, rawValue.value.isFinite {
                    values[key] = rawValue.value
                    readings[key] = SMCReading(
                        value: rawValue.value,
                        dataType: dataType,
                        dataSize: dataSize,
                        status: .available
                    )
                } else {
                    let status: SMCReadingStatus
                    if result == kIOReturnNotFound {
                        status = .missing
                    } else if result == kIOReturnUnsupported {
                        status = .unsupportedType
                    } else {
                        status = .failed
                    }
                    readings[key] = SMCReading(
                        value: nil,
                        dataType: dataType,
                        dataSize: dataSize,
                        status: status
                    )
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
            smcValues: values,
            smcReadings: readings,
            smcCapabilities: smcCapabilities,
            smcCapabilityCount: smcCapabilities.count,
            smcNumericCapabilityCount: smcNumericCapabilityCount
        )
    }

    /// A read-only inventory for diagnostics/support bundles. Business logic
    /// samples only `smcKeys`, whose semantics are independently known.
    func smcCapabilityDiagnostics() -> [SMCCapability] {
        smcCapabilities.values.sorted { $0.key < $1.key }
    }

    private func discoverSMCCapabilities() {
        smcDiscoveryCompleted = true
        let reportedCount = SMCGetKeyCount(smcConnection)
        smcReportedKeyCount = max(0, Int(reportedCount))
        let safeCount = min(smcReportedKeyCount, 8_192)
        guard safeCount > 0 else { return }

        var discovered: [String: SMCCapability] = [:]
        var enumeratedKeys: Set<String> = []
        var successfullyEnumeratedIndexCount = 0
        discovered.reserveCapacity(safeCount)
        enumeratedKeys.reserveCapacity(safeCount)
        for index in 0..<safeCount {
            var keyBytes = [CChar](repeating: 0, count: 5)
            let keyResult = keyBytes.withUnsafeMutableBufferPointer { buffer in
                SMCGetKeyFromIndex(
                    smcConnection,
                    Int32(index),
                    buffer.baseAddress
                )
            }
            guard keyResult == kIOReturnSuccess else { continue }

            let rawBytes = keyBytes.prefix(4).map {
                UInt8(bitPattern: $0)
            }
            guard rawBytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7e }) else {
                continue
            }
            successfullyEnumeratedIndexCount += 1
            let key = String(decoding: rawBytes, as: UTF8.self)
            enumeratedKeys.insert(key)

            var keyInfo = SMCKeyData_keyInfo_t()
            let infoResult = key.withCString {
                SMCGetKeyInfo(smcConnection, $0, &keyInfo)
            }
            guard infoResult == kIOReturnSuccess else { continue }

            discovered[key] = SMCCapability(
                key: key,
                dataType: fourCCString(keyInfo.dataType),
                dataSize: Int(keyInfo.dataSize),
                isNumeric: SMCDataTypeIsNumeric(keyInfo.dataType) != 0
            )
        }
        smcCapabilities = discovered
        smcEnumeratedKeys = enumeratedKeys
        // Only a complete, uncapped #KEY walk proves that a key is absent.
        // If even one index failed (or firmware reported more than our safety
        // cap), known keys still get an ordinary direct read below. This keeps
        // a transient discovery failure from suppressing a real sensor for the
        // lifetime of the app session.
        smcMissingKeyShortCircuitIsSafe =
            smcReportedKeyCount <= 8_192
            && successfullyEnumeratedIndexCount == smcReportedKeyCount
        smcNumericCapabilityCount = discovered.values.reduce(0) {
            $0 + ($1.isNumeric ? 1 : 0)
        }
    }

    private func fourCCString(_ value: UInt32) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(decoding: bytes, as: UTF8.self)
    }

    func close() {
        if smcConnection != 0 {
            SMCClose(smcConnection)
            smcConnection = 0
        }
        smcDiscoveryCompleted = false
        smcCapabilities.removeAll(keepingCapacity: false)
        smcEnumeratedKeys.removeAll(keepingCapacity: false)
        smcReportedKeyCount = 0
        smcNumericCapabilityCount = 0
        smcMissingKeyShortCircuitIsSafe = false
    }
}
