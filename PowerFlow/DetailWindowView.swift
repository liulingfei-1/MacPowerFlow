import AppKit
import Charts
import Combine
import SwiftUI

nonisolated enum DetailSection: String, CaseIterable, Identifiable {
    case activity, history, battery, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .activity: "活动与读数"
        case .history: "历史与任务"
        case .battery: "电池与散热"
        case .settings: "设置与节能"
        }
    }
    var symbol: String {
        switch self {
        case .activity: "waveform.path.ecg"
        case .history: "chart.xyaxis.line"
        case .battery: "battery.75percent"
        case .settings: "gearshape"
        }
    }
}

@MainActor
final class DetailNavigation: ObservableObject {
    @Published var selection: DetailSection = .activity
}

struct AppAppearance<Content: View>: View {
    @AppStorage("appearance") private var appearance = "system"
    @ViewBuilder var content: () -> Content
    var body: some View {
        content().preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
    }
}

struct DetailWindowView: View {
    @ObservedObject var model: PowerMonitor
    @ObservedObject var navigation: DetailNavigation
    var toggleLogin: () -> Void
    var loginStatus: () -> String
    var isWindowVisible: () -> Bool = { false }
    @Environment(\.colorScheme) private var colorScheme
    @State private var currentLoginStatus = ""
    @AppStorage("appearance") private var appearance = "system"

    private var sidebarText: Color { colorScheme == .dark ? .white : .black }
    private var sidebarSelection: Color {
        colorScheme == .dark ? Color(red: 0.35, green: 0.9, blue: 0.55) : Color(red: 0.05, green: 0.4, blue: 0.2)
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(DetailSection.allCases) { section in
                    Button { navigation.selection = section } label: {
                        Label {
                            Text(section.title).foregroundStyle(navigation.selection == section ? sidebarSelection : sidebarText)
                        } icon: {
                            Image(systemName: section.symbol).foregroundStyle(navigation.selection == section ? sidebarSelection : sidebarText)
                        }
                            .font(.system(size: 13, weight: navigation.selection == section ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(navigation.selection == section ? Color.accentColor.opacity(0.12) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(navigation.selection == section ? .isSelected : [])
                }
                Spacer()
            }
            .padding(10)
            .navigationSplitViewColumnWidth(min: 150, ideal: 175, max: 220)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("MacPowerFlow").font(.headline).foregroundStyle(sidebarText)
                    Text(model.chipName).font(.caption).foregroundStyle(sidebarText.opacity(0.65))
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(navigation.selection.title).font(.system(size: 24, weight: .semibold))
                    switch navigation.selection {
                    case .activity:
                        sectionBox { InsightsView(model: model).activity }
                        sectionBox { InsightsView(model: model).memory }
                        sectionBox { InsightsView(model: model).quality }
                        EnergyFlowView(model: model, content: .components)
                    case .history:
                        sectionBox { HistoryPanel(history: model.history) }
                        SleepHistoryPanel(store: model.energyInsights)
                    case .battery:
                        sectionBox { InsightsView(model: model).charging }
                        FanPanel(fans: model.fans, thermal: model.thermalStateText)
                        HealthHistoryPanel(store: model.energyInsights)
                        DisclosureGroup("完整硬件读数") { EnergyFlowView(model: model, content: .hardware) }
                    case .settings:
                        settings
                    }
                }
                .padding(24).frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(navigation.selection)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .font(.system(size: 13))
        .frame(minWidth: 760, minHeight: 560)
        .task(id: navigation.selection) {
            let section = navigation.selection
            model.setActivityRequested(section == .activity)
            model.powerControls.refreshWhenVisible(section == .settings)
            if section == .settings { model.alerts.restorePreferences() }
            currentLoginStatus = loginStatus()
        }
        .onDisappear { model.setActivityRequested(false) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshVisibleSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            refreshVisibleSettings()
        }
    }

    private func refreshVisibleSettings() {
        guard navigation.selection == .settings, isWindowVisible() else { return }
        model.powerControls.refreshWhenVisible(true, force: true)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 22) {
            PowerSettingsPanel(model: model, controls: model.powerControls)
            sectionBox {
                Text("外观与启动").font(.headline)
                Picker("外观", selection: $appearance) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }.pickerStyle(.segmented)
                HStack {
                    Text(currentLoginStatus)
                    Spacer()
                    Button("更改登录启动") { toggleLogin(); currentLoginStatus = loginStatus() }
                }
            }
            sectionBox {
                Text("采样服务").font(.headline)
                Text("面板或任务记录时每2秒，后台每5秒，低功耗后台每10秒。增强服务使用同一档位。")
                    .foregroundStyle(.secondary)
                Text("当前档位 \(Int(model.samplingIntervalSeconds)) 秒 · \(model.administratorSampleIsFresh ? "增强数据有效" : "标准采样")")
                if !model.administratorErrorMessage.isEmpty { Text(model.administratorErrorMessage).foregroundStyle(.secondary) }
                Button("启用或更新增强服务…") { model.startAdministratorSampling(allowInstallation: true) }
                Text("仅主动启用时申请管理员授权。自动启动和服务重连不弹密码框。")
                    .foregroundStyle(.secondary)
            }
            sectionBox { AlertPanel(alerts: model.alerts) }
            sectionBox { DiagnosticsPanel(diagnostics: model.diagnostics) }
        }
    }
}

