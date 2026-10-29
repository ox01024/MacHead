import Foundation
import Combine
import IOKit.ps
import IOKit
import AppKit

private func batteryChangedCallback(context: UnsafeMutableRawPointer?) {
    guard let context = context else { return }
    let manager = Unmanaged<BatteryManager>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async {
        manager.handlePowerSourceChanged()
    }
}

final class BatteryManager: ObservableObject {
    static let shared = BatteryManager()

    private var runLoopSource: CFRunLoopSource?
    private var refreshTimer: Timer?

    // MARK: - 基础电源与充电状态
    @Published private(set) var currentCapacity: Int = 100
    @Published private(set) var isCharging: Bool = false
    @Published private(set) var isCharged: Bool = false
    @Published private(set) var powerState: String = "AC Power"
    @Published private(set) var isBatteryProtectionActive: Bool = false

    var isUPSActive: Bool {
        powerState == kIOPSBatteryPowerValue
    }
    var isExternalConnected: Bool {
        !isUPSActive
    }

    // MARK: - 可调节充电上限与防鼓包保护
    @Published var customLimitEnabled: Bool = UserDefaults.standard.bool(forKey: "CustomChargeLimitEnabled") {
        didSet {
            UserDefaults.standard.set(customLimitEnabled, forKey: "CustomChargeLimitEnabled")
            checkChargeLimitPolicy()
            evaluateCustomChargeLimit()
        }
    }

    @Published var customLimitThreshold: Int = (UserDefaults.standard.integer(forKey: "CustomChargeLimitThreshold") == 0 ? 80 : UserDefaults.standard.integer(forKey: "CustomChargeLimitThreshold")) {
        didSet {
            UserDefaults.standard.set(customLimitThreshold, forKey: "CustomChargeLimitThreshold")
            checkChargeLimitPolicy()
            evaluateCustomChargeLimit()
        }
    }

    @Published private(set) var isSMCControlActive: Bool = false
    @Published private(set) var isChargeLimitEnabled: Bool = false
    @Published private(set) var chargeLimitPercent: Int = 80
    @Published private(set) var chargeLimitSource: String = L("未开启", "Disabled")

    var isSupportedNativeLimit: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    @Published private(set) var isPrivilegedHelperConfigured: Bool = FileManager.default.fileExists(atPath: "/etc/sudoers.d/machead")

    // MARK: - 电池健康与容量指标
    @Published private(set) var batteryHealth: Double = 100.0
    @Published private(set) var cycleCount: Int = 0
    @Published private(set) var batteryTemperature: Double = 0.0
    @Published private(set) var rawCurrentCapacity: Int = 0 // 当前电量 (mAh)
    @Published private(set) var rawMaxCapacity: Int = 0     // 实际可用最大容量 (mAh)
    @Published private(set) var designCapacity: Int = 0     // 原厂设计容量 (mAh)

    // MARK: - 实时电气指标
    @Published private(set) var voltage: Double = 0.0       // 实时电压 (V)
    @Published private(set) var amperage: Int = 0           // 实时电流 (mA，充电为正，放电为负)
    @Published private(set) var powerWatts: Double = 0.0    // 实时充放电功率 (W)
    @Published private(set) var adapterWatts: Int = 0       // 外接适配器额定功率 (W)
    @Published private(set) var adapterName: String = ""    // 外接适配器描述

    // MARK: - 智能 UPS 模式与续航预测
    @Published private(set) var timeRemainingMinutes: Int = -1
    @Published private(set) var timeRemainingFormatted: String = ""

    private var lastPowerState: String?
    private var wasLowBattery: Bool = false
    private var languageObserver: NSObjectProtocol?

    private init() {}

    deinit {
        stop()
    }

    func start() {
        guard runLoopSource == nil else { return }

        let context = Unmanaged.passUnretained(self).toOpaque()
        let source = IOPSNotificationCreateRunLoopSource(batteryChangedCallback, context).takeRetainedValue()
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, CFRunLoopMode.defaultMode)

        // Initial evaluation (don't alert on cold boot)
        updateBatteryInfo()
        checkChargeLimitPolicy()
        evaluateCustomChargeLimit()
        self.lastPowerState = powerState
        let threshold = UserDefaults.standard.integer(forKey: "BatteryThreshold")
        let thresholdVal = threshold == 0 ? 20 : threshold
        self.wasLowBattery = (currentCapacity <= thresholdVal)

