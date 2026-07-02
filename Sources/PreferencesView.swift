import SwiftUI
import CoreGraphics

struct PreferencesView: View {
    @AppStorage("AutoEnableHeadlessOnLaunch") private var autoEnableOnLaunch = true
    @AppStorage("PreventIdleSleep") private var preventIdleSleep = true
    @State private var launchAtLogin = LaunchAtLoginHelper.shared.isEnabled
    @State private var connectedDisplays: [String] = []
    @State private var disableTrackpad = UserDefaults.standard.bool(forKey: "DisableTrackpadWhenExternalMouseConnected")
    @State private var enableBatteryProtection = UserDefaults.standard.bool(forKey: "EnableBatteryProtection")
    @State private var batteryThreshold = UserDefaults.standard.integer(forKey: "BatteryThreshold") == 0 ? 20 : UserDefaults.standard.integer(forKey: "BatteryThreshold")
    @State private var batteryCapacity = BatteryManager.shared.currentCapacity
    @State private var batteryState = BatteryManager.shared.powerState
    @State private var isCharging = BatteryManager.shared.isCharging
    @State private var muteMicrophone = UserDefaults.standard.bool(forKey: "MuteMicrophoneInHeadlessMode")
    @State private var isMicrophoneMuted = MediaDeviceManager.shared.isMuted
    @State private var enableWebServer = UserDefaults.standard.bool(forKey: "EnableWebServer")
    @State private var webServerIP = WebServer.shared.getLocalIPAddress()
    @State private var webServerPassword = UserDefaults.standard.string(forKey: "WebServerPassword") ?? ""
    @State private var disableKeyboardAndTrackpadInHeadless = UserDefaults.standard.bool(forKey: "DisableKeyboardAndTrackpadInHeadlessMode")
    @State private var isAccessibilityTrusted = AXIsProcessTrusted()

    var body: some View {
        TabView {
            // Tab 1: General Settings (通用)
            Form {
                Section {
                    Toggle("开机时自动启动 MacHead", isOn: Binding(
                        get: { self.launchAtLogin },
                        set: { newValue in
                            self.launchAtLogin = newValue
                            LaunchAtLoginHelper.shared.isEnabled = newValue
                        }
                    ))
                    
                    Toggle("检测到外接屏幕时自动启用无头模式", isOn: $autoEnableOnLaunch)
                    
                    Toggle("无头模式下防止系统进入空闲睡眠", isOn: $preventIdleSleep)
                } header: {
                    Text("启动与睡眠")
                }
                
                Section {
                    Toggle("启用电池保护（防低电量耗尽）", isOn: Binding(
                        get: { self.enableBatteryProtection },
                        set: { newValue in
                            self.enableBatteryProtection = newValue
                            UserDefaults.standard.set(newValue, forKey: "EnableBatteryProtection")
                            BatteryManager.shared.handlePowerSourceChanged()
                        }
                    ))
                    
                    if enableBatteryProtection {
                        HStack {
                            Slider(value: Binding(
                                get: { Double(self.batteryThreshold) },
                                set: { newValue in
                                    let intVal = Int(newValue)
                                    self.batteryThreshold = intVal
                                    UserDefaults.standard.set(intVal, forKey: "BatteryThreshold")
                                    BatteryManager.shared.handlePowerSourceChanged()
                                }
                            ), in: 10...50, step: 5)
                            Text("允许休眠电量: \(batteryThreshold)%")
                                .frame(width: 120, alignment: .trailing)
                        }
                    }
                } header: {
                    Text("电源管理")
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("通用", systemImage: "gearshape")
            }
            
            // Tab 2: Devices Settings (设备)
            Form {
                Section {
                    Toggle("连接外接鼠标时禁用内置触控板", isOn: Binding(
                        get: { self.disableTrackpad },
                        set: { newValue in
                            self.disableTrackpad = newValue
                            UserDefaults.standard.set(newValue, forKey: "DisableTrackpadWhenExternalMouseConnected")
                            InputDeviceManager.shared.evaluateTrackpadAndKeyboardState()
                        }
                    ))
                    
                    Toggle("无头模式下禁用内置键盘与触控板", isOn: Binding(
                        get: { self.disableKeyboardAndTrackpadInHeadless },
                        set: { newValue in
                            self.disableKeyboardAndTrackpadInHeadless = newValue
                            UserDefaults.standard.set(newValue, forKey: "DisableKeyboardAndTrackpadInHeadlessMode")
                            InputDeviceManager.shared.evaluateTrackpadAndKeyboardState()
                            self.isAccessibilityTrusted = AXIsProcessTrusted()
                        }
                    ))
                    
                    if disableKeyboardAndTrackpadInHeadless && !isAccessibilityTrusted {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("未授权辅助功能权限")
                                    .font(.subheadline)
                                    .bold()
                            }
                            Text("请在“系统设置 -> 隐私与安全性 -> 辅助功能”中允许 MacHead。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Button("去系统设置开启") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .foregroundColor(.accentColor)
                        }
                        .padding(.vertical, 2)
                    }
                    
                    Toggle("无头模式下自动静音内置麦克风", isOn: Binding(
                        get: { self.muteMicrophone },
                        set: { newValue in
                            self.muteMicrophone = newValue
                            UserDefaults.standard.set(newValue, forKey: "MuteMicrophoneInHeadlessMode")
                            if HeadlessModeController.shared.isHeadlessModeEnabled {
                                if newValue {
                                    MediaDeviceManager.shared.muteBuiltInMicrophone()
                                } else {
                                    MediaDeviceManager.shared.unmuteBuiltInMicrophone()
                                }
                                self.isMicrophoneMuted = MediaDeviceManager.shared.isMuted
                            }
                        }
                    ))
                } header: {
                    Text("输入与输出拦截")
                }
                
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("电池容量: \(batteryCapacity)%")
                            if isCharging {
                                Image(systemName: "bolt.fill")
                                    .foregroundColor(.yellow)
                            }
                            Spacer()
                            Text(batteryState == "AC Power" ? "外接电源直供" : "电池供电中")
                                .foregroundColor(.secondary)
                        }
                        
                        Divider()
                        
                        Text("当前显示器列表:")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        ForEach(connectedDisplays, id: \.self) { name in
                            Label(name, systemImage: name.contains("内置") ? "laptopcomputer" : "display")
                                .font(.body)
                        }
                    }
                } header: {
                    Text("硬件状态")
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("设备", systemImage: "keyboard")
            }
            
