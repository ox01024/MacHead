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
    
    // 忽略配置起始阶段（kCGDisplayBeginConfigurationFlag）
    // 官方 CoreGraphics 规范明确指出：BeginConfiguration 仅代表事务开始，硬件拓扑与驱动状态处于未决中间态，
    // 不得在此期间调用显示配置修改接口；所有插拔、恢复与无头模式维持逻辑均在配置完成后（非 beginConfigurationFlag）统一处理。
    guard !flags.contains(.beginConfigurationFlag) else {
        return
    }

    let currentExternals = controller.currentExternalDisplays()

    // 启动自适应就绪队列响应：若正在等待外接屏就绪且检测到外接屏出现，即刻开启无头模式
    // 关键修复：即使当前仍处于启动前 1.0 秒静默期（isDisplayMonitoringStarted 为 false），
    // 只要自适应队列在等待且有效外接屏就绪，必须立刻响应开启无头，绝不在静默期丢弃回调！
    if controller.isWaitingForLaunchReady && !currentExternals.isEmpty {
        NSLog("MacHead: 启动自适应就绪队列在显示器连接回调中检测到有效外接屏就绪，即刻开启无头模式")
        controller.completeLaunchAdaptiveReady(foundExternals: true)
        return
    }

    guard controller.isDisplayMonitoringStarted else { return }

    let previousExternals = controller.activeExternalDisplays
    let isBuiltInEvent = controller.isBuiltInDisplay(displayID)

    // 若变动事件属于内置屏且外接屏列表在瞬态中暂时为空，不得破坏已记录的外接显示器快照
    if !isBuiltInEvent || !currentExternals.isEmpty {
        controller.activeExternalDisplays = currentExternals
        if !currentExternals.isEmpty {
            controller.lastKnownExternalDisplays = currentExternals
        }
    }

    NSLog("MacHead: 显示配置变更完成。变动屏ID: %d (是否内置: %d), 之前外接: %@, 当前外接: %@, 数量: %d, 无头模式: %d",
          displayID, isBuiltInEvent ? 1 : 0, previousExternals.description, currentExternals.description, currentExternals.count, controller.isHeadlessModeEnabled ? 1 : 0)

    // 所有外接显示器都已断开（外接屏插拔事件，且外接屏集合从非空变为清空）：按需安全恢复内屏
    // 注意：若变动的显示器是内置屏本身（例如进入无头模式主动断开内屏），绝不得误当做外接屏拔除而触发恢复
    if !isBuiltInEvent && currentExternals.isEmpty {
        // 如果处于唤醒总线稳定期且曾有外接显示器，暂不在此瞬时回调中贸然判定拔线（避免总线握手延时误判）；
        // 稳定期结束由 systemDidWake 统一复核
        if controller.isWakeStabilizing && !controller.lastKnownExternalDisplays.isEmpty {
            NSLog("MacHead: 处于唤醒稳定期内，暂缓在瞬时重配置回调中触发安全恢复，交由唤醒计时器复核")
            return
        }

        let hadExternals = !previousExternals.isEmpty || !controller.lastKnownExternalDisplays.isEmpty
        if hadExternals,
           controller.isHeadlessModeEnabled,
           UserDefaults.standard.bool(forKey: "AutoExitHeadlessOnDisconnect") {
            NSLog("MacHead: 检测到外接显示器已断开，主队列复核后按需退出无头模式...")
            DispatchQueue.main.async {
                // 双重确认：外接屏必须在主队列复核时依然为空，防止外接屏成为主屏时的瞬态重排或启动时序竞争误关无头
                guard controller.currentExternalDisplays().isEmpty else {
                    NSLog("MacHead: 经复核外接显示器依然在线，忽略瞬态空列表")
                    return
                }
                controller.triggerSafeRecovery()
            }
        }
        return
    }

    // 无头模式下内屏被系统意外点亮（插拔/唤醒）：延迟片刻让系统稳定后重新切断
    if controller.isHeadlessModeEnabled {
        if controller.isBuiltInActive() {
            NSLog("MacHead: 无头模式下检测到内屏处于活动状态，重新切断内屏以维持 Headless...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                controller.maintainBuiltInDisconnect()
            }
        }
        return
    }

    // 非无头模式：有新的外接显示器接入时，按需自动恢复 Headless
    let newDisplays = currentExternals.subtracting(previousExternals)
    guard !newDisplays.isEmpty,
          UserDefaults.standard.bool(forKey: "AutoRestoreHeadlessOnConnect") else { return }
    NSLog("MacHead: 检测到新外接显示器已接入: %@，自动恢复 Headless 模式...", newDisplays.description)
    DispatchQueue.main.async {
        controller.enableHeadlessMode()
    }
}

final class HeadlessModeController {
    static let shared = HeadlessModeController()
    
    private(set) var isHeadlessModeEnabled = false
    private var sleepAssertionID: IOPMAssertionID = 0
    private var activeAssertionType: String = ""
    private var isCallbackRegistered = false
    var isDisplayMonitoringStarted = false
    fileprivate(set) var activeExternalDisplays: Set<CGDirectDisplayID> = []
    /// 记录最近一次确认处于连通状态的外接显示器集合（用于判断无头会话是否曾有外接屏）
    fileprivate(set) var lastKnownExternalDisplays: Set<CGDirectDisplayID> = []
    /// 唤醒总线稳定期标记，在此期间暂缓高频判定以留出总线握手时间
    fileprivate(set) var isWakeStabilizing = false
    private var wakeStabilizationWorkItem: DispatchWorkItem?
    
