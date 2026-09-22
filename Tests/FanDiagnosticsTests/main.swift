import Foundation
@main struct Checks {
    static func reading(_ value: Double?, _ status: SMCReadingStatus = .available) -> SMCReading {
        SMCReading(value: value, dataType: "flt ", dataSize: 4, status: status)
    }
    static func main() async {
        precondition(FanDiagnostics.snapshots(readings: [:]) == nil)
        precondition(FanDiagnostics.snapshots(readings: ["FNum": reading(0)])?.isEmpty == true)
        let fixtures = FanDiagnostics.snapshots(readings: ["FNum": reading(2),
            "F0Ac": reading(0), "F0Mn": reading(1200), "F0Mx": reading(6000),
            "F0md": reading(nil, .missing), "F0Md": reading(1), "F0Tg": reading(2400),
            "F1Ac": reading(nil, .missing), "F1md": reading(9)])!
        precondition(fixtures[0].currentRPM == 0 && fixtures[0].status == .available)
        precondition(fixtures[0].mode == 1 && fixtures[0].modeKey == "F0Md")
        precondition(fixtures[1].currentRPM == nil && fixtures[1].status == .missing)
        precondition(fixtures[1].mode == nil)
        let invalid = FanDiagnostics.snapshots(readings: ["FNum": reading(1),
            "F0Ac": reading(.nan), "F0Mn": reading(5000), "F0Mx": reading(1000),
            "F0Tg": reading(-1)])![0]
        precondition(invalid.currentRPM == nil && invalid.status == .failed)
        precondition(invalid.minimumRPM == nil && invalid.maximumRPM == nil && invalid.targetRPM == nil)
        precondition(FanDiagnostics.snapshots(readings: ["F2Ac": reading(2500)])?.first?.id == 2)
        let unsupported = FanDiagnostics.snapshots(readings: ["FNum": reading(1),
            "F0Ac": reading(nil, .unsupportedType), "F0md": reading(0), "F0Md": reading(1)])![0]
        precondition(unsupported.status == .unsupportedType && unsupported.currentRPM == nil)
        precondition(unsupported.mode == 0 && unsupported.modeKey == "F0md")
        let tooFast = FanDiagnostics.snapshots(readings: ["FNum": reading(1), "F0Ac": reading(30_001)])![0]
        precondition(tooFast.currentRPM == nil && tooFast.status == .failed)
        print("PASS fan fixtures: stopped/unknown, missing, invalid range, case-sensitive mode fallback, absent count")
        if CommandLine.arguments.contains("--live") {
            let sampler = HardwareSampler()
            let snapshot = await sampler.sample()
            if let fans = snapshot.fans {
                for fan in fans {
                    print("fan=\(fan.id) current=\(fan.currentRPM.map(String.init(describing:)) ?? "unknown") min=\(fan.minimumRPM.map(String.init(describing:)) ?? "unknown") max=\(fan.maximumRPM.map(String.init(describing:)) ?? "unknown") target=\(fan.targetRPM.map(String.init(describing:)) ?? "unknown") mode=\(fan.mode.map(String.init) ?? "unknown") modeKey=\(fan.modeKey ?? "unknown") status=\(fan.status)")
                }
                if fans.isEmpty { print("confirmed fanless") }
            } else { print("fan inventory unavailable") }
            await sampler.close()
        }
    }
}
