import Cocoa
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover?
    private let controller = HeadlessModeController.shared
    private var preferencesWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as an accessory (menu-bar only) app
        NSApp.setActivationPolicy(.accessory)

        // Register default preferences
        UserDefaults.standard.register(defaults: [
            "AppLanguage": "system",
            "PreventIdleSleep": true,
            "KeepRunningOnLidClose": false,
            "AutoEnableHeadlessOnLaunch": false,
            "DisableTrackpadWhenExternalMouseConnected": false,
            "DisableKeyboardInHeadless": false,
            "DisableKeyboardWhenExternalKeyboardConnected": false,
            "DisableTrackpadInHeadless": false,
            "EnableBatteryProtection": true,
            "BatteryThreshold": 20,
            "MuteMicrophoneInHeadlessMode": false,
            "EnableWebServer": false,
            "WebServerPort": 8080,
            "DisableKeyboardAndTrackpadInHeadlessMode": false,
            "AutoExitHeadlessOnDisconnect": true,
            "AutoRestoreHeadlessOnConnect": true,
            "nezhaEnabled": false,
            "nezhaServer": "",
            "nezhaSecret": "",
            "nezhaTls": false,
            "serverStatusEnabled": false,
            "serverStatusAddr": "",
            "serverStatusUser": "",
            "serverStatusPassword": "",
            "kumaEnabled": false,
            "kumaPushUrl": "",
            "kumaInterval": 60.0,
            "frpEnabled": false,
            "frpMode": "quick",
            "frpServerAddr": "",
            "frpServerPort": "7000",
            "frpToken": "",
            "frpProxyName": "machead-ssh",
            "frpProxyType": "tcp",
            "frpLocalIP": "127.0.0.1",
            "frpLocalPort": "22",
            "frpRemotePort": "6022",
            "frpCustomDomains": "",
            "frpSubdomain": "",
            "frpCustomConfig": "# frpc.toml\nserverAddr = \"127.0.0.1\"\nserverPort = 7000\nauth.token = \"\"\n\n[[proxies]]\nname = \"machead-ssh\"\ntype = \"tcp\"\nlocalIP = \"127.0.0.1\"\nlocalPort = 22\nremotePort = 6022\n",
            "notificationsEnabled": false,
            "barkEnabled": false,
            "barkKey": "",
            "telegramEnabled": false,
            "telegramBotToken": "",
            "telegramChatId": "",
            "overheatAlertEnabled": false,
            "overheatThreshold": 85.0,
            "telemetryEnabled": true,
            "tailcatEnabled": false,
            "tailcatCodeMode": "ephemeral",
            "tailcatRequirePassword": false,
            "tailcatAccessPassword": "",
            "tailcatFixedCode": "",
            "tailcatBinaryPath": ""
        ])

        // Generate random default WebServerPassword if not present
        if UserDefaults.standard.string(forKey: "WebServerPassword") == nil ||
           UserDefaults.standard.string(forKey: "WebServerPassword")?.isEmpty == true {
            let randomPass = "MH-" + String((0..<4).map { _ in "0123456789ABCDEF".randomElement()! })
            UserDefaults.standard.set(randomPass, forKey: "WebServerPassword")
        }

        // Start monitoring input devices
        InputDeviceManager.shared.start()

        // Start monitoring battery/power status
        BatteryManager.shared.start()

        // Start Web Server if enabled in preferences
        WebServer.shared.start()

        // Pre-cache built-in display ID when available
        _ = DisplayManager.shared.builtInDisplayID

        // Start monitoring display plug/unplug events globally
        controller.registerDisplayCallback()

        // Start all active integrations (Nezha, ServerStatus, Uptime Kuma, SMC)
        IntegrationManager.shared.startAllServices()

        // Create menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateIcon()

        // Observe headless mode state changes (such as auto-restoration)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStateChanged),
            name: .headlessModeStateChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLanguageChanged),
            name: .appLanguageChanged,
            object: nil
        )
        // Observe Distributed Notifications from CLI Client
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleCLIEngage),
            name: NSNotification.Name("com.waffle.MacHead.CLI.enable"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleCLIDisengage),
            name: NSNotification.Name("com.waffle.MacHead.CLI.disable"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )

        // CLI 软链接为 opt-in 组件：仅在偏好设置中开启后维护，默认零包外写入；
        // 异步执行，提权弹窗不得阻塞启动流程
        DispatchQueue.main.async { CLIToolInstaller.setupIfEnabled() }

        // Auto-enable headless mode on launch if enabled in preferences
        let autoEnable = UserDefaults.standard.bool(forKey: "AutoEnableHeadlessOnLaunch")
        if autoEnable {
            NSLog("MacHead: 偏好设置中已开启「启动时自动进入无头模式」，启动自适应就绪监听队列...")
            controller.startLaunchAdaptiveReadyQueue(timeout: 8.0, pollInterval: 0.5) { [weak self] in
                self?.updateIcon()
            }
        }

        // Silent background check for updates 3 seconds after launch & send telemetry heartbeat
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            UpdateManager.shared.checkForUpdates(silent: true)
            TelemetryManager.shared.track(event: "app_heartbeat")
        }
    }

    private func updateIcon() {
        let isHeadless = controller.isHeadlessModeEnabled

        let imageName = isHeadless ? "macmini" : "laptopcomputer"
        if let image = NSImage(systemSymbolName: imageName, accessibilityDescription: "MacHead") {
            image.isTemplate = true
            statusItem.button?.image = image
            statusItem.button?.title = ""
        } else {
            statusItem.button?.image = nil
            statusItem.button?.title = isHeadless ? "●" : "○"
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover(sender)
        }
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if let popover = popover, popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover(sender)
        }
    }

    private func showPopover(_ sender: NSStatusBarButton) {
        if popover == nil {
            let popoverInstance = NSPopover()
            popoverInstance.behavior = .transient
            popoverInstance.animates = true
            self.popover = popoverInstance
        }

        let popoverView = StatusPopoverView(
            onOpenPreferences: { [weak self] in
                self?.popover?.performClose(nil)
                self?.openPreferences()
            },
            onQuitApp: { [weak self] in
                self?.popover?.performClose(nil)
                self?.quitApp()
            }
        )

        popover?.contentViewController = NSHostingController(rootView: popoverView)
        popover?.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover?.contentViewController?.view.window?.makeKey()
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let toggleItem = NSMenuItem(
            title: controller.isHeadlessModeEnabled
                ? L("恢复内置屏显示", "Restore Built-In Display")
                : L("开启 Headless 模式", "Enable Headless Mode"),
            action: #selector(toggleHeadlessModeMenuAction),
            keyEquivalent: "h"
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(NSMenuItem.separator())

        let preferencesItem = NSMenuItem(
            title: L("偏好设置...", "Settings..."),
            action: #selector(openPreferences),
            keyEquivalent: ","
        )
        preferencesItem.target = self
        menu.addItem(preferencesItem)

        let updateItem = NSMenuItem(
            title: L("检查更新...", "Check for Updates..."),
            action: #selector(checkForUpdatesMenuAction),
            keyEquivalent: ""
        )
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: L("退出 MacHead", "Quit MacHead"),
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleHeadlessModeMenuAction() {
        if controller.isHeadlessModeEnabled {
            controller.disableHeadlessMode()
        } else {
            controller.enableHeadlessMode()
        }
    }

    @objc private func checkForUpdatesMenuAction() {
        UpdateManager.shared.checkForUpdates(silent: false)
    }

    private func ensureAppMenuItems() {
        guard let mainMenu = NSApp.mainMenu,
              let appMenu = mainMenu.items.first?.submenu else { return }

        if let existingUpdateItem = appMenu.items.first(where: {
            $0.action == #selector(checkForUpdatesMenuAction) || $0.title.contains("检查更新") || $0.title.contains("Check for Updates")
        }) {
            existingUpdateItem.title = L("检查更新...", "Check for Updates...")
        } else {
            let insertIndex = min(2, appMenu.items.count)
            let updateItem = NSMenuItem(
                title: L("检查更新...", "Check for Updates..."),
                action: #selector(checkForUpdatesMenuAction),
                keyEquivalent: ""
            )
            updateItem.target = self
            appMenu.insertItem(updateItem, at: insertIndex)
        }
    }

    @objc private func handleLanguageChanged() {
        preferencesWindow?.title = L("MacHead 偏好设置", "MacHead Settings")
        ensureAppMenuItems()
        BatteryManager.shared.handlePowerSourceChanged()
    }

    @objc func openPreferences() {
        if preferencesWindow == nil {
            let view = PreferencesView()
            let controller = NSHostingController(rootView: view)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 680, height: 580),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = L("MacHead 偏好设置", "MacHead Settings")
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = .clear
            window.contentViewController = controller
            window.center()
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("MacHeadPreferencesWindow")
            window.delegate = self
            self.preferencesWindow = window
        } else {
            preferencesWindow?.title = L("MacHead 偏好设置", "MacHead Settings")
        }

        // Switch to .regular while Preferences window is open so macOS menu bar shows "MacHead -> 检查更新..."
        NSApp.setActivationPolicy(.regular)
        ensureAppMenuItems()
        NSApp.activate(ignoringOtherApps: true)
        preferencesWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if let closedWindow = notification.object as? NSWindow, closedWindow == preferencesWindow {
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    @objc private func handleStateChanged() {
        updateIcon()
        InputDeviceManager.shared.evaluateTrackpadAndKeyboardState()
    }


    @objc private func handleCLIEngage() {
        NSLog("MacHead: 收到来自 CLI 的启用命令，正在启用 Headless 模式...")
        if !controller.isHeadlessModeEnabled {
            controller.enableHeadlessMode()
        }
    }

    @objc private func handleCLIDisengage() {
        NSLog("MacHead: 收到来自 CLI 的禁用命令，正在关闭 Headless 模式...")
        if controller.isHeadlessModeEnabled {
            controller.disableHeadlessMode()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        IntegrationManager.shared.stopAllServices()
        WebServer.shared.stop()
        if controller.isHeadlessModeEnabled {
            controller.disableHeadlessMode()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
