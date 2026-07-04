import Cocoa
import IOKit
import IOKit.pwr_mgt
import CoreGraphics

extension Notification.Name {
    static let headlessModeStateChanged = Notification.Name("com.waffle.MacHead.headlessModeStateChanged")
}

/// 全局/文件级的显示器重配置回调函数，符合 C 语言函数指针的调用约定
private func displayReconfigurationCallback(
    displayID: CGDirectDisplayID,
    flags: CGDisplayChangeSummaryFlags,
    userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo = userInfo else { return }
    let controller = Unmanaged<HeadlessModeController>.fromOpaque(userInfo).takeUnretainedValue()
    
    // 1. 如果是开始配置且显示器是内置的，且我们仍处于无头模式，则再次断开
    if flags.contains(.beginConfigurationFlag),
       CGDisplayIsBuiltin(displayID) != 0,
       controller.isHeadlessModeEnabled {
        NSLog("MacHead: 检测到内置显示屏重新上线，尝试在 0.5 秒后断开...")
        // 稍等一下让系统完成配置，再切断
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if controller.isHeadlessModeEnabled {
                DisplayManager.shared.disconnectBuiltIn()
            }
        }
    }
    
    // 2. 配置完成且监测已启动，执行显示器变动时的自动退出/恢复逻辑
    if !flags.contains(.beginConfigurationFlag) && controller.isDisplayMonitoringStarted {
        var count: UInt32 = 0
        if CGGetOnlineDisplayList(0, nil, &count) == .success {
            var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
            if CGGetOnlineDisplayList(count, &displays, &count) == .success {
                // 计算在线的外接显示器数量
                let externalCount = displays.filter { CGDisplayIsBuiltin($0) == 0 }.count
                NSLog("MacHead: 显示配置变更完成，当前在线外接显示器数量: %d", externalCount)
                
                if externalCount == 0 {
                    if controller.isHeadlessModeEnabled {
                        let autoExit = UserDefaults.standard.bool(forKey: "AutoExitHeadlessOnDisconnect")
                        if autoExit {
                            NSLog("MacHead: 检测到所有外接显示器已断开，启动安全防黑屏恢复...")
                            DispatchQueue.main.async {
                                controller.triggerSafeRecovery()
                            }
                        }
                    }
                } else {
                    if !controller.isHeadlessModeEnabled {
                        let autoRestore = UserDefaults.standard.bool(forKey: "AutoRestoreHeadlessOnConnect")
                        if autoRestore {
                            NSLog("MacHead: 检测到外接显示器已重新接入，自动恢复 Headless 模式...")
                            DispatchQueue.main.async {
                                controller.enableHeadlessMode()
                            }
                        }
                    }
                }
            }
        }
    }
}

final class HeadlessModeController {
    static let shared = HeadlessModeController()
    
    private(set) var isHeadlessModeEnabled = false
    private var sleepAssertionID: IOPMAssertionID = 0
    private var isCallbackRegistered = false
    var isDisplayMonitoringStarted = false
    
    private init() {}
    
    func enableHeadlessMode() {
        guard !isHeadlessModeEnabled else { return }
        isHeadlessModeEnabled = true
        UserDefaults.standard.set(true, forKey: "HeadlessModeEnabled")
        NSLog("MacHead: 正在启用无头模式...")
        
        // 1. 切断内屏
        DisplayManager.shared.disconnectBuiltIn()
        
        // 1.5. 自动静音内置麦克风
        MediaDeviceManager.shared.muteBuiltInMicrophone()
        
        // 2. 评估并获取电源断言状态
        evaluatePowerAssertion()
        
        // 4. 监听系统唤醒，确保唤醒后内屏仍被断开
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        
        NotificationCenter.default.post(name: .headlessModeStateChanged, object: nil)
    }
    
