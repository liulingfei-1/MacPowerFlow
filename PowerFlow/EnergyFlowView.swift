import AppKit
import SwiftUI

struct EnergyFlowView: View {
    @ObservedObject var model: PowerMonitor
    @State private var detailExpanded = false

    private let accent = Color(red: 0.10, green: 0.78, blue: 0.38)
    private let background = Color(red: 0.075, green: 0.082, blue: 0.092)
    private let panel = Color(red: 0.17, green: 0.18, blue: 0.20)
    private let secondary = Color.white.opacity(0.64)

    var body: some View {
        ZStack {
            background.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    statusStrip
                    batteryRail
                    powerFlow
                    componentDetailCard
                    hardwareCard
                    processCard
                    footer
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 16)
            }
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [.clear, background.opacity(0.96)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 14)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .frame(width: 420)
        .environment(\.colorScheme, .dark)
    }

    private var statusStrip: some View {
        HStack(spacing: 7) {
            statusPill(
                adapterLimitText,
                symbol: "powerplug.fill"
            )
            statusPill(
                powerSourceText,
                symbol: model.isOnAC ? "bolt.fill" : "battery.100"
            )
            statusPill(
                chargeStateText,
                symbol: chargeStateSymbol
            )

            Spacer(minLength: 0)

            Button {
                model.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(panel)
                            .overlay {
                                Circle()
                                    .stroke(Color.white.opacity(0.11), lineWidth: 1)
                            }
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.white.opacity(0.72))
            .help("立即刷新")
            .accessibilityLabel("立即刷新功耗数据")
        }
    }

    private var batteryRail: some View {
        GeometryReader { geometry in
            let progress = model.batteryPresent && model.batteryLevel >= 0
                ? CGFloat(min(max(model.batteryLevel, 0), 100)) / 100
                : 1
            let railStart = model.isCharging
                ? accent.opacity(0.74)
                : Color.white.opacity(0.24)
            let railEnd = model.isCharging
                ? accent.opacity(0.96)
                : Color.white.opacity(0.42)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(panel)
                    .overlay {
                        Capsule()
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    }

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [railStart, railEnd],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(34, geometry.size.width * progress))

                HStack(spacing: 7) {
                    Text(batteryRailValue)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .monospacedDigit()

                    Image(systemName: batteryRailSymbol)
                        .font(.system(size: 12, weight: .bold))

                    Spacer()

                    Text(batteryRailDetail)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.76))
                }
                .padding(.horizontal, 13)
            }
        }
        .frame(height: 36)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("电池状态")
        .accessibilityValue(
            model.batteryPresent
                ? "电量 \(max(model.batteryLevel, 0))%，\(chargeStateText)，\(batteryRailDetail)"
                : "无内置电池，\(powerSourceText)"
        )
    }

    private var powerFlow: some View {
        SculptedPowerFlow(
            isOnAC: model.isOnAC,
            batteryPresent: model.batteryPresent,
            batteryDirection: model.batteryFlowDirection,
            sourcePower: model.isOnAC
                ? model.adapterInputWatts
                : model.batteryFlowWatts,
            batteryPower: model.batteryFlowWatts,
            systemPower: model.systemLoadWatts,
            cpuPower: model.effectiveCPUPowerWatts,
            gpuPower: model.effectiveGPUPowerWatts,
            displayPower: model.effectiveDisplayPowerWatts,
            unclassifiedPower: model.effectiveOtherPowerWatts
        )
        .frame(height: 228)
    }

    private var componentDetailCard: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    detailExpanded.toggle()
                }
            } label: {
                HStack(spacing: 9) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.07))
                            .frame(width: 30, height: 30)
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.66))
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("其他功耗分项")
                            .font(.system(size: 12, weight: .semibold))
                        Text("当前功耗分配")
                            .font(.system(size: 9.5))
                            .foregroundStyle(secondary)
                    }

                    Spacer()

                    Text(watts(model.effectiveOtherPowerWatts))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .monospacedDigit()

                    Image(systemName: detailExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(secondary)
                }
                .contentShape(Rectangle())
                .padding(12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(detailExpanded ? "收起分项详情" : "展开分项详情")

            if detailExpanded {
                hairline
                    .padding(.horizontal, 12)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("当前分配")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(secondary)
                        Spacer()
                        Text(watts(model.effectiveOtherPowerWatts, allowZero: true))
                            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color.white.opacity(0.62))
                    }

                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 6),
                            GridItem(.flexible(), spacing: 6)
                        ],
                        spacing: 6
                    ) {
                        ForEach(model.readableOtherPowerComponents) { item in
                            miniMetric(
                                item.label,
                                watts(item.powerWatts, allowZero: true)
                            )
                            .help(item.basis)
                        }

                        ForEach(model.estimatedOtherPowerComponents) { item in
                            miniMetric(
                                item.label,
                                watts(item.powerWatts, allowZero: true)
                            )
                            .help(item.basis)
                        }
                    }

                    Text(otherModelNote)
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color.white.opacity(0.52))
                        .fixedSize(horizontal: false, vertical: true)

                    Text(
                        "“其他”是整机负载扣除 CPU、GPU 与显示后的剩余功耗；"
                            + "分项会随系统活动及可用传感器同步变化。"
                    )
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.56))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .graphiteCard()
    }

    private var hardwareCard: some View {
        VStack(spacing: 0) {
            cardHeader("电源与电池", symbol: "battery.100")

            if model.batteryPresent {
                metricRow(
                    "电池温度",
                    symbol: "thermometer.medium",
                    value: temperature(model.batteryTempC)
                )
                metricRow(
                    model.isFullyCharged
                        ? "充电状态"
                        : (model.isCharging ? "预计充满" : "预计可用"),
                    symbol: "clock",
                    value: model.batteryTimeText
                )
                metricRow(
                    "电池电气",
                    symbol: "waveform.path.ecg",
                    value: electrical(
                        voltage: model.batteryVoltage,
                        current: model.batteryCurrent
                    )
                )
                metricRow(
                    "健康与循环",
                    symbol: "heart.text.square",
                    value: healthText,
                    detail: model.cycleCount > 0 ? "\(model.cycleCount) 次" : nil
                )
                metricRow(
                    "当前 / 满充容量",
                    symbol: "gauge.with.dots.needle.50percent",
                    value: capacityText
                )
                hairline.padding(.horizontal, 12)
            }

            metricRow(
                "适配器输入",
                symbol: "powerplug.fill",
                value: watts(model.adapterInputWatts),
                detail: model.adapterRatedWatts > 0
                    ? "上限 \(watts(model.adapterRatedWatts))"
                    : nil
            )
            metricRow(
                "适配器电气",
                symbol: "bolt.horizontal.fill",
                value: electrical(
                    voltage: model.adapterVoltage,
                    current: model.adapterCurrent
                ),
                detail: model.adapterName.isEmpty ? nil : model.adapterName
            )
            metricRow(
                "转换损耗 / 对外供电",
                symbol: "arrow.left.arrow.right",
                value: "\(watts(model.adapterEfficiencyLossWatts, allowZero: true))  /  \(watts(model.externalPowerOutWatts, allowZero: true))"
            )
            metricRow(
                "整机负载",
                symbol: "laptopcomputer",
                value: watts(model.systemLoadWatts),
                detail: model.lowPowerModeEnabled ? "低电量已开" : "低电量已关"
            )

            hairline.padding(.horizontal, 12)
            cardHeader("芯片与散热", symbol: "cpu")

            if model.administratorSamplingState == .active {
                metricRow(
                    "CPU / GPU 活跃度",
                    symbol: "speedometer",
                    value: "\(administratorPercent(model.administratorCPUActivePercent))  /  \(administratorPercent(model.administratorGPUActivePercent))"
                )
                metricRow(
                    "CPU / GPU 频率",
                    symbol: "waveform.path",
                    value: "\(administratorFrequency(model.administratorCPUFrequencyMHz))  /  \(administratorFrequency(model.administratorGPUFrequencyMHz))"
                )
                metricRow(
                    "增强热压力",
                    symbol: "thermometer.and.liquid.waves",
                    value: model.administratorSampleIsFresh
                        ? model.administratorThermalPressureText
                        : "—",
                    detail: "连续样本 \(model.administratorSampleCount)"
                )
            }
            metricRow(
                "CPU 平均 / 热点",
                symbol: "thermometer.high",
                value: "\(temperature(model.cpuTempC))  /  \(temperature(model.cpuDieHotspotC))"
            )
            metricRow(
                "GPU 温度 / 频率",
                symbol: "rectangle.3.group",
                value: "\(temperature(model.gpuTempC))  /  \(frequency(model.effectiveGPUFrequencyMHz))"
            )
            metricRow(
                "能效核活跃 / 频率",
                symbol: "e.circle",
                value: cluster(
                    usage: model.efficiencyClusterUsagePercent,
                    frequency: model.efficiencyClusterFrequencyMHz
                )
            )
            metricRow(
                "性能核活跃 / 频率",
                symbol: "p.circle",
                value: cluster(
                    usage: model.performanceClusterUsagePercent,
                    frequency: model.performanceClusterFrequencyMHz
                )
            )
            if model.superClusterFrequencyMHz > 0
                || model.superClusterUsagePercent > 0
            {
                metricRow(
                    "超大核活跃 / 频率",
                    symbol: "s.circle",
                    value: cluster(
                        usage: model.superClusterUsagePercent,
                        frequency: model.superClusterFrequencyMHz
                    )
                )
            }
            metricRow(
                "GPU 活跃度",
                symbol: "speedometer",
                value: percent(model.gpuUsagePercent),
                detail: "CPU \(percent(model.cpuUsagePercent))"
            )
            metricRow(
                "风扇转速",
                symbol: "fan",
                value: fanSummary,
                detail: model.thermalStateText
            )
        }
        .graphiteCard()
    }

    private var processCard: some View {
        VStack(spacing: 0) {
            if model.topProcesses.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(accent)
                    Text("没有明显的高 CPU 进程")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("当前稳定")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(secondary)
                }
                .padding(.horizontal, 13)
                .frame(minHeight: 48)
            } else {
                cardHeader("当前高负载进程", symbol: "chart.bar.xaxis")
                ForEach(model.topProcesses) { process in
                    HStack(spacing: 9) {
                        Text(process.name.prefix(1).uppercased())
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .frame(width: 24, height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.white.opacity(0.07))
                            )
                        Text(process.name)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                        Spacer()
                        Text(String(format: "%.1f%% CPU", process.cpuPercent))
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.63))
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 34)
                }
                Text("进程显示的是 CPU 占用，不是逐应用瓦数。")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.white.opacity(0.44))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(accent.opacity(0.09))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(accent.opacity(0.18), lineWidth: 1)
                }
        )
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.isSampling ? accent : Color.orange)
                .frame(width: 5, height: 5)
            Text(model.isSampling ? "实时采样" : "等待采样")
            administratorFooterStatus
            Spacer(minLength: 4)
            Text(lastUpdatedText)
            Text(model.chipName)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .font(.system(size: 9.5, weight: .medium))
        .foregroundStyle(Color.white.opacity(0.44))
        .padding(.horizontal, 2)
    }

    private var administratorFooterStatus: some View {
        HStack(spacing: 3) {
            if administratorStateIsTransitioning {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.54)
                    .frame(width: 10, height: 10)
            } else {
                Image(systemName: administratorStatusSymbol)
                    .font(.system(size: 8.5, weight: .semibold))
            }

            Text(administratorStatusText)
                .lineLimit(1)
        }
        .foregroundStyle(administratorStatusColor)
        .help(administratorStatusHelp)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(administratorStatusHelp)
    }

    private func statusPill(_ title: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .bold))
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .foregroundStyle(Color.white.opacity(0.74))
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(
            Capsule()
                .fill(panel)
                .overlay {
                    Capsule()
                        .stroke(Color.white.opacity(0.11), lineWidth: 1)
                }
        )
        .accessibilityElement(children: .combine)
    }

    private func miniMetric(
        _ label: String,
        _ value: String,
        detail: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.45))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(value)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            if let detail {
                Text(detail)
                    .font(.system(size: 7.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }
        }
        .padding(.horizontal, 8)
        .frame(
            maxWidth: .infinity,
            minHeight: detail == nil ? 40 : 50,
            alignment: .leading
        )
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue([value, detail].compactMap { $0 }.joined(separator: "，"))
    }

    private func cardHeader(_ title: String, symbol: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.58))
                .frame(width: 15)
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.76))
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    private func metricRow(
        _ label: String,
        symbol: String,
        value: String,
        detail: String? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.48))
                .frame(width: 15)

            Text(label)
                .font(.system(size: 10.8))
                .foregroundStyle(Color.white.opacity(0.56))

            Spacer(minLength: 8)

            if let detail {
                Text(detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.white.opacity(0.42))
                    .lineLimit(1)
            }

            Text(value)
                .font(.system(size: 10.8, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.84))
                .lineLimit(1)
                .minimumScaleFactor(0.74)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 29)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue([detail, value].compactMap { $0 }.joined(separator: "，"))
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.white.opacity(0.09))
            .frame(height: 1)
    }

    private var adapterLimitText: String {
        model.adapterRatedWatts > 0
            ? "上限 \(compactWatts(model.adapterRatedWatts))"
            : "电源上限 —"
    }

    private var powerSourceText: String {
        guard hasSample else { return "读取中" }
        return model.isOnAC ? "外接电源" : "电池供电"
    }

    private var chargeStateText: String {
        guard hasSample else { return "采样中" }
        guard model.batteryPresent else { return "无电池" }
        if model.isFullyCharged { return "已充满" }
        if model.isCharging { return "充电中" }
        return "未充电"
    }

    private var chargeStateSymbol: String {
        if model.isCharging { return "plus.circle.fill" }
        if model.isFullyCharged { return "checkmark.circle.fill" }
        return "minus.circle"
    }

    private var administratorStateIsTransitioning: Bool {
        switch model.administratorSamplingState {
        case .authorizing, .starting, .stopping:
            return true
        case .inactive, .active, .failed:
            return false
        }
    }

    private var administratorStatusSymbol: String {
        switch model.administratorSamplingState {
        case .inactive, .authorizing, .starting, .stopping:
            return "shield"
        case .active:
            return "checkmark.shield.fill"
        case .failed:
            return "exclamationmark.shield.fill"
        }
    }

    private var administratorStatusColor: Color {
        switch model.administratorSamplingState {
        case .active:
            return model.administratorSampleIsFresh
                ? accent
                : Color.yellow.opacity(0.78)
        case .failed:
            return .orange
        case .inactive, .authorizing, .starting, .stopping:
            return Color.white.opacity(0.48)
        }
    }

    private var administratorStatusText: String {
        switch model.administratorSamplingState {
        case .inactive:
            return "标准采样"
        case .authorizing:
            return "连接服务"
        case .starting:
            return "增强启动"
        case .active:
            return model.administratorSampleIsFresh ? "免密增强" : "增强等待"
        case .stopping:
            return "增强停止"
        case .failed:
            return "增强失败"
        }
    }

    private var administratorStatusHelp: String {
        switch model.administratorSamplingState {
        case .inactive:
            return "增强服务尚未启动，当前使用标准采样"
        case .authorizing:
            return "正在连接增强服务；首次使用时只需批准安装一次"
        case .starting:
            return "增强服务已连接，正在等待第一组 CPU / GPU 数据"
        case .active:
            return model.administratorSampleIsFresh
                ? "免密增强采样已启用"
                : "免密增强采样已启用，正在等待兼容样本"
        case .stopping:
            return "正在停止增强采样"
        case .failed:
            return model.administratorErrorMessage.isEmpty
                ? "增强服务启动失败"
                : model.administratorErrorMessage
        }
    }

    private var batteryRailValue: String {
        guard hasSample else { return "—" }
        return model.batteryPresent ? "\(max(model.batteryLevel, 0))" : "AC"
    }

    private var batteryRailSymbol: String {
        if !model.batteryPresent { return "powerplug.fill" }
        return model.isCharging ? "bolt.fill" : "battery.100"
    }

    private var batteryRailDetail: String {
        guard hasSample else { return "正在读取传感器" }
        guard model.batteryPresent else { return "无内置电池" }
        return model.batteryTimeText
    }

    private var hasSample: Bool {
        model.lastUpdated != Date.distantPast
    }

    private var healthText: String {
        guard model.healthPercent > 0 else { return "—" }
        return "\(model.healthPercent)%"
    }

    private var capacityText: String {
        guard model.fullCapacityMAh > 0 else { return "—" }
        return "\(model.currentCapacityMAh) / \(model.fullCapacityMAh) mAh"
    }

    private var fanSummary: String {
        if model.fanRPM > 0, model.fan2RPM > 0 {
            return "\(model.fanRPM) / \(model.fan2RPM) RPM"
        }
        if model.fanRPM > 0 {
            return "\(model.fanRPM) RPM"
        }
        return "—"
    }

    private var otherModelNote: String {
        let readRate = max(0, model.dramReadBytesPerSecond)
        let writeRate = max(0, model.dramWriteBytesPerSecond)
        let memoryRate = readRate > Int64.max - writeRate
            ? Int64.max
            : readRate + writeRate
        var signals = ["整机负载", "芯片活跃度"]
        if memoryRate > 0 {
            signals.append("内存带宽 \(bandwidth(memoryRate))")
        }
        if model.fanRPM > 0 || model.fan2RPM > 0 {
            signals.append("风扇 \(fanSummary)")
        }
        return "跟随" + signals.joined(separator: "、")
            + "同步更新，每次采样都会重新分配。"
    }

    private var lastUpdatedText: String {
        guard hasSample else { return "等待首次采样" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: model.lastUpdated)
    }

    private func watts(
        _ value: Double,
        allowZero: Bool = false
    ) -> String {
        guard value > 0.02 || allowZero else { return "—" }
        let number = value >= 100
            ? String(format: "%.0f", value)
            : String(format: "%.1f", max(0, value))
        return "\(number) W"
    }

    private func administratorPercent(_ value: Double) -> String {
        model.administratorSampleIsFresh ? percent(value) : "—"
    }

    private func administratorFrequency(_ value: Int) -> String {
        model.administratorSampleIsFresh ? frequency(value) : "—"
    }

    private func compactWatts(_ value: Double) -> String {
        value >= 100
            ? String(format: "%.0fW", value)
            : String(format: "%.1fW", value)
    }

    private func temperature(_ value: Double) -> String {
        value > 0 ? String(format: "%.1f°C", value) : "—"
    }

    private func percent(_ value: Double) -> String {
        value >= 0 ? String(format: "%.0f%%", value) : "—"
    }

    private func frequency(_ value: Int) -> String {
        value > 0 ? String(format: "%.2f GHz", Double(value) / 1000) : "—"
    }

    private func bandwidth(_ bytesPerSecond: Int64) -> String {
        guard bytesPerSecond > 0 else { return "—" }
        let rate = Double(bytesPerSecond)
        if rate >= 1_000_000_000 {
            return String(format: "%.1f GB/s", rate / 1_000_000_000)
        }
        if rate >= 1_000_000 {
            return String(format: "%.0f MB/s", rate / 1_000_000)
        }
        return String(format: "%.0f KB/s", rate / 1_000)
    }

    private func cluster(usage: Double, frequency: Int) -> String {
        let usageText = usage > 0 ? String(format: "%.0f%%", usage) : "—"
        return "\(usageText)  /  \(self.frequency(frequency))"
    }

    private func electrical(voltage: Double, current: Double) -> String {
        guard voltage > 0 else { return "—" }
        if abs(current) > 0.001 {
            return String(format: "%.1f V  ·  %+.2f A", voltage, current)
        }
        return String(format: "%.1f V", voltage)
    }
}

