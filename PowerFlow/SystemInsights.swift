import Foundation
import Darwin
import IOKit
import IOKit.pwr_mgt

/// All values describe activity or OS accounting, never per-process watts.
/// nil means unavailable (or no valid interval yet); a measured zero stays zero.
nonisolated struct SystemInsightsSnapshot: Sendable, Codable {
    let timestamp: Date
    let memory: MemoryInsights?
    let powerAssertions: [PowerAssertionInsight]?
    let topProcesses: [ProcessInsight]?
    let topGPUProcesses: [ProcessInsight]?
    let network: ThroughputInsights?
    let disk: ThroughputInsights?
    let gpuActivityAvailable: Bool
}

nonisolated enum MemoryPressure: String, Sendable, Codable {
    case normal, warning, critical
}

nonisolated struct MemoryInsights: Sendable, Codable {
    let totalBytes: UInt64
    let usedBytes: UInt64
    let compressedBytes: UInt64
    let swapUsedBytes: UInt64?
    let pressure: MemoryPressure?
    let swapInBytesPerSecond: Double?
    let swapOutBytesPerSecond: Double?
    let pageInBytesPerSecond: Double?
    let pageOutBytesPerSecond: Double?
}

nonisolated enum PowerAssertionKind: String, Sendable, Codable {
    case systemSleep, displaySleep, userActivity, background, other
}

nonisolated struct PowerAssertionInsight: Sendable, Codable, Identifiable {
    let id: String
    let pid: Int32
    let name: String
    let reason: String
    let type: String
    let kind: PowerAssertionKind
}

nonisolated struct ProcessInsight: Sendable, Codable, Identifiable {
    var id: Int32 { pid }
    let pid: Int32
    let name: String
    /// 100% means one fully occupied CPU core; may exceed 100%.
    let cpuPercent: Double?
    let residentBytes: UInt64
    /// Raw GPU execution time / wall-clock interval. Not percent and not watts.
    let gpuMillisecondsPerSecond: Double?
}

nonisolated struct ThroughputInsights: Sendable, Codable {
    /// Network: received bytes. Disk: read bytes.
    let readBytesPerSecond: Double?
    /// Network: transmitted bytes. Disk: written bytes.
    let writeBytesPerSecond: Double?
    let sourceCount: Int
}

// These pure types also define the boundary rules exercised by the regression test.
nonisolated struct InsightsProcessCounter: Sendable {
    let pid: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let name: String
    let cpuNanoseconds: UInt64
    let residentBytes: UInt64
}

nonisolated struct InsightsIOCounter: Sendable {
    let read: UInt64
    let write: UInt64
}

nonisolated struct InsightsMemoryCounter: Sendable {
    let pageSize: UInt64
    let swapins: UInt64
    let swapouts: UInt64
    let pageins: UInt64
    let pageouts: UInt64
}

nonisolated struct InsightsGPUCounter: Sendable {
    let pid: Int32
    let nanoseconds: UInt64
}

