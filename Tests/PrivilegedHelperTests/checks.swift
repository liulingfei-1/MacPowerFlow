// Appended to production helper source in a temporary test module, without its @main.
@main private enum HelperPolicyChecks {
    private static func require(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }
    private static func perform(_ coordinator: LowPowerCoordinator, source: Int, setting: Int?,
                                authorized: @escaping () -> Bool = { true }) async -> (Bool, Bool, String?) {
        await withCheckedContinuation { continuation in
            coordinator.perform(source: source, setting: setting, isAuthorized: authorized) {
                continuation.resume(returning: ($0, $1, $2))
            }
        }
    }
    static func main() async {
        for interval in [2, 5, 10] {
            let arguments = MPFPrivilegedService.samplingArguments(intervalSeconds: interval)!
            require(arguments[3] == String(interval * 1000), "actual powermetrics sample-rate")
            require(arguments.enumerated().allSatisfy { $0.offset == 3 || $0.element == MPFPrivilegedService.powermetricsArguments[$0.offset] }, "no other command arguments change")
        }
        for interval in [-1, 0, 1, 3, 10000] {
            require(MPFPrivilegedService.samplingArguments(intervalSeconds: interval) == nil, "interval whitelist")
        }
        for source in [-1, 2, Int.max] { require(MPFLowPowerPolicy.arguments(source: source, enabled: 1) == nil, "source whitelist") }
        for value in [-1, 2, Int.max] { require(MPFLowPowerPolicy.arguments(source: 0, enabled: value) == nil, "boolean whitelist") }
        require(MPFLowPowerPolicy.arguments(source: 0, enabled: 1) == ["-b", "lowpowermode", "1"], "fixed battery arguments")
        require(MPFLowPowerPolicy.arguments(source: 1, enabled: 0) == ["-c", "lowpowermode", "0"], "fixed AC arguments")
        require(!MPFLowPowerPolicy.supportsLowPower("notlowpowermode"), "capability whole token")
        let off = "Battery Power:\n lowpowermode 0\nAC Power:\n lowpowermode 1\n"
        require(MPFLowPowerPolicy.configuredValue(source: 0, output: off) == false, "battery section scoped")
        require(MPFLowPowerPolicy.configuredValue(source: 1, output: off) == true, "AC section scoped")
        require(MPFLowPowerPolicy.configuredValue(source: 0, output: "Battery Power:\n lowpowermode 9\n") == nil, "unknown system value")
        var calls: [[String]] = []
        var enabled = false
        let good = LowPowerCoordinator { arguments in
            calls.append(arguments)
            if arguments == ["-g", "cap"] { return "Capabilities for AC Power:\n lowpowermode\n" }
            if arguments == ["-g", "custom"] { return "Battery Power:\n lowpowermode \(enabled ? 1 : 0)\nAC Power:\n lowpowermode 0\n" }
            require(arguments == ["-b", "lowpowermode", "1"], "executor sees only fixed write")
            enabled = true; return ""
        }
        let query = await perform(good, source: 0, setting: nil)
        require(query.0 && !query.1 && calls.allSatisfy { $0.first == "-g" }, "query never writes")
        calls.removeAll()
        let set = await perform(good, source: 0, setting: 1)
        require(set.0 && set.1 && calls == [["-g", "cap"], ["-g", "custom"], ["-b", "lowpowermode", "1"], ["-g", "custom"]], "write preflight and verified readback")
        calls.removeAll()
        let idempotent = await perform(good, source: 0, setting: 1)
        require(idempotent.0 && calls.allSatisfy { $0.first == "-g" }, "already set avoids redundant write")
        let unsupported = LowPowerCoordinator { arguments in require(arguments == ["-g", "cap"], "unsupported must stop before write"); return "sleep" }
        require(!(await perform(unsupported, source: 0, setting: 1)).0, "unsupported rejection")
        let invalid = LowPowerCoordinator { _ in fatalError("invalid/disconnected must never run a command") }
        require(!(await perform(invalid, source: 99, setting: 1)).0, "invalid source rejected helper side")
        require(!(await perform(invalid, source: 0, setting: 2)).0, "invalid boolean rejected helper side")
        require(!(await perform(invalid, source: 0, setting: 1, authorized: { false })).0, "closed connection rejected")
        var authorizationChecks = 0
        let cancelledBeforeWrite = LowPowerCoordinator { arguments in
            require(arguments.first == "-g", "cancelled queued request must not write")
            return arguments == ["-g", "cap"] ? "lowpowermode" : "Battery Power:\n lowpowermode 0\n"
        }
        let cancelled = await perform(cancelledBeforeWrite, source: 0, setting: 1, authorized: {
            authorizationChecks += 1
            return authorizationChecks == 1
        })
        require(!cancelled.0 && authorizationChecks == 2, "connection rechecked immediately before mutation")
        let mismatch = LowPowerCoordinator { arguments in
            arguments == ["-g", "cap"] ? "lowpowermode" : "Battery Power:\n lowpowermode 0\n"
        }
        let mismatched = await perform(mismatch, source: 0, setting: 1)
        require(!mismatched.0 && mismatched.2 != nil, "mismatched readback never success")
        let failed = LowPowerCoordinator { _ in throw HelperFailure.message("fixture process timeout") }
        require(!(await perform(failed, source: 0, setting: 1)).0, "process failure reaches caller")
        let rejectedStart: Bool = await withCheckedContinuation { continuation in
            MetricsCoordinator.shared.start(owner: UUID(), intervalSeconds: 99, sendData: { _ in }, sendFailure: { _ in }) { ok, _ in
                continuation.resume(returning: !ok)
            }
        }
        require(rejectedStart, "helper rejects invalid sampling interval before spawning")
        if CommandLine.arguments.contains("--live-query") {
            for source in [0, 1] {
                let value = await perform(LowPowerCoordinator.shared, source: source, setting: nil)
                require(value.0, "real read-only pmset capability/query should complete")
                print("READ-ONLY: source=\(source), lowPowerEnabled=\(value.1)")
            }
        }
        print("PASS: helper fixed command policy, cadence whitelist, both-side invalid rejection, cap check, query-only, readback, idempotence, cancelled authorization, process failure; all setting commands mocked")
    }
}