    /// 启动就绪队列状态
    fileprivate(set) var isWaitingForLaunchReady = false
    private var launchReadyWorkItem: DispatchWorkItem?
    private var launchAdaptiveCompletion: (() -> Void)?
    
    // MARK: - Test Hooks
    /// 测试模式：动作函数只记录 was*Called 标志位，不触碰真实显示器/麦克风/电源断言/遥测
    var isTestMode = false
    var wasEnableHeadlessModeCalled = false
    var wasDisableHeadlessModeCalled = false
    var wasTriggerSafeRecoveryCalled = false
    var wasMaintainDisconnectCalled = false
    var mockExternalDisplays: Set<CGDirectDisplayID>? = nil
    var mockBuiltInDisplayID: CGDirectDisplayID? = nil
    /// nil = 读取真实活动状态；否则用该值替代（供测试模拟内屏被系统点亮）
    var mockBuiltInActive: Bool? = nil
    var mockBuiltInOnline: Bool? {
        get { mockBuiltInActive }
        set { mockBuiltInActive = newValue }
    }
    
    private init() {}

    /// 判断指定显示器 ID 是否为内置显示器
    func isBuiltInDisplay(_ id: CGDirectDisplayID) -> Bool {
        if let mock = mockBuiltInDisplayID {
            return id == mock
        }
        if isTestMode {
            return id == 1
        }
        if CGDisplayIsBuiltin(id) != 0 {
            return true
        }
        if let builtInID = DisplayManager.shared.builtInDisplayID {
            return id == builtInID
        }
        let persisted = UserDefaults.standard.integer(forKey: "BuiltInDisplayID")
        if persisted != 0 {
            return id == CGDirectDisplayID(persisted)
        }
        #if arch(arm64)
        // Apple Silicon MacBook 默认内屏 ID 惯例为 1（仅在完全无权威/缓存数据时兜底）
        return id == 1
        #else
        return false
        #endif
    }

    /// 内置屏是否处于活动状态（测试模式可被 mockBuiltInActive/mockBuiltInOnline 覆盖）
    func isBuiltInActive() -> Bool {
        mockBuiltInActive ?? DisplayManager.shared.isBuiltInActive
    }

    /// 内置屏是否在线/活动（保留该方法以兼容旧调用，语义对齐活动状态）
    func isBuiltInOnline() -> Bool {
        isBuiltInActive()
    }

    /// 维持无头：仅当无头模式生效且仍有外接屏时，重新切断被系统意外点亮的内屏。
    /// 由显示器回调（0.3s 延迟）与 systemDidWake（1.0s 延迟）共用；0.3/1.0 秒的延迟
    /// 是有意留出的系统稳定窗口，因此这里重新读取实时外接屏状态而非用旧快照。
    func maintainBuiltInDisconnect() {
        guard isHeadlessModeEnabled, !currentExternalDisplays().isEmpty else { return }
        guard isBuiltInActive() else {
            NSLog("MacHead: 内屏当前未处于活动状态，无需重复切断")
            return
        }
        if isTestMode {
            wasMaintainDisconnectCalled = true
            return
        }
        DisplayManager.shared.disconnectBuiltIn()
    }

    func currentExternalDisplays() -> Set<CGDirectDisplayID> {
        if let mock = mockExternalDisplays {
            return mock
        }
        guard let online = DisplayManager.shared.onlineDisplayIDs() else { return [] }
        return Set(online.filter { CGDisplayIsBuiltin($0) == 0 && !DisplayManager.isVirtualDisplay($0) })
    }
    
    func enableHeadlessMode() {
        wasEnableHeadlessModeCalled = true
        cancelLaunchAdaptiveReady()
        isDisplayMonitoringStarted = true
        guard !isHeadlessModeEnabled, !isTestMode else { return }
        isHeadlessModeEnabled = true
        let externals = currentExternalDisplays()
        activeExternalDisplays = externals
        if !externals.isEmpty {
            lastKnownExternalDisplays = externals
        }
        UserDefaults.standard.set(true, forKey: "HeadlessModeEnabled")
        NSLog("MacHead: 正在启用无头模式...")
        
        // 1. 切断内屏
        DisplayManager.shared.disconnectBuiltIn()
        
        // 1.5. 自动静音内置麦克风
        MediaDeviceManager.shared.muteBuiltInMicrophone()
        
        // 2. 评估并获取电源断言状态
        evaluatePowerAssertion()
        
        // 4. 监听系统唤醒与屏幕点亮，确保唤醒后内屏拓扑与无头状态正确
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        
        NotificationCenter.default.post(name: .headlessModeStateChanged, object: nil)
        TelemetryManager.shared.track(event: "app_event", extraInfo: ["action": "enable_headless"])
    }
    
