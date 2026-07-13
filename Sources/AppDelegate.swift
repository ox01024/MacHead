import Cocoa
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let controller = HeadlessModeController.shared
    private var preferencesWindow: NSWindow?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as an accessory (menu-bar only) app
        NSApp.setActivationPolicy(.accessory)
        
        // Register default preferences
        UserDefaults.standard.register(defaults: [
            "PreventIdleSleep": true,
            "KeepRunningOnLidClose": false,
            "AutoEnableHeadlessOnLaunch": true,
            "DisableTrackpadWhenExternalMouseConnected": false,
            "DisableKeyboardInHeadless": false,
            "DisableKeyboardWhenExternalKeyboardConnected": false,
            "DisableTrackpadInHeadless": false,
            "EnableBatteryProtection": true,
            "BatteryThreshold": 20,
            "MuteMicrophoneInHeadlessMode": false,
            "EnableWebServer": false,
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
            "notificationsEnabled": false,
            "barkEnabled": false,
            "barkKey": "",
            "telegramEnabled": false,
            "telegramBotToken": "",
            "telegramChatId": "",
            "overheatAlertEnabled": false,
            "overheatThreshold": 85.0
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
        
        // Start monitoring display plug/unplug events globally
        controller.registerDisplayCallback()
        
        // Start all active integrations (Nezha, ServerStatus, Uptime Kuma, SMC)
        IntegrationManager.shared.startAllServices()
        
        // Create menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        updateMenu()
        
        // Observe headless mode state changes (such as auto-restoration)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStateChanged),
            name: .headlessModeStateChanged,
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
        
        // Auto-install CLI helper symlink
        setupCLISymlink()
        
        // Auto-reconnect if headless mode was previously enabled and autoEnableOnLaunch is true
        let autoEnable = UserDefaults.standard.bool(forKey: "AutoEnableHeadlessOnLaunch")
        let previouslyEnabled = UserDefaults.standard.bool(forKey: "HeadlessModeEnabled")
        if autoEnable && previouslyEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.controller.enableHeadlessMode()
                self.updateIcon()
                self.updateMenu()
            }
        }
        
        // Silent background check for updates 3 seconds after launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            UpdateManager.shared.checkForUpdates(silent: true)
        }
    }
    
    private func setupCLISymlink() {
        let fileManager = FileManager.default
        let symlinkPath = "/usr/local/bin/machead"
        let executablePath = "/Applications/MacHead.app/Contents/MacOS/MacHead"
        
        // Ensure the source executable exists (so we only symlink if we are actually installed in /Applications)
        guard fileManager.fileExists(atPath: executablePath) else {
            print("CLI Auto-Link: Source executable not found at \(executablePath). Skipping auto-link.")
            return
        }
        
        // Check if symlink already exists and points to the correct location
        if fileManager.fileExists(atPath: symlinkPath) {
            if let destination = try? fileManager.destinationOfSymbolicLink(atPath: symlinkPath), destination == executablePath {
                return // Already set up correctly
            }
        }
        
        // Try creating directory and link directly (in case /usr/local/bin is user-writeable)
        let binDir = "/usr/local/bin"
        var needsElevation = false
        if !fileManager.fileExists(atPath: binDir) {
            do {
                try fileManager.createDirectory(atPath: binDir, withIntermediateDirectories: true, attributes: nil)
            } catch {
                needsElevation = true
            }
        }
        
        if !needsElevation {
            if fileManager.fileExists(atPath: symlinkPath) {
                try? fileManager.removeItem(atPath: symlinkPath)
            }
            do {
                try fileManager.createSymbolicLink(atPath: symlinkPath, withDestinationPath: executablePath)
                print("CLI Auto-Link: Created successfully under user privileges.")
                return
            } catch {
                needsElevation = true
            }
        }
        
        if needsElevation {
            // Prompt the user on main thread to grant permission for CLI link installation
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "安装 MacHead 命令行工具"
                alert.informativeText = "MacHead 希望在 /usr/local/bin/machead 创建命令行工具的软链接。启用后，您可以在终端中运行 'machead' 直接管控设备守护程序。"
                alert.alertStyle = .informational
                alert.addButton(withTitle: "立即安装 (需密码或Touch ID)")
                alert.addButton(withTitle: "稍后")
                
                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    let script = "do shell script \"mkdir -p /usr/local/bin && ln -sf /Applications/MacHead.app/Contents/MacOS/MacHead /usr/local/bin/machead\" with administrator privileges"
                    if let appleScript = NSAppleScript(source: script) {
                        var error: NSDictionary?
                        appleScript.executeAndReturnError(&error)
                        if let err = error {
                            print("CLI Auto-Link: Elevation failed: \(err)")
                        } else {
                            print("CLI Auto-Link: Successfully created symlink via elevation.")
                        }
                    }
                }
            }
        }
    }
    
    private func updateIcon() {
        let autoEnable = UserDefaults.standard.bool(forKey: "AutoEnableHeadlessOnLaunch")
        let previouslyEnabled = UserDefaults.standard.bool(forKey: "HeadlessModeEnabled")
        let isHeadless = controller.isHeadlessModeEnabled || (autoEnable && previouslyEnabled)
        
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
    
    private func updateMenu() {
        let menu = NSMenu()
        
        // Mode toggle item
        let toggleItem = NSMenuItem(
            title: "MacBook Headless 模式",
            action: #selector(toggleHeadlessModeMenuAction),
            keyEquivalent: "h"
        )
        toggleItem.target = self
        toggleItem.state = controller.isHeadlessModeEnabled ? .on : .off
        menu.addItem(toggleItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Preferences item
        let preferencesItem = NSMenuItem(
            title: "偏好设置...",
            action: #selector(openPreferences),
            keyEquivalent: ","
        )
        preferencesItem.target = self
        menu.addItem(preferencesItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Quit item
        let quitItem = NSMenuItem(
            title: "退出 MacHead",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem.menu = menu
    }
    
    @objc private func toggleHeadlessModeMenuAction() {
        if controller.isHeadlessModeEnabled {
            controller.disableHeadlessMode()
        } else {
            controller.enableHeadlessMode()
        }
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
            window.title = "MacHead 偏好设置"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = .clear
            window.contentViewController = controller
            window.center()
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("MacHeadPreferencesWindow")
            self.preferencesWindow = window
        }
        
        // Bring window to front
        NSApp.activate(ignoringOtherApps: true)
        preferencesWindow?.makeKeyAndOrderFront(nil)
    }
    
    @objc private func handleStateChanged() {
        updateIcon()
        updateMenu()
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
        // Stop all integrations
        IntegrationManager.shared.stopAllServices()
        
        // Stop Web Server
        WebServer.shared.stop()
        
        // Safety fallback: restore built-in screen when quitting
        if controller.isHeadlessModeEnabled {
            controller.disableHeadlessMode()
        }
        NSApp.terminate(nil)
    }
}
