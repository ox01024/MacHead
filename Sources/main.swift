import Cocoa

let arguments = CommandLine.arguments

private func resolveAppDefaults() -> UserDefaults {
    if Bundle.main.bundleIdentifier == "com.waffle.MacHead" {
        return .standard
    }
    return UserDefaults(suiteName: "com.waffle.MacHead") ?? .standard
}

private func isMacHeadDaemonRunning() -> Bool {
    let currentPID = ProcessInfo.processInfo.processIdentifier
    let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.waffle.MacHead")
        .filter { $0.processIdentifier != currentPID }
    return !runningApps.isEmpty
}

if arguments.count > 1 {
    let arg = arguments[1]
    let subArg = arguments.count > 2 ? arguments[2] : ""
    let defaults = resolveAppDefaults()

    if arg == "--telemetry-json" {
        defaults.synchronize()
        let isHeadless = defaults.bool(forKey: "HeadlessModeEnabled")
        let preventIdleSleep = defaults.object(forKey: "PreventIdleSleep") as? Bool ?? true
        let keepRunningOnLidClose = defaults.bool(forKey: "KeepRunningOnLidClose")
        let smc = SMCManager.shared
        let payload: [String: Any] = [
            "isHeadless": isHeadless,
            "preventIdleSleep": preventIdleSleep,
            "keepRunningOnLidClose": keepRunningOnLidClose,
            "cpuTemp": round(smc.currentTemperature * 10) / 10,
            "fanSpeed": smc.fanSpeed,
            "isFanless": smc.isFanless
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        } else {
            print("{}")
        }
        exit(0)

    } else if arg == "--status" || arg == "-s" || arg == "status" {
        defaults.synchronize()
        let isHeadless = defaults.bool(forKey: "HeadlessModeEnabled")
        let daemonRunning = isMacHeadDaemonRunning()

        if subArg == "--short" || subArg == "-q" {
            if !daemonRunning {
                print("offline")
            } else {
                print(isHeadless ? "headless" : "normal")
            }
            exit(0)
        }

        // 1. Mode / 运行模式
        let modeLine: String
        if !daemonRunning {
            let lastState = isHeadless ? L("无头模式", "headless") : L("正常显示", "normal")
            modeLine = L(
                "运行模式: 未运行 (上次状态: \(lastState))",
                "Mode: OFFLINE (last saved state: \(lastState))"
            )
        } else if isHeadless {
            modeLine = L(
                "运行模式: 无头服务器模式 (内置屏幕已断电)",
                "Mode: HEADLESS (Internal Display powered off)"
            )
        } else {
            modeLine = L(
                "运行模式: 正常显示 (内置屏幕已点亮)",
                "Mode: NORMAL (Active Screen)"
            )
        }

        // 2. WebServer / Web 控制台
        let enableWebServer = defaults.bool(forKey: "EnableWebServer")
        let storedPort = defaults.integer(forKey: "WebServerPort")
        let port = (storedPort >= 1 && storedPort <= 65535) ? storedPort : Int(WebServer.defaultPort)
        let ip = WebServer.shared.getLocalIPAddress()
        let webServerLine: String
        if daemonRunning && enableWebServer {
            webServerLine = L(
                "Web 控制台: 运行中 (http://\(ip):\(port))",
                "WebServer: RUNNING (http://\(ip):\(port))"
            )
        } else if enableWebServer {
            webServerLine = L(
                "Web 控制台: 已停止 (http://\(ip):\(port))",
                "WebServer: STOPPED (http://\(ip):\(port))"
            )
        } else {
            webServerLine = L(
                "Web 控制台: 未启用",
                "WebServer: DISABLED"
            )
        }

        // 3. Sleep Prevention / 合盖防休眠
        let preventIdleSleep = defaults.object(forKey: "PreventIdleSleep") as? Bool ?? true
        let keepRunningOnLidClose = defaults.bool(forKey: "KeepRunningOnLidClose")
        let activeAssertionID = defaults.integer(forKey: "ActiveSleepAssertionID")
        let sleepActive = daemonRunning && ((isHeadless && preventIdleSleep) || keepRunningOnLidClose || activeAssertionID > 0)
        let sleepLine = sleepActive
            ? L("合盖防休眠: 已启用", "Sleep Prevention: ENABLED")
            : L("合盖防休眠: 未启用", "Sleep Prevention: DISABLED")

        // 4. Power Source / 当前电源
        BatteryManager.shared.updateBatteryInfo()
        let onBattery = (BatteryManager.shared.powerState == "Battery Power")
        let capacity = BatteryManager.shared.currentCapacity
        let powerLine = onBattery
            ? L("当前电源: 电池供电 (电池 \(capacity)%)", "Power Source: Battery Power (Battery \(capacity)%)")
            : L("当前电源: 交流电源 (电池 \(capacity)%)", "Power Source: AC Power (Battery \(capacity)%)")

        // 5. Keyboard/Trackpad Lockout in Headless / 无头模式内置键鼠防误触
        let lockoutConfigured = defaults.bool(forKey: "DisableKeyboardInHeadless")
            || defaults.bool(forKey: "DisableTrackpadInHeadless")
            || defaults.bool(forKey: "DisableKeyboardAndTrackpadInHeadlessMode")
        let lockoutLine: String
        if daemonRunning && isHeadless {
            lockoutLine = lockoutConfigured
                ? L("无头模式内置键鼠防误触: 已启用", "Keyboard/Trackpad Lockout in Headless: ACTIVE")
                : L("无头模式内置键鼠防误触: 未启用", "Keyboard/Trackpad Lockout in Headless: DISABLED")
        } else {
            lockoutLine = L(
                "无头模式内置键鼠防误触: 已就绪",
                "Keyboard/Trackpad Lockout in Headless: READY"
            )
        }

        print(modeLine)
        print(webServerLine)
        print(sleepLine)
        print(powerLine)
        print(lockoutLine)
        exit(0)

    } else if arg == "--enable" || arg == "-e" || arg == "enable" {
        guard isMacHeadDaemonRunning() else {
            print(L("MacHead: 主程序未运行，请先启动 MacHead.app", "MacHead: Daemon is not running. Please launch MacHead.app first."))
            exit(1)
        }
        print(L("MacHead: 正在启用无头模式...", "MacHead: Enabling Headless Server Mode..."))
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.waffle.MacHead.CLI.enable"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.35))
        defaults.synchronize()

        print(L("MacHead: 已通过 SkyLight 逻辑切断内置屏幕电源", "MacHead: Internal display logically powered off via SkyLight"))
        if defaults.bool(forKey: "MuteMicrophoneInHeadlessMode") {
            print(L("MacHead: 内置麦克风已自动静音锁定", "MacHead: Built-in microphone muted"))
        }
        let preventIdleSleep = defaults.object(forKey: "PreventIdleSleep") as? Bool ?? true
        if preventIdleSleep || defaults.bool(forKey: "KeepRunningOnLidClose") {
            print(L("MacHead: 合盖防休眠电源断言已锁定", "MacHead: Clamshell sleep prevention assertion locked"))
        }
        if defaults.bool(forKey: "EnableWebServer") {
            let storedPort = defaults.integer(forKey: "WebServerPort")
            let port = (storedPort >= 1 && storedPort <= 65535) ? storedPort : Int(WebServer.defaultPort)
            let ip = WebServer.shared.getLocalIPAddress()
            print(L("Web 控制台: http://\(ip):\(port)", "WebServer: http://\(ip):\(port)"))
        }
        print(L("运行模式: 无头服务器模式 (内置屏幕已断电)", "Mode: HEADLESS (Internal Display powered off)"))
        exit(0)

    } else if arg == "--disable" || arg == "-d" || arg == "disable" {
        guard isMacHeadDaemonRunning() else {
            print(L("MacHead: 主程序未运行，请先启动 MacHead.app", "MacHead: Daemon is not running. Please launch MacHead.app first."))
            exit(1)
        }
        print(L("MacHead: 正在退出无头模式...", "MacHead: Disabling Headless Server Mode..."))
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.waffle.MacHead.CLI.disable"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.35))
        defaults.synchronize()

        print(L("MacHead: 内置屏幕已恢复供电与点亮", "MacHead: Internal display power restored"))
        if defaults.bool(forKey: "MuteMicrophoneInHeadlessMode") {
            print(L("MacHead: 内置麦克风静音已解除", "MacHead: Built-in microphone unmuted"))
        }
        if !defaults.bool(forKey: "KeepRunningOnLidClose") {
            print(L("MacHead: 防休眠电源断言已释放", "MacHead: Sleep assertion released"))
        }
        print(L("运行模式: 正常显示 (内置屏幕已点亮)", "Mode: NORMAL (Active Screen)"))
        exit(0)

    } else if arg == "sleep-prevent" || arg == "--sleep-prevent" || (arg == "sleep" && (subArg == "prevent" || subArg == "on" || subArg == "enable" || subArg.isEmpty)) {
        guard isMacHeadDaemonRunning() else {
            print(L("MacHead: 主程序未运行，请先启动 MacHead.app", "MacHead: Daemon is not running. Please launch MacHead.app first."))
            exit(1)
        }
        print(L("MacHead: 正在开启合盖防休眠断言...", "MacHead: Acquiring clamshell sleep assertion..."))
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.waffle.MacHead.CLI.sleepPrevent"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.35))
        defaults.synchronize()
        let assertionID = defaults.integer(forKey: "ActiveSleepAssertionID")
        if assertionID > 0 {
            print(L("MacHead: 系统电源断言锁定成功 (ID: \(assertionID))", "MacHead: IOPMAssertion locked (ID: \(assertionID))"))
        } else {
            print(L("MacHead: 系统电源断言锁定成功", "MacHead: IOPMAssertion locked"))
        }
        print(L("合盖防休眠: 已启用", "Sleep Prevention: ENABLED"))
        print(L("系统将在合盖状态下持续保持唤醒运行。", "System will stay awake continuously with lid closed."))
        exit(0)

    } else if arg == "sleep-allow" || arg == "--sleep-allow" || (arg == "sleep" && (subArg == "allow" || subArg == "off" || subArg == "disable")) {
        guard isMacHeadDaemonRunning() else {
            print(L("MacHead: 主程序未运行，请先启动 MacHead.app", "MacHead: Daemon is not running. Please launch MacHead.app first."))
            exit(1)
        }
        print(L("MacHead: 正在释放防休眠电源断言...", "MacHead: Releasing sleep prevention assertion..."))
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.waffle.MacHead.CLI.sleepAllow"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.35))
        print(L("合盖防休眠: 未启用", "Sleep Prevention: DISABLED"))
        exit(0)

    } else if arg == "--test" {
        HeadlessModeController.runTests()
        exit(0)

    } else if arg == "--inhibit-charging" || arg == "--charge-inhibit" {
        let val = arguments.count > 2 ? arguments[2] : "1"
        let inhibit = (val == "1" || val.lowercased() == "true")
        let success = SMCManager.shared.setChargingInhibited(inhibit)
        if success {
            print(inhibit ? "Charging inhibited (stopped)" : "Charging restored (enabled)")
            exit(0)
        } else {
            print("Failed to set charging inhibit via SMC (requires root privileges)")
            exit(1)
        }

    } else if arg == "--set-bclm" {
        let limit = arguments.count > 2 ? (Int(arguments[2]) ?? 80) : 80
        let success = SMCManager.shared.setBCLMChargeLimit(limit)
        if success {
            print("BCLM charge limit set to \(limit)%")
            exit(0)
        } else {
            print("Failed to set BCLM via SMC (requires root privileges or Apple Silicon doesn't support BCLM)")
            exit(1)
        }

    } else if arg == "--help" || arg == "-h" || arg == "help" {
        print(L("MacHead - MacBook 无头服务器模式管理工具 (CLI)", "MacHead - MacBook Headless Mode Manager (CLI)"))
        print("")
        print(L("用法:", "Usage:"))
        print("  machead <command> [options]")
        print("")
        print(L("命令与选项:", "Commands & Options:"))
        print(L("  status, -s, --status         查看当前完整运行状态 (加上 --short 仅输出单词状态)", "  status, -s, --status         Show detailed runtime status (add --short for single-word output)"))
        print(L("  enable, -e, --enable         开启无头模式 (切断内置屏幕电源并锁定防休眠)", "  enable, -e, --enable         Enable Headless Mode (power off built-in display & lock sleep)"))
        print(L("  disable, -d, --disable       退出无头模式 (恢复内置屏幕显示)", "  disable, -d, --disable       Disable Headless Mode (restore built-in display)"))
        print(L("  sleep prevent                开启合盖与空闲防休眠电源断言", "  sleep prevent                Acquire power assertion to prevent idle & clamshell sleep"))
        print(L("  sleep allow                  释放防休眠电源断言", "  sleep allow                  Release sleep prevention power assertion"))
        print(L("  --test                       运行 HeadlessModeController 单元测试", "  --test                       Run unit tests for HeadlessModeController"))
        print(L("  help, -h, --help             显示此帮助信息", "  help, -h, --help             Show this help message"))
        exit(0)

    } else {
        print(L("未知命令或参数: \(arg)", "Unknown option: \(arg)"))
        print(L("请使用 machead --help 查看可用命令。", "Use 'machead --help' to view available commands."))
        exit(1)
    }
} else {
    // Launch the SwiftUI app GUI
    MacHeadApp.main()
}
