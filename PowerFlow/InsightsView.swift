import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

struct InsightsView: View {
    @ObservedObject var model: PowerMonitor
    @State private var expanded: Bool
    init(model: PowerMonitor, initiallyExpanded: Bool = false) {
        self.model = model
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isSupplementingAdapter {
                Label("已接电源，电池正在补电", systemImage: "battery.25")
                    .foregroundStyle(.orange)
            }
            DisclosureGroup("诊断与历史", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 16) {
                    charging
                    quality
                    memory
                    activity
                    HistoryPanel(history: model.history)
                    AlertPanel(alerts: model.alerts)
                    DiagnosticsPanel(diagnostics: model.diagnostics)
                }.padding(.top, 12)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(.primary)
        .padding(12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
    }

    var charging: some View {
        VStack(alignment: .leading, spacing: 7) {
            title("充电诊断", "powerplug")
            if let battery = model.latestBattery {
                row("输入 / 系统", "\(watts(model.isOnAC ? model.adapterInputWatts : nil)) / \(watts(model.systemLoadAvailable ? model.systemLoadWatts : nil))")
                row("电池流向", model.signedBatteryWatts.map { value in
                    abs(value) <= 0.2 ? "闲置" : "\(value > 0 ? "充入" : "输出") \(watts(abs(value)))"
                } ?? "不可用")
                if let profile = battery.currentPDProfile {
                    row("协商档位", String(format: "%.1f V × %.2f A · 上限 %.0f W", profile.voltage, profile.current, profile.maximumWatts))
                }
                if !battery.pdProfiles.isEmpty {
                    Text("可用档位：" + battery.pdProfiles.map { String(format: "%.0f V / %.2f A", $0.voltage, $0.current) }.joined(separator: "、"))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let reason = battery.chargerNotChargingReason, reason != 0 { row("不充电原因码", "\(reason)（系统原始码）") }
                if let reason = battery.chargerSlowChargingReason, reason != 0 { row("慢充原因码", "\(reason)（系统原始码）") }
                if battery.isOnAC && !model.isCharging && !model.isSupplementingAdapter {
                    Text("已接电源但未充电可能是满电、优化充电或控制器暂缓；不单凭状态码推断故障。")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    var quality: some View {
        VStack(alignment: .leading, spacing: 7) {
            title("读数与来源", "waveform.path.ecg")
            row("整机来源", model.powerSourceLabel)
            if let residual = model.powerBalanceResidual, abs(residual) > 0.25 {
                row("跨来源平衡差额", String(format: "%+.2f W", residual))
            }
            row("CPU / GPU 原始值", "\(watts(model.rawCPUWatts)) / \(watts(model.rawGPUWatts))")
            row("能量采样窗口", model.sampleDuration > 0 ? String(format: "%.2f 秒 · %@", model.sampleDuration, model.samplingStatus == "available" ? "有效" : "建立基线") : "建立基线 / 暂不可用")
            row("当前刷新间隔", String(format: "%.0f 秒", model.samplingIntervalSeconds))
            if let battery = model.latestBattery {
                row("电源遥测", freshness(battery.telemetryFreshness))
            }
            if model.flowWasAdjusted {
                Text("流图已按整机预算调整宽度和显示值；上方原始读数与导出数据保留原值。")
                    .foregroundStyle(.orange)
            }
            Text("CPU/GPU来自 Apple 能量模型或 powermetrics 估算。不同来源可能不同步；未知显示 —，有效零值保留0。")
                .foregroundStyle(.secondary)
        }
    }

    var memory: some View {
        VStack(alignment: .leading, spacing: 7) {
            title("内存状态", "memorychip")
            if let memory = model.insights?.memory {
                row("使用 / 总量", "\(bytes(Double(memory.usedBytes))) / \(bytes(Double(memory.totalBytes)))")
                row("压力", memory.pressure.map { $0 == .normal ? "正常" : ($0 == .warning ? "偏高" : "严重") } ?? "不可用")
                row("压缩 / Swap", "\(bytes(Double(memory.compressedBytes))) / \(bytes(memory.swapUsedBytes.map(Double.init)))")
                row("Swap 换入 / 换出", "\(rate(memory.swapInBytesPerSecond)) / \(rate(memory.swapOutBytesPerSecond))")
            } else { Text("等待内存样本").foregroundStyle(.secondary) }
        }
    }

    var activity: some View {
        VStack(alignment: .leading, spacing: 7) {
            title("耗电原因 · 活动指标", "list.bullet.rectangle")
            if let insights = model.insights {
                row("物理网卡 接收 / 发送", "\(rate(insights.network?.readBytesPerSecond)) / \(rate(insights.network?.writeBytesPerSecond))")
                row("物理磁盘 读取 / 写入", "\(rate(insights.disk?.readBytesPerSecond)) / \(rate(insights.disk?.writeBytesPerSecond))")
                Text("高 CPU 进程 · 单核100%") .foregroundStyle(.secondary)
                if !model.processDataReady { Text(model.processStatusText).foregroundStyle(.secondary) }
                ForEach(insights.topProcesses ?? []) { process in
                    row(process.name, process.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "建立基线")
                }
                Text("GPU 活动 · 毫秒/秒，不是瓦数").foregroundStyle(.secondary)
                if let gpu = insights.topGPUProcesses, !gpu.isEmpty {
                    ForEach(gpu) { process in
                        row(process.name, process.gpuMillisecondsPerSecond.map { String(format: "%.1f ms/s", $0) } ?? "建立基线")
                    }
                } else { Text(insights.gpuActivityAvailable ? "当前无有效活动样本" : "本机暂不可用").foregroundStyle(.secondary) }
                Text("阻止空闲睡眠").foregroundStyle(.secondary)
                if let assertions = insights.powerAssertions {
                    let blocking = assertions.filter { $0.kind == .systemSleep || $0.kind == .displaySleep }
                    if blocking.isEmpty { Text("没有相关有效声明").foregroundStyle(.secondary) }
                    ForEach(blocking.prefix(8)) { assertion in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(assertion.name) · \(assertion.kind == .systemSleep ? "系统" : "显示器")")
                            Text(assertion.reason).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                } else { Text("不可用").foregroundStyle(.secondary) }
                Text("活动指标每10秒更新；进程分别列出，不将CPU时间、GPU时间或网络流量换算成应用瓦数。")
                    .foregroundStyle(.secondary)
            } else { Text("正在建立活动基线").foregroundStyle(.secondary) }
        }
    }

    private func freshness(_ value: TelemetryFreshness) -> String {
        switch value {
        case .fresh: "已观察到更新"
        case .stale: "未更新，已停止用于功率平衡"
        case .unverified: "首次读取 / 时间未确认"
        case .unavailable: "不可用"
        }
    }
    private func title(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.system(size: 12, weight: .semibold)).padding(.top, 3)
    }
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).lineLimit(2)
            Spacer(minLength: 8)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }
    private func watts(_ value: Double?) -> String { value.map { String(format: "%.2f W", $0) } ?? "—" }
    private func bytes(_ value: Double?) -> String { value.map { $0 == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: Int64(max(0, $0)), countStyle: .memory) } ?? "—" }
    private func rate(_ value: Double?) -> String { value == nil ? "—" : bytes(value) + "/s" }
}

struct HistoryChartPoint: Identifiable {
    let timestamp: Date
    let watts: Double
    let segment: Int
    var id: Date { timestamp }
}

func historyChartPoints(_ points: [PowerHistoryPoint]) -> [HistoryChartPoint] {
    var segment = 0
    var result: [HistoryChartPoint] = []
    for point in points {
        guard point.quality.canIntegrate, let watts = point.systemWatts else { segment += 1; continue }
        if point.startsNewSegment { segment += 1 }
        result.append(HistoryChartPoint(timestamp: point.timestamp, watts: watts, segment: segment))
    }
    return result
}

struct HistoryPanel: View {
    @ObservedObject var history: PowerHistoryStore
    @State private var duration: Double = 900
    @State private var sessionName = "任务"
    @State private var exportMessage = ""
    @State private var exporting = false
    @State private var comparisonA: UUID?
    @State private var comparisonB: UUID?

    private var since: Date { (history.points.last?.timestamp ?? Date()).addingTimeInterval(-duration) }
    private var plotted: [HistoryChartPoint] {
        historyChartPoints(history.chartPoints(since: since, targetCount: 400))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("功耗历史", systemImage: "chart.xyaxis.line").font(.system(size: 12, weight: .semibold))
            Picker("时间范围", selection: $duration) {
                Text("15分钟").tag(900.0)
                Text("1小时").tag(3600.0)
                Text("24小时").tag(86400.0)
            }.pickerStyle(.segmented)
            Chart(plotted) { point in
                LineMark(x: .value("时间", point.timestamp), y: .value("瓦", point.watts), series: .value("连续段", point.segment))
                    .foregroundStyle(.green)
            }.frame(height: 190).chartYAxisLabel("W")
                .chartXScale(domain: since...Date())
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour().minute())
                    }
                }
                .accessibilityLabel("整机功率历史；缺失时段断开")
            let summary = history.summary(since: since)
            Text(String(format: "有效覆盖 %.0f 秒 · 约 %.3f Wh · 峰值 %@", summary.coveredSeconds, summary.energyWh, summary.peakWatts.map { String(format: "%.1f W", $0) } ?? "—"))
                .foregroundStyle(.secondary)
            if let active = history.activeSession {
                Text("\(active.name) · 约 \(String(format: "%.3f", active.summary.energyWh)) Wh")
                Button("结束任务记录") { history.endSession() }
            } else {
                HStack {
                    TextField("任务名称", text: $sessionName).textFieldStyle(.roundedBorder)
                    Button("开始记录") { history.startSession(name: sessionName) }
                }
            }
            sessionComparison
            ForEach(history.sessions.suffix(10).reversed()) { session in
                Text("\(session.name) · \(String(format: "%.3f", session.summary.energyWh)) Wh · 有效 \(Int(session.summary.coveredSeconds)) 秒")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("导出 CSV") { export(json: false) }
                Button("导出 JSON") { export(json: true) }
                if exporting { ProgressView().controlSize(.small) }
            }.disabled(exporting)
            Text("本机保存最多24小时 / 20,000点；能耗为有效时段积分估算，不填补休眠或缺失时段。")
                .foregroundStyle(.secondary)
            if let error = history.persistenceError { Text(error).foregroundStyle(.orange) }
            if !exportMessage.isEmpty { Text(exportMessage).foregroundStyle(.secondary) }
        }
    }
    private var sessionComparison: some View {
        VStack(alignment: .leading, spacing: 8) {
            if history.sessions.count >= 2 {
                Text("比较两次任务").font(.headline)
                HStack {
                    sessionPicker("任务 A", selection: $comparisonA)
                    sessionPicker("任务 B", selection: $comparisonB)
                }
                if let a = history.sessions.first(where: { $0.id == comparisonA }),
                   let b = history.sessions.first(where: { $0.id == comparisonB }) {
                    if a.id == b.id {
                        Text("请选择两个不同的任务").foregroundStyle(.secondary)
                    } else {
                        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 7) {
                            GridRow { Text(""); Text("A"); Text("B") }
                            GridRow { Text("有效能耗"); Text(String(format: "%.3f Wh", a.summary.energyWh)); Text(String(format: "%.3f Wh", b.summary.energyWh)) }
                            GridRow { Text("耗时"); Text(durationText(a.elapsedSeconds)); Text(durationText(b.elapsedSeconds)) }
                            GridRow { Text("有效覆盖"); Text(coverage(a.coverageFraction)); Text(coverage(b.coverageFraction)) }
                            GridRow { Text("平均功率"); Text(a.summary.averageWatts.map { String(format: "%.1f W", $0) } ?? "—"); Text(b.summary.averageWatts.map { String(format: "%.1f W", $0) } ?? "—") }
                        }.monospacedDigit()
                        Text("请比较相同工作量和相近条件；缺失时段未计入能耗，瞬时功率更低不一定更省电。")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    private func sessionPicker(_ label: String, selection: Binding<UUID?>) -> some View {
        Picker(label, selection: selection) {
            Text("选择任务").tag(Optional<UUID>.none)
            ForEach(history.sessions.reversed()) { session in
                Text("\(session.name) · \(session.startedAt.formatted(date: .abbreviated, time: .shortened))")
                    .tag(Optional(session.id))
            }
        }
    }
    private func coverage(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0 * 100) } ?? "—" }
    private func durationText(_ value: Double?) -> String { value.map { String(format: "%.1f 分钟", $0 / 60) } ?? "—" }

    private func export(json: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [json ? .json : .commaSeparatedText]
        panel.nameFieldStringValue = "MacPowerFlow-history.\(json ? "json" : "csv")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exporting = true
        Task {
            defer { exporting = false }
            do {
                let data: Data
                if json { data = try await history.jsonDataAsync() }
                else { data = await history.csvDataAsync() }
                try await Task.detached(priority: .utility) { try data.write(to: url, options: .atomic) }.value
                exportMessage = "已导出 \(url.lastPathComponent)"
            } catch { exportMessage = "导出失败：\(error.localizedDescription)" }
        }
    }
}

struct AlertPanel: View {
    @ObservedObject var alerts: PowerAlerts
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("持续异常时通知", isOn: Binding(get: { alerts.requestedEnabled }, set: { alerts.setEnabled($0) }))
            HStack {
                Text("高功耗阈值")
                TextField("瓦", value: $alerts.highPowerThreshold, format: .number).frame(width: 60)
                Text("W")
            }
            Text(alerts.status).foregroundStyle(.secondary)
            Text("连续30秒后提醒，同类提醒间隔10分钟；包括高功耗、高温、低电量和电池补电。")
                .foregroundStyle(.secondary)
        }
    }
}

struct DiagnosticsPanel: View {
    @ObservedObject var diagnostics: AppDiagnostics
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("应用自身诊断", systemImage: "stethoscope")
            Text(diagnostics.summary).foregroundStyle(.secondary)
            Text("报告仅保存在本机，不上传。系统日报尚未到达时显示等待。")
                .foregroundStyle(.secondary)
        }
    }
}