            // Tab 3: Remote Server Control (远程控制)
            Form {
                Section {
                    Toggle("启用局域网 Web 控制面板", isOn: Binding(
                        get: { self.enableWebServer },
                        set: { newValue in
                            self.enableWebServer = newValue
                            UserDefaults.standard.set(newValue, forKey: "EnableWebServer")
                            if newValue {
                                WebServer.shared.start()
                                self.webServerIP = WebServer.shared.getLocalIPAddress()
                            } else {
                                WebServer.shared.stop()
                            }
                        }
                    ))
                } header: {
                    Text("服务开关")
                }
                
                if enableWebServer {
                    Section {
                        HStack {
                            Text("管理密码")
                            Spacer()
                            TextField("未配置", text: Binding(
                                get: { self.webServerPassword },
                                set: { newValue in
                                    self.webServerPassword = newValue
                                    UserDefaults.standard.set(newValue, forKey: "WebServerPassword")
                                }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                        }
                        
                        HStack {
                            Text("访问地址")
                            Spacer()
                            Text("http://\(webServerIP):8080")
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.accentColor)
                                .textSelection(.enabled)
                        }
                    } header: {
                        Text("访问凭证与链接")
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("远程控制", systemImage: "network")
            }
        }
        .frame(width: 480, height: 380)
        .onAppear {
            updateConnectedDisplays()
            updateBatteryState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .headlessModeStateChanged)) { _ in
            updateConnectedDisplays()
            updateBatteryState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            self.isAccessibilityTrusted = AXIsProcessTrusted()
        }
    }

    private func updateBatteryState() {
        self.batteryCapacity = BatteryManager.shared.currentCapacity
        self.batteryState = BatteryManager.shared.powerState
        self.isCharging = BatteryManager.shared.isCharging
        self.isMicrophoneMuted = MediaDeviceManager.shared.isMuted
        self.webServerIP = WebServer.shared.getLocalIPAddress()
        self.webServerPassword = UserDefaults.standard.string(forKey: "WebServerPassword") ?? ""
        self.isAccessibilityTrusted = AXIsProcessTrusted()
        self.disableKeyboardAndTrackpadInHeadless = UserDefaults.standard.bool(forKey: "DisableKeyboardAndTrackpadInHeadlessMode")
    }

    private func updateConnectedDisplays() {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return }
        
        self.connectedDisplays = displays.map { id in
            if CGDisplayIsBuiltin(id) != 0 {
                return "内置显示屏 (Color LCD)"
            } else {
                return "外接显示器 (ID: \(id))"
            }
        }
    }
}
