import AppKit
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject,
    NSApplicationDelegate,
    NSMenuDelegate,
    NSPopoverDelegate,
    NSWindowDelegate
{
    private let contentWidth: CGFloat = 420
    private let maximumContentHeight: CGFloat = 660
    private let model = PowerMonitor()
    private let popover = NSPopover()
    private let contextMenu = NSMenu()

    private var statusItem: NSStatusItem?
    private var previewWindow: NSWindow?
    private var detailWindow: NSWindow?
    private let detailNavigation = DetailNavigation()
    private var launchAtLoginItem: NSMenuItem?
    private var modelObservation: AnyCancellable?
    private var pendingStatusUpdate: DispatchWorkItem?
    private var pendingLaunchAtLoginStatusUpdate: DispatchWorkItem?

    private var isPreviewMode: Bool {
        ProcessInfo.processInfo.arguments.contains("--preview")
            || isChargingPreview
            || isAboutPreview
            || ProcessInfo.processInfo.arguments.contains("--audit-ui")
            || ProcessInfo.processInfo.arguments.contains("--verify-integration")
    }

    private var isChargingPreview: Bool {
        ProcessInfo.processInfo.arguments.contains("--preview-charging")
    }

    private var isAboutPreview: Bool {
        ProcessInfo.processInfo.arguments.contains("--preview-about")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isPreviewMode {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }

        configureStatusItem()
        configurePopover()
        configureContextMenu()
        observeModel()

        if isChargingPreview {
            model.installChargingPreview()
        } else {
            model.startMonitoring(
                automaticallyStartAdministrator: !isPreviewMode
            )
        }
        updateStatusItem()

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--verify-integration") {
            guard ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--data-directory=") }) else {
                print("FAIL: isolated --data-directory is required")
                NSApp.terminate(nil)
                return
            }
            Task { @MainActor in
                do {
                    let checks = try await model.verifyLifecycleForTesting()
                    checks.forEach { print("PASS: \($0)") }
                    print("PASS: integration complete")
                } catch { print("FAIL: integration \(error)") }
                NSApp.terminate(nil)
            }
            return
        }
        #endif

        if ProcessInfo.processInfo.arguments.contains("--audit-ui") {
            model.setActivityRequested(true)
            model.powerControls.refreshWhenVisible(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 22) { [weak self] in
                guard let self,
                      let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--render-directory=") }) else { return }
                let directory = URL(fileURLWithPath: String(argument.dropFirst("--render-directory=".count)), isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    for scheme in [ColorScheme.dark, .light] {
                        let suffix = scheme == .dark ? "dark" : "light"
                        self.renderAuditView(EnergyFlowView(model: self.model).environment(\.colorScheme, scheme),
                                             size: NSSize(width: 420, height: 660),
                                             to: directory.appendingPathComponent("overview-\(suffix).png"), scheme: scheme)
                        for section in DetailSection.allCases {
                            self.detailNavigation.selection = section
                            let view = DetailWindowView(model: self.model, navigation: self.detailNavigation,
                                                        toggleLogin: {}, loginStatus: { "预览 · 不更改登录设置" })
                                .environment(\.colorScheme, scheme)
                            self.renderAuditView(view, size: NSSize(width: 980, height: 760),
                                                 to: directory.appendingPathComponent("\(section.rawValue)-\(suffix).png"), scheme: scheme)
                        }
                    }
                    print("Rendered current live samples to \(directory.path)")
                } catch { print("Render failed: \(error.localizedDescription)") }
                NSApp.terminate(nil)
            }
        }

        if ProcessInfo.processInfo.arguments.contains("--diagnose-startup") {
            // Uses the ordinary automatic startup path, including the silent
            // helper preflight. Never requests installation authorization.
            DispatchQueue.main.asyncAfter(deadline: .now() + 16) { [weak self] in
                guard let self else { return }
                let report: [String: Any] = [
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                    "hasHardwareSample": self.model.lastUpdated != .distantPast,
                    "systemLoadWatts": self.model.systemLoadWatts,
                    "batteryLevel": self.model.batteryLevel,
                    "enhancedState": String(describing: self.model.administratorSamplingState),
                    "enhancedMessage": self.model.administratorErrorMessage,
                    "enhancedSampleCount": self.model.administratorSampleCount,
                    "powerSource": self.model.powerSourceLabel,
                    "systemLoadAvailable": self.model.systemLoadAvailable,
                    "signedBatteryWatts": self.model.signedBatteryWatts as Any? ?? NSNull(),
                    "cpuRawWatts": self.model.rawCPUWatts as Any? ?? NSNull(),
                    "gpuRawWatts": self.model.rawGPUWatts as Any? ?? NSNull(),
                    "powerDomains": self.model.powerAvailability.sorted(),
                    "sampleDuration": self.model.sampleDuration,
                    "samplingStatus": self.model.samplingStatus,
                    "historyPoints": self.model.history.points.count,
                    "memoryAvailable": self.model.insights?.memory != nil,
                    "processCount": self.model.insights?.topProcesses?.count ?? 0,
                    "gpuActivityAvailable": self.model.insights?.gpuActivityAvailable ?? false,
                    "telemetryFreshness": self.model.latestBattery?.telemetryFreshness.rawValue ?? "unknown",
                    "diagnostics": self.model.diagnostics.summary,
                    "launchAtLoginStatus": SMAppService.mainApp.status.rawValue,
                ]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                    FileHandle.standardOutput.write(data)
                    FileHandle.standardOutput.write(Data("\n".utf8))
                }
                if let path = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--render-details=") })?.dropFirst("--render-details=".count) {
                    let view = InsightsView(model: self.model, initiallyExpanded: true)
                        .padding(16).frame(width: 420).background(Color.black)
                        .environment(\.colorScheme, .dark)
                    // AppKit-backed controls cannot be rendered by ImageRenderer.
                    let host = NSHostingView(rootView: view)
                    host.frame = NSRect(origin: .zero, size: host.fittingSize)
                    let renderWindow = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                    renderWindow.contentView = host
                    host.layoutSubtreeIfNeeded()
                    if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        if let png = bitmap.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: String(path)))
                        }
                    }
                    renderWindow.orderOut(nil)
                }
                self.model.history.flush()
                NSApp.terminate(nil)
            }
        }

        if isAboutPreview {
            showAbout(nil)
        } else if isPreviewMode {
            showPreviewWindow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func renderAuditView<V: View>(_ view: V, size: NSSize, to url: URL, scheme: ColorScheme) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: url) }
        }
        window.orderOut(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        pendingStatusUpdate?.cancel()
        pendingLaunchAtLoginStatusUpdate?.cancel()
        modelObservation?.cancel()
        model.stopMonitoring()
    }

    private func configurePopover() {
        let contentHeight = preferredContentHeight(on: NSScreen.main)
        popover.delegate = self
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(
            width: contentWidth,
            height: contentHeight
        )
        popover.contentViewController = NSHostingController(
            rootView: makeRootView(height: contentHeight)
        )
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }

        button.image = Self.makeMenuStatusImage(
            level: nil,
            isCharging: false,
            hasBattery: true,
            loadText: "--W"
        )
        button.imagePosition = .imageOnly
        button.imageHugsTitle = true
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        button.title = ""
        button.toolTip = "MacPowerFlow"
        button.setAccessibilityLabel("MacPowerFlow")
        button.setAccessibilityHelp("左键打开功耗详情，右键打开快捷菜单")
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        statusItem = item
    }

    private func configureContextMenu() {
        contextMenu.delegate = self
        let detailItem = NSMenuItem(title: "打开详细窗口", action: #selector(openDetailWindow(_:)), keyEquivalent: "d")
        detailItem.target = self
        contextMenu.addItem(detailItem)
        let settingsItem = NSMenuItem(title: "设置与节能…", action: #selector(openSettingsWindow(_:)), keyEquivalent: ",")
        settingsItem.target = self
        contextMenu.addItem(settingsItem)
        contextMenu.addItem(.separator())

        let refreshItem = NSMenuItem(
            title: "立即刷新",
            action: #selector(refreshNow(_:)),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        contextMenu.addItem(refreshItem)

        let enhancedItem = NSMenuItem(
            title: "启用或更新增强采样…",
            action: #selector(enableEnhancedSampling(_:)),
            keyEquivalent: ""
        )
        enhancedItem.target = self
        contextMenu.addItem(enhancedItem)

        let loginItem = NSMenuItem(
            title: "登录时启动",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        loginItem.target = self
        launchAtLoginItem = loginItem
        contextMenu.addItem(loginItem)

        contextMenu.addItem(.separator())

        let aboutItem = NSMenuItem(
            title: "关于 MacPowerFlow",
            action: #selector(showAbout(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = self
        contextMenu.addItem(aboutItem)

        contextMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出 MacPowerFlow",
            action: #selector(quit(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        contextMenu.addItem(quitItem)

        updateLaunchAtLoginItem()
    }

    private func observeModel() {
        modelObservation = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }

                // ObservableObject emits before its @Published values change.
                // Coalesce the individual property emissions and read once on
                // the next main-run-loop turn.
                self.pendingStatusUpdate?.cancel()
                let workItem = DispatchWorkItem { [weak self] in
                    self?.updateStatusItem()
                }
                self.pendingStatusUpdate = workItem
                DispatchQueue.main.async(execute: workItem)
            }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }

        let hasSample = model.lastUpdated != Date.distantPast
        let batteryText: String
        let batteryLevel: Int?
        if !hasSample {
            batteryText = "--"
            batteryLevel = nil
        } else if model.batteryPresent && model.batteryLevel >= 0 {
            batteryText = "\(min(model.batteryLevel, 100))%"
            batteryLevel = min(model.batteryLevel, 100)
        } else {
            batteryText = "AC"
            batteryLevel = nil
        }
        let loadText = model.systemLoadWatts > 0.05
            ? Self.formatWatts(model.systemLoadWatts)
            : "--W"
        let displayedBatteryLevel = isChargingPreview ? 100 : batteryLevel
        let displayedIsCharging = isChargingPreview || model.isCharging
        let displayedHasBattery = isChargingPreview
            || !hasSample
            || model.batteryPresent

        button.image = Self.makeMenuStatusImage(
            level: displayedBatteryLevel,
            isCharging: displayedIsCharging,
            hasBattery: displayedHasBattery,
            loadText: loadText
        )
        // Both pieces are rendered into one image. This avoids AppKit's
        // otherwise unavoidable image/title separator while preserving the
        // green charging state that a template image would flatten.
        button.title = ""

        let source: String
        if !hasSample {
            source = "等待首次采样"
        } else if model.batteryPresent {
            source = model.isOnAC ? "外接电源" : "电池供电"
        } else {
            source = "外接电源"
        }
        let batteryState: String
        if displayedIsCharging {
            batteryState = model.batteryFlowWatts > 0.02
                ? "，正在充电 · 充入 \(Self.formatWatts(model.batteryFlowWatts))"
                : "，正在充电"
        } else if model.isSupplementingAdapter {
            batteryState = "，电池正在补电 · 输出 \(Self.formatWatts(model.batteryFlowWatts))"
        } else if model.isFullyCharged {
            batteryState = "，已充满"
        } else if model.batteryPresent && model.isOnAC {
            batteryState = "，已接电源但未充电"
        } else if model.batteryPresent {
            batteryState = model.batteryFlowWatts > 0.02
                ? "，电池输出 \(Self.formatWatts(model.batteryFlowWatts))"
                : "，正在使用电池"
        } else {
            batteryState = ""
        }
        button.toolTip = "\(source)\(batteryState) · 系统负载 \(loadText)"
        let batteryAccessibility: String
        if !hasSample {
            batteryAccessibility = ""
        } else if model.batteryPresent {
            batteryAccessibility = "电池 \(batteryText)，"
        } else {
            batteryAccessibility = "无内置电池，"
        }
        button.setAccessibilityValue(
            "\(batteryAccessibility)\(source)\(batteryState)，系统负载 \(loadText)"
        )
    }

    private static func makeMenuStatusImage(
        level: Int?,
        isCharging: Bool,
        hasBattery: Bool,
        loadText: String
    ) -> NSImage {
        let batteryImage = makeMenuBatteryImage(
            level: level,
            isCharging: isCharging,
            hasBattery: hasBattery
        )
        let loadLabel = NSAttributedString(
            string: loadText,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(
                    ofSize: 12,
                    weight: .medium
                ),
                .foregroundColor: NSColor.labelColor
            ]
        )
        let labelSize = loadLabel.size()
        // Start the wattage exactly where the battery canvas ends. There is no
        // artificial separator, and the battery terminal cannot overlap the
        // first digit.
        let labelX = batteryImage.size.width
        let size = NSSize(
            width: labelX + ceil(labelSize.width),
            height: 16
        )
        let image = NSImage(size: size, flipped: false) { _ in
            batteryImage.draw(
                in: NSRect(origin: .zero, size: batteryImage.size),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            loadLabel.draw(
                at: NSPoint(
                    x: labelX,
                    y: floor((size.height - labelSize.height) / 2)
                )
            )
            return true
        }
        // The battery is green while charging, so the composite image must
        // retain its own colors instead of being flattened by template tinting.
        image.isTemplate = false
        image.accessibilityDescription = "电池电量与系统负载"
        return image
    }

    private static func makeMenuBatteryImage(
        level: Int?,
        isCharging: Bool,
        hasBattery: Bool
    ) -> NSImage {
        // Keep the three-digit state stable without leaving the oversized tail
        // that previously followed "100". The terminal ends exactly at the
        // canvas edge, so the wattage can start immediately after it.
        let size = NSSize(width: 29.5, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            NSGraphicsContext.current?.imageInterpolation = .high

            let ink = isCharging
                ? NSColor.systemGreen
                : NSColor.labelColor
            if !hasBattery {
                let symbol = NSImage(
                    systemSymbolName: "powerplug.fill",
                    accessibilityDescription: nil
                )
                let baseConfiguration = NSImage.SymbolConfiguration(
                    pointSize: 10,
                    weight: .semibold
                )
                let paletteConfiguration =
                    NSImage.SymbolConfiguration(paletteColors: [ink])
                let configuration = baseConfiguration.applying(
                    paletteConfiguration
                )
                symbol?.withSymbolConfiguration(configuration)?
                    .draw(in: NSRect(x: 0.5, y: 2.5, width: 10.5, height: 11))

                let text = NSAttributedString(
                    string: "AC",
                    attributes: [
                        .font: NSFont.monospacedDigitSystemFont(
                            ofSize: 7.8,
                            weight: .semibold
                        ),
                        .foregroundColor: ink
                    ]
                )
                let textSize = text.size()
                text.draw(
                    at: NSPoint(
                        x: 12,
                        y: floor((size.height - textSize.height) / 2)
                    )
                )
                return true
            }

            let body = NSRect(x: 0.5, y: 2.5, width: 27, height: 11)
            let outline = NSBezierPath(
                roundedRect: body,
                xRadius: 3,
                yRadius: 3
            )
            ink.withAlphaComponent(0.88).setStroke()
            outline.lineWidth = 1
            outline.stroke()

            let terminal = NSBezierPath(
                roundedRect: NSRect(x: 28, y: 5.5, width: 1.5, height: 5),
                xRadius: 0.75,
                yRadius: 0.75
            )
            ink.withAlphaComponent(0.88).setFill()
            terminal.fill()

            if let level {
                let clamped = CGFloat(min(max(level, 0), 100)) / 100
                let fillWidth = max(0, (body.width - 3) * clamped)
                if fillWidth > 0 {
                    let fill = NSBezierPath(
                        roundedRect: NSRect(
                            x: body.minX + 1.5,
                            y: body.minY + 1.5,
                            width: fillWidth,
                            height: body.height - 3
                        ),
                        xRadius: min(1.8, fillWidth / 2),
                        yRadius: min(1.8, fillWidth / 2)
                    )
                    ink.withAlphaComponent(isCharging ? 0.26 : 0.18).setFill()
                    fill.fill()
                }
            }

            let value = level.map(String.init) ?? "--"
            let fontSize: CGFloat = value.count >= 3 ? 7.1 : 7.8
            let text = NSAttributedString(
                string: value,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(
                        ofSize: fontSize,
                        weight: .semibold
                    ),
                    .foregroundColor: ink
                ]
            )
            let textSize = text.size()
            let boltSize = NSSize(width: 5.5, height: 7.5)
            let boltGap: CGFloat = 0.75
            let groupWidth = textSize.width
                + (isCharging ? boltSize.width + boltGap : 0)
            let groupX = body.midX - groupWidth / 2

            if isCharging {
                let symbol = NSImage(
                    systemSymbolName: "bolt.fill",
                    accessibilityDescription: nil
                )
                let baseConfiguration = NSImage.SymbolConfiguration(
                    pointSize: 6.2,
                    weight: .bold
                )
                let paletteConfiguration =
                    NSImage.SymbolConfiguration(paletteColors: [ink])
                let configuration = baseConfiguration.applying(
                    paletteConfiguration
                )
                symbol?.withSymbolConfiguration(configuration)?
                    .draw(
                        in: NSRect(
                            x: groupX,
                            y: body.midY - boltSize.height / 2,
                            width: boltSize.width,
                            height: boltSize.height
                        )
                    )
            }

            text.draw(
                at: NSPoint(
                    x: groupX
                        + (isCharging ? boltSize.width + boltGap : 0),
                    y: floor((size.height - textSize.height) / 2)
                )
            )
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "电池电量"
        return image
    }

    private static func formatWatts(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "--W" }
        if value >= 100 {
            return String(format: "%.0fW", value)
        }
        return String(format: "%.1fW", value)
    }

    private func makeRootView(height: CGFloat) -> some View {
        AppAppearance { [model, weak self] in
            EnergyFlowView(model: model, openDetails: { section in self?.showDetails(section) })
        }.frame(width: contentWidth, height: height)
    }

    private func showPreviewWindow() {
        let contentHeight = preferredContentHeight(on: NSScreen.main)
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: contentWidth,
                height: contentHeight
            ),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        model.setPanelVisible(true, surface: "preview")
        window.delegate = self
        window.title = "MacPowerFlow"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: makeRootView(height: contentHeight)
        )
        window.center()
        window.makeKeyAndOrderFront(nil)

        previewWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc
    private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            togglePopover(relativeTo: sender)
            return
        }

        if event.type == .rightMouseUp {
            if popover.isShown {
                popover.performClose(nil)
            }
            updateLaunchAtLoginItem()
            NSMenu.popUpContextMenu(contextMenu, with: event, for: sender)
        } else {
            togglePopover(relativeTo: sender)
        }
    }

    @objc private func openDetailWindow(_ sender: Any?) { showDetails(.activity) }
    @objc private func openSettingsWindow(_ sender: Any?) { showDetails(.settings) }

    func openDetailSection(_ section: DetailSection) { showDetails(section) }

    private func showDetails(_ section: DetailSection) {
        detailNavigation.selection = section
        if detailWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "MacPowerFlow"
            window.minSize = NSSize(width: 760, height: 560)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setFrameAutosaveName("MacPowerFlowDetails")
            window.contentViewController = NSHostingController(rootView: AppAppearance { [model, detailNavigation, weak self] in
                DetailWindowView(model: model, navigation: detailNavigation,
                    toggleLogin: { self?.toggleLaunchAtLogin(nil) },
                    loginStatus: {
                        switch SMAppService.mainApp.status {
                        case .enabled: "登录启动已开启"
                        case .requiresApproval: "登录启动等待系统批准"
                        default: "登录启动未开启"
                        }
                    }, isWindowVisible: { [weak self] in
                        guard let window = self?.detailWindow else { return false }
                        return window.isVisible && !window.isMiniaturized && !NSApp.isHidden
                    })
            })
            window.center()
            detailWindow = window
        }
        model.setPanelVisible(true, surface: "details")
        model.setActivityRequested(section == .activity)
        model.powerControls.refreshWhenVisible(section == .settings)
        popover.performClose(nil)
        detailWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === detailWindow {
            model.setPanelVisible(false, surface: "details")
            model.setActivityRequested(false)
        } else if window === previewWindow {
            model.setPanelVisible(false, surface: "preview")
        }
    }

    func windowDidMiniaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === detailWindow {
            model.setPanelVisible(false, surface: "details")
            model.setActivityRequested(false)
        } else if window === previewWindow { model.setPanelVisible(false, surface: "preview") }
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === detailWindow {
            model.setPanelVisible(true, surface: "details")
            model.setActivityRequested(detailNavigation.selection == .activity)
        } else if window === previewWindow { model.setPanelVisible(true, surface: "preview") }
    }

    private func togglePopover(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.refreshNow()
            let contentHeight = preferredContentHeight(on: button.window?.screen)
            popover.contentSize = NSSize(
                width: contentWidth,
                height: contentHeight
            )
            popover.contentViewController = NSHostingController(
                rootView: makeRootView(height: contentHeight)
            )
            popover.show(
                relativeTo: button.bounds,
                of: button,
                preferredEdge: .minY
            )
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc
    private func refreshNow(_ sender: Any?) {
        model.refreshNow()
    }

    @objc
    private func enableEnhancedSampling(_ sender: Any?) {
        model.startAdministratorSampling(allowInstallation: true)
    }

    @objc
    private func toggleLaunchAtLogin(_ sender: Any?) {
        let service = SMAppService.mainApp

        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .notRegistered, .notFound:
                guard isRunningFromApplicationsFolder else {
                    presentMoveToApplicationsMessage()
                    updateLaunchAtLoginItem()
                    return
                }

                // On a clean installation, current macOS releases can report
                // .notFound until the first register() call creates the BTM
                // record. Treating .notFound as a terminal error makes it
                // impossible to enable launch at login for the first time.
                try service.register()
            case .requiresApproval:
                updateLaunchAtLoginItem()
                presentLaunchAtLoginApprovalMessage()
                return
            @unknown default:
                presentLaunchAtLoginMessage("当前系统无法识别登录项状态。")
            }
        } catch {
            handleLaunchAtLoginError(error)
            updateLaunchAtLoginItem()
            return
        }

        updateLaunchAtLoginItem()
        scheduleLaunchAtLoginStatusRefresh()
    }

    private func updateLaunchAtLoginItem() {
        guard let item = launchAtLoginItem else { return }

        switch SMAppService.mainApp.status {
        case .enabled:
            item.title = "登录时启动"
            item.state = .on
        case .notRegistered:
            item.title = "登录时启动"
            item.state = .off
        case .requiresApproval:
            item.title = "登录时启动（需要在系统设置中批准…）"
            item.state = .mixed
        case .notFound:
            // Before the first registration, BTM can legitimately have no
            // record for the main app. Keep this visibly off, not unavailable;
            // selecting it will perform the initial registration.
            item.title = "登录时启动"
            item.state = .off
        @unknown default:
            item.title = "登录时启动"
            item.state = .off
        }
    }

    private var isRunningFromApplicationsFolder: Bool {
        let bundleURL = Bundle.main.bundleURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let applicationsURL = URL(
            fileURLWithPath: "/Applications",
            isDirectory: true
        )
        .resolvingSymlinksInPath()
        .standardizedFileURL

        return bundleURL.path.hasPrefix(applicationsURL.path + "/")
    }

    private func scheduleLaunchAtLoginStatusRefresh() {
        pendingLaunchAtLoginStatusUpdate?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.updateLaunchAtLoginItem()

            if SMAppService.mainApp.status == .requiresApproval {
                self.presentLaunchAtLoginApprovalMessage()
            }
        }
        pendingLaunchAtLoginStatusUpdate = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.5,
            execute: workItem
        )
    }

    private func handleLaunchAtLoginError(_ error: Error) {
        let nsError = error as NSError

        if nsError.code == kSMErrorLaunchDeniedByUser {
            updateLaunchAtLoginItem()
            presentLaunchAtLoginApprovalMessage()
            return
        }

        // A concurrent settings change can make the requested transition
        // finish before our call reaches ServiceManagement. In that case the
        // current status is authoritative and no error dialog is useful.
        if nsError.code == kSMErrorAlreadyRegistered,
           SMAppService.mainApp.status == .enabled
        {
            return
        }
        if nsError.code == kSMErrorJobNotFound,
           SMAppService.mainApp.status == .notRegistered
        {
            return
        }

        presentLaunchAtLoginError(error)
    }

    private func presentMoveToApplicationsMessage() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "请先从“应用程序”文件夹运行"
        alert.informativeText = "登录时启动需要一个固定的应用路径。请退出 MacPowerFlow，将 MacPowerFlow.app 移到 /Applications，然后从那里重新打开并再次开启此选项。\n\n当前路径：\(Bundle.main.bundleURL.path)"
        alert.addButton(withTitle: "打开“应用程序”文件夹")
        alert.addButton(withTitle: "取消")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(fileURLWithPath: "/Applications", isDirectory: true)
            )
        }
    }

    private func presentLaunchAtLoginApprovalMessage() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "还需要在系统设置中批准"
        alert.informativeText = "MacPowerFlow 已提交登录项注册，但 macOS 当前不允许它自动启动。请在“系统设置 › 通用 › 登录项与扩展”中允许 MacPowerFlow。批准前，菜单会保持“需要批准”状态，不会显示为已开启。"
        alert.addButton(withTitle: "打开登录项设置")
        alert.addButton(withTitle: "稍后")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private func presentLaunchAtLoginError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法更改登录启动设置"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")

        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func presentLaunchAtLoginMessage(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "登录时启动"
        alert.informativeText = message
        alert.addButton(withTitle: "好")

        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func preferredContentHeight(on screen: NSScreen?) -> CGFloat {
        let availableHeight = screen?.visibleFrame.height
            ?? NSScreen.main?.visibleFrame.height
            ?? maximumContentHeight
        return max(480, min(maximumContentHeight, availableHeight - 48))
    }

    @objc
    private func showAbout(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: AboutCredits.make(),
        ])
    }

    @objc
    private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    func popoverWillShow(_ notification: Notification) { model.setPanelVisible(true) }
    func popoverDidClose(_ notification: Notification) { model.setPanelVisible(false) }

    func menuWillOpen(_ menu: NSMenu) {
        updateLaunchAtLoginItem()
    }
}
