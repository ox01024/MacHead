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
}
