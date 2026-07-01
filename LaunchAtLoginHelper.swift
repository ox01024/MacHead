import Foundation
import ServiceManagement

final class LaunchAtLoginHelper {
    static let shared = LaunchAtLoginHelper()
    
    private init() {}
    
    var isEnabled: Bool {
        get {
            return SMAppService.mainApp.status == .enabled
        }
        set {
            do {
                if newValue {
                    if SMAppService.mainApp.status == .enabled {
                        return
                    }
                    try SMAppService.mainApp.register()
                    NSLog("MacHead: 成功开启开机自启")
                } else {
                    if SMAppService.mainApp.status != .enabled {
                        return
                    }
                    try SMAppService.mainApp.unregister()
                    NSLog("MacHead: 成功关闭开机自启")
                }
            } catch {
                NSLog("MacHead: 设置开机自启状态失败: %@", error.localizedDescription)
            }
        }
    }
}