nonisolated enum InsightsDelta {
    /// PROC_PIDTASKALLINFO CPU totals use Mach absolute-time units on the
    /// target kernel. Convert without overflowing the intermediate product.
    static func nanoseconds(ticks: UInt64, numerator: UInt32, denominator: UInt32) -> UInt64? {
        guard numerator > 0, denominator > 0 else { return nil }
        let divisor = UInt64(denominator)
        let multiplier = UInt64(numerator)
        let (whole, overflow) = (ticks / divisor).multipliedReportingOverflow(by: multiplier)
        guard !overflow else { return nil }
        let fraction = (ticks % divisor) * multiplier / divisor
        let (result, sumOverflow) = whole.addingReportingOverflow(fraction)
        return sumOverflow ? nil : result
    }

    /// Large gaps (including suspend/resume) are not current activity readings.
    static func rate(current: UInt64, previous: UInt64, seconds: Double) -> Double? {
        guard seconds.isFinite, seconds > 0, seconds <= 30,
              current >= previous else { return nil }
        return Double(current - previous) / seconds
    }

    static func cpuPercent(
        current: InsightsProcessCounter,
        previous: InsightsProcessCounter?,
        seconds: Double
    ) -> Double? {
        guard let previous,
              current.pid == previous.pid,
              current.startSeconds == previous.startSeconds,
              current.startMicroseconds == previous.startMicroseconds,
              let nanoseconds = rate(
                current: current.cpuNanoseconds,
                previous: previous.cpuNanoseconds,
                seconds: seconds
              ) else { return nil }
        return nanoseconds / 1_000_000_000 * 100
    }

    static func throughput(
        current: [String: InsightsIOCounter],
        previous: [String: InsightsIOCounter]?,
        seconds: Double
    ) -> ThroughputInsights {
        // Require a complete common inventory. An attached/removed device or
        // reset counter must establish a new baseline, not appear as a burst.
        guard let previous, !current.isEmpty,
              Set(current.keys) == Set(previous.keys) else {
            return ThroughputInsights(
                readBytesPerSecond: nil, writeBytesPerSecond: nil,
                sourceCount: current.count
            )
        }
        var read = 0.0
        var write = 0.0
        for (key, counter) in current {
            guard let old = previous[key],
                  let r = rate(current: counter.read, previous: old.read, seconds: seconds),
                  let w = rate(current: counter.write, previous: old.write, seconds: seconds)
            else {
                return ThroughputInsights(
                    readBytesPerSecond: nil, writeBytesPerSecond: nil,
                    sourceCount: current.count
                )
            }
            read += r
            write += w
        }
        return ThroughputInsights(
            readBytesPerSecond: read, writeBytesPerSecond: write,
            sourceCount: current.count
        )
    }

    static func assertionKind(_ type: String) -> PowerAssertionKind {
        switch type {
        case "PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion":
            return .systemSleep
        case "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion":
            return .displaySleep
        case "UserIsActive":
            return .userActivity
        case "BackgroundTask", "ApplePushServiceTask", "NetworkClientActive":
            return .background
        default:
            return .other
        }
    }

    static func activeAssertion(
        pid: Int32, processName: String, properties: [String: Any], index: Int
    ) -> PowerAssertionInsight? {
        // IOPMLib guarantees a level field. Missing/unknown level is not proof
        // of an active assertion; do not silently promote it to active.
        guard let level = (properties["AssertLevel"] as? NSNumber)?.intValue,
              level == Int(kIOPMAssertionLevelOn),
              let type = (properties["AssertType"] ?? properties["AssertionType"]) as? String
        else { return nil }
        let reason = properties["AssertName"] as? String ?? type
        let assertionID = (properties["AssertionId"] as? NSNumber)?.stringValue
            ?? (properties["AssertionID"] as? NSNumber)?.stringValue
            ?? String(index)
        return PowerAssertionInsight(
            id: "\(pid):\(assertionID)", pid: pid, name: processName,
            reason: reason, type: type, kind: assertionKind(type)
        )
    }
}

