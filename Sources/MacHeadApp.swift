import SwiftUI

struct MacHeadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(L("偏好设置...", "Settings...")) {
                    appDelegate.openPreferences()
                }
                .keyboardShortcut(",", modifiers: .command)

                Button(L("检查更新...", "Check for Updates...")) {
                    UpdateManager.shared.checkForUpdates(silent: false)
                }
            }
        }
    }
}
