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
            "AutoEnableHeadlessOnLaunch": true,
            "DisableTrackpadWhenExternalMouseConnected": false,
            "EnableBatteryProtection": true,
            "BatteryThreshold": 20,
            "MuteMicrophoneInHeadlessMode": false,
            "EnableWebServer": false,
            "DisableKeyboardAndTrackpadInHeadlessMode": false,
            "AutoExitHeadlessOnDisconnect": true,
            "AutoRestoreHeadlessOnConnect": true
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
            object: nil
        )
        
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleCLIDisengage),
            name: NSNotification.Name("com.waffle.MacHead.CLI.disable"),
            object: nil
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
    }
    
    private func setupCLISymlink() {
        let fileManager = FileManager.default
        let symlinkPath = "/usr/local/bin/machead"
        let executablePath = "/Applications/MacHead.app/Contents/MacOS/MacHead"
        
        // Ensure the source executable exists (so we only symlink if we are actually installed in /Applications)
        guard fileManager.fileExists(atPath: executablePath) else {
            print("CLI Auto-Link: Source executable not found at \(executablePath). Skipping.")
            return
        }
        
        // Ensure /usr/local/bin directory exists
        let binDir = "/usr/local/bin"
        if !fileManager.fileExists(atPath: binDir) {
            do {
                try fileManager.createDirectory(atPath: binDir, withIntermediateDirectories: true, attributes: nil)
            } catch {
                print("CLI Auto-Link: Failed to create directory \(binDir): \(error)")
                return
            }
        }
        
        // If symlink already exists
        if fileManager.fileExists(atPath: symlinkPath) {
            // Check if it already points to the correct location
            if let destination = try? fileManager.destinationOfSymbolicLink(atPath: symlinkPath), destination == executablePath {
                return // Already set up correctly
            }
            // Remove incorrect symlink
            do {
                try fileManager.removeItem(atPath: symlinkPath)
            } catch {
                print("CLI Auto-Link: Failed to remove old symlink: \(error)")
                return
            }
        }
        
        // Create symlink
        do {
            try fileManager.createSymbolicLink(atPath: symlinkPath, withDestinationPath: executablePath)
            print("CLI Auto-Link: Successfully created symlink at \(symlinkPath)")
        } catch {
            print("CLI Auto-Link: Failed to create symlink at \(symlinkPath): \(error)")
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
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "MacHead 偏好设置"
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
    
    @objc private func quitApp() {
        // Stop Web Server
        WebServer.shared.stop()
        
        // Safety fallback: restore built-in screen when quitting
        if controller.isHeadlessModeEnabled {
            controller.disableHeadlessMode()
        }
        NSApp.terminate(nil)
    }
}