/// Native, read-only telemetry collected off the main actor. A 5–10 s cadence
/// is sufficient for these supplementary details; the app's power sampler is
/// independent. No subprocesses, elevation, or new system permissions.
actor SystemInsightsSampler {
    private let timebaseNumerator: UInt32
    private let timebaseDenominator: UInt32

    init() {
        var timebase = mach_timebase_info_data_t()
        if mach_timebase_info(&timebase) == KERN_SUCCESS {
            timebaseNumerator = timebase.numer
            timebaseDenominator = timebase.denom
        } else {
            timebaseNumerator = 0
            timebaseDenominator = 0
        }
    }
    private var previousTime: Double?
    private var previousProcesses: [Int32: InsightsProcessCounter]?
    private var previousMemory: InsightsMemoryCounter?
    private var previousNetwork: [String: InsightsIOCounter]?
    private var previousDisk: [String: InsightsIOCounter]?
    private var previousGPU: [UInt64: InsightsGPUCounter]?

    func reset() {
        previousTime = nil
        previousProcesses = nil
        previousMemory = nil
        previousNetwork = nil
        previousDisk = nil
        previousGPU = nil
    }

    func sample(includeDetails: Bool = true) -> SystemInsightsSnapshot {
        let timestamp = Date()
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = previousTime.map { now - $0 } ?? 0
        let memory = readMemory(elapsed: elapsed)
        guard includeDetails else {
            // Keep memory's consecutive window, but discard all expensive
            // sources' baselines. Reopening the panel establishes fresh detail
            // samples instead of dividing an old counter by a short interval.
            previousTime = now
            previousProcesses = nil
            previousNetwork = nil
            previousDisk = nil
            previousGPU = nil
            return SystemInsightsSnapshot(
                timestamp: timestamp, memory: memory, powerAssertions: nil,
                topProcesses: nil, topGPUProcesses: nil,
                network: nil, disk: nil, gpuActivityAvailable: false
            )
        }
        let processes = readProcesses()
        let gpu = readGPUCounters()
        let network = readNetworkCounters()
        let disk = readDiskCounters()
        let assertions = readPowerAssertions(processes: processes)
        let rows = processes.map { counters in
            counters.values.map { counter in
                ProcessInsight(
                    pid: counter.pid, name: counter.name,
                    cpuPercent: InsightsDelta.cpuPercent(
                        current: counter, previous: previousProcesses?[counter.pid],
                        seconds: elapsed
                    ),
                    residentBytes: counter.residentBytes,
                    gpuMillisecondsPerSecond: gpuRate(
                        pid: counter.pid, currentProcess: counter,
                        currentGPU: gpu, seconds: elapsed
                    )
                )
            }
        }
        let cpuRows = rows.map {
            Array($0.sorted {
                if $0.cpuPercent != $1.cpuPercent {
                    return ($0.cpuPercent ?? -1) > ($1.cpuPercent ?? -1)
                }
                return $0.pid < $1.pid
            }.prefix(8))
        }
        let gpuRows = rows.map {
            Array($0.filter { $0.gpuMillisecondsPerSecond != nil }.sorted {
                if $0.gpuMillisecondsPerSecond != $1.gpuMillisecondsPerSecond {
                    return ($0.gpuMillisecondsPerSecond ?? -1) > ($1.gpuMillisecondsPerSecond ?? -1)
                }
                return $0.pid < $1.pid
            }.prefix(5))
        }
        let snapshot = SystemInsightsSnapshot(
            timestamp: timestamp, memory: memory, powerAssertions: assertions,
            topProcesses: cpuRows, topGPUProcesses: gpu == nil ? nil : gpuRows,
            network: network.map {
                InsightsDelta.throughput(current: $0, previous: previousNetwork, seconds: elapsed)
            },
            disk: disk.map {
                InsightsDelta.throughput(current: $0, previous: previousDisk, seconds: elapsed)
            },
            gpuActivityAvailable: gpu != nil
        )
        // A failed read clears that source's baseline, so recovery never spans
        // an unknown interval or resurrects an exited PID's old counters.
        previousTime = now
        previousProcesses = processes
        previousNetwork = network
        previousDisk = disk
        previousGPU = gpu
        return snapshot
    }

    private func readMemory(elapsed: Double) -> MemoryInsights? {
        var total: UInt64 = 0
        var totalSize = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &total, &totalSize, nil, 0) == 0,
              total > 0 else {
            previousMemory = nil
            return nil
        }
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
        )
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        let pageSize = sysconf(_SC_PAGESIZE)
        guard result == KERN_SUCCESS, pageSize > 0 else {
            previousMemory = nil
            return nil
        }
        let pageBytes = UInt64(pageSize)
        // Same accounting categories as Activity Monitor style used memory:
        // cached/external and purgeable pages are not charged as application use.
        let allocatedPages = UInt64(stats.active_count) + UInt64(stats.inactive_count)
            + UInt64(stats.speculative_count) + UInt64(stats.wire_count)
            + UInt64(stats.compressor_page_count)
        let cachedPages = UInt64(stats.purgeable_count) + UInt64(stats.external_page_count)
        let usedPages = allocatedPages >= cachedPages ? allocatedPages - cachedPages : 0
        let usedBytes = min(total, usedPages * pageBytes)
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapUsed: UInt64? = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0
            ? swap.xsu_used : nil
        var pressureRaw: Int32 = 0
        var pressureSize = MemoryLayout<Int32>.size
        var pressure: MemoryPressure?
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureRaw, &pressureSize, nil, 0) == 0 {
            switch pressureRaw {
            case 1: pressure = .normal
            case 2: pressure = .warning
            case 4: pressure = .critical
            default: pressure = nil
            }
        }
        let current = InsightsMemoryCounter(
            pageSize: pageBytes, swapins: stats.swapins, swapouts: stats.swapouts,
            pageins: stats.pageins, pageouts: stats.pageouts
        )
        func bytesRate(_ key: KeyPath<InsightsMemoryCounter, UInt64>) -> Double? {
            guard let previousMemory, previousMemory.pageSize == pageBytes else { return nil }
            return InsightsDelta.rate(
                current: current[keyPath: key], previous: previousMemory[keyPath: key],
                seconds: elapsed
            ).map { $0 * Double(pageBytes) }
        }
        let snapshot = MemoryInsights(
            totalBytes: total, usedBytes: usedBytes,
            compressedBytes: UInt64(stats.compressor_page_count) * pageBytes,
            swapUsedBytes: swapUsed, pressure: pressure,
            swapInBytesPerSecond: bytesRate(\.swapins),
            swapOutBytesPerSecond: bytesRate(\.swapouts),
            pageInBytesPerSecond: bytesRate(\.pageins),
            pageOutBytesPerSecond: bytesRate(\.pageouts)
        )
        previousMemory = current
        return snapshot
    }

    private func readProcesses() -> [Int32: InsightsProcessCounter]? {
        // proc_listallpids returns a process count (not byte count). Leave room
        // for forks racing the sizing call, retry once if the buffer fills.
        let estimated = proc_listallpids(nil, 0)
        guard estimated > 0 else { return nil }
        var capacity = min(Int(estimated) + 128, 65_536)
        var pids: [Int32] = []
        for _ in 0..<2 {
            pids = Array(repeating: 0, count: capacity)
            let count = pids.withUnsafeMutableBytes {
                proc_listallpids($0.baseAddress, Int32($0.count))
            }
            guard count > 0 else { return nil }
            if count < capacity {
                pids.removeSubrange(Int(count)..<pids.count)
                break
            }
            capacity = min(capacity * 2, 65_536)
        }
        var counters: [Int32: InsightsProcessCounter] = [:]
        for pid in pids where pid > 0 {
            // One kernel call gives a consistent process identity plus CPU/RSS.
            var info = proc_taskallinfo()
            let expected = MemoryLayout<proc_taskallinfo>.size
            let read = proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, Int32(expected))
            guard read == expected else { continue }
            let (cpuTime, overflow) = info.ptinfo.pti_total_user.addingReportingOverflow(
                info.ptinfo.pti_total_system
            )
            guard !overflow, let cpuNanoseconds = InsightsDelta.nanoseconds(
                ticks: cpuTime, numerator: timebaseNumerator,
                denominator: timebaseDenominator
            ) else { continue }
            let startSec = info.pbsd.pbi_start_tvsec
            let startUSec = info.pbsd.pbi_start_tvusec
            let cached = previousProcesses?[pid]
            let name: String
            let shortName = withUnsafeBytes(of: info.pbsd.pbi_comm) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            if let cached, cached.startSeconds == startSec, cached.startMicroseconds == startUSec,
               !shortName.isEmpty, cached.name.hasPrefix(shortName) {
                name = cached.name
            } else {
                name = processName(pid)
            }
            // The macOS 27 Apple Silicon read-only smoke test verifies these
            // totals use Mach ticks: convert with the host's real timebase.
            // A single-core calibration catches a mistaken 1:1 assumption.
            counters[pid] = InsightsProcessCounter(
                pid: pid, startSeconds: startSec, startMicroseconds: startUSec,
                name: name, cpuNanoseconds: cpuNanoseconds,
                residentBytes: info.ptinfo.pti_resident_size
            )
        }
        return counters.isEmpty ? nil : counters
    }

    private func processName(_ pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBytes {
            proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        if length > 0 {
            let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let name = (path as NSString).lastPathComponent
            if !name.isEmpty { return name }
        }
        let shortLength = buffer.withUnsafeMutableBytes {
            proc_name(pid, $0.baseAddress, UInt32($0.count))
        }
        return shortLength > 0 ? String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : "PID \(pid)"
    }

    private func readPowerAssertions(
        processes: [Int32: InsightsProcessCounter]?
    ) -> [PowerAssertionInsight]? {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let raw = unmanaged?.takeRetainedValue() else { return nil }
        let dictionary = raw as NSDictionary
        var results: [PowerAssertionInsight] = []
        for (key, value) in dictionary {
            guard let pidNumber = key as? NSNumber,
                  let entries = value as? [[String: Any]] else { continue }
            let pid = pidNumber.int32Value
            let name = processes?[pid]?.name ?? processName(pid)
            for (index, properties) in entries.enumerated() {
                if let assertion = InsightsDelta.activeAssertion(
                    pid: pid, processName: name, properties: properties, index: index
                ) {
                    results.append(assertion)
                }
            }
        }
        return results.sorted {
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            if $0.pid != $1.pid { return $0.pid < $1.pid }
            return $0.id < $1.id
        }
    }

    private func readNetworkCounters() -> [String: InsightsIOCounter]? {
        // NET_RT_IFLIST2 uses 64-bit counters. getifaddrs' legacy if_data byte
        // counters can wrap at 4 GiB and are unsuitable for long-running meters.
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
              size > 0, size <= 16 * 1_024 * 1_024 else { return nil }
        let memory = UnsafeMutableRawPointer.allocate(
            byteCount: size, alignment: MemoryLayout<if_msghdr2>.alignment
        )
        defer { memory.deallocate() }
        guard sysctl(&mib, u_int(mib.count), memory, &size, nil, 0) == 0 else { return nil }
        var offset = 0
        var counters: [String: InsightsIOCounter] = [:]
        while offset + 4 <= size {
            let ptr = memory.advanced(by: offset)
            let length = Int(ptr.loadUnaligned(as: UInt16.self))
            guard length >= 4, offset + length <= size else { return nil }
            defer { offset += length }
            let messageType = ptr.load(fromByteOffset: 3, as: UInt8.self)
            guard messageType == RTM_IFINFO2,
                  length >= MemoryLayout<if_msghdr2>.size else { continue }
            let info = ptr.loadUnaligned(as: if_msghdr2.self)
            var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
            guard if_indextoname(UInt32(info.ifm_index), &nameBuffer) != nil else { continue }
            let name = String(decoding: nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            // Sum physical Ethernet/Wi-Fi interfaces only. Exclude loopback,
            // VPN, bridge and AWDL views that can count the same bytes twice.
            guard name.hasPrefix("en"), info.ifm_flags & IFF_LOOPBACK == 0 else { continue }
            counters["\(info.ifm_index):\(name)"] = InsightsIOCounter(
                read: info.ifm_data.ifi_ibytes, write: info.ifm_data.ifi_obytes
            )
        }
        return counters.isEmpty ? nil : counters
    }

    private func readDiskCounters() -> [String: InsightsIOCounter]? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var counters: [String: InsightsIOCounter] = [:]
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard isPhysicalStorageDriver(entry), let value = IORegistryEntryCreateCFProperty(
                entry, "Statistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue(), let statistics = value as? [String: Any],
                  let read = unsignedNumber(statistics["Bytes (Read)"]),
                  let write = unsignedNumber(statistics["Bytes (Write)"])
            else { continue }
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(entry, &entryID) == KERN_SUCCESS else { continue }
            counters[String(entryID)] = InsightsIOCounter(read: read, write: write)
        }
        return counters.isEmpty ? nil : counters
    }

    private func isPhysicalStorageDriver(_ entry: io_registry_entry_t) -> Bool {
        // Disk images generate their own block-driver statistics in addition
        // to the backing physical disk. Counting both doubles the same IO.
        var device: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &device) == KERN_SUCCESS
        else { return false }
        defer { IOObjectRelease(device) }
        guard let value = IORegistryEntryCreateCFProperty(
            device, "Protocol Characteristics" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue(), let properties = value as? [String: Any],
              let interconnect = properties["Physical Interconnect"] as? String,
              !interconnect.isEmpty else { return false }
        let location = properties["Physical Interconnect Location"] as? String
        return interconnect != "Virtual Interface" && location != "File"
    }

    private func unsignedNumber(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
        return number.uint64Value
    }

    private func readGPUCounters() -> [UInt64: InsightsGPUCounter]? {
        let accelerator = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AGXAccelerator")
        )
        guard accelerator != 0 else { return nil }
        defer { IOObjectRelease(accelerator) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        var counters: [UInt64: InsightsGPUCounter] = [:]
        var sawValidCounter = false
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard IOObjectConformsTo(entry, "AGXDeviceUserClient") != 0 else { continue }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(
                entry, &properties, kCFAllocatorDefault, 0
            ) == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() as? [String: Any],
                  let creator = dictionary["IOUserClientCreator"] as? String,
                  creator.hasPrefix("pid "),
                  let pid = Int32(creator.dropFirst(4).prefix { $0.isNumber }),
                  let usage = dictionary["AppUsage"] as? [[String: Any]] else { continue }
            var sum: UInt64 = 0
            var valid = false
            var overflowed = false
            for item in usage {
                guard let time = unsignedNumber(item["accumulatedGPUTime"]) else { continue }
                let (next, overflow) = sum.addingReportingOverflow(time)
                if overflow { overflowed = true; break }
                valid = true
                sum = next
            }
            guard valid, !overflowed else { continue }
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(entry, &entryID) == KERN_SUCCESS else { continue }
            sawValidCounter = true
            counters[entryID] = InsightsGPUCounter(pid: pid, nanoseconds: sum)
        }
        // Existing service alone is not proof of readable AppUsage counters.
        return sawValidCounter ? counters : nil
    }

    private func gpuRate(
        pid: Int32, currentProcess: InsightsProcessCounter,
        currentGPU: [UInt64: InsightsGPUCounter]?, seconds: Double
    ) -> Double? {
        guard let currentGPU, let previousGPU,
              let oldProcess = previousProcesses?[pid],
              oldProcess.startSeconds == currentProcess.startSeconds,
              oldProcess.startMicroseconds == currentProcess.startMicroseconds else { return nil }
        let currentClients = currentGPU.filter { $0.value.pid == pid }
        let oldClients = previousGPU.filter { $0.value.pid == pid }
        guard !currentClients.isEmpty, Set(currentClients.keys) == Set(oldClients.keys) else { return nil }
        var rate = 0.0
        for (id, client) in currentClients {
            guard let previous = oldClients[id],
                  let next = InsightsDelta.rate(
                    current: client.nanoseconds, previous: previous.nanoseconds,
                    seconds: seconds
                  ) else { return nil }
            rate += next / 1_000_000
        }
        return rate
    }
}
