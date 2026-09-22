import XCTest
@testable import PowerMetricsCore

final class PowerMetricsCoreTests: XCTestCase {
    private let minimalPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>elapsed_ns</key><integer>2000000000</integer>
        <key>processor</key>
        <dict>
            <key>gpu_power</key><real>5816.4</real>
        </dict>
    </dict>
    </plist>
    """

    func testStreamDecoderEmitsLeadingNULXMLFrameImmediately() throws {
        var decoder = PowerMetricsFrameDecoder()
        var packet = Data([0])
        packet.append(Data(minimalPlist.utf8))

        let frames = try XCTUnwrap(decoder.append(packet))

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(decoder.bufferedByteCount, 0)
        let plist = try PropertyListSerialization.propertyList(
            from: XCTUnwrap(frames.first),
            options: [],
            format: nil
        )
        let root = try XCTUnwrap(plist as? [String: Any])
        let processor = try XCTUnwrap(root["processor"] as? [String: Any])
        XCTAssertEqual(
            PowerMetricsCore.resolvedSamplePowerWatts(
                domain: "gpu",
                processor: processor,
                root: root
            ) ?? -1,
            5.8164,
            accuracy: 0.000_001
        )
    }

    func testStreamDecoderReassemblesSplitXMLFrame() throws {
        var decoder = PowerMetricsFrameDecoder()
        var packet = Data([0])
        packet.append(Data(minimalPlist.utf8))
        let splitIndex = packet.count / 2

        XCTAssertTrue(try XCTUnwrap(
            decoder.append(packet[..<splitIndex])
        ).isEmpty)
        let frames = try XCTUnwrap(decoder.append(packet[splitIndex...]))

        XCTAssertEqual(frames, [Data(minimalPlist.utf8)])
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    func testStreamDecoderDoesNotDuplicateFramesAcrossLeadingSeparators() throws {
        var decoder = PowerMetricsFrameDecoder()
        var firstPacket = Data([0])
        firstPacket.append(Data(minimalPlist.utf8))
        var secondPacket = Data([0])
        secondPacket.append(Data(minimalPlist.utf8))

        let firstFrames = try XCTUnwrap(decoder.append(firstPacket))
        let secondFrames = try XCTUnwrap(decoder.append(secondPacket))

        XCTAssertEqual(firstFrames.count, 1)
        XCTAssertEqual(secondFrames.count, 1)
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    func testStreamDecoderAcceptsLegacyNULTerminatedFrame() throws {
        var decoder = PowerMetricsFrameDecoder()
        var packet = Data("legacy-frame".utf8)
        packet.append(0)

        XCTAssertEqual(
            try XCTUnwrap(decoder.append(packet)),
            [Data("legacy-frame".utf8)]
        )
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    func testStreamDecoderPreservesXMLAfterHarmlessInterFrameWhitespace() throws {
        var decoder = PowerMetricsFrameDecoder()
        var packet = Data("\n \t".utf8)
        packet.append(0)
        packet.append(Data(minimalPlist.utf8))

        XCTAssertEqual(
            try XCTUnwrap(decoder.append(packet)),
            [Data(minimalPlist.utf8)]
        )
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    func testStreamDecoderRetainsIncompleteFrameForNextChunk() throws {
        var decoder = PowerMetricsFrameDecoder()
        let partial = Data("<?xml version=\"1.0\"?><plist>".utf8)

        XCTAssertTrue(try XCTUnwrap(decoder.append(partial)).isEmpty)
        XCTAssertEqual(decoder.bufferedByteCount, partial.count)
    }

    func testStreamDecoderResynchronizesAtEarlierNULDelimiter() throws {
        var decoder = PowerMetricsFrameDecoder()
        var packet = Data("truncated-frame".utf8)
        packet.append(0)
        packet.append(Data(minimalPlist.utf8))

        let frames = try XCTUnwrap(decoder.append(packet))

        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames.first, Data("truncated-frame".utf8))
        XCTAssertEqual(frames.last, Data(minimalPlist.utf8))
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    func testStreamDecoderExtractsMultipleFramesInOneAppend() throws {
        var decoder = PowerMetricsFrameDecoder()
        var packet = Data([0])
        packet.append(Data(minimalPlist.utf8))
        packet.append(0)
        packet.append(Data(minimalPlist.utf8))

        let frames = try XCTUnwrap(decoder.append(packet))

        XCTAssertEqual(frames, [
            Data(minimalPlist.utf8),
            Data(minimalPlist.utf8),
        ])
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    func testStreamDecoderRejectsFrameThatCrossesByteLimit() throws {
        var decoder = PowerMetricsFrameDecoder()
        let firstChunk = Data("<plist>123456".utf8)

        XCTAssertTrue(try XCTUnwrap(decoder.append(
            firstChunk,
            maximumFrameBytes: firstChunk.count + 4
        )).isEmpty)
        XCTAssertNil(decoder.append(
            Data("7890</plist>".utf8),
            maximumFrameBytes: firstChunk.count + 4
        ))
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    func testStreamDecoderAcceptsLeadingNULFrameAtExactByteLimit() throws {
        var decoder = PowerMetricsFrameDecoder()
        let frame = Data(minimalPlist.utf8)
        var packet = Data([0])
        packet.append(frame)

        XCTAssertEqual(
            try XCTUnwrap(decoder.append(
                packet,
                maximumFrameBytes: frame.count
            )),
            [frame]
        )
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    func testPowermetricsPlistFieldsUseEnergyWhenCPUPowerIsZero() throws {
        let fixture = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>elapsed_ns</key><integer>2000000000</integer>
            <key>processor</key>
            <dict>
                <key>cpu_power</key><real>0</real>
                <key>cpu_energy</key><integer>7200</integer>
            </dict>
        </dict>
        </plist>
        """
        let plist = try PropertyListSerialization.propertyList(
            from: Data(fixture.utf8),
            options: [],
            format: nil
        )
        let root = try XCTUnwrap(plist as? [String: Any])
        let processor = try XCTUnwrap(root["processor"] as? [String: Any])

