import Foundation
import CoreGraphics
import ApplicationServices

typealias CGSConfigureDisplayEnabledFunc = @convention(c) (
    OpaquePointer?, // CGDisplayConfigRef
    CGDirectDisplayID,
    Bool
) -> Int32

final class DisplayManager {
    static let shared = DisplayManager()
    
    private let setMode: CGSConfigureDisplayEnabledFunc?
    
    private init() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY
        ) else {
            setMode = nil
            NSLog("MacHead: 无法加载 SkyLight 框架")
            return
        }
        
        let sym = dlsym(handle, "CGSConfigureDisplayEnabled")
        setMode = sym.map { unsafeBitCast($0, to: CGSConfigureDisplayEnabledFunc.self) }
        if setMode == nil {
            NSLog("MacHead: 无法在 SkyLight 中找到 CGSConfigureDisplayEnabled 符号")
        }
    }
    
    /// 获取当前或缓存的内置显示器 ID
    var builtInDisplayID: CGDirectDisplayID? {
        var count: UInt32 = 0
        if CGGetOnlineDisplayList(0, nil, &count) == .success {
            var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
            if CGGetOnlineDisplayList(count, &displays, &count) == .success {
                if let id = displays.first(where: { CGDisplayIsBuiltin($0) != 0 }) {
                    // Cache the found ID
                    UserDefaults.standard.set(id, forKey: "BuiltInDisplayID")
                    return id
                }
            }
        }
        
        // Fallback to cached ID if display is already disabled and thus offline
        let cached = UserDefaults.standard.integer(forKey: "BuiltInDisplayID")
        if cached != 0 {
            return CGDirectDisplayID(cached)
        }
        
        return nil
    }
    
    /// 断开内置显示器
    func disconnectBuiltIn() {
        guard let id = builtInDisplayID else {
            NSLog("MacHead: 未找到内置显示屏以进行断开操作")
            return
        }
        
        guard let setMode = setMode else {
            NSLog("MacHead: CGSConfigureDisplayEnabled API 不可用")
            return
        }
        
        NSLog("MacHead: 正在断开内置显示屏 ID: %d", id)
        var configRef: CGDisplayConfigRef? = nil
        let beginErr = CGBeginDisplayConfiguration(&configRef)
        if beginErr == .success {
            let configureErr = setMode(configRef, id, false)
            let completeErr = CGCompleteDisplayConfiguration(configRef, .permanently)
            NSLog("MacHead: 断开内置屏结果 - 设定: %d, 提交: %d", configureErr, completeErr.rawValue)
        } else {
            NSLog("MacHead: CGBeginDisplayConfiguration 失败: %d", beginErr.rawValue)
        }
    }
    
    /// 重新连接内置显示器
    func reconnectBuiltIn() {
        guard let id = builtInDisplayID else {
            NSLog("MacHead: 未找到内置显示屏以进行恢复操作")
            return
        }
        
        guard let setMode = setMode else {
            NSLog("MacHead: CGSConfigureDisplayEnabled API 不可用")
            return
        }
        
        NSLog("MacHead: 正在重新连接内置显示屏 ID: %d", id)
        var configRef: CGDisplayConfigRef? = nil
        let beginErr = CGBeginDisplayConfiguration(&configRef)
        if beginErr == .success {
            let configureErr = setMode(configRef, id, true)
            let completeErr = CGCompleteDisplayConfiguration(configRef, .permanently)
            NSLog("MacHead: 恢复内置屏结果 - 设定: %d, 提交: %d", configureErr, completeErr.rawValue)
        } else {
            NSLog("MacHead: CGBeginDisplayConfiguration 失败: %d", beginErr.rawValue)
        }
    }
    
    /// 获取显示器的持久化 UUID
    func getDisplayUUID(id: CGDirectDisplayID) -> String {
        if let uuidRef = CGDisplayCreateUUIDFromDisplayID(id) {
            let uuid = uuidRef.takeRetainedValue()
            let uuidString = CFUUIDCreateString(kCFAllocatorDefault, uuid) as String
            return uuidString
        }
        return "\(id)"
    }
    
    /// 检测显示器是否已被伪装
    func isDisplaySpoofed(id: CGDirectDisplayID) -> Bool {
        // 如果我们缓存了其物理原身份，表示它目前处于伪装状态
        let uuid = getDisplayUUID(id: id)
        if let original = UserDefaults.standard.array(forKey: "OriginalDisplay-\(uuid)") as? [Int], original.count == 2 {
            let folderName = String(format: "DisplayVendorID-%x", original[0])
            let fileName = String(format: "DisplayProductID-%x", original[1])
            let path = "/Library/Displays/Contents/Resources/Overrides/\(folderName)/\(fileName)"
            return FileManager.default.fileExists(atPath: path)
        }
        
        return false
    }
    
    /// 从 IOKit 注册表中获取显示器的物理 EDID
    private func getPhysicalEDID(displayID: CGDirectDisplayID, originalVendor: UInt32, originalProduct: UInt32) -> Data? {
        var edidData: Data? = nil
        let matching = IOServiceMatching("IODisplayConnect")
        var iterator: io_iterator_t = 0
        
        if IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess {
            while case let regEntry = IOIteratorNext(iterator), regEntry != 0 {
                let infoRef = IODisplayCreateInfoDictionary(regEntry, IOOptionBits(kIODisplayOnlyPreferredName))
                if let info = infoRef?.takeRetainedValue() as? [String: Any] {
                    if let devVendor = info["DisplayVendorID"] as? UInt32,
                       let devProduct = info["DisplayProductID"] as? UInt32,
                       devVendor == originalVendor,
                       devProduct == originalProduct {
                        if let edid = info["IODisplayEDID"] as? Data {
                            edidData = edid
                            IOObjectRelease(regEntry)
                            break
                        }
                    }
                }
                IOObjectRelease(regEntry)
            }
            IOObjectRelease(iterator)
        }
        return edidData
    }
    
    /// 将物理 EDID 改写为 Apple Studio Display 属性（APP, 0xAE3E）并更新校验和
    private func patchEDID(originalEDID: Data) -> Data {
        var edid = originalEDID
        guard edid.count >= 128 else { return originalEDID }
        
        // 1. 厂商 ID 改为 "APP" (0x0610)
        edid[8] = 0x06
        edid[9] = 0x10
        
        // 2. 产品 ID 改为 0xAE3E (Studio Display, little-endian: 0x3E, 0xAE)
        edid[10] = 0x3E
        edid[11] = 0xAE
        
        // 3. 重新计算校验和 (EDID 第 127 字节)
        var sum: UInt32 = 0
        for i in 0..<127 {
            sum += UInt32(edid[i])
        }
        let checksum = UInt8((256 - (sum % 256)) % 256)
        edid[127] = checksum
        
        return edid
    }
    
    /// 伪装显示器为 Apple 官方显示器
    func spoofDisplay(id: CGDirectDisplayID) {
        let vendor = CGDisplayVendorNumber(id)
        let product = CGDisplayModelNumber(id)
        
        // 防止对内置屏或已经是 Apple 的屏误操作
        guard vendor != 0x05AC && CGDisplayIsBuiltin(id) == 0 else { return }
        
        let uuid = getDisplayUUID(id: id)
        let folderName = String(format: "DisplayVendorID-%x", vendor)
        let fileName = String(format: "DisplayProductID-%x", product)
        
        // 尝试提取并注入改写后的 IODisplayEDID 以强制系统加载官方图标
        var edidXmlString = ""
        if let physicalEDID = getPhysicalEDID(displayID: id, originalVendor: vendor, originalProduct: product) {
            let patchedEDID = patchEDID(originalEDID: physicalEDID)
            let base64EDID = patchedEDID.base64EncodedString()
            edidXmlString = "\n    <key>IODisplayEDID</key>\n    <data>\n        \(base64EDID)\n    </data>"
            NSLog("MacHead: 成功读取并改写显示器物理 EDID 校验和")
        } else {
            NSLog("MacHead: 提示：未获取到物理 EDID，将仅伪装设备名与分辨率缩放")
        }
        
        let plistContent = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>DisplayVendorID</key>
    <integer>1452</integer> <!-- 0x05AC -->
    <key>DisplayProductID</key>
    <integer>44606</integer> <!-- 0xAE3E (Studio Display) -->
    <key>DisplayProductName</key>
    <string>Apple Studio Display</string>\(edidXmlString)
</dict>
</plist>
"""
        
        let tempPath = "/tmp/\(fileName).plist"
        do {
            try plistContent.write(toFile: tempPath, atomically: true, encoding: .utf8)
            
            let script = """
            mkdir -p /Library/Displays/Contents/Resources/Overrides/\(folderName) && \
            cp \(tempPath) /Library/Displays/Contents/Resources/Overrides/\(folderName)/\(fileName) && \
            rm -f \(tempPath)
            """
            
            let success = runPrivilegedScript(script)
            if success {
                // 备份物理原身份
                UserDefaults.standard.set([vendor, product], forKey: "OriginalDisplay-\(uuid)")
                NSLog("MacHead: 成功伪装显示器为 Apple 显示器，请重新插拔线缆生效")
            } else {
                NSLog("MacHead: 伪装显示器授权写入失败")
            }
        } catch {
            NSLog("MacHead: 写入临时 plist 失败")
        }
    }
    
    /// 还原显示器为原始状态
    func restoreDisplay(id: CGDirectDisplayID) {
        let uuid = getDisplayUUID(id: id)
        
        // 查找备份的物理原身份
        guard let original = UserDefaults.standard.array(forKey: "OriginalDisplay-\(uuid)") as? [Int], original.count == 2 else {
            NSLog("MacHead: 未找到该显示器的物理原身份备份")
            return
        }
        
        let folderName = String(format: "DisplayVendorID-%x", original[0])
        let fileName = String(format: "DisplayProductID-%x", original[1])
        
        let targetPath = "/Library/Displays/Contents/Resources/Overrides/\(folderName)/\(fileName)"
        let script = "rm -f \(targetPath)"
        
        let success = runPrivilegedScript(script)
        if success {
            UserDefaults.standard.removeObject(forKey: "OriginalDisplay-\(uuid)")
            NSLog("MacHead: 成功还原显示器为原始状态，请重新插拔线缆生效")
        } else {
            NSLog("MacHead: 还原显示器授权写入失败")
        }
    }
    
    /// 使用 Process 衍生 osascript 执行提权脚本以绕过 macOS TCC 自动化沙盒限制
    private func runPrivilegedScript(_ script: String) -> Bool {
        let process = Process()
        process.launchPath = "/usr/bin/osascript"
        process.arguments = ["-e", "do shell script \"\(script)\" with administrator privileges"]
        
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        
        process.launch()
        process.waitUntilExit()
        
        if process.terminationStatus == 0 {
            return true
        } else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let errorMsg = String(data: data, encoding: .utf8) {
                NSLog("MacHead: 提权执行失败: %@", errorMsg)
            }
            return false
        }
    }
}