private struct FlowBandBounds {
    let top: CGFloat
    let bottom: CGFloat

    var center: CGFloat { (top + bottom) / 2 }
    var height: CGFloat { max(0, bottom - top) }
}

private struct FlowBranchDefinition {
    let id: Int
    let label: String
    let symbol: String
    let iconSize: CGFloat
    let power: Double
    let emphasized: Bool
}

private struct FlowBranchLayout: Identifiable {
    let definition: FlowBranchDefinition
    let left: FlowBandBounds
    let right: FlowBandBounds

    var id: Int { definition.id }

    func bounds(at progress: CGFloat) -> FlowBandBounds {
        let clamped = min(max(progress, 0), 1)
        let eased = clamped * clamped * (3 - 2 * clamped)
        return FlowBandBounds(
            top: left.top + (right.top - left.top) * eased,
            bottom: left.bottom + (right.bottom - left.bottom) * eased
        )
    }
}

private struct FlowRibbonShape: Shape {
    let startX: CGFloat
    let endX: CGFloat
    var leftTop: CGFloat
    var leftBottom: CGFloat
    var rightTop: CGFloat
    var rightBottom: CGFloat

    var animatableData:
        AnimatablePair<
            AnimatablePair<CGFloat, CGFloat>,
            AnimatablePair<CGFloat, CGFloat>
        >
    {
        get {
            AnimatablePair(
                AnimatablePair(leftTop, leftBottom),
                AnimatablePair(rightTop, rightBottom)
            )
        }
        set {
            leftTop = newValue.first.first
            leftBottom = newValue.first.second
            rightTop = newValue.second.first
            rightBottom = newValue.second.second
        }
    }