        let watts = PowerMetricsCore.resolvedSamplePowerWatts(
            domain: "cpu",
            processor: processor,
            root: root
        )

        XCTAssertEqual(watts ?? -1, 3.6, accuracy: 0.000_001)
    }

    func testEnergyFallbackReconstructsPowerWhenDirectFieldIsZero() {
        let watts = PowerMetricsCore.resolvedSamplePowerWatts(
            directMilliwatts: 0,
            energyMillijoules: 7_200,
            elapsedNanoseconds: 2_000_000_000
        )

        XCTAssertEqual(watts ?? -1, 3.6, accuracy: 0.000_001)
    }

    func testPositiveDirectPowerRemainsPreferred() {
        let watts = PowerMetricsCore.resolvedSamplePowerWatts(
            directMilliwatts: 4_200,
            energyMillijoules: 7_200,
            elapsedNanoseconds: 2_000_000_000
        )

        XCTAssertEqual(watts ?? -1, 4.2, accuracy: 0.000_001)
    }

    func testMissingDirectPowerFallsBackToEnergy() {
        let watts = PowerMetricsCore.resolvedSamplePowerWatts(
            directMilliwatts: nil,
            energyMillijoules: 1_500,
            elapsedNanoseconds: 1_000_000_000
        )

        XCTAssertEqual(watts ?? -1, 1.5, accuracy: 0.000_001)
    }

    func testInvalidElapsedTimeDoesNotDivideByZero() {
        XCTAssertNil(PowerMetricsCore.averagePowerWatts(
            energyMillijoules: 1_000,
            elapsedNanoseconds: 0
        ))
        XCTAssertNil(PowerMetricsCore.averagePowerWatts(
            energyMillijoules: 1_000,
            elapsedNanoseconds: nil
        ))
    }

    func testZeroAdministratorFrameFallsBackToStandardThenEstimate() {
        XCTAssertEqual(
            PowerMetricsCore.firstMeaningfulPowerWatts([0, 4.2, 6.7]),
            4.2,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            PowerMetricsCore.firstMeaningfulPowerWatts([0, 0, 6.7]),
            6.7,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            PowerMetricsCore.firstMeaningfulPowerWatts([8.1, 4.2, 6.7]),
            8.1,
            accuracy: 0.000_001
        )
    }

    func testProcessorOvershootScalesCPUAndGPUTogether() {
        let allocation = PowerMetricsCore.allocateProcessorPower(
            cpuCandidateWatts: 10,
            gpuCandidateWatts: 15,
            budgetWatts: 20
        )

        XCTAssertEqual(allocation.cpuWatts, 8, accuracy: 0.000_001)
        XCTAssertEqual(allocation.gpuWatts, 12, accuracy: 0.000_001)
        XCTAssertEqual(
            allocation.cpuWatts + allocation.gpuWatts,
            20,
            accuracy: 0.000_001
        )
    }

    func testProcessorAllocationLeavesInBudgetValuesUntouched() {
        let allocation = PowerMetricsCore.allocateProcessorPower(
            cpuCandidateWatts: 5,
            gpuCandidateWatts: 3,
            budgetWatts: 20
        )

        XCTAssertEqual(allocation.cpuWatts, 5, accuracy: 0.000_001)
        XCTAssertEqual(allocation.gpuWatts, 3, accuracy: 0.000_001)
    }

    func testChargingBalanceUsesDynamicPDTRMinusPSTRInsteadOfPPBR() {
        let balance = PowerMetricsCore.resolveChargingPowerBalance(
            smcPDTRWatts: 66.73,
            smcPSTRWatts: 44.98,
            smcPPBRWatts: 0.94,
            telemetrySystemPowerInWatts: nil,
            telemetrySystemLoadWatts: nil,
            telemetryBatteryPowerWatts: nil,
            packBatteryChargeWatts: nil
        )

        XCTAssertEqual(balance.source, .smcPDTRPSTR)
        XCTAssertEqual(balance.adapterInputWatts, 66.73, accuracy: 0.000_001)
        XCTAssertEqual(balance.systemLoadWatts, 44.98, accuracy: 0.000_001)
        XCTAssertEqual(balance.batteryChargeWatts, 21.75, accuracy: 0.000_001)
        XCTAssertEqual(
            balance.adapterInputWatts,
            balance.systemLoadWatts + balance.batteryChargeWatts,
            accuracy: 0.000_001
        )
    }

    func testChargingBalancePrefersAtomicTelemetryWhenSMCAlsoReconciles() {
        let balance = PowerMetricsCore.resolveChargingPowerBalance(
            smcPDTRWatts: 66.73,
            smcPSTRWatts: 44.98,
            smcPPBRWatts: 0.94,
            telemetrySystemPowerInWatts: 64.245,
            telemetrySystemLoadWatts: 35.513,
            telemetryBatteryPowerWatts: 28.732,
            packBatteryChargeWatts: 28.4
        )

        XCTAssertEqual(balance.source, .powerTelemetry)
        XCTAssertEqual(balance.adapterInputWatts, 64.245, accuracy: 0.000_001)
        XCTAssertEqual(balance.systemLoadWatts, 35.513, accuracy: 0.000_001)
        XCTAssertEqual(balance.batteryChargeWatts, 28.732, accuracy: 0.000_001)
    }

    func testChargingBalanceKeepsAtomicTelemetryTupleTogether() {
        let balance = PowerMetricsCore.resolveChargingPowerBalance(
            smcPDTRWatts: nil,
            smcPSTRWatts: nil,
            smcPPBRWatts: 0.97,
            telemetrySystemPowerInWatts: 84.481,
            telemetrySystemLoadWatts: 61.814,
            telemetryBatteryPowerWatts: 22.667,
            packBatteryChargeWatts: 22.2
        )

        XCTAssertEqual(balance.source, .powerTelemetry)
        XCTAssertEqual(balance.adapterInputWatts, 84.481, accuracy: 0.000_001)
        XCTAssertEqual(balance.systemLoadWatts, 61.814, accuracy: 0.000_001)
        XCTAssertEqual(balance.batteryChargeWatts, 22.667, accuracy: 0.000_001)
    }

    func testChargingBalanceRejectsGrosslyLaggingSMCResidualWithPackPower() {
        let balance = PowerMetricsCore.resolveChargingPowerBalance(
            smcPDTRWatts: 90,
            smcPSTRWatts: 20,
            smcPPBRWatts: 1,
            telemetrySystemPowerInWatts: nil,
            telemetrySystemLoadWatts: nil,
            telemetryBatteryPowerWatts: nil,
            packBatteryChargeWatts: 19.260
        )

        XCTAssertEqual(balance.source, .adapterAndBattery)
        XCTAssertEqual(balance.adapterInputWatts, 90, accuracy: 0.000_001)
        XCTAssertEqual(balance.systemLoadWatts, 70.740, accuracy: 0.000_001)
        XCTAssertEqual(balance.batteryChargeWatts, 19.260, accuracy: 0.000_001)
    }

    func testChargingBalanceDerivesMissingSystemLegFromPackPower() {
        let balance = PowerMetricsCore.resolveChargingPowerBalance(
            smcPDTRWatts: 80.376,
            smcPSTRWatts: nil,
            smcPPBRWatts: 0.95,
            telemetrySystemPowerInWatts: nil,
            telemetrySystemLoadWatts: nil,
            telemetryBatteryPowerWatts: nil,
            packBatteryChargeWatts: 19.260
        )

        XCTAssertEqual(balance.source, .adapterAndBattery)
        XCTAssertEqual(balance.systemLoadWatts, 61.116, accuracy: 0.000_001)
        XCTAssertEqual(
            balance.adapterInputWatts,
            balance.systemLoadWatts + balance.batteryChargeWatts,
            accuracy: 0.000_001
        )
    }

    func testChargingBalanceDerivesMissingAdapterLegFromPackPower() {
        let balance = PowerMetricsCore.resolveChargingPowerBalance(
            smcPDTRWatts: nil,
            smcPSTRWatts: 61.116,
            smcPPBRWatts: 0.95,
            telemetrySystemPowerInWatts: nil,
            telemetrySystemLoadWatts: nil,
            telemetryBatteryPowerWatts: nil,
            packBatteryChargeWatts: 19.260
        )

        XCTAssertEqual(balance.source, .systemAndBattery)
        XCTAssertEqual(balance.adapterInputWatts, 80.376, accuracy: 0.000_001)
        XCTAssertEqual(balance.systemLoadWatts, 61.116, accuracy: 0.000_001)
    }

    func testChargingBalanceDoesNotInventPowerFromPPBRAlone() {
        let balance = PowerMetricsCore.resolveChargingPowerBalance(
            smcPDTRWatts: nil,
            smcPSTRWatts: nil,
            smcPPBRWatts: 5,
            telemetrySystemPowerInWatts: nil,
            telemetrySystemLoadWatts: nil,
            telemetryBatteryPowerWatts: nil,
            packBatteryChargeWatts: nil
        )

        XCTAssertEqual(balance.source, .unavailable)
        XCTAssertEqual(balance.adapterInputWatts, 0)
        XCTAssertEqual(balance.systemLoadWatts, 0)
        XCTAssertEqual(balance.batteryChargeWatts, 0)
    }

    func testChargingBalanceRejectsNonFinitePartialSamples() {
        let balance = PowerMetricsCore.resolveChargingPowerBalance(
            smcPDTRWatts: .nan,
            smcPSTRWatts: .infinity,
            smcPPBRWatts: 4,
            telemetrySystemPowerInWatts: nil,
            telemetrySystemLoadWatts: nil,
            telemetryBatteryPowerWatts: nil,
            packBatteryChargeWatts: nil
        )

        XCTAssertEqual(balance.source, .unavailable)
    }

    func testChargingEvidenceRejectsStaleUnbalancedTelemetry() {
        XCTAssertFalse(PowerMetricsCore.hasCorroboratedChargingPower(
            telemetrySystemPowerInWatts: 80,
            telemetrySystemLoadWatts: 61,
            telemetryBatteryPowerWatts: 4,
            positivePackPowerWatts: 0
        ))
    }

    func testChargingEvidenceAcceptsBalancedTelemetryOrPositivePackPower() {
        XCTAssertTrue(PowerMetricsCore.hasCorroboratedChargingPower(
            telemetrySystemPowerInWatts: 80,
            telemetrySystemLoadWatts: 61,
            telemetryBatteryPowerWatts: 19,
            positivePackPowerWatts: 0
        ))
        XCTAssertTrue(PowerMetricsCore.hasCorroboratedChargingPower(
            telemetrySystemPowerInWatts: nil,
            telemetrySystemLoadWatts: nil,
            telemetryBatteryPowerWatts: nil,
            positivePackPowerWatts: 7.5
        ))
    }

    func testIOPowerSourcesChargingSignalIsAccepted() {
        let state = BatteryStateCore.resolve(batterySignals(
            powerSourcesIsCharging: true,
            powerSourcesOnAC: true
        ))

        XCTAssertTrue(state.isOnAC)
        XCTAssertTrue(state.isCharging)
        XCTAssertFalse(state.isFullyCharged)
    }

    func testRawExternalConnectionKeepsACStateWhenPrimaryKeyLags() {
        let state = BatteryStateCore.resolve(batterySignals(
            rawRegistryOnAC: true
        ))

        XCTAssertTrue(state.isOnAC)
        XCTAssertFalse(state.isCharging)
        XCTAssertFalse(state.isFullyCharged)
    }

    func testActiveChargeWinsOverStaleFullFlag() {
        let state = BatteryStateCore.resolve(batterySignals(
            registryIsCharging: true,
            registryFullyCharged: true,
            registryOnAC: true
        ))

        XCTAssertTrue(state.isCharging)
        XCTAssertFalse(state.isFullyCharged)
    }

    func testChargerCurrentAloneDoesNotInventCharging() {
        let state = BatteryStateCore.resolve(batterySignals(
            registryOnAC: true,
            chargingCurrentMilliamps: 2_000
        ))

        XCTAssertTrue(state.isOnAC)
        XCTAssertFalse(state.isCharging)
    }

    func testCorroboratedChargerCurrentRecoversMissingBoolean() {
        let state = BatteryStateCore.resolve(batterySignals(
            registryOnAC: true,
            chargingCurrentMilliamps: 2_000,
            hasMeasuredBatteryPower: true
        ))

        XCTAssertTrue(state.isCharging)
        XCTAssertFalse(state.isFullyCharged)
    }

    func testFullBatteryOnACRemainsIdle() {
        let state = BatteryStateCore.resolve(batterySignals(
            registryFullyCharged: true,
            powerSourcesOnAC: true,
            chargingCurrentMilliamps: 2_000,
            hasMeasuredBatteryPower: true
        ))

        XCTAssertTrue(state.isOnAC)
        XCTAssertFalse(state.isCharging)
        XCTAssertTrue(state.isFullyCharged)
    }

    func testSignedTelemetryHandlesReal20WAdapterSupplementFixture() throws {
        let balance = signedBalance(input: 19.402, load: 31.891, battery: -12.489, pack: -16.155545)
        XCTAssertEqual(balance.source, .powerTelemetry)
        XCTAssertEqual(try XCTUnwrap(balance.systemLoadWatts), 31.891, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(balance.signedBatteryWatts), -12.489, accuracy: 0.000001)
        XCTAssertTrue(balance.isSupplementingAdapter)
        XCTAssertTrue(balance.isCoherent)
    }

    func testSignedIdleZeroIsAvailableRatherThanMissing() {
        let balance = signedBalance(input: 20, load: 20, battery: 0)
        XCTAssertEqual(balance.signedBatteryWatts, 0)
        XCTAssertEqual(balance.source, .powerTelemetry)
        XCTAssertFalse(balance.isSupplementingAdapter)
        XCTAssertEqual(PowerMetricsCore.firstAvailablePowerWatts([0, 7]), 0)
        XCTAssertNil(PowerMetricsCore.firstAvailablePowerWatts([nil, .nan, -1]))
    }

    func testMissingBatteryPowerIsNotInventedAsZero() {
        let balance = signedBalance(input: nil, load: nil, battery: nil)
        XCTAssertNil(balance.signedBatteryWatts)
        XCTAssertNil(balance.systemLoadWatts)
        XCTAssertFalse(balance.isCoherent)
    }

    func testChargingAndBatteryOnlySignedBalance() {
        let charge = signedBalance(input: 80, load: 50, battery: 30)
        XCTAssertEqual(charge.signedBatteryWatts, 30)
        let discharge = signedBalance(input: nil, load: nil, battery: nil, pack: -15, onAC: false)
        XCTAssertEqual(discharge.adapterInputWatts, 0)
        XCTAssertEqual(discharge.systemLoadWatts, 15)
        XCTAssertEqual(discharge.source, .batteryOnly)
    }

    func testInvalidSignedPowerCannotCreateAValidBalance() {
        for invalid in [Double.nan, .infinity, -.infinity, 200, -200] {
            let balance = signedBalance(input: nil, load: nil, battery: invalid, pack: invalid)
            XCTAssertNil(balance.signedBatteryWatts)
            XCTAssertFalse(balance.isCoherent)
        }
    }

    func testSignedPackFallbackAddsDischargeToAdapterRatherThanSubtracting() throws {
        let balance = signedBalance(input: 19.402, load: nil, battery: nil, pack: -16.155545)
        XCTAssertEqual(try XCTUnwrap(balance.systemLoadWatts), 35.557545, accuracy: 0.000001)
        XCTAssertEqual(balance.source, .adapterAndBattery)
        XCTAssertTrue(balance.isSupplementingAdapter)
    }

    func testNegativeAtomicPowerOverridesEveryStaleChargingBoolean() {
        var signals = batterySignals(registryIsCharging: true, chargerIsCharging: true,
                                     powerSourcesIsCharging: true, registryOnAC: true)
        signals.signedBatteryPowerWatts = -12.489
        let state = BatteryStateCore.resolve(signals)
        XCTAssertTrue(state.isOnAC)
        XCTAssertFalse(state.isCharging)
    }

    func testZeroBatteryPowerOverridesStaleChargingBoolean() {
        var signals = batterySignals(registryIsCharging: true, registryFullyCharged: true, registryOnAC: true)
        signals.signedBatteryPowerWatts = 0
        let state = BatteryStateCore.resolve(signals)
        XCTAssertFalse(state.isCharging)
        XCTAssertTrue(state.isFullyCharged)
    }

    func testUnpluggedNegativePackDoesNotInheritACFromStaleChargeFlag() {
        var signals = batterySignals(registryIsCharging: true)
        signals.signedBatteryPowerWatts = -15
        let state = BatteryStateCore.resolve(signals)
        XCTAssertFalse(state.isOnAC)
        XCTAssertFalse(state.isCharging)
        let balance = signedBalance(input: 80, load: 50, battery: 30, pack: -15, onAC: false)
        XCTAssertEqual(balance.systemLoadWatts, 15)
        XCTAssertEqual(balance.source, .batteryOnly)
    }

    func testUnpluggedPositivePackCannotInventACFromLaggingChargeFlag() {
        var signals = batterySignals(registryIsCharging: true)
        signals.signedBatteryPowerWatts = 15
        let state = BatteryStateCore.resolve(signals)
        XCTAssertFalse(state.isOnAC)
        XCTAssertFalse(state.isCharging)
    }

    func testStaleTelemetryIsExcludedAndSignedPackControlsDirection() {
        let balance = signedBalance(input: 80, load: 50, battery: 30, pack: -15, usable: false)
        XCTAssertNil(balance.adapterInputWatts)
        XCTAssertEqual(balance.signedBatteryWatts, -15)
        XCTAssertEqual(balance.source, .unavailable)
    }

    func testUnknownSignedPowerRetainsExistingBooleanFallback() {
        var signals = batterySignals(registryIsCharging: true, registryOnAC: true)
        for unknown: Double? in [nil, .nan, .infinity] {
            signals.signedBatteryPowerWatts = unknown
            XCTAssertTrue(BatteryStateCore.resolve(signals).isCharging)
        }
    }

    func testDirectionTransitionsDoNotCarryPriorTuple() {
        for battery in [30.0, 0, -12, 0, 5] {
            var signals = batterySignals(registryIsCharging: true, registryOnAC: true)
            signals.signedBatteryPowerWatts = battery
            XCTAssertEqual(BatteryStateCore.resolve(signals).isCharging, battery > 0)
            let balance = signedBalance(input: 20, load: 20 - battery, battery: battery)
            if battery <= 20 { XCTAssertEqual(balance.signedBatteryWatts, battery) }
        }
    }

    func testRepeatedCachedTelemetryBecomesStaleWithoutForgingHardwareTimestamp() {
        var freshness = TelemetryFreshnessState()
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(freshness.observe(fingerprint: "a", uptime: 10, date: start), .unverified)
        XCTAssertEqual(freshness.observe(fingerprint: "a", uptime: 19, date: start.addingTimeInterval(9)), .unverified)
        XCTAssertEqual(freshness.observe(fingerprint: "a", uptime: 20, date: start.addingTimeInterval(10)), .stale)
        XCTAssertEqual(freshness.lastChangedAt, start)
        XCTAssertEqual(freshness.observe(fingerprint: "b", uptime: 21, date: start.addingTimeInterval(11)), .fresh)
        XCTAssertEqual(freshness.lastChangedAt, start.addingTimeInterval(11))
        XCTAssertEqual(freshness.observe(fingerprint: nil, uptime: 22, date: start), .unavailable)
        XCTAssertNil(freshness.lastChangedAt)
    }

    func testFullIdlePackDoesNotBecomeChargingFromSmallSMCResidual() throws {
        let balance = PowerMetricsCore.resolvePowerBalance(
            smcPDTRWatts: 17.661, smcPSTRWatts: 17.264,
            telemetrySystemPowerInWatts: 17.264, telemetrySystemLoadWatts: 17.264,
            telemetryBatteryPowerWatts: 0, signedPackBatteryWatts: 0,
            isOnAC: true, telemetryIsUsable: false)
        XCTAssertEqual(balance.adapterInputWatts, 17.661)
        XCTAssertEqual(balance.systemLoadWatts, 17.264)
        XCTAssertEqual(balance.signedBatteryWatts, 0)
        XCTAssertEqual(balance.source, .smcPDTRPSTR)
        XCTAssertEqual(try XCTUnwrap(balance.residualWatts), 0.397, accuracy: 0.000001)
        var signals = batterySignals(registryIsCharging: true, registryFullyCharged: true, registryOnAC: true)
        signals.signedBatteryPowerWatts = balance.signedBatteryWatts
        let state = BatteryStateCore.resolve(signals)
        XCTAssertFalse(state.isCharging)
        XCTAssertTrue(state.isFullyCharged)
    }

    func testLowMeasuredPackFlowsArePreservedDespiteContradictingSMCDifference() {
        for pack in [-0.3, -0.05, 0, 0.05, 0.3] {
            let balance = PowerMetricsCore.resolvePowerBalance(
                smcPDTRWatts: 17, smcPSTRWatts: 17.397,
                telemetrySystemPowerInWatts: nil, telemetrySystemLoadWatts: nil,
                telemetryBatteryPowerWatts: nil, signedPackBatteryWatts: pack,
                isOnAC: true)
            XCTAssertEqual(balance.signedBatteryWatts, pack)
            XCTAssertEqual(balance.systemLoadWatts, 17.397)
            XCTAssertEqual(balance.adapterInputWatts, 17)
            var signals = batterySignals(registryOnAC: true)
            signals.signedBatteryPowerWatts = balance.signedBatteryWatts
            XCTAssertEqual(BatteryStateCore.resolve(signals).isCharging, pack > 0.02)
        }
    }

    func testSMCStillDerivesBatteryWhenPackGaugeIsMissingOrInvalid() throws {
        for pack: Double? in [nil, .nan, .infinity] {
            let balance = PowerMetricsCore.resolvePowerBalance(
                smcPDTRWatts: 17.661, smcPSTRWatts: 17.264,
                telemetrySystemPowerInWatts: nil, telemetrySystemLoadWatts: nil,
                telemetryBatteryPowerWatts: nil, signedPackBatteryWatts: pack,
                isOnAC: true)
            XCTAssertEqual(try XCTUnwrap(balance.signedBatteryWatts), 0.397, accuracy: 0.000001)
            XCTAssertEqual(try XCTUnwrap(balance.residualWatts), 0, accuracy: 0.000001)
        }
    }

    func testCoherentAtomicChargingTupleStillWinsOverDifferentPackWindow() {
        let balance = PowerMetricsCore.resolvePowerBalance(
            smcPDTRWatts: 17.661, smcPSTRWatts: 17.264,
            telemetrySystemPowerInWatts: 17.661, telemetrySystemLoadWatts: 17.264,
            telemetryBatteryPowerWatts: 0.397, signedPackBatteryWatts: 0,
            isOnAC: true)
        XCTAssertEqual(balance.source, .powerTelemetry)
        XCTAssertEqual(balance.signedBatteryWatts, 0.397)
    }

    func testLargeSMCResidualWithIdlePackPreservesRawSystemLoad() throws {
        let balance = PowerMetricsCore.resolvePowerBalance(
            smcPDTRWatts: 19.07, smcPSTRWatts: 12,
            telemetrySystemPowerInWatts: nil, telemetrySystemLoadWatts: nil,
            telemetryBatteryPowerWatts: nil, signedPackBatteryWatts: 0, isOnAC: true)
        XCTAssertEqual(balance.adapterInputWatts, 19.07)
        XCTAssertEqual(balance.systemLoadWatts, 12)
        XCTAssertEqual(balance.signedBatteryWatts, 0)
        XCTAssertEqual(balance.source, .smcPDTRPSTR)
        XCTAssertEqual(try XCTUnwrap(balance.residualWatts), 7.07, accuracy: 0.000001)
        XCTAssertFalse(balance.isCoherent)
    }

    func testLargeSMCResidualConflictingWithDischargingPackKeepsAllMeasuredLegs() {
        let balance = PowerMetricsCore.resolvePowerBalance(
            smcPDTRWatts: 20, smcPSTRWatts: 10,
            telemetrySystemPowerInWatts: nil, telemetrySystemLoadWatts: nil,
            telemetryBatteryPowerWatts: nil, signedPackBatteryWatts: -12, isOnAC: true)
        XCTAssertEqual(balance.adapterInputWatts, 20)
        XCTAssertEqual(balance.systemLoadWatts, 10)
        XCTAssertEqual(balance.signedBatteryWatts, -12)
        XCTAssertEqual(balance.residualWatts, 22)
        XCTAssertFalse(balance.isCoherent)
    }

    func testImpossibleResidualDoesNotEraseKnownInputAndSystemReadings() {
        let balance = PowerMetricsCore.resolvePowerBalance(
            smcPDTRWatts: 400, smcPSTRWatts: 10,
            telemetrySystemPowerInWatts: nil, telemetrySystemLoadWatts: nil,
            telemetryBatteryPowerWatts: nil, signedPackBatteryWatts: nil, isOnAC: true)
        XCTAssertEqual(balance.adapterInputWatts, 400)
        XCTAssertEqual(balance.systemLoadWatts, 10)
        XCTAssertNil(balance.signedBatteryWatts)
        XCTAssertEqual(balance.source, .smcPDTRPSTR)
        XCTAssertFalse(balance.isCoherent)
    }

    private func signedBalance(input: Double?, load: Double?, battery: Double?,
                               pack: Double? = nil, onAC: Bool = true,
                               usable: Bool = true) -> PowerBalance {
        PowerMetricsCore.resolvePowerBalance(
            smcPDTRWatts: nil, smcPSTRWatts: nil,
            telemetrySystemPowerInWatts: input, telemetrySystemLoadWatts: load,
            telemetryBatteryPowerWatts: battery, signedPackBatteryWatts: pack,
            isOnAC: onAC, telemetryIsUsable: usable
        )
    }

    private func batterySignals(
        registryIsCharging: Bool = false,
        chargerIsCharging: Bool = false,
        powerSourcesIsCharging: Bool = false,
        registryFullyCharged: Bool = false,
        powerSourcesFullyCharged: Bool = false,
        registryOnAC: Bool = false,
        rawRegistryOnAC: Bool = false,
        powerSourcesOnAC: Bool = false,
        chargingCurrentMilliamps: Double = 0,
        hasMeasuredBatteryPower: Bool = false
    ) -> BatteryStateSignals {
        BatteryStateSignals(
            registryIsCharging: registryIsCharging,
            chargerIsCharging: chargerIsCharging,
            powerSourcesIsCharging: powerSourcesIsCharging,
            registryFullyCharged: registryFullyCharged,
            powerSourcesFullyCharged: powerSourcesFullyCharged,
            registryOnAC: registryOnAC,
            rawRegistryOnAC: rawRegistryOnAC,
            powerSourcesOnAC: powerSourcesOnAC,
            chargingCurrentMilliamps: chargingCurrentMilliamps,
            hasMeasuredBatteryPower: hasMeasuredBatteryPower
        )
    }
}
