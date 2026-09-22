import Foundation

final class MockMetricsRunner: MPFPrivilegedMetricsRunner {
    var interval = 2
    var starts: [Int] = []
    var stops = 0
    var active = false
    var callback: MPFPrivilegedMetricsStateHandler?
    var dataCallback: MPFPrivilegedMetricsDataHandler?
    override func configureSamplingInterval(_ seconds: Int) -> Bool {
        guard !active, [2, 5, 10].contains(seconds) else { return false }
        interval = seconds; return true
    }
    override func startAllowingInstallation(_ allowInstallation: Bool, dataHandler: @escaping MPFPrivilegedMetricsDataHandler, stateHandler: @escaping MPFPrivilegedMetricsStateHandler) {
        assert(!allowInstallation)
        starts.append(interval); active = true; callback = stateHandler; dataCallback = dataHandler
        stateHandler(.running, nil)
    }
    override func stop() {
        stops += 1; callback?(.stopping, nil)
    }
    func finishStop() { active = false; callback?(.idle, nil) }
}

@main struct SamplerChecks {
    @MainActor static func main() {
        let runner = MockMetricsRunner()
        let sampler = PrivilegedPowerSampler(runner: runner)
        assert(!sampler.setSamplingInterval(seconds: 99))
        assert(sampler.setSamplingInterval(seconds: 5) && runner.starts.isEmpty)
        assert(sampler.start(onSample: { _ in }, onStateChange: { _ in }, completion: { assert($0 == nil) }))
        assert(runner.starts == [5])
        let oldCallback = runner.callback
        assert(sampler.setSamplingInterval(seconds: 10))
        assert(runner.stops == 1 && sampler.state == .stopping)
        assert(sampler.setSamplingInterval(seconds: 2)) // latest desired interval wins
        runner.finishStop()
        assert(runner.starts == [5, 2] && sampler.state == .running)
        oldCallback?(.failed, "old queued callback")
        assert(sampler.state == .running)
        assert(sampler.setSamplingInterval(seconds: 10))
        sampler.stop() // explicit stop revokes pending automatic cadence restart
        runner.finishStop()
        assert(runner.starts == [5, 2] && sampler.state == .idle)
        assert(sampler.setSamplingInterval(seconds: 5))
        assert(runner.starts == [5, 2])
        print("PASS: cadence restarts real runner facade, latest cadence wins, idle configuration cannot start, explicit stop cancels restart, stale callbacks rejected")
    }
}
