import Foundation
import IOKit.ps
import IOKit

private func batteryChangedCallback(context: UnsafeMutableRawPointer?) {
    guard let context = context else { return }
    let manager = Unmanaged<BatteryManager>.fromOpaque(context).takeUnretainedValue()
    manager.handlePowerSourceChanged()
}

final class BatteryManager {
    static let shared = BatteryManager()
    
    private var runLoopSource: CFRunLoopSource?
    
    private(set) var currentCapacity: Int = 100
    private(set) var isCharging: Bool = false
    private(set) var powerState: String = "AC Power"
    private(set) var isBatteryProtectionActive: Bool = false
    private(set) var batteryHealth: Double = 100.0
    private(set) var cycleCount: Int = 0
    private(set) var batteryTemperature: Double = 0.0
    
    private var lastPowerState: String?
    private var wasLowBattery: Bool = false
    
    private init() {}
    
    func start() {
        guard runLoopSource == nil else { return }
        
        let context = Unmanaged.passUnretained(self).toOpaque()
        let source = IOPSNotificationCreateRunLoopSource(batteryChangedCallback, context).takeRetainedValue()
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, CFRunLoopMode.defaultMode)
        
        // Initial evaluation (don't alert on cold boot)
        updateBatteryInfo()
        self.lastPowerState = powerState
        self.wasLowBattery = (currentCapacity <= (UserDefaults.standard.integer(forKey: "BatteryThreshold") == 0 ? 20 : UserDefaults.standard.integer(forKey: "BatteryThreshold")))
    }
    
    func handlePowerSourceChanged() {
        updateBatteryInfo()
        
        let enableProtection = UserDefaults.standard.bool(forKey: "EnableBatteryProtection")
        let threshold = UserDefaults.standard.integer(forKey: "BatteryThreshold")
        let thresholdVal = threshold == 0 ? 20 : threshold // Default 20%
        
        let onBattery = (powerState == kIOPSBatteryPowerValue)
        let lowBattery = (currentCapacity <= thresholdVal)
        
        // Trigger alerts on state changes
        if let lastState = lastPowerState, lastState != powerState {
            if onBattery {
                NotificationService.shared.sendAlert(
                    type: .powerDisconnect,
                    title: "外部电源已断开 🔌",
                    body: "Mac 已切换至电池供电。当前剩余电量：\(currentCapacity)%，请及时检查电源连接情况。"
                )
            } else {
                NotificationService.shared.sendAlert(
                    type: .powerDisconnect,
                    title: "外部电源已恢复 🔌",
                    body: "Mac 已恢复交流电供电，当前正在充电，剩余电量：\(currentCapacity)%。"
                )
            }
        }
        lastPowerState = powerState
        
        if lowBattery && !wasLowBattery && onBattery && enableProtection {
            NotificationService.shared.sendAlert(
                type: .lowBattery,
                title: "系统低电量警告 🔋",
                body: "Mac 剩余电量已降至 \(currentCapacity)%，低于电池保护阈值（\(thresholdVal)%）。MacHead 已自动释放休眠阻止，Mac 将进入自动休眠状态以保护电池寿命。"
            )
        }
        wasLowBattery = lowBattery
        
        let shouldActive = enableProtection && onBattery && lowBattery
        
        if shouldActive != isBatteryProtectionActive {
            isBatteryProtectionActive = shouldActive
            NSLog("MacHead: 电池保护状态发生变化 -> 激活: %@", String(shouldActive))
            
            if shouldActive {
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
        
        if let cycleNum = dict["CycleCount"] as? NSNumber {
            self.cycleCount = cycleNum.intValue
        } else if let cycle = dict["CycleCount"] as? Int {
            self.cycleCount = cycle
        }
        
        if let tempNum = dict["Temperature"] as? NSNumber {
            let tempRaw = tempNum.doubleValue
            self.batteryTemperature = (tempRaw / 10.0) - 273.15
        } else if let tempRaw = dict["Temperature"] as? Int {
            self.batteryTemperature = (Double(tempRaw) / 10.0) - 273.15
        }
        
        let rawMaxNum = dict["AppleRawMaxCapacity"] as? NSNumber ?? (dict["AppleRawMaxCapacity"] as? Int as NSNumber?)
        let designNum = dict["DesignCapacity"] as? NSNumber ?? (dict["DesignCapacity"] as? Int as NSNumber?)
        let rawDesignNum = dict["AppleRawDesignCapacity"] as? NSNumber ?? (dict["AppleRawDesignCapacity"] as? Int as NSNumber?)
        let maxNum = dict["MaxCapacity"] as? NSNumber ?? (dict["MaxCapacity"] as? Int as NSNumber?)
        
        if let rawMax = rawMaxNum?.doubleValue, let design = designNum?.doubleValue, design > 0 {
            self.batteryHealth = (rawMax / design) * 100.0
        } else if let rawMax = rawMaxNum?.doubleValue, let rawDesign = rawDesignNum?.doubleValue, rawDesign > 0 {
            self.batteryHealth = (rawMax / rawDesign) * 100.0
        } else if let max = maxNum?.doubleValue, let design = designNum?.doubleValue, design > 0 {
            if max <= 100 {
                self.batteryHealth = max
            } else {
                self.batteryHealth = (max / design) * 100.0
            }
        }
    }
    
    private func updateBatteryInfo() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return
        }
        
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            
            let type = info[kIOPSTypeKey] as? String ?? ""
            if type == kIOPSInternalBatteryType {
                self.powerState = info[kIOPSPowerSourceStateKey] as? String ?? "AC Power"
                self.currentCapacity = info[kIOPSCurrentCapacityKey] as? Int ?? 100
                self.isCharging = info[kIOPSIsChargingKey] as? Bool ?? false
                break
            }
        }
        
        updateBatteryRegistryInfo()
    }
}