    func path(in _: CGRect) -> Path {
        let distance = endX - startX
        let firstControlX = startX + distance * 0.38
        let secondControlX = endX - distance * 0.32

        var path = Path()
        path.move(to: CGPoint(x: startX, y: leftTop))
        path.addCurve(
            to: CGPoint(x: endX, y: rightTop),
            control1: CGPoint(x: firstControlX, y: leftTop),
            control2: CGPoint(x: secondControlX, y: rightTop)
        )
        path.addLine(to: CGPoint(x: endX, y: rightBottom))
        path.addCurve(
            to: CGPoint(x: startX, y: leftBottom),
            control1: CGPoint(x: secondControlX, y: rightBottom),
            control2: CGPoint(x: firstControlX, y: leftBottom)
        )
        path.closeSubpath()
        return path
    }
}

private struct SculptedPowerFlow: View {
    let isOnAC: Bool
    let batteryPresent: Bool
    let batteryDirection: BatteryFlowDirection
    let sourcePower: Double
    let batteryPower: Double
    let systemPower: Double
    let cpuPower: Double
    let gpuPower: Double
    let displayPower: Double
    let unclassifiedPower: Double

    private let fill = Color(red: 0.19, green: 0.20, blue: 0.22)
    private let strongFill = Color(red: 0.22, green: 0.23, blue: 0.25)
    private let stroke = Color.white.opacity(0.13)
    private let text = Color.white.opacity(0.88)
    private let quiet = Color.white.opacity(0.60)
    private let chargingAccent = Color(red: 0.10, green: 0.78, blue: 0.38)

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let canvasHeight = proxy.size.height
            let secondaryNodeWidth: CGFloat = 124
            let secondaryNodeHeight: CGFloat = 32
            let sourceBlockWidth: CGFloat = 46
            let capWidth: CGFloat = 92
            let capX = width - capWidth
            let systemX = width * 0.42
            let systemWidth: CGFloat = 64
            let branchStart = systemX + systemWidth - 1
            let branchEnd = capX + 1
            let inputX = sourceBlockWidth + 6
            let inputWidth = systemX - inputX + 1
            let systemTop: CGFloat = 66
            let secondaryLinkStartX = secondaryNodeWidth - 2
            let secondaryLinkEndX = systemX + 1
            let secondaryLinkHeight = secondarySourceLinkHeight()
            let secondaryLink = FlowRibbonShape(
                startX: secondaryLinkStartX,
                endX: secondaryLinkEndX,
                leftTop: 22 - secondaryLinkHeight / 2,
                leftBottom: 22 + secondaryLinkHeight / 2,
                rightTop: systemTop,
                rightBottom: systemTop + secondaryLinkHeight
            )
            let layouts = branchLayouts(canvasHeight: canvasHeight)