private func sectionBox<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 12, content: content)
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
}

struct MiniHistoryPanel: View {
    @ObservedObject var history: PowerHistoryStore
    private var points: [HistoryChartPoint] {
        historyChartPoints(history.chartPoints(since: Date().addingTimeInterval(-900), targetCount: 100))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("最近15分钟").font(.system(size: 12, weight: .medium))
                Spacer()
                if let active = history.activeSession {
                    Label("正在记录 · \(active.name)", systemImage: "record.circle")
                        .lineLimit(1).foregroundStyle(.orange)
                }
            }
            Chart(points) { point in
                LineMark(x: .value("时间", point.timestamp), y: .value("功率", point.watts), series: .value("连续段", point.segment))
                    .foregroundStyle(.green)
            }
            .frame(height: 72).chartXScale(domain: Date().addingTimeInterval(-900)...Date()).chartXAxis(.hidden).chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) }
            .overlay { if points.isEmpty { Text("等待有效历史样本").foregroundStyle(.secondary) } }
            .accessibilityLabel("最近15分钟整机功率，单位瓦，缺失时段断开")
        }.font(.system(size: 11)).padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct PowerSettingsPanel: View {
    @ObservedObject var model: PowerMonitor
    @ObservedObject var controls: PowerControls
    var body: some View {
        sectionBox {
            Text("电源模式与充电").font(.headline)
            Text(model.lowPowerModeEnabled ? "当前已开启低功耗模式" : "当前未开启低功耗模式")
            Text("低功耗会影响性能。可分别设置使用电池和接通电源时的行为，设置后立即回读确认。")
                .foregroundStyle(.secondary)
            if controls.snapshot?.lowPowerModeSupported == true {
                ForEach([LowPowerModeSource.battery, .adapter], id: \.rawValue) { source in
                    HStack {
                        Text(source == .battery ? "使用电池时" : "接通电源时")
                        Text(configuredMode(source)).foregroundStyle(.secondary)
                        Spacer()
                        Button("开启低功耗") { model.setLowPowerMode(source: source, enabled: true) }
                        Button("关闭低功耗") { model.setLowPowerMode(source: source, enabled: false) }
                    }.disabled(model.lowPowerControlBusy)
                }
                Text("应用内切换需要当前版本的增强服务；也可直接到系统电池设置中调整。")
                    .foregroundStyle(.secondary)
            }
            if !model.lowPowerControlMessage.isEmpty { Text(model.lowPowerControlMessage).textSelection(.enabled) }
            Divider()
            if #available(macOS 26.4, *) {
                Text("系统充电上限 80%–100%").font(.headline)
                Text("在系统设置 → 电池 → 充电中调整。系统可能偶尔充满以保持电量估计准确；当前上限请以系统设置为准。临时需要充满时，可使用系统电池菜单中的“立即充满”。")
                    .foregroundStyle(.secondary)
            } else {
                Text("优化充电由系统管理；固定80%–100%上限需要 Apple 芯片 Mac 与 macOS 26.4或更新版本。")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("打开系统电池设置") { openSystemSettings("com.apple.Battery-Settings.extension") }
                Link("Apple 充电说明", destination: URL(string: "https://support.apple.com/102338")!)
            }
            Divider()
            Text("空闲节能设置").font(.headline)
            if let snapshot = controls.snapshot {
                ForEach(snapshot.profiles, id: \.source) { profile in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile.source == "AC Power" ? "接通电源" : profile.source == "Battery Power" ? "使用电池" : profile.source).fontWeight(.medium)
                        Text("显示器 \(sleepText(profile.displaySleepMinutes)) · 电脑 \(sleepText(profile.systemSleepMinutes))")
                            .foregroundStyle(.secondary)
                        if profile.displaySleepMinutes == 0 || profile.systemSleepMinutes == 0 {
                            Text("有空闲计时器设为永不；若非刻意设置，可在系统中调整。应用防休眠声明仍可能影响实际睡眠。")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else { Text(controls.status).foregroundStyle(.secondary) }
            Button("打开锁定屏幕设置") { openSystemSettings("com.apple.Lock-Screen-Settings.extension") }
        }
    }
    private func sleepText(_ value: Int?) -> String {
        guard let value else { return "不可用" }
        return value == 0 ? "不自动休眠" : "\(value)分钟后休眠"
    }
    private func configuredMode(_ source: LowPowerModeSource) -> String {
        let name = source == .battery ? "Battery Power" : "AC Power"
        guard let value = controls.snapshot?.profiles.first(where: { $0.source == name })?.lowPowerMode,
              value == 0 || value == 1 else { return "未确认" }
        return value == 1 ? "已开启" : "已关闭"
    }
}

private func openSystemSettings(_ pane: String) {
    guard let url = URL(string: "x-apple.systempreferences:\(pane)") else { return }
    if !NSWorkspace.shared.open(url) {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}

private struct FanPanel: View {
    let fans: [FanSnapshot]?
    let thermal: String
    var body: some View {
        sectionBox {
            HStack { Text("风扇与散热").font(.headline); Spacer(); Text("热状态 · \(thermal)").foregroundStyle(.secondary) }
            if let fans {
                if fans.isEmpty { Text("本机没有报告风扇").foregroundStyle(.secondary) }
                ForEach(fans) { fan in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label("风扇 \(fan.id + 1)", systemImage: "fan")
                            Spacer()
                            Text(rpm(fan.currentRPM)).monospacedDigit().fontWeight(.semibold)
                            Text(fan.mode == 0 ? "系统自动" : fan.mode == 1 ? "手动模式" : "模式未提供").foregroundStyle(.secondary)
                        }
                        Text("目标 \(rpm(fan.targetRPM)) · 范围 \(rpm(fan.minimumRPM))–\(rpm(fan.maximumRPM))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else { Text("风扇信息暂不可用").foregroundStyle(.secondary) }
            Text("转速由系统或已有控制工具管理。本页读取实际状态；温度和风扇转速不等于风扇自身功耗。")
                .foregroundStyle(.secondary)
        }
    }
    private func rpm(_ value: Double?) -> String { value.map { String(format: "%.0f RPM", $0) } ?? "—" }
}

private struct HealthHistoryPanel: View {
    @ObservedObject var store: EnergyInsightsStore
    var body: some View {
        sectionBox {
            Text("电池健康趋势 · 最近90天").font(.headline)
            if store.healthDays.count >= 2 {
                Chart(store.healthDays) { day in
                    if let value = day.estimatedHealthPercent {
                        LineMark(x: .value("日期", day.day), y: .value("容量比", value))
                        PointMark(x: .value("日期", day.day), y: .value("容量比", value))
                    }
                }.frame(height: 140).chartYAxisLabel("%")
            } else { Text("已开始按天记录，积累两天后显示趋势。").foregroundStyle(.secondary) }
            if let last = store.healthDays.last {
                HStack {
                    Text(last.estimatedHealthPercent.map { String(format: "容量比估算 %.1f%%", $0) } ?? "容量暂不可用")
                    Spacer()
                    Text(last.cycleCount.map { "\($0) 次循环" } ?? "循环数不可用")
                }
            }
            Text("趋势按原始满充容量与设计容量之比估算；完整硬件读数优先使用标称容量，百分比可能不同。短期波动不等于电池突然老化；没有历史的数据不会补造。")
                .foregroundStyle(.secondary)
            if let error = store.persistenceError { Text(error).foregroundStyle(.orange) }
        }
    }
}

private struct SleepHistoryPanel: View {
    @ObservedObject var store: EnergyInsightsStore
    var body: some View {
        sectionBox {
            Text("睡眠耗电 · 端点估算").font(.headline)
            if store.sleepRecords.isEmpty {
                Text("保持应用运行，下一次睡眠和唤醒后会记录。睡眠中未采样的功率不会补算进实时历史。")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.sleepRecords.suffix(15).reversed()) { record in
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(record.sleptAt.formatted(date: .abbreviated, time: .shortened)) · \(String(format: "%.1f小时", record.durationSeconds / 3600))")
                    if record.quality == .endpointEstimate {
                        Text("电量 \(record.beforeLevel.map(String.init) ?? "—")% → \(record.afterLevel.map(String.init) ?? "—")% · \(record.estimatedEnergyWh.map { String(format: "约 %.3f Wh", $0) } ?? "能耗不可估算")")
                        Text(record.estimatedPercentPerHour.map { String(format: "约 %.2f%% / 小时", $0) } ?? "电量速率不可估算").foregroundStyle(.secondary)
                    } else { Text(reason(record.quality)).foregroundStyle(.secondary) }
                }
                Divider()
            }
            Text("根据睡前/醒后的电量、容量与电压估算。期间未收到的插拔电源事件和电池计量误差会影响结果。")
                .foregroundStyle(.secondary)
        }
    }
    private func reason(_ quality: SleepEnergyQuality) -> String {
        switch quality {
        case .endpointEstimate: "端点估算"
        case .powerSourceChanged: "电源发生变化，不估算耗电"
        case .externalPower: "接通电源，不估算电池耗电"
        case .missingData: "端点数据不完整，不估算"
        case .capacityIncreased: "电量或容量上升，不估算耗电"
        case .tooShort: "间隔不足1分钟，不估算"
        case .tooLong: "间隔超过72小时，不估算"
        case .batteryUnavailable: "电池数据不可用"
        }
    }
}
