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
    
    private init() {}
    
    func start() {
        guard runLoopSource == nil else { return }
        
        let context = Unmanaged.passUnretained(self).toOpaque()
        let source = IOPSNotificationCreateRunLoopSource(batteryChangedCallback, context).takeRetainedValue()
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, CFRunLoopMode.defaultMode)
        
        // Initial evaluation
        handlePowerSourceChanged()
    }
    
    func handlePowerSourceChanged() {
        updateBatteryInfo()
        
        let enableProtection = UserDefaults.standard.bool(forKey: "EnableBatteryProtection")
        let threshold = UserDefaults.standard.integer(forKey: "BatteryThreshold")
        let thresholdVal = threshold == 0 ? 20 : threshold // Default 20%
        
        let onBattery = (powerState == kIOPSBatteryPowerValue)
        let lowBattery = (currentCapacity <= thresholdVal)
        
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
        
        if let cycle = dict["CycleCount"] as? Int {
            self.cycleCount = cycle
        }
        
        if let tempRaw = dict["Temperature"] as? Int {
            // Temperature in AppleSmartBattery is in centikelvin. Convert to Celsius.
            // Formula: (tempRaw / 10.0) - 273.15
            self.batteryTemperature = (Double(tempRaw) / 10.0) - 273.15
        }
        
        if let rawMax = dict["AppleRawMaxCapacity"] as? Int, let design = dict["DesignCapacity"] as? Int, design > 0 {
            self.batteryHealth = (Double(rawMax) / Double(design)) * 100.0
        } else if let rawMax = dict["AppleRawMaxCapacity"] as? Int, let rawDesign = dict["AppleRawDesignCapacity"] as? Int, rawDesign > 0 {
            self.batteryHealth = (Double(rawMax) / Double(rawDesign)) * 100.0
        } else if let max = dict["MaxCapacity"] as? Int, let design = dict["DesignCapacity"] as? Int, design > 0 {
            if max <= 100 {
                self.batteryHealth = Double(max)
            } else {
                self.batteryHealth = (Double(max) / Double(design)) * 100.0
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
