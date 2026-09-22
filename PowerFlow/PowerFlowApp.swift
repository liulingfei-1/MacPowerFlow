import SwiftUI

@main
struct MacPowerFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置与节能…") { appDelegate.openDetailSection(.settings) }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("监控") {
                Button("活动与读数") { appDelegate.openDetailSection(.activity) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("历史与任务") { appDelegate.openDetailSection(.history) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("电池与散热") { appDelegate.openDetailSection(.battery) }
                    .keyboardShortcut("3", modifiers: .command)
            }
        }
    }
}
