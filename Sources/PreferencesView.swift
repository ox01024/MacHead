import SwiftUI
import CoreGraphics

struct DisplayInfo: Hashable {
    let id: CGDirectDisplayID
    let name: String
    let isBuiltIn: Bool
    let isApple: Bool
}

struct PreferencesView: View {
    @AppStorage("AutoEnableHeadlessOnLaunch") private var autoEnableOnLaunch = true
    @AppStorage("PreventIdleSleep") private var preventIdleSleep = true
    @State private var launchAtLogin = LaunchAtLoginHelper.shared.isEnabled
    @State private var connectedDisplays: [DisplayInfo] = []
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
        VStack(spacing: 0) {
            // Header / App Branding
            HStack(spacing: 12) {
                if let appIcon = NSImage(named: NSImage.applicationIconName) {
                    Image(nsImage: appIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 44, height: 44)
                } else {
                    Image(systemName: "macmini.fill")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 40, height: 40)
                        .foregroundColor(.accentColor)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("MacHead")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("MacBook 无头工作站模式管理器")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            ScrollView {
                Form {
                    Section(header: Text("启动与运行").font(.headline)) {
                        Toggle("开机自启动", isOn: Binding(
                            get: { self.launchAtLogin },
                            set: { newValue in
                                self.launchAtLogin = newValue
                                LaunchAtLoginHelper.shared.isEnabled = newValue
                            }
                        ))
                        .help("在 Mac 开机登录时自动运行 MacHead。")
                        
                        Toggle("启动时自动进入 Headless 模式", isOn: $autoEnableOnLaunch)
                            .help("应用启动时，若检测到外接显示器则自动切断内屏并启用 Headless 模式。")
                    }
                    .padding(.bottom, 10)
                    
                    Divider()
                    
                    Section(header: Text("电源管理").font(.headline)) {
                        Toggle("防止空闲睡眠", isOn: $preventIdleSleep)
                            .help("在 Headless 模式激活期间，阻止 Mac 因长时间闲置而自动休眠。")
                    }
                    .padding(.vertical, 10)
                    
                    Divider()
                    
                    Section(header: Text("输入设备管理").font(.headline)) {
                        Toggle("有外接鼠标时禁用内置触控板", isOn: Binding(
                            get: { self.disableTrackpad },
                            set: { newValue in
                                self.disableTrackpad = newValue
                                UserDefaults.standard.set(newValue, forKey: "DisableTrackpadWhenExternalMouseConnected")
                                InputDeviceManager.shared.evaluateTrackpadAndKeyboardState()
                            }
                        ))
                        .help("检测到 USB 或蓝牙等外接鼠标连接时，自动独占内置触控板并禁用其输入。")
                        
                        Toggle("无头模式下自动禁用内置键盘和触控板", isOn: Binding(
                            get: { self.disableKeyboardAndTrackpadInHeadless },
                            set: { newValue in
                                self.disableKeyboardAndTrackpadInHeadless = newValue
                                UserDefaults.standard.set(newValue, forKey: "DisableKeyboardAndTrackpadInHeadlessMode")
                                InputDeviceManager.shared.evaluateTrackpadAndKeyboardState()
                                self.isAccessibilityTrusted = AXIsProcessTrusted()
                            }
                        ))
                        .help("合盖或进入无头工作站模式后，自动屏蔽内置键盘按键与触控板，防止误触。")
                        
                        if disableKeyboardAndTrackpadInHeadless && !isAccessibilityTrusted {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 4) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.orange)
                                    Text("未授权辅助功能权限")
                                        .font(.subheadline)
                                        .bold()
                                }
                                Text("请在“系统设置 -> 隐私与安全性 -> 辅助功能”中允许 MacHead，以使屏蔽键盘功能生效。")
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
                            .padding(.top, 4)
                        }
                    }
                    .padding(.vertical, 10)
                    
                    Divider()
                    
                    Section(header: Text("电池与电源保护").font(.headline)) {
                        HStack {
                            Text("当前电量: \(batteryCapacity)%")
                            if isCharging {
                                Image(systemName: "bolt.fill")
                                    .foregroundColor(.yellow)
                            }
                            Spacer()
                            Text(batteryState == "AC Power" ? "外接电源直供" : "电池供电中")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        
                        Toggle("启用低电量电池保护", isOn: Binding(
                            get: { self.enableBatteryProtection },
                            set: { newValue in
                                self.enableBatteryProtection = newValue
                                UserDefaults.standard.set(newValue, forKey: "EnableBatteryProtection")
                                BatteryManager.shared.handlePowerSourceChanged()
                            }
                        ))
                        .help("在电池供电且电量低于设定阈值时，自动允许系统睡眠以防电池耗尽。")
                        
                        if enableBatteryProtection {
                            HStack {
                                Text("允许休眠电量阈值: \(batteryThreshold)%")
                                Slider(value: Binding(
                                    get: { Double(self.batteryThreshold) },
                                    set: { newValue in
                                        let intVal = Int(newValue)
                                        self.batteryThreshold = intVal
                                        UserDefaults.standard.set(intVal, forKey: "BatteryThreshold")
                                        BatteryManager.shared.handlePowerSourceChanged()
                                    }
                                ), in: 10...50, step: 5)
                            }
                        }
                    }
                    .padding(.vertical, 10)
                    
                    Divider()
                    
                    Section(header: Text("多媒体设备").font(.headline)) {
                        HStack {
                            Text("麦克风状态: \(isMicrophoneMuted ? "已静音 🔇" : "正常 🎙️")")
                            Spacer()
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
                                        MediaDeviceManager.shared.forceUnmute()
                                    }
                                    self.isMicrophoneMuted = MediaDeviceManager.shared.isMuted
                                }
                            }
                        ))
                        .help("当 MacBook 进入无头模式后，自动静音系统默认的内置麦克风，退出时恢复。")
                    }
                    .padding(.vertical, 10)
                    
                    Divider()
                    
                    Section(header: Text("远程控制").font(.headline)) {
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
                        .help("开启后，允许在局域网内通过浏览器远程管理和监控您的 MacBook。")
                        
                        if enableWebServer {
                            HStack {
                                Text("管理密码:")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                TextField("管理密码", text: Binding(
                                    get: { self.webServerPassword },
                                    set: { newValue in
                                        self.webServerPassword = newValue
                                        UserDefaults.standard.set(newValue, forKey: "WebServerPassword")
                                    }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 150)
                            }
                            .padding(.vertical, 4)
                            
                            VStack(alignment: .leading, spacing: 6) {
                                Text("本地局域网访问地址:")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Text("http://\(webServerIP):8080")
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(.accentColor)
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(.vertical, 10)
                    
                    Divider()
                    
                    Section(header: Text("系统状态").font(.headline)) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("当前显示器列表:")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            
                            ForEach(connectedDisplays, id: \.self) { display in
                                HStack {
                                    Label(
                                        display.name,
                                        systemImage: display.isBuiltIn ? "laptopcomputer" : (display.isApple ? "apple.studio.display" : "display")
                                    )
                                    .font(.body)
                                }
                            }
                            
                            if connectedDisplays.isEmpty {
                                Text("未检测到显示器")
                                    .font(.body)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .padding(.top, 10)
                }
                .padding()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            Divider()
            
            // Footer
            HStack {
                Text("Version 1.0 (Build 1)")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Spacer()
                Button("关闭") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 480, height: 820)
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
            let isBuiltIn = CGDisplayIsBuiltin(id) != 0
            let vendorID = CGDisplayVendorNumber(id)
            let isApple = vendorID == 0x05AC // Apple's Vendor ID
            let name: String
            if isBuiltIn {
                name = "内置显示屏 (Color LCD)"
            } else {
                name = isApple ? "Apple 显示器 (ID: \(id))" : "外接显示器 (ID: \(id))"
            }
            return DisplayInfo(id: id, name: name, isBuiltIn: isBuiltIn, isApple: isApple)
        }
    }
}