        // Lightweight background timer to update dynamic electrical metrics only (no heavy disk I/O)
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.updateBatteryInfo()
            self?.evaluateCustomChargeLimit()
        }

        if languageObserver == nil {
            languageObserver = NotificationCenter.default.addObserver(
                forName: .appLanguageChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.updateBatteryInfo()
                self?.checkChargeLimitPolicy()
            }
        }
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, CFRunLoopMode.defaultMode)
            self.runLoopSource = nil
        }
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let observer = languageObserver {
            NotificationCenter.default.removeObserver(observer)
            languageObserver = nil
        }
    }

    func handlePowerSourceChanged() {
        updateBatteryInfo()
        checkChargeLimitPolicy()
        evaluateCustomChargeLimit()

        let enableProtection = UserDefaults.standard.bool(forKey: "EnableBatteryProtection")
        let threshold = UserDefaults.standard.integer(forKey: "BatteryThreshold")
        let thresholdVal = threshold == 0 ? 20 : threshold // Default 20%

        let onBattery = (powerState == kIOPSBatteryPowerValue)
        let lowBattery = (currentCapacity <= thresholdVal)

        // Trigger alerts on power state change
        if let lastState = lastPowerState, lastState != powerState {
            if onBattery {
                var estText = ""
                if timeRemainingMinutes > 0 {
                    estText = L(
                        "，预计还可支撑运行约 \(timeRemainingFormatted)（实时放电功率 \(String(format: "%.1f", powerWatts))W）",
                        ", estimated runtime ~\(timeRemainingFormatted) (discharge power \(String(format: "%.1f", powerWatts))W)"
                    )
                }
                NotificationService.shared.sendAlert(
                    type: .powerDisconnect,
                    title: L("外部电源已断开 🔌 (UPS 模式)", "AC Power Disconnected 🔌 (UPS Mode)"),
                    body: L(
                        "Mac 已切换至电池供电。当前剩余电量：\(currentCapacity)%\(estText)，请及时检查电源连接情况。",
                        "Mac switched to battery power. Remaining charge: \(currentCapacity)%\(estText). Please check your power adapter."
                    )
                )
            } else {
                let adapterInfo = adapterWatts > 0
                    ? L("（已连接 \(adapterWatts)W 适配器）", " (\(adapterWatts)W adapter connected)")
                    : ""
                NotificationService.shared.sendAlert(
                    type: .powerDisconnect,
                    title: L("外部电源已恢复 🔌", "AC Power Restored 🔌"),
                    body: L(
                        "Mac 已恢复交流电供电\(adapterInfo)，当前剩余电量：\(currentCapacity)%。",
                        "Mac is back on AC power\(adapterInfo). Current battery charge: \(currentCapacity)%."
                    )
                )
            }
        }
        lastPowerState = powerState

        if lowBattery && !wasLowBattery && onBattery && enableProtection {
            NotificationService.shared.sendAlert(
                type: .lowBattery,
                title: L("系统低电量警告 🔋", "Low Battery Alert 🔋"),
                body: L(
                    "Mac 剩余电量已降至 \(currentCapacity)%，低于电池保护阈值（\(thresholdVal)%）。MacHead 已自动释放休眠阻止，Mac 将进入自动休眠状态以保护电池寿命。",
                    "Battery dropped to \(currentCapacity)%, below the protection threshold (\(thresholdVal)%). MacHead released sleep prevention so your Mac can sleep safely."
                )
            )
        }
        wasLowBattery = lowBattery

        let shouldActive = enableProtection && onBattery && lowBattery

        if shouldActive != isBatteryProtectionActive {
            isBatteryProtectionActive = shouldActive
            NSLog("MacHead: 电池保护状态发生变化 -> 激活: %@", String(shouldActive))

            if shouldActive {
                TelemetryManager.shared.track(event: "app_event", extraInfo: ["action": "battery_protection_fired"])
                NSLog("MacHead: 低电量保护触发！电量为 %d%% (低于阈值 %d%%) 且处于电池供电下。释放休眠阻碍。", currentCapacity, thresholdVal)
            } else {
                NSLog("MacHead: 电池保护解除 (电量: %d%%, 直供: %@)。", currentCapacity, String(!onBattery))
            }

            // Notify controller to update assertion
            DispatchQueue.main.async {
                HeadlessModeController.shared.evaluatePowerAssertion()
                NotificationCenter.default.post(name: .headlessModeStateChanged, object: nil)
            }
        }
    }

    func updateBatteryRegistryInfo() {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard entry != 0 else { return }
        defer { IOObjectRelease(entry) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let dict = props?.takeRetainedValue() as? [String: Any] else {
            return
        }

        // 循环次数
        if let cycleNum = dict["CycleCount"] as? NSNumber {
            self.cycleCount = cycleNum.intValue
        } else if let cycle = dict["CycleCount"] as? Int {
            self.cycleCount = cycle
        }

        // 温度 (0.1K 转换为 °C)
        if let tempNum = dict["Temperature"] as? NSNumber {
            let tempRaw = tempNum.doubleValue
            self.batteryTemperature = (tempRaw / 10.0) - 273.15
        } else if let tempRaw = dict["Temperature"] as? Int {
            self.batteryTemperature = (Double(tempRaw) / 10.0) - 273.15
        }

        // 电压 (mV -> V)
        let voltageMV = (dict["Voltage"] as? NSNumber)?.intValue
            ?? (dict["AppleRawBatteryVoltage"] as? NSNumber)?.intValue
            ?? 0
        self.voltage = Double(voltageMV) / 1000.0

        // 电流 (mA，充为正，放为负)
        let ampMA = (dict["InstantAmperage"] as? NSNumber)?.intValue
            ?? (dict["Amperage"] as? NSNumber)?.intValue
            ?? 0
        self.amperage = ampMA

        // 实时功率计算 (W)
        if voltageMV > 0 && ampMA != 0 {
            self.powerWatts = abs(Double(ampMA) * Double(voltageMV)) / 1_000_000.0
        } else {
            self.powerWatts = 0.0
        }

        // 容量参数 (mAh)
        let rawCur = (dict["AppleRawCurrentCapacity"] as? NSNumber)?.intValue
            ?? (dict["CurrentCapacity"] as? NSNumber)?.intValue
            ?? 0
        let rawMax = (dict["AppleRawMaxCapacity"] as? NSNumber)?.intValue
            ?? (dict["MaxCapacity"] as? NSNumber)?.intValue
            ?? 0
        let designCap = (dict["DesignCapacity"] as? NSNumber)?.intValue
            ?? (dict["AppleRawDesignCapacity"] as? NSNumber)?.intValue
            ?? 0

        self.rawCurrentCapacity = rawCur
        self.rawMaxCapacity = rawMax
        self.designCapacity = designCap

        // 真实健康度 (SOH) 计算
        if rawMax > 0 && designCap > 0 {
            self.batteryHealth = (Double(rawMax) / Double(designCap)) * 100.0
        } else if let maxNum = dict["MaxCapacity"] as? NSNumber, maxNum.doubleValue <= 100 {
            self.batteryHealth = maxNum.doubleValue
        }

        // 适配器详情读取 (备选路径)
        if self.adapterWatts == 0,
           let details = (dict["AdapterDetails"] as? [String: Any]) ?? (dict["AppleRawAdapterDetails"] as? [[String: Any]])?.first {
            if let w = details["Watts"] as? Int {
                self.adapterWatts = w
            }
            if let desc = details["Description"] as? String {
                self.adapterName = desc
            }
        }
    }

    private func updateBatteryInfo() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return
        }

        var foundBattery = false
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }

            let type = info[kIOPSTypeKey] as? String ?? ""
            if type == kIOPSInternalBatteryType {
                foundBattery = true
                self.powerState = info[kIOPSPowerSourceStateKey] as? String ?? "AC Power"
                self.currentCapacity = info[kIOPSCurrentCapacityKey] as? Int ?? 100
                self.isCharging = info[kIOPSIsChargingKey] as? Bool ?? false
                self.isCharged = info[kIOPSIsChargedKey] as? Bool ?? false

                // 评估电源与 UPS 状态
                let onBattery = (self.powerState == kIOPSBatteryPowerValue)

                // 剩余时间计算 (分钟)
                if onBattery {
                    var estMinutes = -1
                    if let sysTimeToEmpty = info[kIOPSTimeToEmptyKey] as? Int, sysTimeToEmpty > 0 && sysTimeToEmpty < 60000 {
                        estMinutes = sysTimeToEmpty
                    } else if self.amperage < 0 && self.rawCurrentCapacity > 0 {
                        // 动态根据当前放电电流测算
                        let dyn = Int(Double(self.rawCurrentCapacity) / Double(abs(self.amperage)) * 60.0)
                        if dyn > 0 && dyn < 2880 {
                            estMinutes = dyn
                        }
                    }
                    self.timeRemainingMinutes = estMinutes

                    if estMinutes > 0 {
                        let h = estMinutes / 60
                        let m = estMinutes % 60
                        self.timeRemainingFormatted = h > 0
                            ? L("\(h)小时\(m)分钟", "\(h)h \(m)m")
                            : L("\(m)分钟", "\(m)m")
                    } else {
                        self.timeRemainingFormatted = L("计算中...", "Calculating...")
                    }
                } else {
                    // 外接电源状态
                    if self.isCharging {
                        if let fullMinutes = info[kIOPSTimeToFullChargeKey] as? Int, fullMinutes > 0 && fullMinutes < 60000 {
                            self.timeRemainingMinutes = fullMinutes
                            let h = fullMinutes / 60
                            let m = fullMinutes % 60
                            self.timeRemainingFormatted = h > 0
                                ? L("\(h)小时\(m)分充满", "\(h)h \(m)m to full")
                                : L("\(m)分钟充满", "\(m)m to full")
                        } else {
                            self.timeRemainingMinutes = -1
                            self.timeRemainingFormatted = L("正在充电...", "Charging...")
                        }
                    } else {
                        self.timeRemainingMinutes = 0
                        if self.isCharged || self.currentCapacity >= 99 {
                            self.timeRemainingFormatted = L("已充满 (交流电直供)", "Fully Charged (AC Direct)")
                        } else {
                            self.timeRemainingFormatted = L("外接电源直供", "AC Direct Power")
                        }
                    }
                }
                break
            }
        }

        if !foundBattery {
            self.powerState = "AC Power"
        }

        // 读取外接适配器官方详情
        if let adapterDetails = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
            if let w = adapterDetails[kIOPSPowerAdapterWattsKey] as? Int {
                self.adapterWatts = w
            }
            if let name = adapterDetails["Name"] as? String {
                self.adapterName = name
            } else if let desc = adapterDetails["Description"] as? String {
                self.adapterName = desc
            }
        } else if self.isUPSActive {
            self.adapterWatts = 0
            self.adapterName = ""
        }

        updateBatteryRegistryInfo()
    }

    // MARK: - 可调节充电上限控制 (Sailing Mode 回充死区机制)
    func evaluateCustomChargeLimit() {
        if customLimitEnabled {
            guard isExternalConnected else {
                if isSMCControlActive {
                    _ = executeChargeInhibit(false)
                    isSMCControlActive = false
                }
                return
            }

            let target = customLimitThreshold
            let resumeThreshold = max(20, target - 5) // 5% 回充死区，防微小波动频繁微充

            if currentCapacity >= target && !isSMCControlActive {
                let success = executeChargeInhibit(true)
                if success {
                    isSMCControlActive = true
                    NSLog("MacHead: 自主限充已触发停充 -> 当前电量 %d%% (>= 设定阈值 %d%%)", currentCapacity, target)
                }
            } else if currentCapacity <= resumeThreshold && isSMCControlActive {
                let success = executeChargeInhibit(false)
                if success {
                    isSMCControlActive = false
                    NSLog("MacHead: 自主限充已恢复补电 -> 当前电量 %d%% (<= 回充电量 %d%%)", currentCapacity, resumeThreshold)
                }
            }
        } else {
            if isSMCControlActive {
                _ = executeChargeInhibit(false)
                isSMCControlActive = false
            }
        }
    }

    /// 执行底层 SMC 停充/启充指令 (绝对严禁在后台触发任何密码弹窗)
    @discardableResult
    func executeChargeInhibit(_ inhibit: Bool) -> Bool {
        // 1. 优先尝试直接写 SMC (如已有权限)
        if SMCManager.shared.setChargingInhibited(inhibit) {
            return true
        }

        // 2. 若未配置免密特权，直接跳过，避免进程拉起开销与阻塞
        guard isPrivilegedHelperConfigured else { return false }

        let target = Bundle.main.executablePath ?? CLIToolInstaller.targetPath
        guard FileManager.default.fileExists(atPath: target) else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", target, "--inhibit-charging", inhibit ? "1" : "0"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// 更新免密特权配置状态
    func updatePrivilegeStatus() {
        self.isPrivilegedHelperConfigured = FileManager.default.fileExists(atPath: "/etc/sudoers.d/machead")
    }

    /// 用户在界面显式点击授权 (仅在用户主动点击时弹窗一次，配置免密通道)
    @discardableResult
    func requestPrivilegedAccess() -> Bool {
        let appPath = Bundle.main.executablePath ?? CLIToolInstaller.targetPath
        let rule = "%admin ALL=(ALL) NOPASSWD: \(appPath) --inhibit-charging *, \(appPath) --set-bclm *\n"
        let tmpFile = "/tmp/machead_sudoers"
        do {
            try rule.write(toFile: tmpFile, atomically: true, encoding: .utf8)
        } catch {
            return false
        }

        let cmd = "mkdir -p /etc/sudoers.d && cp '\(tmpFile)' /etc/sudoers.d/machead && chmod 0440 /etc/sudoers.d/machead && rm -f '\(tmpFile)'"
        let ok = CLIToolInstaller.runElevated(cmd)
        try? FileManager.default.removeItem(atPath: tmpFile)
        if ok {
            updatePrivilegeStatus()
            checkChargeLimitPolicy()
            evaluateCustomChargeLimit()
        }
        return ok
    }

    /// 撤销免密特权配置
    @discardableResult
    func removePrivilegedAccess() -> Bool {
        guard isPrivilegedHelperConfigured else { return true }
        let ok = CLIToolInstaller.runElevated("rm -f /etc/sudoers.d/machead")
        if ok {
            updatePrivilegeStatus()
            checkChargeLimitPolicy()
            evaluateCustomChargeLimit()
        }
        return ok
    }

    // MARK: - 充电上限状态检测与系统对接
    func openSystemBatterySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func checkChargeLimitPolicy() {
        // 1. 如果开启了 MacHead 自主可调节限充
        if customLimitEnabled {
            self.isChargeLimitEnabled = true
            self.chargeLimitPercent = customLimitThreshold
            if isSMCControlActive {
                self.chargeLimitSource = L("MacHead 底层守护 (已停充)", "MacHead SMC Guard (Paused)")
            } else {
                self.chargeLimitSource = L("MacHead 自主限充 (Sailing Mode)", "MacHead Charge Limit (Sailing Mode)")
            }
            return
        }

        // 3. 解析系统级充电控制策略文件 (针对 macOS 15+)
        let path = "/Library/Preferences/com.apple.powerd.charging.plist"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let policiesData = plist["policies"] as? Data,
           let rawPlist = try? PropertyListSerialization.propertyList(from: policiesData, options: [], format: nil) as? [String: Any],
           let objects = rawPlist["$objects"] as? [Any] {

            for item in objects {
                guard let dict = item as? [String: Any] else { continue }
                if let limit = dict["soclimit"] as? Int {
                    let terminated = (dict["terminated"] as? Bool) ?? ((dict["terminated"] as? Int) == 1)
                    let noChargeToFull = (dict["noChargeToFull"] as? Bool) ?? ((dict["noChargeToFull"] as? Int) == 1)
                    if !terminated && (noChargeToFull || limit < 100) {
                        self.isChargeLimitEnabled = true
                        self.chargeLimitPercent = limit
                        self.chargeLimitSource = L("macOS 系统原生限充", "macOS Native Charge Limit")
                        return
                    }
                }
            }
        }

        // 4. 检测外部开源 SMC 控制器 (如用户安装并配置了 batt)
        let fileManager = FileManager.default
        let battPaths = ["/opt/homebrew/bin/batt", "/usr/local/bin/batt"]
        for bPath in battPaths {
            if fileManager.fileExists(atPath: bPath) {
                self.chargeLimitSource = L("第三方控制器 (batt)", "3rd-Party Controller (batt)")
                self.isChargeLimitEnabled = true
                return
            }
        }

        // 5. 回退状态 (特别区分老系统)
        self.isChargeLimitEnabled = false
        self.chargeLimitPercent = 80
        if isSupportedNativeLimit {
            self.chargeLimitSource = L("未激活系统限充", "System Limit Inactive")
        } else {
            self.chargeLimitSource = L("老系统无原生限充 (建议开启自主守护)", "No Native Limit (Enable MacHead Guard)")
        }
    }
}
