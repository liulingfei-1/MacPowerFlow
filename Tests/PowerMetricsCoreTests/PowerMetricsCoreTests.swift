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
