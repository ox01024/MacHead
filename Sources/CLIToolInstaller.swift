import Foundation
import AppKit

/// machead 命令行工具软链接管理 (/usr/local/bin/machead → App 可执行文件)
/// 属于唯一的"包外自动组件"，严格 opt-in：仅在用户于偏好设置中开启后创建，
/// 关闭时移除；默认用户对系统路径零写入，拖废纸篓即可完全卸载。
enum CLIToolInstaller {
    static let defaultsKey = "EnableCLITool"
    static let symlinkPath = "/usr/local/bin/machead"
    static let targetPath = "/Applications/MacHead.app/Contents/MacOS/MacHead"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    /// 应用启动时调用：仅当用户已开启 CLI 工具时维护软链接
    static func setupIfEnabled() {
        // 老版本迁移（仅一次）：从未写入过偏好且已存在软链接的历史用户视为已显式开启；
        // 此后以存储的偏好为准，不再用文件系统状态覆盖用户的选择
        if UserDefaults.standard.object(forKey: defaultsKey) == nil,
           FileManager.default.fileExists(atPath: symlinkPath) {
            UserDefaults.standard.set(true, forKey: defaultsKey)
        }
        guard isEnabled else { return }
        install()
    }

    /// 创建软链接，无写权限时引导用户授权
    @discardableResult
    static func install() -> Bool {
        let fm = FileManager.default

        // 仅当 App 位于 /Applications 时创建（与其他机器路径不兼容）
        guard fm.fileExists(atPath: targetPath) else { return false }

        // 已存在且指向正确，无需处理
        if fm.fileExists(atPath: symlinkPath),
           let dest = try? fm.destinationOfSymbolicLink(atPath: symlinkPath), dest == targetPath {
            return true
        }

        // 先尝试用户权限直接创建（/usr/local/bin 可写时；目录已存在时创建为空操作）
        do {
            try fm.createDirectory(atPath: "/usr/local/bin", withIntermediateDirectories: true)
            if fm.fileExists(atPath: symlinkPath) {
                try fm.removeItem(atPath: symlinkPath)
            }
            try fm.createSymbolicLink(atPath: symlinkPath, withDestinationPath: targetPath)
            NSLog("MacHead: CLI 软链接创建成功 (用户权限)")
            return true
        } catch {
            // 无写权限，走提权
        }

        // 提权创建（与用户确认后）
        return onMainIfRemote {
            let alert = NSAlert()
            alert.messageText = L("安装 MacHead 命令行工具", "Install MacHead CLI Tool")
            alert.informativeText = L(
                "MacHead 希望在 /usr/local/bin/machead 创建命令行工具的软链接。启用后，您可以在终端中运行 'machead' 直接管控设备守护程序。",
                "MacHead wants to create a symlink at /usr/local/bin/machead so you can control the daemon directly from the terminal using 'machead'."
            )
            alert.alertStyle = .informational
            alert.addButton(withTitle: L("立即安装 (需密码或Touch ID)", "Install Now (Requires Admin)"))
            alert.addButton(withTitle: L("稍后", "Later"))

            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            return runElevated("mkdir -p /usr/local/bin && ln -sf \(targetPath) \(symlinkPath)")
        }
    }

    /// 移除软链接，无写权限时引导用户授权
    @discardableResult
    static func remove() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: symlinkPath) else { return true }

        do {
            try fm.removeItem(atPath: symlinkPath)
            return true
        } catch {
            return onMainIfRemote {
                let alert = NSAlert()
                alert.messageText = L("移除 MacHead 命令行工具", "Remove MacHead CLI Tool")
                alert.informativeText = L(
                    "删除 /usr/local/bin/machead 需要管理员权限。",
                    "Administrator privileges are required to remove /usr/local/bin/machead."
                )
                alert.addButton(withTitle: L("授权移除", "Remove"))
                alert.addButton(withTitle: L("跳过", "Skip"))

                guard alert.runModal() == .alertFirstButtonReturn else { return false }
                return runElevated("rm -f \(symlinkPath)")
            }
        }
    }

    // MARK: - Privileged Helpers

    /// 提权执行 shell 命令 (osascript)
    static func runElevated(_ command: String) -> Bool {
        let script = "do shell script \"\(command)\" with administrator privileges"
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let err = error {
                NSLog("MacHead: CLIToolInstaller 提权操作失败: %@", err)
                return false
            }
            return true
        }
        return false
    }

    /// 确保弹窗与模态交互在主线程执行（从后台线程调用时同步派发）
    private static func onMainIfRemote(_ work: () -> Bool) -> Bool {
        if Thread.isMainThread {
            return work()
        }
        var result = false
        DispatchQueue.main.sync {
            result = work()
        }
        return result
    }
}