    func disableHeadlessMode() {
        guard isHeadlessModeEnabled else { return }
        isHeadlessModeEnabled = false
        UserDefaults.standard.set(false, forKey: "HeadlessModeEnabled")
        NSLog("MacHead: 正在关闭无头模式...")
        
        // 1. 重连内屏
        DisplayManager.shared.reconnectBuiltIn()
        
        // 1.5. 恢复内置麦克风的静音状态
        MediaDeviceManager.shared.unmuteBuiltInMicrophone()
        
        // 2. 释放所有电源断言
        updateSleepAssertion(enabled: false)
        
        // 4. 移除唤醒监听
        NSWorkspace.shared.notificationCenter.removeObserver(
            self,
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        
        NotificationCenter.default.post(name: .headlessModeStateChanged, object: nil)
    }
    
    /// 触发防黑屏安全恢复，强行退出无头模式并弹窗告警
    func triggerSafeRecovery() {
        guard isHeadlessModeEnabled else { return }
        
        // 1. 退出无头模式
        disableHeadlessMode()
        
        // 3. 弹窗警告用户
        let alert = NSAlert()
        alert.messageText = "安全恢复提示"
        alert.informativeText = "检测到所有外接显示器已断开。为了防止屏幕彻底黑屏，MacHead 已自动退出 Headless 模式并恢复了内置显示屏。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "我知道了")
        
        // 将应用带到前台显示弹窗
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    
    /// 动态管理空闲睡眠断言
    func updateSleepAssertion(enabled: Bool) {
        if enabled {
            guard isHeadlessModeEnabled else { return }
            if sleepAssertionID == 0 {
                let reason = "MacHead: Headless mode active" as CFString
                let result = IOPMAssertionCreateWithName(
                    kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    reason,
                    &sleepAssertionID
                )
                if result != kIOReturnSuccess {
                    NSLog("MacHead: 无法创建电源断言 %d", result)
                } else {
                    NSLog("MacHead: 成功创建电源断言，ID: %d", sleepAssertionID)
                }
            }
        } else {
            if sleepAssertionID != 0 {
                IOPMAssertionRelease(sleepAssertionID)
                NSLog("MacHead: 释放电源断言，ID: %d", sleepAssertionID)
                sleepAssertionID = 0
            }
        }
    }
    
    
    /// 重新评估电源断言状态
    func evaluatePowerAssertion() {
        guard isHeadlessModeEnabled else { return }
        
        let preventIdleSleep = UserDefaults.standard.bool(forKey: "PreventIdleSleep")
        let isBatteryLow = BatteryManager.shared.isBatteryProtectionActive
        
        // 只有在允许防止睡眠且电池不处于低电量保护状态时，才持有断言
        let shouldHoldAssertion = preventIdleSleep && !isBatteryLow
        updateSleepAssertion(enabled: shouldHoldAssertion)
    }
    
    // MARK: - 显示器变化守护
    
    func registerDisplayCallback() {
        guard !isCallbackRegistered else { return }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let result = CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, userInfo)
        if result == .success {
            isCallbackRegistered = true
            NSLog("MacHead: 成功注册显示器变化回调")
            // 延时 1 秒启动显示器插拔监测，避开 App 启动时的初始状态回调
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.isDisplayMonitoringStarted = true
                NSLog("MacHead: 显示器插拔监测已正式启动")
            }
        } else {
            NSLog("MacHead: 注册显示器变化回调失败: %d", result.rawValue)
        }
    }
    
    func unregisterDisplayCallback() {
        guard isCallbackRegistered else { return }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let result = CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, userInfo)
        if result == .success {
            isCallbackRegistered = false
            NSLog("MacHead: 成功注销显示器变化回调")
        } else {
            NSLog("MacHead: 注销显示器变化回调失败: %d", result.rawValue)
        }
    }
    
    @objc private func systemDidWake() {
        // 唤醒后系统可能重新枚举显示器，再次确保内屏断开
        guard isHeadlessModeEnabled else { return }
        NSLog("MacHead: 系统唤醒，检查并确保内置显示器断开...")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if self.isHeadlessModeEnabled {
                DisplayManager.shared.disconnectBuiltIn()
            }
        }
    }
}