            ZStack {
                secondaryLink
                    .fill(fill)
                    .overlay {
                        secondaryLink.stroke(stroke, lineWidth: 1)
                    }
                    .animation(
                        .easeInOut(duration: 0.35),
                        value: safePower(batteryPower)
                    )

                ForEach(layouts) { branch in
                    let ribbon = FlowRibbonShape(
                        startX: branchStart,
                        endX: branchEnd,
                        leftTop: branch.left.top,
                        leftBottom: branch.left.bottom,
                        rightTop: branch.right.top,
                        rightBottom: branch.right.bottom
                    )

                    ribbon
                        .fill(
                            branch.definition.emphasized
                                ? strongFill
                                : fill
                        )
                        .overlay {
                            ribbon.stroke(stroke, lineWidth: 1)
                        }
                        .animation(
                            .easeInOut(duration: 0.35),
                            value: branch.definition.power
                        )
                }

                Canvas { context, _ in
                    drawStaticBlocks(
                        context: &context,
                        inputX: inputX,
                        inputWidth: inputWidth,
                        systemX: systemX,
                        systemWidth: systemWidth,
                        canvasHeight: canvasHeight
                    )
                }
                .accessibilityHidden(true)

                ForEach(layouts) { branch in
                    RoundedRectangle(
                        cornerRadius: min(
                            14,
                            max(6, branch.right.height / 2)
                        ),
                        style: .continuous
                    )
                    .fill(
                        branch.definition.emphasized
                            ? strongFill
                            : fill
                    )
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: min(
                                14,
                                max(6, branch.right.height / 2)
                            ),
                            style: .continuous
                        )
                        .stroke(stroke, lineWidth: 1)
                    }
                    .frame(width: capWidth, height: branch.right.height)
                    .position(
                        x: capX + capWidth / 2,
                        y: branch.right.center
                    )
                }

                secondarySourceNode(
                    width: secondaryNodeWidth,
                    height: secondaryNodeHeight
                )
                .position(
                    x: secondaryNodeWidth / 2,
                    y: 22
                )

                sourceLabels(
                    inputX: inputX,
                    inputWidth: inputWidth,
                    canvasHeight: canvasHeight
                )
                systemLabel(
                    x: systemX + systemWidth / 2,
                    width: systemWidth - 10,
                    canvasHeight: canvasHeight
                )

                ForEach(layouts) { branch in
                    branchDestinationLabel(
                        branch.definition,
                        width: capWidth,
                        height: branch.right.height
                    )
                    .position(
                        x: capX + capWidth / 2,
                        y: branch.right.center
                    )
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("当前能量流")
        .accessibilityValue(accessibilitySummary)
    }

    private func drawStaticBlocks(
        context: inout GraphicsContext,
        inputX: CGFloat,
        inputWidth: CGFloat,
        systemX: CGFloat,
        systemWidth: CGFloat,
        canvasHeight: CGFloat
    ) {
        let bottom = canvasHeight - 4

        drawRounded(
            CGRect(x: 0, y: 52, width: 46, height: bottom - 52),
            radius: 17,
            fill: strongFill,
            in: &context
        )

        var inputPath = Path()
        inputPath.move(to: CGPoint(x: inputX, y: 52))
        inputPath.addCurve(
            to: CGPoint(x: inputX + inputWidth, y: 66),
            control1: CGPoint(x: inputX + inputWidth * 0.46, y: 52),
            control2: CGPoint(x: inputX + inputWidth * 0.62, y: 66)
        )
        inputPath.addLine(to: CGPoint(x: inputX + inputWidth, y: bottom))
        inputPath.addLine(to: CGPoint(x: inputX, y: bottom))
        inputPath.closeSubpath()
        fillAndStroke(inputPath, fill: strongFill, in: &context)

        drawRounded(
            CGRect(x: systemX, y: 66, width: systemWidth, height: bottom - 66),
            radius: 13,
            fill: strongFill,
            in: &context
        )
    }

    private func drawRounded(
        _ rect: CGRect,
        radius: CGFloat,
        fill color: Color,
        in context: inout GraphicsContext
    ) {
        let path = Path(roundedRect: rect, cornerRadius: radius)
        fillAndStroke(path, fill: color, in: &context)
    }

    private func fillAndStroke(
        _ path: Path,
        fill color: Color,
        in context: inout GraphicsContext
    ) {
        context.fill(path, with: .color(color))
        context.stroke(path, with: .color(stroke), lineWidth: 1)
    }

    private func sourceLabels(
        inputX: CGFloat,
        inputWidth: CGFloat,
        canvasHeight: CGFloat
    ) -> some View {
        let centerY = (52 + canvasHeight - 4) / 2

        return ZStack {
            Image(systemName: isOnAC ? "powerplug.fill" : "battery.100")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(quiet)
                .position(x: 23, y: centerY)

            VStack(spacing: 4) {
                Text(isOnAC ? "适配器" : "电池")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(quiet)
                Text(watt(sourcePower))
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(text)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)
                    .allowsTightening(true)
            }
            .frame(width: max(42, inputWidth - 14))
            .position(x: inputX + inputWidth / 2, y: centerY)
        }
    }

    private func secondarySourceNode(
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        let charging = isOnAC
            && batteryPresent
            && batteryDirection == .charging

        return HStack(spacing: 6) {
            Image(systemName: secondarySourceSymbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(charging ? chargingAccent : quiet)

            Text(secondarySourceText)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(text)
                .lineLimit(1)
                .minimumScaleFactor(0.64)
                .allowsTightening(true)
        }
        .padding(.horizontal, 9)
        .frame(width: width, height: height, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                .fill(charging ? chargingAccent.opacity(0.13) : fill)
                .overlay {
                    RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                        .stroke(
                            charging ? chargingAccent.opacity(0.42) : stroke,
                            lineWidth: 1
                        )
                }
        )
    }

    private func secondarySourceLinkHeight() -> CGFloat {
        let secondaryPower =
            isOnAC && batteryPresent ? safePower(batteryPower) : 0
        let referencePower = max(
            1,
            safePower(sourcePower),
            safePower(systemPower)
        )
        let ratio = min(1, secondaryPower / referencePower)
        return 10 + 10 * CGFloat(pow(ratio, 0.55))
    }

    private var secondarySourceText: String {
        guard isOnAC else { return "未接适配器" }
        guard batteryPresent else { return "无内置电池" }

        let state: String
        switch batteryDirection {
        case .charging:
            state = "充电"
        case .supplying:
            state = "放电"
        case .idle, .unknown, .unavailable:
            state = "待机"
        }
        return "\(state)  \(compactWatt(batteryPower, allowZero: true))"
    }

    private var secondarySourceSymbol: String {
        guard isOnAC else { return "powerplug" }
        guard batteryPresent else { return "minus" }
        return batterySymbol
    }

    private func systemLabel(
        x: CGFloat,
        width: CGFloat,
        canvasHeight: CGFloat
    ) -> some View {
        let centerY = (66 + canvasHeight - 4) / 2

        return VStack(spacing: 5) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(quiet)
            Text(compactWatt(systemPower))
                .font(.system(size: 14.5, weight: .bold, design: .rounded))
                .foregroundStyle(text)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.56)
                .allowsTightening(true)
            Text("系统")
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(quiet)
        }
        .frame(width: width)
        .position(x: x, y: centerY)
    }

    private func branchLayouts(canvasHeight: CGFloat) -> [FlowBranchLayout] {
        let definitions = [
            FlowBranchDefinition(
                id: 0,
                label: "CPU",
                symbol: "cpu",
                iconSize: 13,
                power: safePower(cpuPower),
                emphasized: true
            ),
            FlowBranchDefinition(
                id: 1,
                label: "GPU",
                symbol: "rectangle.3.group",
                iconSize: 12,
                power: safePower(gpuPower),
                emphasized: true
            ),
            FlowBranchDefinition(
                id: 2,
                label: "显示",
                symbol: "display",
                iconSize: 10,
                power: safePower(displayPower),
                emphasized: false
            ),
            FlowBranchDefinition(
                id: 3,
                label: "其他",
                symbol: "ellipsis",
                iconSize: 13,
                power: safePower(unclassifiedPower),
                emphasized: false
            )
        ]
        let weights = definitions.map {
            pow(max($0.power, 0.05), 0.72)
        }
        let leftBands = bandBounds(
            weights: weights,
            top: 70,
            bottom: canvasHeight - 10,
            gap: 5,
            preferredMinimum: 18
        )
        let rightBands = bandBounds(
            weights: Array(repeating: 1, count: definitions.count),
            top: 2,
            bottom: canvasHeight - 2,
            gap: 5,
            preferredMinimum: 42
        )

        return definitions.indices.map { index in
            FlowBranchLayout(
                definition: definitions[index],
                left: leftBands[index],
                right: rightBands[index]
            )
        }
    }

    private func bandBounds(
        weights: [Double],
        top: CGFloat,
        bottom: CGFloat,
        gap: CGFloat,
        preferredMinimum: CGFloat
    ) -> [FlowBandBounds] {
        guard !weights.isEmpty else { return [] }

        let gapTotal = gap * CGFloat(max(0, weights.count - 1))
        let available = max(0, bottom - top - gapTotal)
        let minimum = min(
            preferredMinimum,
            available / CGFloat(weights.count)
        )
        let distributable = max(
            0,
            available - minimum * CGFloat(weights.count)
        )
        let totalWeight = max(0.0001, weights.reduce(0, +))
        var cursor = top

        return weights.indices.map { index in
            let height = minimum
                + distributable * CGFloat(weights[index] / totalWeight)
            let bandBottom = index == weights.indices.last
                ? bottom
                : cursor + height
            let bounds = FlowBandBounds(top: cursor, bottom: bandBottom)
            cursor = bandBottom + gap
            return bounds
        }
    }

    private func branchDestinationLabel(
        _ branch: FlowBranchDefinition,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: branch.symbol)
                .font(.system(size: branch.iconSize, weight: .medium))
                .foregroundStyle(quiet)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(branch.label)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(quiet)
                    .lineLimit(1)

                Text(compactWatt(branch.power))
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                    .allowsTightening(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 9)
        .frame(width: width, height: height, alignment: .leading)
        .clipped()
    }

    private var batterySymbol: String {
        batteryDirection == .charging ? "battery.100.bolt" : "battery.100"
    }

    private var accessibilitySummary: String {
        [
            isOnAC
                ? "适配器输入 \(watt(sourcePower))"
                : "电池输出 \(watt(sourcePower))",
            isOnAC
                ? "电池功率 \(watt(batteryPower, allowZero: true))"
                : "未连接适配器",
            "系统负载 \(watt(systemPower))",
            "CPU \(watt(cpuPower))",
            "GPU \(watt(gpuPower))",
            "显示 \(watt(displayPower))",
            "其他 \(watt(unclassifiedPower))"
        ].joined(separator: "；")
    }

    private func safePower(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }

    private func compactWatt(
        _ value: Double,
        allowZero: Bool = false
    ) -> String {
        guard value > 0.02 || allowZero else { return "—" }
        let number = value >= 100
            ? String(format: "%.0f", value)
            : String(format: "%.1f", max(0, value))
        return "\(number)W"
    }

    private func watt(
        _ value: Double,
        allowZero: Bool = false
    ) -> String {
        guard value > 0.02 || allowZero else { return "—" }
        let number = value >= 100
            ? String(format: "%.0f", value)
            : String(format: "%.1f", max(0, value))
        return "\(number) W"
    }
}

private extension View {
    func graphiteCard() -> some View {
        background(
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .fill(Color(red: 0.17, green: 0.18, blue: 0.20))
                .overlay {
                    RoundedRectangle(cornerRadius: 19, style: .continuous)
                        .stroke(Color.white.opacity(0.11), lineWidth: 1)
                }
        )
    }
}