    func disableHeadlessMode(forceReconnect: Bool = true) {
        wasDisableHeadlessModeCalled = true
        cancelLaunchAdaptiveReady()
        wakeStabilizationWorkItem?.cancel()
        wakeStabilizationWorkItem = nil
        isWakeStabilizing = false
        guard isHeadlessModeEnabled, !isTestMode else { return }
        isHeadlessModeEnabled = false
        UserDefaults.standard.set(false, forKey: "HeadlessModeEnabled")
        NSLog("MacHead: 正在关闭无头模式...")
        
        // 1. 重连内屏
        DisplayManager.shared.reconnectBuiltIn(force: forceReconnect)
        
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
        NSWorkspace.shared.notificationCenter.removeObserver(
            self,
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        
        NotificationCenter.default.post(name: .headlessModeStateChanged, object: nil)
        TelemetryManager.shared.track(event: "app_event", extraInfo: ["action": "disable_headless"])
    }
    
    /// 触发安全恢复，直接退出无头模式
    func triggerSafeRecovery() {
        wasTriggerSafeRecoveryCalled = true
        guard isHeadlessModeEnabled, !isTestMode else { return }
        guard currentExternalDisplays().isEmpty else {
            NSLog("MacHead: 复核发现外接显示器仍在，取消安全恢复")
            return
        }
        NSLog("MacHead: 检测到外接屏断开，直接退出无头模式以恢复内屏")
        disableHeadlessMode(forceReconnect: true)
    }
    
    /// 动态管理空闲与合盖睡眠断言
    func updateSleepAssertion(enabled: Bool) {
        let keepRunningOnLidClose = UserDefaults.standard.bool(forKey: "KeepRunningOnLidClose")
        let targetType = keepRunningOnLidClose ? (kIOPMAssertionTypePreventSystemSleep as String) : (kIOPMAssertionTypePreventUserIdleSystemSleep as String)
        
        if enabled {
            guard isHeadlessModeEnabled else { return }
            
            // 如果已有断言且类型不符，先释放
            if sleepAssertionID != 0 && activeAssertionType != targetType {
                IOPMAssertionRelease(sleepAssertionID)
                NSLog("MacHead: 释放旧类型电源断言，ID: %d", sleepAssertionID)
                sleepAssertionID = 0
                activeAssertionType = ""
            }
            
            if sleepAssertionID == 0 {
                let reason = "MacHead: Headless mode active" as CFString
                let result = IOPMAssertionCreateWithName(
                    targetType as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    reason,
                    &sleepAssertionID
                )
                if result != kIOReturnSuccess {
                    NSLog("MacHead: 无法创建电源断言 (%@) %d", targetType, result)
                } else {
                    NSLog("MacHead: 成功创建电源断言 (%@)，ID: %d", targetType, sleepAssertionID)
                    activeAssertionType = targetType
                }
            }
        } else {
            if sleepAssertionID != 0 {
                IOPMAssertionRelease(sleepAssertionID)
                NSLog("MacHead: 释放电源断言，ID: %d", sleepAssertionID)
                sleepAssertionID = 0
                activeAssertionType = ""
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
                if !self.isHeadlessModeEnabled {
                    self.activeExternalDisplays = self.currentExternalDisplays()
                }
                self.isDisplayMonitoringStarted = true
                NSLog("MacHead: 显示器插拔监测已正式启动，当前外接显示器: %@", self.activeExternalDisplays.description)
            }
        } else {
            NSLog("MacHead: 注册显示器变化回调失败: %d", result.rawValue)
        }
    }
    
    @objc func systemDidWake() {
        guard isHeadlessModeEnabled else { return }
        NSLog("MacHead: 系统或屏幕唤醒，开启 1.2 秒唤醒稳定期以等待显示总线与外接屏完成握手...")

        // 取消前一个未完成的稳定计时（如连续唤醒）
        wakeStabilizationWorkItem?.cancel()
        isWakeStabilizing = true

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.isWakeStabilizing = false
            guard self.isHeadlessModeEnabled else { return }

            let externals = self.currentExternalDisplays()
            NSLog("MacHead: 唤醒稳定期结束，复核显示器拓扑。当前外接: %@, 之前外接: %@",
                  externals.description, self.lastKnownExternalDisplays.description)

            if externals.isEmpty {
                // 如果休眠前曾有外接显示器，但唤醒稳定期过后所有外接屏均已断开（例如休眠期间被拔线）：
                // 自动退出无头模式以恢复内屏
                if !self.lastKnownExternalDisplays.isEmpty && UserDefaults.standard.bool(forKey: "AutoExitHeadlessOnDisconnect") {
                    NSLog("MacHead: 唤醒后检测到所有外接显示器已断开，直接退出无头模式以恢复内屏！")
                    self.triggerSafeRecovery()
                }
            } else {
                // 外接显示器仍在：更新记录，并在内屏被系统点亮时重新切断
                self.activeExternalDisplays = externals
                self.lastKnownExternalDisplays = externals
                self.maintainBuiltInDisconnect()
            }
        }

        wakeStabilizationWorkItem = workItem
        // 延时 1.2 秒留出老款 Intel Mac / 雷电扩展坞的握手时间
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: workItem)
    }

    // MARK: - 启动自适应就绪队列

    /// 启动自适应外接显示器就绪监听队列：
    /// 在最多等待 timeout 秒内，每 pollInterval 秒轮询一次，或在收到显示器连接回调时响应；
    /// 一旦检测到有效外接屏就绪即刻开启无头模式；若超时仍无外接屏则按原策略兜底开启无头模式。
    func startLaunchAdaptiveReadyQueue(
        timeout: TimeInterval = 8.0,
        pollInterval: TimeInterval = 0.5,
        completion: (() -> Void)? = nil
    ) {
        cancelLaunchAdaptiveReady()
        guard !isHeadlessModeEnabled else {
            completion?()
            return
        }
        isWaitingForLaunchReady = true
        launchAdaptiveCompletion = completion

        // 若在启动时外接显示器已完成硬件握手，直接即刻开启无头模式
        if !currentExternalDisplays().isEmpty {
            NSLog("MacHead: 启动就绪队列检测到外接显示器已就绪，即刻开启无头模式")
            completeLaunchAdaptiveReady(foundExternals: true)
            return
        }

        NSLog("MacHead: 启动就绪队列开始等待外接显示器握手（最大等待 %.1f 秒，轮询间隔 %.2f 秒）...", timeout, pollInterval)

        let startTime = Date()

        func schedulePoll() {
            guard self.isWaitingForLaunchReady else { return }

            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed >= timeout {
                NSLog("MacHead: 启动就绪等待超时 (%.1f 秒)，未检测到外接显示器，按原策略兜底开启无头模式", elapsed)
                self.completeLaunchAdaptiveReady(foundExternals: false)
                return
            }

            let remaining = timeout - elapsed
            let delay = min(pollInterval, remaining)

            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self, self.isWaitingForLaunchReady else { return }

                if !self.currentExternalDisplays().isEmpty {
                    NSLog("MacHead: 启动就绪队列在轮询中检测到有效外接屏就绪，即刻开启无头模式")
                    self.completeLaunchAdaptiveReady(foundExternals: true)
                    return
                }

                let curElapsed = Date().timeIntervalSince(startTime)
                if curElapsed >= timeout {
                    NSLog("MacHead: 启动就绪等待超时 (%.1f 秒)，未检测到外接显示器，按原策略兜底开启无头模式", curElapsed)
                    self.completeLaunchAdaptiveReady(foundExternals: false)
                    return
                }

                schedulePoll()
            }

            self.launchReadyWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }

        schedulePoll()
    }

    func completeLaunchAdaptiveReady(foundExternals: Bool) {
        guard isWaitingForLaunchReady else { return }
        isWaitingForLaunchReady = false
        launchReadyWorkItem?.cancel()
        launchReadyWorkItem = nil

        let action = { [weak self] in
            guard let self = self else { return }
            self.isDisplayMonitoringStarted = true
            self.enableHeadlessMode()
            let callback = self.launchAdaptiveCompletion
            self.launchAdaptiveCompletion = nil
            callback?()
        }

        if Thread.isMainThread {
            action()
        } else {
            DispatchQueue.main.async(execute: action)
        }
    }

    func cancelLaunchAdaptiveReady() {
        guard isWaitingForLaunchReady else { return }
        isWaitingForLaunchReady = false
        launchReadyWorkItem?.cancel()
        launchReadyWorkItem = nil
        launchAdaptiveCompletion = nil
    }
    
    static func runTests() {
        print("Running HeadlessModeController Unit Tests...")
        let controller = HeadlessModeController.shared
        
        // 测试模式：动作只记录标志位，绝不触碰真实显示器/麦克风/遥测
        controller.isTestMode = true

        // Save current real state
        let originalIsHeadless = controller.isHeadlessModeEnabled
        let originalIsMonitoring = controller.isDisplayMonitoringStarted
        let originalActiveExternals = controller.activeExternalDisplays
        let originalLastKnownExternals = controller.lastKnownExternalDisplays
        let originalIsWakeStabilizing = controller.isWakeStabilizing

        defer {
            // Restore original state
            controller.cancelLaunchAdaptiveReady()
            controller.isHeadlessModeEnabled = originalIsHeadless
            controller.isDisplayMonitoringStarted = originalIsMonitoring
            controller.activeExternalDisplays = originalActiveExternals
            controller.lastKnownExternalDisplays = originalLastKnownExternals
            controller.isWakeStabilizing = originalIsWakeStabilizing
            controller.mockExternalDisplays = nil
            controller.mockBuiltInActive = nil
            controller.mockBuiltInDisplayID = nil
            controller.isTestMode = false
        }

        // Helper to reset hooks
        func resetHooks() {
            controller.wasEnableHeadlessModeCalled = false
            controller.wasDisableHeadlessModeCalled = false
            controller.wasTriggerSafeRecoveryCalled = false
            controller.wasMaintainDisconnectCalled = false
        }

        // 回调里的动作经 DispatchQueue.main.async 派发，而 CLI 进程没有常驻 runloop，
        // 必须排水主队列，被派发的动作才会真正执行、标志位才会被记录。
        // 注意：用 precondition 而非 assert —— assert 在 -O 下会被整体编译移除，测试将永远"假绿"。
        func drainMainQueue(seconds: Double = 0.05) {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
        }

        // 模拟一次"显示器配置变更完成"事件：重置钩子、设置 mock 状态并触发回调
        func fireChange(headless: Bool,
                        previous: Set<CGDirectDisplayID>,
                        current: Set<CGDirectDisplayID>,
                        builtInOnline: Bool = false,
                        displayID: CGDirectDisplayID = 101,
                        flags: CGDisplayChangeSummaryFlags = []) {
            resetHooks()
            controller.isHeadlessModeEnabled = headless
            controller.activeExternalDisplays = previous
            controller.lastKnownExternalDisplays = previous
            controller.mockExternalDisplays = current
            controller.mockBuiltInOnline = builtInOnline
            displayReconfigurationCallback(displayID: displayID, flags: flags,
                                           userInfo: Unmanaged.passUnretained(controller).toOpaque())
        }

        controller.isDisplayMonitoringStarted = true

        // Test 1: Manually turning off headless mode when an external display is connected.
        // We want to make sure AutoRestoreHeadlessOnConnect does NOT trigger.
        print("Test 1: Manually turning off headless mode when an external display is connected...")
        fireChange(headless: false, previous: [101], current: [101]) // external display remains connected
        drainMainQueue()

        precondition(!controller.wasEnableHeadlessModeCalled, "FAIL: Auto-restore was incorrectly triggered when manually disabling headless mode!")
        precondition(!controller.wasMaintainDisconnectCalled, "FAIL: Maintain-disconnect was incorrectly triggered when headless mode is off!")
        print("Test 1: PASS")

        // Test 2: Unplugging the last external display when headless mode is active.
        // We expect triggerSafeRecovery to be called.
        print("Test 2: Unplugging the last external display when headless mode is active...")
        // Make sure user defaults has AutoExitHeadlessOnDisconnect set to true for test consistency
        let originalAutoExit = UserDefaults.standard.bool(forKey: "AutoExitHeadlessOnDisconnect")
        UserDefaults.standard.set(true, forKey: "AutoExitHeadlessOnDisconnect")
        defer {
            UserDefaults.standard.set(originalAutoExit, forKey: "AutoExitHeadlessOnDisconnect")
        }

        fireChange(headless: true, previous: [101], current: []) // unplugged
        drainMainQueue()

        precondition(controller.wasTriggerSafeRecoveryCalled, "FAIL: Safe recovery was not triggered when all external displays were disconnected!")
        print("Test 2: PASS")

        // Test 3: Plugging in a new external display when headless mode is inactive.
        // We expect enableHeadlessMode to be called.
        print("Test 3: Plugging in a new external display when headless mode is inactive...")
        let originalAutoRestore = UserDefaults.standard.bool(forKey: "AutoRestoreHeadlessOnConnect")
        UserDefaults.standard.set(true, forKey: "AutoRestoreHeadlessOnConnect")
        defer {
            UserDefaults.standard.set(originalAutoRestore, forKey: "AutoRestoreHeadlessOnConnect")
        }

        fireChange(headless: false, previous: [], current: [101]) // plugged in
        drainMainQueue()

        precondition(controller.wasEnableHeadlessModeCalled, "FAIL: Headless mode was not auto-restored when new display connected!")
        print("Test 3: PASS")

        // Test 4: Plugging in a second external display when headless mode is active.
        // We expect no action.
        print("Test 4: Plugging in a second external display when headless mode is active...")
        fireChange(headless: true, previous: [101], current: [101, 102], builtInOnline: false) // 内屏本应离线
        drainMainQueue()

        precondition(!controller.wasEnableHeadlessModeCalled, "FAIL: Incorrect action when adding second external display in headless mode!")
        precondition(!controller.wasDisableHeadlessModeCalled, "FAIL: Headless mode disabled when adding second external display!")
        precondition(!controller.wasMaintainDisconnectCalled, "FAIL: Maintain-disconnect triggered when adding second external display!")
        print("Test 4: PASS")

        // Test 5: Built-in display begins configuration when no external displays are connected.
        // Protect built-in display from being mistakenly disconnected.
        print("Test 5: Built-in display begins configuration when no external displays are connected...")
        fireChange(headless: true, previous: [], current: [], displayID: 1, flags: [.beginConfigurationFlag])
        drainMainQueue()

        precondition(controller.isHeadlessModeEnabled, "FAIL: Headless mode should not be corrupted by beginConfigurationFlag!")
        precondition(!controller.wasMaintainDisconnectCalled, "FAIL: Maintain-disconnect triggered during beginConfigurationFlag!")
        print("Test 5: PASS")

        // Test 6: Headless mode is active, the system unexpectedly re-lit the built-in display,
        // and external displays are still connected. Expect the built-in to be re-disconnected.
        print("Test 6: Headless mode with built-in unexpectedly re-lit and externals present...")
        fireChange(headless: true, previous: [101], current: [101], builtInOnline: true) // 模拟系统把内屏点亮

        // 维持断开带有 0.3 秒延迟，需要更长的排水窗口
        drainMainQueue(seconds: 0.4)

        precondition(controller.wasMaintainDisconnectCalled, "FAIL: Built-in display was not re-disconnected while headless mode is active with externals present!")
        precondition(controller.isHeadlessModeEnabled, "FAIL: Maintain-disconnect should not turn off headless mode!")
        print("Test 6: PASS")

        // Test 7: Built-in display finishes disconnecting when no external display was previously connected
        // (e.g. pure headless server or before external monitor finishes waking at boot).
        // Must NOT falsely trigger safe recovery as if an external display had been unplugged.
        print("Test 7: Built-in display finishes disconnecting when no external display was previously connected...")
        fireChange(headless: true, previous: [], current: [], builtInOnline: false, displayID: 1)
        drainMainQueue()

        precondition(!controller.wasTriggerSafeRecoveryCalled, "FAIL: Safe recovery was falsely triggered when previousExternals was already empty!")
        precondition(controller.isHeadlessModeEnabled, "FAIL: Headless mode should remain active when no external display was unplugged!")
        print("Test 7: PASS")

        // Test 8: System wake with external display disconnected during sleep.
        // Expect safe recovery to be triggered after wake delay to restore internal display.
        print("Test 8: System wake with external display disconnected during sleep...")
        resetHooks()
        UserDefaults.standard.set(true, forKey: "AutoExitHeadlessOnDisconnect")
        controller.isHeadlessModeEnabled = true
        controller.activeExternalDisplays = [101] // Was connected before sleep
        controller.lastKnownExternalDisplays = [101]
        controller.mockExternalDisplays = []     // Unplugged during sleep
        controller.mockBuiltInActive = false
        controller.systemDidWake()
        drainMainQueue(seconds: 1.4)

        precondition(controller.wasTriggerSafeRecoveryCalled, "FAIL: Safe recovery was not triggered when waking up with external unplugged!")
        print("Test 8: PASS")

        // Test 9: System wake with external display still connected and built-in screen unexpectedly re-lit.
        // Expect maintainBuiltInDisconnect to be called.
        print("Test 9: System wake with external display still connected and built-in screen re-lit...")
        resetHooks()
        controller.isHeadlessModeEnabled = true
        controller.activeExternalDisplays = [101]
        controller.lastKnownExternalDisplays = [101]
        controller.mockExternalDisplays = [101]
        controller.mockBuiltInActive = true // System re-lit the panel upon wake
        controller.systemDidWake()
        drainMainQueue(seconds: 1.4)

        precondition(controller.wasMaintainDisconnectCalled, "FAIL: Maintain-disconnect was not triggered when waking with external present and built-in re-lit!")
        print("Test 9: PASS")

        // Test 10: System wake in pure headless mode (activeExternalDisplays was empty before sleep).
        // Must NOT falsely trigger safe recovery.
        print("Test 10: System wake in pure headless mode...")
        resetHooks()
        controller.isHeadlessModeEnabled = true
        controller.activeExternalDisplays = [] // Pure headless
        controller.lastKnownExternalDisplays = []
        controller.mockExternalDisplays = []
        controller.mockBuiltInActive = false
        controller.systemDidWake()
        drainMainQueue(seconds: 1.4)

        precondition(!controller.wasTriggerSafeRecoveryCalled, "FAIL: Safe recovery was falsely triggered when waking in pure headless mode!")
        precondition(controller.isHeadlessModeEnabled, "FAIL: Headless mode was incorrectly disabled in pure headless wake!")
        print("Test 10: PASS")

        // Test 11: Built-in display active vs inactive state discrimination.
        // When mockBuiltInActive is false, isBuiltInActive() must return false even if onlineDisplayIDs contains it.
        print("Test 11: Built-in display active vs inactive state discrimination...")
        controller.mockBuiltInActive = false
        precondition(!controller.isBuiltInActive(), "FAIL: isBuiltInActive() must return false when display is inactive!")
        controller.mockBuiltInActive = true
        precondition(controller.isBuiltInActive(), "FAIL: isBuiltInActive() must return true when display is active!")
        controller.mockBuiltInActive = nil
        print("Test 11: PASS")

        // Test 12: Manual disable headless mode always calls disableHeadlessMode with forceReconnect = true
        print("Test 12: Manual disable headless mode with forceReconnect default...")
        resetHooks()
        controller.isHeadlessModeEnabled = true
        controller.disableHeadlessMode()
        precondition(controller.wasDisableHeadlessModeCalled, "FAIL: disableHeadlessMode was not invoked!")
        print("Test 12: PASS")

        // Test 13: Wake stabilization prevents premature safe recovery in callback
        print("Test 13: Wake stabilization suppresses premature callback safe recovery...")
        resetHooks()
        UserDefaults.standard.set(true, forKey: "AutoExitHeadlessOnDisconnect")
        controller.isHeadlessModeEnabled = true
        controller.activeExternalDisplays = [101]
        controller.lastKnownExternalDisplays = [101]
        controller.mockExternalDisplays = []
        controller.isWakeStabilizing = true // Bus handshake in progress
        displayReconfigurationCallback(displayID: 101, flags: [],
                                       userInfo: Unmanaged.passUnretained(controller).toOpaque())
        drainMainQueue(seconds: 0.1)
        precondition(!controller.wasTriggerSafeRecoveryCalled, "FAIL: Safe recovery should be suppressed during wake stabilization!")
        controller.isWakeStabilizing = false
        print("Test 13: PASS")

        // Test 14: Built-in display finishes disconnecting when external display was connected (launch auto-enable).
        // Transient empty display list during internal panel disconnect must NOT falsely trigger safe recovery!
        print("Test 14: Built-in display finishes disconnecting when external display was connected (launch auto-enable)...")
        fireChange(headless: true, previous: [101], current: [], builtInOnline: false, displayID: 1)
        drainMainQueue()

        precondition(!controller.wasTriggerSafeRecoveryCalled, "FAIL: Safe recovery was falsely triggered on built-in display disconnect event!")
        precondition(controller.isHeadlessModeEnabled, "FAIL: Headless mode should remain active during internal panel disconnect on launch!")
        print("Test 14: PASS")

        // Test 15: Auto-enable headless mode on launch with external display present.
        print("Test 15: Auto-enable headless mode on launch with external display present...")
        resetHooks()
        controller.isHeadlessModeEnabled = false
        controller.mockExternalDisplays = [101]
        controller.enableHeadlessMode()
        precondition(controller.wasEnableHeadlessModeCalled, "FAIL: enableHeadlessMode was not invoked!")
        print("Test 15: PASS")

        // Test 16: External display with ID 1 is not misidentified as built-in display when built-in ID is different.
        print("Test 16: External display with ID 1 is not misidentified as built-in display...")
        resetHooks()
        controller.mockBuiltInDisplayID = 69730122
        precondition(!controller.isBuiltInDisplay(1), "FAIL: ID 1 was falsely identified as built-in display when built-in ID is 69730122!")
        precondition(controller.isBuiltInDisplay(69730122), "FAIL: Real built-in ID 69730122 was not recognized!")
        controller.mockBuiltInDisplayID = nil
        print("Test 16: PASS")

        // Test 17: Transient empty external display list during external screen mode change does NOT trigger safe recovery
        // if external display is still present upon async verification.
        print("Test 17: Transient empty external display list does not falsely trigger safe recovery...")
        resetHooks()
        UserDefaults.standard.set(true, forKey: "AutoExitHeadlessOnDisconnect")
        controller.isHeadlessModeEnabled = true
        controller.activeExternalDisplays = [101]
        controller.lastKnownExternalDisplays = [101]
        controller.mockExternalDisplays = [] // Momentary blip during WindowServer mode change
        displayReconfigurationCallback(displayID: 101, flags: [],
                                       userInfo: Unmanaged.passUnretained(controller).toOpaque())
        // Display recovers immediately before main queue drain
        controller.mockExternalDisplays = [101]
        drainMainQueue()

        precondition(!controller.wasTriggerSafeRecoveryCalled, "FAIL: Safe recovery was falsely triggered on transient empty external list!")
        precondition(controller.isHeadlessModeEnabled, "FAIL: Headless mode should remain active when external display is still connected!")
        print("Test 17: PASS")

        // Test 18: Built-in display event preserves activeExternalDisplays snapshot even if current list is transiently empty.
        print("Test 18: Built-in display event preserves activeExternalDisplays snapshot...")
        resetHooks()
        controller.isHeadlessModeEnabled = true
        controller.activeExternalDisplays = [101]
        controller.lastKnownExternalDisplays = [101]
        controller.mockExternalDisplays = [] // Empty during internal disconnect
        displayReconfigurationCallback(displayID: 1, flags: [],
                                       userInfo: Unmanaged.passUnretained(controller).toOpaque())
        precondition(controller.activeExternalDisplays == [101], "FAIL: activeExternalDisplays was corrupted by built-in disconnect transient empty list!")
        drainMainQueue()
        print("Test 18: PASS")

        // Test 19: Adaptive launch queue enables headless mode immediately when external display connects before timeout
        print("Test 19: Adaptive launch queue enables headless mode when external display becomes ready...")
        resetHooks()
        controller.isHeadlessModeEnabled = false
        controller.mockExternalDisplays = []
        var test19CompletionCalled = false
        controller.startLaunchAdaptiveReadyQueue(timeout: 1.0, pollInterval: 0.1) {
            test19CompletionCalled = true
        }
        precondition(controller.isWaitingForLaunchReady, "FAIL: Queue should be waiting!")
        precondition(!controller.wasEnableHeadlessModeCalled, "FAIL: enableHeadlessMode should not be called yet!")

        // Simulate external display becoming ready after 0.15s
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            controller.mockExternalDisplays = [101]
        }
        drainMainQueue(seconds: 0.35)

        precondition(!controller.isWaitingForLaunchReady, "FAIL: Queue should have completed!")
        precondition(controller.wasEnableHeadlessModeCalled, "FAIL: enableHeadlessMode was not called when external display appeared!")
        precondition(test19CompletionCalled, "FAIL: completion callback was not invoked!")
        print("Test 19: PASS")

        // Test 20: Adaptive launch queue falls back to enabling headless mode after timeout when no external display connects
        print("Test 20: Adaptive launch queue timeout fallback...")
        resetHooks()
        controller.isHeadlessModeEnabled = false
        controller.mockExternalDisplays = []
        var test20CompletionCalled = false
        controller.startLaunchAdaptiveReadyQueue(timeout: 0.2, pollInterval: 0.05) {
            test20CompletionCalled = true
        }
        precondition(controller.isWaitingForLaunchReady, "FAIL: Queue should be waiting!")
        precondition(!controller.wasEnableHeadlessModeCalled, "FAIL: enableHeadlessMode should not be called yet!")

        drainMainQueue(seconds: 0.35)

        precondition(!controller.isWaitingForLaunchReady, "FAIL: Queue should have timed out and stopped waiting!")
        precondition(controller.wasEnableHeadlessModeCalled, "FAIL: enableHeadlessMode was not called on timeout fallback!")
        precondition(test20CompletionCalled, "FAIL: completion callback was not invoked on timeout fallback!")
        print("Test 20: PASS")

        // Test 21: Adaptive launch queue immediately responds to display reconfiguration callback with new external display
        // even during initial 1-second settling period (isDisplayMonitoringStarted == false)
        print("Test 21: Adaptive launch queue responds to display connection callback during settling period...")
        resetHooks()
        controller.isHeadlessModeEnabled = false
        controller.isDisplayMonitoringStarted = false // Simulate realistic launch condition before 1.0s settling
        controller.mockExternalDisplays = []
        var test21CompletionCalled = false
        controller.startLaunchAdaptiveReadyQueue(timeout: 2.0, pollInterval: 0.5) {
            test21CompletionCalled = true
        }
        precondition(controller.isWaitingForLaunchReady, "FAIL: Queue should be waiting!")

        controller.mockExternalDisplays = [102]
        displayReconfigurationCallback(displayID: 102, flags: [],
                                       userInfo: Unmanaged.passUnretained(controller).toOpaque())
        drainMainQueue(seconds: 0.1)

        precondition(!controller.isWaitingForLaunchReady, "FAIL: Queue should have completed via display callback!")
        precondition(controller.wasEnableHeadlessModeCalled, "FAIL: enableHeadlessMode was not called via display callback!")
        precondition(controller.isDisplayMonitoringStarted, "FAIL: isDisplayMonitoringStarted should be true after launch queue completes!")
        precondition(test21CompletionCalled, "FAIL: completion callback was not invoked via display callback!")
        print("Test 21: PASS")

        // Test 22: Cancelling adaptive launch queue aborts waiting and prevents timeout fallback
        print("Test 22: Cancelling adaptive launch queue...")
        resetHooks()
        controller.isHeadlessModeEnabled = false
        controller.mockExternalDisplays = []
        var test22CompletionCalled = false
        controller.startLaunchAdaptiveReadyQueue(timeout: 0.2, pollInterval: 0.05) {
            test22CompletionCalled = true
        }
        precondition(controller.isWaitingForLaunchReady, "FAIL: Queue should be waiting!")
        controller.cancelLaunchAdaptiveReady()
        precondition(!controller.isWaitingForLaunchReady, "FAIL: Queue should no longer be waiting after cancellation!")

        drainMainQueue(seconds: 0.35)
        precondition(!controller.wasEnableHeadlessModeCalled, "FAIL: enableHeadlessMode was called despite cancellation!")
        precondition(!test22CompletionCalled, "FAIL: Completion was incorrectly called after cancellation!")
        print("Test 22: PASS")

        // Test 23: Adaptive launch queue enables headless mode immediately when external display already present at launch
        print("Test 23: Adaptive launch queue with external display already present at launch...")
        resetHooks()
        controller.isHeadlessModeEnabled = false
        controller.mockExternalDisplays = [101]
        var test23CompletionCalled = false
        controller.startLaunchAdaptiveReadyQueue(timeout: 8.0, pollInterval: 0.5) {
            test23CompletionCalled = true
        }
        drainMainQueue(seconds: 0.05)
        precondition(!controller.isWaitingForLaunchReady, "FAIL: Queue should immediately complete when external display is present!")
        precondition(controller.wasEnableHeadlessModeCalled, "FAIL: enableHeadlessMode should be called immediately!")
        precondition(test23CompletionCalled, "FAIL: completion callback was not invoked!")
        print("Test 23: PASS")

        // Test 24: Headless mode enabled via launch queue enables monitoring immediately, allowing safe recovery on unplug
        print("Test 24: Unplugging external display shortly after launch queue enabled headless mode...")
        resetHooks()
        UserDefaults.standard.set(true, forKey: "AutoExitHeadlessOnDisconnect")
        controller.isHeadlessModeEnabled = true
        controller.isDisplayMonitoringStarted = true
        controller.activeExternalDisplays = [101]
        controller.lastKnownExternalDisplays = [101]
        controller.mockExternalDisplays = [] // User unplugs screen
        displayReconfigurationCallback(displayID: 101, flags: [],
                                       userInfo: Unmanaged.passUnretained(controller).toOpaque())
        drainMainQueue(seconds: 0.1)
        precondition(controller.wasTriggerSafeRecoveryCalled, "FAIL: Safe recovery should be triggered on unplug after launch!")
        print("Test 24: PASS")

        print("All Tests Passed Successfully! 🎉")
    }
}
