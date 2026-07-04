import Cocoa

let arguments = CommandLine.arguments

if arguments.count > 1 {
    let arg = arguments[1]
    
    if arg == "--status" || arg == "-s" || arg == "status" {
        let defaults = UserDefaults.standard
        let isHeadless = defaults.bool(forKey: "HeadlessModeEnabled")
        
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.waffle.MacHead")
        if runningApps.isEmpty {
            print("offline (last saved state: \(isHeadless ? "headless" : "normal"))")
        } else {
            print(isHeadless ? "headless" : "normal")
        }
        exit(0)
        
    } else if arg == "--enable" || arg == "-e" || arg == "enable" {
        print("Sending enable command to MacHead daemon...")
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.waffle.MacHead.CLI.enable"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        Thread.sleep(forTimeInterval: 0.2)
        exit(0)
        
    } else if arg == "--disable" || arg == "-d" || arg == "disable" {
        print("Sending disable command to MacHead daemon...")
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.waffle.MacHead.CLI.disable"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        Thread.sleep(forTimeInterval: 0.2)
        exit(0)
        
    } else if arg == "--help" || arg == "-h" || arg == "help" {
        print("MacHead - MacBook Headless Mode Manager (CLI Client)")
        print("Usage:")
        print("  MacHead [options]")
        print("")
        print("Options:")
        print("  -s, --status   Show current mode status (headless, normal, or offline)")
        print("  -e, --enable   Enable Headless Mode (turns off built-in display, locks sleep)")
        print("  -d, --disable  Disable Headless Mode (restores built-in display)")
        print("  -h, --help     Show this help message")
        exit(0)
        
    } else {
        print("Unknown option: \(arg)")
        print("Use --help to view available commands.")
        exit(1)
    }
} else {
    // Launch the SwiftUI app GUI
    MacHeadApp.main()
}
