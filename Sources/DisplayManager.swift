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

    /// 内存中的内置屏 ID 缓存，避免每次查询都写 UserDefaults
    private var cachedBuiltInID: CGDirectDisplayID?

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

    // MARK: - 显示器域查询原语

    /// 单次枚举当前在线显示器列表（CGGetOnlineDisplayList 的 count/fill 两段式调用）
    func onlineDisplayIDs() -> [CGDirectDisplayID]? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return nil }
        return displays
    }

    /// 单次枚举当前处于活动（正在渲染桌面）的显示器列表（CGGetActiveDisplayList）
    func activeDisplayIDs() -> [CGDirectDisplayID]? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return nil }
        return displays
    }

    /// 检查是否为虚拟/软件显示屏（如系统在无物理显示器时创建的 unkn virt，或远程工具生成的虚拟屏）
    static func isVirtualDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        // 0x756e6b6e = "unkn", 0x76697274 = "virt"
        return vendor == 0x756e6b6e || model == 0x76697274 || vendor == 0xF0F0 || model == 0xF0F0
    }

    /// 获取当前或缓存的内置显示器 ID；返回 nil 表示既不在线也无缓存
    var builtInDisplayID: CGDirectDisplayID? {
        // 优先在当前活动显示器列表中查找
        if let id = activeDisplayIDs()?.first(where: { CGDisplayIsBuiltin($0) != 0 }) {
            persistBuiltInID(id)
            return id
        }

        // 其次在在线显示器列表中查找（Intel 平台内屏被断开时仍在此列表中）
        if let id = onlineDisplayIDs()?.first(where: { CGDisplayIsBuiltin($0) != 0 }) {
            persistBuiltInID(id)
            return id
        }

        // Fallback to cached ID if display is already disabled and thus offline
        if let cached = cachedBuiltInID { return cached }
        let persisted = UserDefaults.standard.integer(forKey: "BuiltInDisplayID")
        if persisted != 0 {
            let id = CGDirectDisplayID(persisted)
            cachedBuiltInID = id
            return id
        }

        return nil
    }

    /// 检查内置显示器是否当前处于活动状态（正常点亮并在桌面中绘制）
    var isBuiltInActive: Bool {
        if let active = activeDisplayIDs() {
            // 1. 如果 activeDisplayIDs 包含已知/缓存的内置显示器 ID，则判定为活动
            if let id = builtInDisplayID, active.contains(id) {
                return true
            }
            // 2. 如果 activeDisplayIDs 中有任一显示器通过硬件标志判定为内置屏，则判定为活动并缓存
            if let id = active.first(where: { CGDisplayIsBuiltin($0) != 0 }) {
                persistBuiltInID(id)
                return true
            }
            // activeDisplayIDs 查询成功且列表中明确不含内置屏，说明内置屏已处于未活动状态
            return false
        }

        // 仅在 activeDisplayIDs() 无法获取（返回 nil）的极端系统异常下，降级核验 CGDisplayIsActive
        // 注意：CGDisplayIsActive 遇错可能返回 -1，必须严格核验 == 1
        if let id = builtInDisplayID, CGDisplayIsActive(id) == 1 {
            return true
        }

        return false
    }

    /// 检查内置显示器是否物理在线（包括低功耗睡眠或已被软件断开但总线仍连通的状态）
    var isBuiltInOnline: Bool {
        guard let online = onlineDisplayIDs(),
              let id = online.first(where: { CGDisplayIsBuiltin($0) != 0 }) else { return false }
        persistBuiltInID(id)
        return true
    }

    private func persistBuiltInID(_ id: CGDirectDisplayID) {
        guard cachedBuiltInID != id else { return }
        cachedBuiltInID = id
        UserDefaults.standard.set(Int(id), forKey: "BuiltInDisplayID")
    }

    /// 触发一次轻量级空提交，刷新 WindowServer 的显示拓扑图，清除休眠唤醒或插拔后的未决合成器状态
    func recommitDisplayConfiguration() {
        var configRef: CGDisplayConfigRef? = nil
        if CGBeginDisplayConfiguration(&configRef) == .success {
            _ = CGCompleteDisplayConfiguration(configRef, .forSession)
        }
    }

    // MARK: - 内置屏断开/恢复

    /// 断开内置显示器（已处于非活动状态时为幂等空操作）
    func disconnectBuiltIn(retriesRemaining: Int = 5) {
        guard HeadlessModeController.shared.isHeadlessModeEnabled else { return }

        guard let setMode = setMode else {
            NSLog("MacHead: CGSConfigureDisplayEnabled API 不可用")
            return
        }

        guard isBuiltInActive else {
            NSLog("MacHead: 内置显示屏未处于活动状态，无需重复断开")
            return
        }

        guard let id = builtInDisplayID else {
            NSLog("MacHead: 未能获取内置显示屏 ID，跳过断开")
            return
        }
        persistBuiltInID(id)

        NSLog("MacHead: 正在断开内置显示屏 ID: %d (剩余重试: %d)", id, retriesRemaining)
        var configRef: CGDisplayConfigRef? = nil
        let beginErr = CGBeginDisplayConfiguration(&configRef)
        if beginErr == .success {
            let configureErr = setMode(configRef, id, false)
            if configureErr == 0 {
                let completeErr = CGCompleteDisplayConfiguration(configRef, .permanently)
                NSLog("MacHead: 断开内置屏结果 - 设定: %d, 提交: %d", configureErr, completeErr.rawValue)
                if completeErr == .success { return }
                CGCancelDisplayConfiguration(configRef)
            } else {
                NSLog("MacHead: 断开内置屏设定失败: %d", configureErr)
                CGCancelDisplayConfiguration(configRef)
            }
            NSLog("MacHead: 提交断开显示配置未成功，将在 0.2 秒后重试...")
        } else {
            NSLog("MacHead: CGBeginDisplayConfiguration 失败: %d", beginErr.rawValue)
        }

        guard retriesRemaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.disconnectBuiltIn(retriesRemaining: retriesRemaining - 1)
        }
    }

    /// 重新连接内置显示器
    func reconnectBuiltIn(retriesRemaining: Int = 5, force: Bool = true) {
        guard !HeadlessModeController.shared.isHeadlessModeEnabled else { return }

        // 如果非强制执行，且内屏已在活动列表中（已正常点亮绘制），则无需重复开启
        if !force && isBuiltInActive {
            NSLog("MacHead: 内置显示屏已处于活动状态，无需重复开启")
            return
        }

        guard let setMode = setMode else {
            NSLog("MacHead: CGSConfigureDisplayEnabled API 不可用")
            return
        }

        // 内屏未活动时使用缓存 ID；无缓存时按 Apple Silicon 惯例以 ID 1 兜底（仅此恢复路径需要猜测）
        let id: CGDirectDisplayID
        if let cached = builtInDisplayID {
            id = cached
        } else {
            NSLog("MacHead: 本地无内置屏缓存 ID，以默认 ID 1 兜底尝试恢复")
            id = CGDirectDisplayID(1)
        }

        NSLog("MacHead: 正在重新连接内置显示屏 ID: %d (剩余重试: %d, force: %d)", id, retriesRemaining, force ? 1 : 0)

        // 提交配置前先执行一次轻量空提交，刷新 WindowServer 显示图，防止合成器处于挂起或脱节状态
        recommitDisplayConfiguration()

        var configRef: CGDisplayConfigRef? = nil
        let beginErr = CGBeginDisplayConfiguration(&configRef)
        if beginErr == .success {
            let configureErr = setMode(configRef, id, true)
            if configureErr == 0 {
                let completeErr = CGCompleteDisplayConfiguration(configRef, .permanently)
                NSLog("MacHead: 启用内置屏结果 - 设定: %d, 提交: %d", configureErr, completeErr.rawValue)
                if completeErr == .success {
                    if isBuiltInActive { return }
                } else {
                    CGCancelDisplayConfiguration(configRef)
                }
            } else {
                NSLog("MacHead: 启用内置屏设定失败: %d", configureErr)
                CGCancelDisplayConfiguration(configRef)
            }
            NSLog("MacHead: 提交启用显示配置未生效或内屏尚未活动，将在 0.2 秒后重试...")
        } else {
            NSLog("MacHead: CGBeginDisplayConfiguration 失败: %d", beginErr.rawValue)
        }

        guard retriesRemaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.reconnectBuiltIn(retriesRemaining: retriesRemaining - 1, force: false)
        }
    }
}
