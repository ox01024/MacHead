import Foundation
import IOKit

public final class SMCManager: ObservableObject {
    public static let shared = SMCManager()
    
    @Published public private(set) var currentTemperature: Double = 0.0
    @Published public private(set) var fanSpeed: Int = 0
    @Published public private(set) var isFanless: Bool = false
    
    private var connection: io_connect_t = 0
    private var timer: Timer?
    
    // SMC parameters
    private static let KERNEL_INDEX_SMC: UInt32 = 2
    private static let kSMCReadKey: UInt8 = 5
    private static let kSMCGetKeyInfo: UInt8 = 9
    
    // Structs for AppleSMC communication
    private struct SMCVersion {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }
    
    private struct SMCPLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }
    
    private struct SMCKeyInfoData {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }
    
    private struct SMCVal {
        var key: UInt32 = 0
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    }
    
    private struct SMCParamStruct {
        var key: UInt32 = 0
        var plimitData = SMCPLimitData()
        var keyInfo = SMCKeyInfoData()
        var val = SMCVal()
        var select: UInt8 = 0
        var result: UInt8 = 0
    }
    
    private init() {
        openSMC()
        detectFanPresence()
        startMonitoring()
    }
    
    deinit {
        stopMonitoring()
        closeSMC()
    }
    
    private func openSMC() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        if service == 0 {
            print("SMCManager: AppleSMC service not found")
            return
        }
        defer { IOObjectRelease(service) }
        
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        if result != kIOReturnSuccess {
            print("SMCManager: Failed to open connection to AppleSMC (error \(result))")
            connection = 0
        }
    }
    
    private func closeSMC() {
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
    }
    
    private func getModelIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }

    private func detectFanPresence() {
        let model = getModelIdentifier()
        let isKnownFanless = model.contains("MacBookAir") || model.hasPrefix("MacBook8,") || model.hasPrefix("MacBook9,") || model.hasPrefix("MacBook10,")
        
        if isKnownFanless {
            self.isFanless = true
        } else {
            // 如果能从 SMC 读到风扇数量，以实际为准；否则默认为有风扇（MacBook Pro/Studio 等皆有风扇）
            if let fNum = readUInt8Value(key: "FNum") {
                self.isFanless = (fNum == 0)
            } else {
                self.isFanless = false
            }
        }
    }
    
    private func getCPUTemperatureFromHID() -> Double {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else {
            return 0.0
        }
        
        let matching: [String: Any] = [
            "PrimaryUsagePage": 0xff00,
            "PrimaryUsage": 0x05
        ]
        
        _ = IOHIDEventSystemClientSetMatching(client, matching as CFDictionary)
        
        guard let services = IOHIDEventSystemClientCopyServices(client) as? [AnyObject] else {
            return 0.0
        }
        
        var cpuTemps: [Double] = []
        
        for service in services {
            let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String ?? ""
            let nameLower = name.lowercased()
            
            if nameLower.contains("tdie") || nameLower.contains("cpu") || nameLower.contains("pacc") || nameLower.contains("eacc") {
                if let event = IOHIDServiceClientCopyEvent(service, 15, 0, 0) {
                    let temp = IOHIDEventGetFloatValue(event, 983040)
                    if temp > 0.0 && temp < 150.0 {
                        cpuTemps.append(temp)
                    }
                }
            }
        }
        
        if cpuTemps.isEmpty {
            return 0.0
        }
        
        return cpuTemps.reduce(0, +) / Double(cpuTemps.count)
    }
    
    public func startMonitoring() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.updateMetrics()
        }
        updateMetrics()
    }
    
    public func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }
    
    private func updateMetrics() {
        // 1. 读取 CPU 温度 (优先尝试 SMC，如果失败或为 0 则通过 IOHIDEventSystemClient 获取，最终回退到电池温度)
        var tempRead: Double = 0.0
        
        if connection != 0 {
            let tempKeys = ["Tp09", "Tp0T", "Tp01", "TC0D", "TC0P", "TC0F", "TG0P"]
            for key in tempKeys {
                if let temp = readTemperature(key: key), temp > 15.0 && temp < 120.0 {
                    tempRead = temp
                    break
                }
            }
        }
        
        if tempRead == 0.0 {
            tempRead = getCPUTemperatureFromHID()
        }
        
        if tempRead == 0.0 {
            tempRead = BatteryManager.shared.batteryTemperature
        }
        
        if tempRead > 0 {
            DispatchQueue.main.async {
                self.currentTemperature = tempRead
            }
        }
        
        // 2. 读取风扇转速
        if !isFanless {
            if connection != 0, let speed = readFanSpeed(key: "F0Ac") {
                DispatchQueue.main.async {
                    self.fanSpeed = speed
                }
            } else {
                // 如果是物理有风扇设备但无法读取具体 RPM（如 Apple Silicon 权限限制），返回 -1 标识“系统控制中”
                DispatchQueue.main.async {
                    self.fanSpeed = -1
                }
            }
        } else {
            DispatchQueue.main.async {
                self.fanSpeed = 0
            }
        }
    }
    
    // MARK: - SMC Helper Operations
    
    private func readTemperature(key: String) -> Double? {
        guard let info = getKeyInfo(key: String(key.prefix(4))) else { return nil }
        guard let val = readKey(key: key, dataSize: info.dataSize) else { return nil }
        
        // Check data type
        let dataTypeStr = fourCharCodeToString(info.dataType)
        
        // Type "sp78": Sign (1 bit), Integer (7 bits), Fraction (8 bits) -> value / 256.0
        if dataTypeStr == "sp78" {
            let u16 = UInt16(val[0]) << 8 | UInt16(val[1])
            let s16 = Int16(bitPattern: u16)
            return Double(s16) / 256.0
        }
        
        // Type "flt ": standard 32-bit float
        if dataTypeStr == "flt " && val.count >= 4 {
            var fval: Float = 0.0
            memcpy(&fval, val, 4)
            return Double(fval)
        }
        
        // Type "ui8 ": 8-bit unsigned int
        if dataTypeStr == "ui8" || dataTypeStr == "ui8 " {
            return Double(val[0])
        }
        
        return nil
    }
    
    private func readFanSpeed(key: String) -> Int? {
        guard let info = getKeyInfo(key: key) else { return nil }
        guard let val = readKey(key: key, dataSize: info.dataSize) else { return nil }
        
        let dataTypeStr = fourCharCodeToString(info.dataType)
        
        // Type "fpe2": 14 bits integer, 2 bits fraction -> value / 4.0
        if dataTypeStr == "fpe2" {
            let u16 = UInt16(val[0]) << 8 | UInt16(val[1])
            return Int(u16 >> 2)
        }
        
        // Type "flt ": standard float
        if dataTypeStr == "flt " && val.count >= 4 {
            var fval: Float = 0.0
            memcpy(&fval, val, 4)
            return Int(fval)
        }
        
        return nil
    }
    
    private func readUInt8Value(key: String) -> UInt8? {
        guard let val = readKey(key: key, dataSize: 1) else { return nil }
        return val[0]
    }
    
    private func getKeyInfo(key: String) -> SMCKeyInfoData? {
        var inputStruct = SMCParamStruct()
        var outputStruct = SMCParamStruct()
        
        inputStruct.key = stringToFourCharCode(key)
        inputStruct.select = SMCManager.kSMCGetKeyInfo
        
        let size = MemoryLayout<SMCParamStruct>.size
        var outputSize = size
        
        let result = IOConnectCallStructMethod(
            connection,
            SMCManager.KERNEL_INDEX_SMC,
            &inputStruct,
            size,
            &outputStruct,
            &outputSize
        )
        
        if result == kIOReturnSuccess && outputStruct.result == 0 {
            return outputStruct.keyInfo
        }
        return nil
    }
    
    private func readKey(key: String, dataSize: UInt32) -> [UInt8]? {
        var inputStruct = SMCParamStruct()
        var outputStruct = SMCParamStruct()
        
        inputStruct.key = stringToFourCharCode(key)
        inputStruct.val.dataSize = dataSize
        inputStruct.select = SMCManager.kSMCReadKey
        
        let size = MemoryLayout<SMCParamStruct>.size
        var outputSize = size
        
        let result = IOConnectCallStructMethod(
            connection,
            SMCManager.KERNEL_INDEX_SMC,
            &inputStruct,
            size,
            &outputStruct,
            &outputSize
        )
        
        if result == kIOReturnSuccess && outputStruct.result == 0 {
            // Extract byte array
            let rawBytes = outputStruct.val.bytes
            var bytesArray = [UInt8](repeating: 0, count: Int(dataSize))
            
            // Safe binding of the tuple bytes
            let mirror = Mirror(reflecting: rawBytes)
            var index = 0
            for child in mirror.children {
                if index >= Int(dataSize) { break }
                if let val = child.value as? UInt8 {
                    bytesArray[index] = val
                    index += 1
                }
            }
            return bytesArray
        }
        return nil
    }
    
    // MARK: - Conversions
    
    private func stringToFourCharCode(_ str: String) -> UInt32 {
        var result: UInt32 = 0
        let bytes = Array(str.utf8)
        for i in 0..<min(4, bytes.count) {
            result = (result << 8) + UInt32(bytes[i])
        }
        // Pad with spaces if shorter than 4 chars
        if bytes.count < 4 {
            for _ in bytes.count..<4 {
                result = (result << 8) + 32
            }
        }
        return result
    }
    
    private func fourCharCodeToString(_ code: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff)
        ]
        
        // Filter out non-printable ASCII
        let filteredBytes = bytes.map { byte -> UInt8 in
            if byte >= 32 && byte <= 126 {
                return byte
            }
            return 32 // space
        }
        
        return String(bytes: filteredBytes, encoding: .ascii) ?? "    "
    }
}
