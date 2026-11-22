import Foundation
import CoreGraphics

/// 纯无头模式（无外接屏）下的虚拟显示器管理。
///
/// 内屏被 CGSConfigureDisplayEnabled(false) 持久化禁用后，若系统处于合盖且无外接屏状态，
/// 远程桌面唤醒只会获得 WindowServer 的临时宽限（DMGrace ~10s），宽限到期即强制熄屏，
/// 触发「断电 → loginwindow 锁屏 → ScreenCaptureKit 断流 → 远控再唤醒」的闪烁循环（issue #23）。
/// 创建虚拟显示器让系统始终持有活动显示器，从根上避免该循环，并为远控提供稳定采集目标。
final class VirtualDisplayManager {
    static let shared = VirtualDisplayManager()

    private var virtualDisplay: CGVirtualDisplay?
    private(set) var displayID: CGDirectDisplayID?
    /// 创建失败闩锁：私有 API 不可用时避免在每次显示器事件中反复重试刷日志
    private var creationFailed = false

    // MARK: - Test Hooks（约定与 HeadlessModeController 一致：只记录标志位，不创建真实显示器）
    var wasCreateCalled = false
    var wasDestroyCalled = false

    private init() {}

    /// 当前虚拟屏是否仍然在线（系统休眠、WindowServer 重启等可能将其移除）
    var isOnline: Bool {
        if HeadlessModeController.shared.isTestMode { return displayID != nil }
        guard let id = displayID,
              let online = DisplayManager.shared.onlineDisplayIDs() else { return false }
        return online.contains(id)
    }

    /// 创建虚拟显示器（幂等：已存在且在线时直接返回成功）。
    /// 分辨率默认对齐内置屏原生分辨率，兜底 1920x1080。
    @discardableResult
    func create(width: UInt32? = nil, height: UInt32? = nil) -> Bool {
        wasCreateCalled = true
        if HeadlessModeController.shared.isTestMode {
            if displayID == nil { displayID = 0x56495254 }
            return true
        }
        if displayID != nil, virtualDisplay != nil, isOnline { return true }
        guard !creationFailed else { return false }

        var w = width ?? 0, h = height ?? 0
        if w == 0 || h == 0 {
            if let builtin = DisplayManager.shared.builtInDisplayID,
               CGDisplayPixelsWide(builtin) > 0, CGDisplayPixelsHigh(builtin) > 0 {
                w = UInt32(CGDisplayPixelsWide(builtin))
                h = UInt32(CGDisplayPixelsHigh(builtin))
            } else {
                w = 1920
                h = 1080
            }
        }

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = "MacHead Virtual Display"
        descriptor.maxPixelsWide = UInt32(w)
        descriptor.maxPixelsHigh = UInt32(h)
        descriptor.sizeInMillimeters = CGSize(width: 530, height: 300)
        descriptor.productID = 0x1D15
        // 0xF0F0 是虚拟显示器生态惯例 VendorID；DisplayManager.isVirtualDisplay 依此将其
        // 从「外接屏」判定中排除，不会干扰拔线安全恢复与无头维持逻辑
        descriptor.vendorID = 0xF0F0
        descriptor.serialNum = 1

        guard let display = CGVirtualDisplay(descriptor: descriptor) else {
            creationFailed = true
            NSLog("MacHead: 创建虚拟显示器失败（CGVirtualDisplay 私有 API 不可用）")
            return false
        }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 0
        settings.modes = [CGVirtualDisplayMode(width: UInt(w), height: UInt(h), refreshRate: 60)]
        guard display.apply(settings), display.displayID != 0 else {
            creationFailed = true
            virtualDisplay = nil
            NSLog("MacHead: 虚拟显示器应用显示模式失败 (%dx%d)", w, h)
            return false
        }
        virtualDisplay = display
        displayID = display.displayID
        NSLog("MacHead: 已创建虚拟显示器 ID: %d (%dx%d)，纯无头模式下保持系统始终有屏",
              display.displayID, w, h)
        return true
    }

    /// 移除虚拟显示器（不存在时为幂等空操作）。释放对象即移除，其上的窗口自动迁回物理屏。
    func destroy() {
        wasDestroyCalled = true
        if HeadlessModeController.shared.isTestMode {
            displayID = nil
            return
        }
        guard virtualDisplay != nil else { return }
        NSLog("MacHead: 正在移除虚拟显示器 ID: %d", displayID ?? 0)
        virtualDisplay = nil
        displayID = nil
        creationFailed = false
    }

    /// 幂等保活：虚拟屏丢失（如系统休眠移除）时重建
    @discardableResult
    func ensure() -> Bool {
        if displayID != nil, virtualDisplay != nil, isOnline { return true }
        return create()
    }
}
