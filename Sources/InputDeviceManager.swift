import Foundation
import IOKit
import IOKit.hid
import CoreGraphics
import ApplicationServices

final class InputDeviceManager {
    static let shared = InputDeviceManager()
    
    private var manager: IOHIDManager?
    private var externalMice = Set<IOHIDDevice>()
    private var externalKeyboards = Set<IOHIDDevice>()
    private var builtInTrackpads = Set<IOHIDDevice>()
    private var builtInKeyboards = Set<IOHIDDevice>()
    private var seizedTrackpads = Set<IOHIDDevice>()
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    
    var lastInternalKeyboardEventTime = Date(timeIntervalSince1970: 0)
    
    private init() {}
    
    func start() {
        guard manager == nil else { return }
        
        let newManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = newManager
        
        let matchingTypes: [[String: Any]] = [
            [
                kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse
            ],
            [
                kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey: kHIDUsage_GD_Pointer
            ],
            [
                kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard
            ]
        ]
        IOHIDManagerSetDeviceMatchingMultiple(newManager, matchingTypes as CFArray)
        
        let context = Unmanaged.passUnretained(self).toOpaque()
        
        IOHIDManagerRegisterDeviceMatchingCallback(newManager, { context, result, sender, device in
            guard let context = context else { return }
            let this = Unmanaged<InputDeviceManager>.fromOpaque(context).takeUnretainedValue()
            this.deviceConnected(device)
        }, context)
        
        IOHIDManagerRegisterDeviceRemovalCallback(newManager, { context, result, sender, device in
            guard let context = context else { return }
            let this = Unmanaged<InputDeviceManager>.fromOpaque(context).takeUnretainedValue()
            this.deviceDisconnected(device)
        }, context)
        
        IOHIDManagerScheduleWithRunLoop(newManager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        
        let result = IOHIDManagerOpen(newManager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            NSLog("MacHead: IOHIDManagerOpen 失败: %d", result)
        } else {
            NSLog("MacHead: IOHIDManager 启动并成功开始监听输入设备变化")
        }
    }
    
    private func isDeviceBuiltIn(_ device: IOHIDDevice) -> Bool {
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? ""
        return transport == "SPI" || name.contains("Internal")
    }
    
    private func deviceConnected(_ device: IOHIDDevice) {
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Unknown"
        let isBuiltIn = isDeviceBuiltIn(device)
        
        let primaryUsagePage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
        let primaryUsage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0
        let isKeyboard = (primaryUsagePage == kHIDPage_GenericDesktop && primaryUsage == kHIDUsage_GD_Keyboard)
        
        NSLog("MacHead: 检测到输入设备连接: %@ (内置: %@, 键盘: %@)", name, String(isBuiltIn), String(isKeyboard))
        
        if isKeyboard {
            if isBuiltIn {
                builtInKeyboards.insert(device)
            } else {
                externalKeyboards.insert(device)
            }
            
            // 为键盘设备注册按键输入时序回调
            let context = Unmanaged.passUnretained(self).toOpaque()
            IOHIDDeviceRegisterInputValueCallback(device, { context, result, sender, value in
                guard let context = context else { return }
                let this = Unmanaged<InputDeviceManager>.fromOpaque(context).takeUnretainedValue()
                if let senderPtr = sender {
                    let dev = Unmanaged<IOHIDDevice>.fromOpaque(senderPtr).takeUnretainedValue()
                    this.keyboardInputReceived(device: dev)
                }
            }, context)
        } else {
            if isBuiltIn {
                builtInTrackpads.insert(device)
            } else {
                externalMice.insert(device)
            }
        }
        
        evaluateTrackpadAndKeyboardState()
    }
    
    private func deviceDisconnected(_ device: IOHIDDevice) {
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Unknown"
        NSLog("MacHead: 检测到输入设备断开: %@", name)
        
        if builtInKeyboards.contains(device) {
            builtInKeyboards.remove(device)
        } else if externalKeyboards.contains(device) {
            externalKeyboards.remove(device)
        } else if builtInTrackpads.contains(device) {
            if seizedTrackpads.contains(device) {
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
                seizedTrackpads.remove(device)
                NSLog("MacHead: 释放已断开的内置触控板")
            }
            builtInTrackpads.remove(device)
        } else {
            externalMice.remove(device)
        }
        
        evaluateTrackpadAndKeyboardState()
    }
    
    private func keyboardInputReceived(device: IOHIDDevice) {
        if isDeviceBuiltIn(device) {
            lastInternalKeyboardEventTime = Date()
        }
    }
    
    func evaluateTrackpadAndKeyboardState() {
        let isHeadless = HeadlessModeController.shared.isHeadlessModeEnabled
        
        let disableKeyboardInHeadless = UserDefaults.standard.bool(forKey: "DisableKeyboardInHeadless")
        let disableKeyboardWhenExtKeyConnected = UserDefaults.standard.bool(forKey: "DisableKeyboardWhenExternalKeyboardConnected")
        
        let disableTrackpadInHeadless = UserDefaults.standard.bool(forKey: "DisableTrackpadInHeadless")
        let disableTrackpadWhenExtMouseConnected = UserDefaults.standard.bool(forKey: "DisableTrackpadWhenExternalMouseConnected")
        
        let hasExtKeyboard = !externalKeyboards.isEmpty
        let hasExtMouse = !externalMice.isEmpty
        
        let shouldDisableKeyboard = (isHeadless && disableKeyboardInHeadless) || (disableKeyboardWhenExtKeyConnected && hasExtKeyboard)
        let shouldDisableTrackpad = (isHeadless && disableTrackpadInHeadless) || (disableTrackpadWhenExtMouseConnected && hasExtMouse)
        
        // 1. 评估内置触控板的 Seize 独占拦截
        if shouldDisableTrackpad {
            for trackpad in builtInTrackpads {
                if !seizedTrackpads.contains(trackpad) {
                    let result = IOHIDDeviceOpen(trackpad, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
                    if result == kIOReturnSuccess {
                        seizedTrackpads.insert(trackpad)
                        NSLog("MacHead: 成功独占（禁用）内置触控板")
                    } else {
                        NSLog("MacHead: 独占内置触控板失败: %d", result)
                    }
                }
            }
        } else {
            for trackpad in seizedTrackpads {
                IOHIDDeviceClose(trackpad, IOOptionBits(kIOHIDOptionsTypeNone))
                NSLog("MacHead: 释放内置触控板")
            }
            seizedTrackpads.removeAll()
        }
        
        // 2. 评估内置键盘的 CGEventTap 时序拦截
        if shouldDisableKeyboard {
            startEventTap()
        } else {
            stopEventTap()
        }
    }
    
    private func startEventTap() {
        guard eventTap == nil else { return }
        
        // 校验辅助功能权限
        guard AXIsProcessTrusted() else {
            NSLog("MacHead: 无法启动键盘拦截 - 未获得辅助功能权限！")
            return
        }
        
        let eventMask = (1 << CGEventType.keyDown.rawValue) |
                         (1 << CGEventType.keyUp.rawValue) |
                         (1 << CGEventType.flagsChanged.rawValue)
        
        let callback: CGEventTapCallBack = { (proxy, type, event, userInfo) -> Unmanaged<CGEvent>? in
            let timeDiff = Date().timeIntervalSince(InputDeviceManager.shared.lastInternalKeyboardEventTime)
            if timeDiff < 0.04 { // 40毫秒高精度事件窗口
                return nil // 丢弃该键盘事件
            }
            return Unmanaged.passRetained(event)
        }
        
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: nil
        ) else {
            NSLog("MacHead: 创建键盘拦截 CGEventTap 失败")
            return
        }
        
        self.eventTap = tap
        self.runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            CGEvent.tapEnable(tap: tap, enable: true)
            NSLog("MacHead: 键盘拦截 CGEventTap 启动成功")
        }
    }
    
    private func stopEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            }
            eventTap = nil
            runLoopSource = nil
            NSLog("MacHead: 键盘拦截 CGEventTap 已关闭")
        }
    }
    
    deinit {
        stopEventTap()
        if let manager = manager {
            for trackpad in seizedTrackpads {
                IOHIDDeviceClose(trackpad, IOOptionBits(kIOHIDOptionsTypeNone))
            }
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }
}
