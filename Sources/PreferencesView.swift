import SwiftUI
import CoreGraphics

struct DisplayInfo: Hashable {
    let id: CGDirectDisplayID
    let name: String
    let isBuiltIn: Bool
    let isApple: Bool
}

enum PreferenceTab: String, CaseIterable, Identifiable {
    case general
    case hardware
    case integrations
    case status
    
    var id: String { self.rawValue }
    
    var title: String {
        switch self {
        case .general: return "常规设置"
        case .hardware: return "硬件与电源"
        case .integrations: return "集成与通知"
        case .status: return "显示器与状态"
        }
    }
    
    var iconName: String {
        switch self {
        case .general: return "gearshape.fill"
        case .hardware: return "cpu"
        case .integrations: return "network"
        case .status: return "display"
        }
    }
    
    var iconColor: Color {
        switch self {
        case .general: return .gray // Metallic grey to match native General tab, prevents blending when row is highlighted
        case .hardware: return .orange
        case .integrations: return .purple
        case .status: return .green
        }
    }
}

// Refined Card Style for Modern macOS with absolute light/dark colors
struct SettingsCard<Content: View>: View {
    @Environment(\.colorScheme) var colorScheme
    let title: String
    let content: Content
    
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium)) // Matches Apple Settings category title size
                .foregroundColor(.secondary)
                .padding(.leading, 8)
            
            VStack(alignment: .leading, spacing: 0) { // Spacing 0 for divider layout
                content
            }
            .background(colorScheme == .dark ? Color(red: 0.18, green: 0.18, blue: 0.20) : Color.white)
            .cornerRadius(10)
            .shadow(color: Color.black.opacity(0.02), radius: 1, x: 0, y: 0.5)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.04), lineWidth: 0.5)
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
    }
}

// Modern setting row styling matching macOS System Settings
struct SettingsRow<Control: View>: View {
    let title: String
    let subtitle: String?
    let control: Control
    
    init(_ title: String, subtitle: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.subtitle = subtitle
        self.control = control()
    }
    
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 38)
    }
}

struct PreferencesView: View {
    @Environment(\.colorScheme) var colorScheme
    
    @AppStorage("AutoEnableHeadlessOnLaunch") private var autoEnableOnLaunch = true
    @AppStorage("PreventIdleSleep") private var preventIdleSleep = true
    @AppStorage("KeepRunningOnLidClose") private var keepRunningOnLidClose = false
    @AppStorage("AutoExitHeadlessOnDisconnect") private var autoExitOnDisconnect = true
    @AppStorage("AutoRestoreHeadlessOnConnect") private var autoRestoreOnConnect = true
    @State private var launchAtLogin = LaunchAtLoginHelper.shared.isEnabled
    @State private var connectedDisplays: [DisplayInfo] = []
    
    // Multi-select states for built-in keyboard & trackpad disabling conditions
    @State private var disableKeyboardInHeadless = UserDefaults.standard.bool(forKey: "DisableKeyboardInHeadless")
    @State private var disableKeyboardWhenExtKeyConnected = UserDefaults.standard.bool(forKey: "DisableKeyboardWhenExternalKeyboardConnected")
    @State private var disableTrackpadInHeadless = UserDefaults.standard.bool(forKey: "DisableTrackpadInHeadless")
    @State private var disableTrackpadWhenExtMouseConnected = UserDefaults.standard.bool(forKey: "DisableTrackpadWhenExternalMouseConnected")

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
    @State private var isAccessibilityTrusted = AXIsProcessTrusted()

    // SMC metrics watcher
    @ObservedObject private var smc = SMCManager.shared

    @State private var nezhaEnabled = UserDefaults.standard.bool(forKey: "nezhaEnabled")
    @State private var nezhaServer = UserDefaults.standard.string(forKey: "nezhaServer") ?? ""
    @State private var nezhaSecret = UserDefaults.standard.string(forKey: "nezhaSecret") ?? ""
    @State private var nezhaTls = UserDefaults.standard.bool(forKey: "nezhaTls")
    @State private var nezhaStatus: NezhaStatus = NezhaAgentService.shared.currentStatus

    private var nezhaStatusColor: Color {
        switch nezhaStatus {
        case .connected: return .green
        case .connecting: return .orange
        case .error: return .red
        case .stopped: return .gray
        }
    }

    private var nezhaStatusBadgeText: String {
        switch nezhaStatus {
        case .connected: return "已连接"
        case .connecting: return "连接中..."
        case .error: return "连接失败"
        case .stopped: return "已停用"
        }
    }

    @State private var serverStatusEnabled = UserDefaults.standard.bool(forKey: "serverStatusEnabled")
    @State private var serverStatusAddr = UserDefaults.standard.string(forKey: "serverStatusAddr") ?? ""
    @State private var serverStatusUser = UserDefaults.standard.string(forKey: "serverStatusUser") ?? ""
    @State private var serverStatusPassword = UserDefaults.standard.string(forKey: "serverStatusPassword") ?? ""

    @State private var kumaEnabled = UserDefaults.standard.bool(forKey: "kumaEnabled")
    @State private var kumaPushUrl = UserDefaults.standard.string(forKey: "kumaPushUrl") ?? ""
    @State private var kumaInterval = UserDefaults.standard.double(forKey: "kumaInterval") == 0 ? 60.0 : UserDefaults.standard.double(forKey: "kumaInterval")

    @State private var notificationsEnabled = UserDefaults.standard.bool(forKey: "notificationsEnabled")
    @State private var barkEnabled = UserDefaults.standard.bool(forKey: "barkEnabled")
    @State private var barkKey = UserDefaults.standard.string(forKey: "barkKey") ?? ""
    @State private var telegramEnabled = UserDefaults.standard.bool(forKey: "telegramEnabled")
    @State private var telegramBotToken = UserDefaults.standard.string(forKey: "telegramBotToken") ?? ""
    @State private var telegramChatId = UserDefaults.standard.string(forKey: "telegramChatId") ?? ""
    @State private var overheatAlertEnabled = UserDefaults.standard.bool(forKey: "overheatAlertEnabled")
    @State private var overheatThreshold = UserDefaults.standard.double(forKey: "overheatThreshold") == 0 ? 85.0 : UserDefaults.standard.double(forKey: "overheatThreshold")

    @State private var selectedTab = PreferenceTab.general

    // Modals visibility states for Switch + Button (设定...) sheets
    @State private var showWebServerConfig = false
    @State private var showOverheatConfig = false
    @State private var showNotificationsConfig = false
    @State private var showNezhaConfig = false
    @State private var showServerStatusConfig = false
    @State private var showKumaConfig = false
    @State private var showBatteryConfig = false

    private var detailBackgroundColor: Color {
        colorScheme == .dark ? Color(red: 0.11, green: 0.11, blue: 0.12) : Color(red: 0.957, green: 0.957, blue: 0.965)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left Sidebar (Stretches to top bounds, utilizes native List styling)
            VStack(alignment: .leading, spacing: 0) {
                // Sidebar Header
                HStack(spacing: 8) {
                    if let appIcon = NSImage(named: NSImage.applicationIconName) {
                        Image(nsImage: appIcon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 32, height: 32)
                    } else {
                        Image(systemName: "macmini.fill")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 28, height: 28)
                            .foregroundColor(.accentColor)
                    }
                    
                    VStack(alignment: .leading, spacing: 1) {
                        Text("MacHead")
                            .font(.headline)
                            .fontWeight(.bold)
                        Text("v\(UpdateManager.shared.currentVersion)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 52) // Offset for traffic lights
                .padding(.bottom, 16)
                
                // Sidebar List with native highlights and selection capsule
                List(selection: $selectedTab) {
                    ForEach(PreferenceTab.allCases) { tab in
                        HStack(spacing: 8) {
                            Image(systemName: tab.iconName)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 20, height: 20)
                                .background(tab.iconColor.gradient)
                                .cornerRadius(5)
                            
                            Text(tab.title)
                                .font(.body)
                        }
                        .tag(tab)
                        .frame(height: 28)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                
                Spacer()
                
                // Sidebar Footer (Updates)
                VStack(alignment: .leading, spacing: 2) {
                    Button(action: {
                        UpdateManager.shared.checkForUpdates(silent: false)
                    }) {
                        Text("检查更新...")
                            .foregroundColor(.accentColor)
                            .font(.footnote)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
            .frame(width: 180)
            .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow))
            
            // Right Details Panel (Solid system color, stretches to Y=0 top bounds)
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        
                        // Active Section Title matching Apple native settings page headers
                        Text(selectedTab.title)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.primary)
                            .padding(.leading, 8)
                            .padding(.top, 48) // Aligns perfectly with left sidebar content top offset
                            .padding(.bottom, 4)
                        
                        switch selectedTab {
                        case .general:
                            SettingsCard(title: "启动与运行") {
                                SettingsRow("开机自启动") {
                                    Toggle("", isOn: Binding(
                                        get: { self.launchAtLogin },
                                        set: { newValue in
                                            self.launchAtLogin = newValue
                                            LaunchAtLoginHelper.shared.isEnabled = newValue
                                        }
                                    ))
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                                }
                                
                                Divider().padding(.horizontal, 16)
                                
                                SettingsRow("启动时自动进入无头模式") {
                                    Toggle("", isOn: $autoEnableOnLaunch)
                                        .toggleStyle(.switch)
                                        .labelsHidden()
                                }
                            }
                            
                            SettingsCard(title: "局域网远程控制") {
                                SettingsRow("启用局域网 Web 控制面板") {
                                    HStack(spacing: 12) {
                                        Toggle("", isOn: Binding(
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
                                        .toggleStyle(.switch)
                                        .labelsHidden()
                                        
                                        Button("设定...") {
                                            self.showWebServerConfig = true
                                        }
                                    }
                                }
                            }
                            
                        case .hardware:
                            SettingsCard(title: "电源管理") {
                                SettingsRow("防止空闲睡眠") {
                                    Toggle("", isOn: Binding(
                                        get: { self.preventIdleSleep },
                                        set: { newValue in
                                            self.preventIdleSleep = newValue
                                            HeadlessModeController.shared.evaluatePowerAssertion()
                                        }
                                    ))
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                                }
                                
                                Divider().padding(.horizontal, 16)
                                
                                SettingsRow("合盖后仍然保持运行状态") {
                                    Toggle("", isOn: Binding(
                                        get: { self.keepRunningOnLidClose },
                                        set: { newValue in
                                            self.keepRunningOnLidClose = newValue
                                            HeadlessModeController.shared.evaluatePowerAssertion()
                                        }
                                    ))
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                                }
                            }
                            
                            SettingsCard(title: "输入设备保护") {
                                SettingsRow("禁用内置键盘") {
                                    HStack(spacing: 16) {
                                        Toggle("无头模式下", isOn: Binding(
                                            get: { self.disableKeyboardInHeadless },
                                            set: { newValue in
                                                self.disableKeyboardInHeadless = newValue
                                                UserDefaults.standard.set(newValue, forKey: "DisableKeyboardInHeadless")
                                                InputDeviceManager.shared.evaluateTrackpadAndKeyboardState()
                                                self.isAccessibilityTrusted = AXIsProcessTrusted()
                                            }
                                        ))
                                        .toggleStyle(.checkbox)
                                        
                                        Toggle("外接键盘下", isOn: Binding(
                                            get: { self.disableKeyboardWhenExtKeyConnected },
                                            set: { newValue in
                                                self.disableKeyboardWhenExtKeyConnected = newValue
                                                UserDefaults.standard.set(newValue, forKey: "DisableKeyboardWhenExternalKeyboardConnected")
                                                InputDeviceManager.shared.evaluateTrackpadAndKeyboardState()
                                                self.isAccessibilityTrusted = AXIsProcessTrusted()
                                            }
                                        ))
                                        .toggleStyle(.checkbox)
                                    }
                                }
                                
                                Divider().padding(.horizontal, 16)
                                
                                SettingsRow("禁用内置触控板") {
                                    HStack(spacing: 16) {
                                        Toggle("无头模式下", isOn: Binding(
                                            get: { self.disableTrackpadInHeadless },
                                            set: { newValue in
                                                self.disableTrackpadInHeadless = newValue
                                                UserDefaults.standard.set(newValue, forKey: "DisableTrackpadInHeadless")
                                                InputDeviceManager.shared.evaluateTrackpadAndKeyboardState()
                                            }
                                        ))
                                        .toggleStyle(.checkbox)
                                        
                                        Toggle("外接鼠标下", isOn: Binding(
                                            get: { self.disableTrackpadWhenExtMouseConnected },
                                            set: { newValue in
                                                self.disableTrackpadWhenExtMouseConnected = newValue
                                                UserDefaults.standard.set(newValue, forKey: "DisableTrackpadWhenExternalMouseConnected")
                                                InputDeviceManager.shared.evaluateTrackpadAndKeyboardState()
                                            }
                                        ))
                                        .toggleStyle(.checkbox)
                                    }
                                }
                                
                                if (disableKeyboardInHeadless || disableKeyboardWhenExtKeyConnected) && !isAccessibilityTrusted {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "exclamationmark.triangle.fill")
                                                .foregroundColor(.orange)
                                            Text("未授权辅助功能权限")
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
                                        .buttonStyle(.plain)
                                        .foregroundColor(.accentColor)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 12)
                                }
                            }
                            
                            SettingsCard(title: "电池保护与睡眠") {
                                SettingsRow("启用低电量电池保护") {
                                    HStack(spacing: 12) {
                                        Toggle("", isOn: Binding(
                                            get: { self.enableBatteryProtection },
                                            set: { newValue in
                                                self.enableBatteryProtection = newValue
                                                UserDefaults.standard.set(newValue, forKey: "EnableBatteryProtection")
                                                BatteryManager.shared.handlePowerSourceChanged()
                                            }
                                        ))
                                        .toggleStyle(.switch)
                                        .labelsHidden()
                                        
                                        Button("设定...") {
                                            self.showBatteryConfig = true
                                        }
                                    }
                                }
                            }
                            
                            SettingsCard(title: "多媒体设备") {
                                SettingsRow("内置麦克风状态") {
                                    Text(isMicrophoneMuted ? "已静音 🔇" : "正常 🎙️")
                                        .fontWeight(.medium)
                                }
                                
                                Divider().padding(.horizontal, 16)
                                
                                SettingsRow("无头模式下自动静音内置麦克风") {
                                    Toggle("", isOn: Binding(
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
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                                }
                            }
                            
                        case .integrations:
                            SettingsCard(title: "系统硬件监控 & 告警") {
                                SettingsRow("当前芯片温度") {
                                    Text(String(format: "%.1f°C", smc.currentTemperature))
                                        .fontWeight(.semibold)
                                        .foregroundColor(smc.currentTemperature >= overheatThreshold ? .red : .primary)
                                }
                                
                                Divider().padding(.horizontal, 16)
                                
                                SettingsRow("当前风扇转速") {
                                    Text(smc.isFanless ? "无风扇 (被动散热)" : (smc.fanSpeed > 0 ? "\(smc.fanSpeed) RPM" : "正常 (系统自动控制)"))
                                        .fontWeight(.semibold)
                                }
                                
                                Divider().padding(.horizontal, 16)
                                
                                SettingsRow("启用芯片过热报警") {
                                    HStack(spacing: 12) {
                                        Toggle("", isOn: Binding(
                                            get: { self.overheatAlertEnabled },
                                            set: { newValue in
                                                self.overheatAlertEnabled = newValue
                                                UserDefaults.standard.set(newValue, forKey: "overheatAlertEnabled")
                                            }
                                        ))
                                        .toggleStyle(.switch)
                                        .labelsHidden()
                                        
                                        Button("设定...") {
                                            self.showOverheatConfig = true
                                        }
                                    }
                                }
                                
                                Divider().padding(.horizontal, 16)
                                
                                SettingsRow("启用消息推送通道") {
                                    HStack(spacing: 12) {
                                        Toggle("", isOn: Binding(
                                            get: { self.notificationsEnabled },
                                            set: { newValue in
                                                self.notificationsEnabled = newValue
                                                UserDefaults.standard.set(newValue, forKey: "notificationsEnabled")
                                            }
                                        ))
                                        .toggleStyle(.switch)
                                        .labelsHidden()
                                        
                                        Button("设定...") {
                                            self.showNotificationsConfig = true
                                        }
                                    }
                                }
                            }
                            
                            SettingsCard(title: "哪吒监控 & ServerStatus 探针") {
                                SettingsRow("启用哪吒监控 (Nezha Agent)") {
                                    HStack(spacing: 10) {
                                        if nezhaEnabled {
                                            HStack(spacing: 4) {
                                                Circle()
                                                    .fill(nezhaStatusColor)
                                                    .frame(width: 6, height: 6)
                                                Text(nezhaStatusBadgeText)
                                                    .font(.caption2)
                                                    .fontWeight(.medium)
                                                    .foregroundColor(nezhaStatusColor)
                                            }
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(nezhaStatusColor.opacity(0.12))
                                            .cornerRadius(5)
                                        }

                                        Toggle("", isOn: Binding(
                                            get: { self.nezhaEnabled },
                                            set: { newValue in
                                                self.nezhaEnabled = newValue
                                                UserDefaults.standard.set(newValue, forKey: "nezhaEnabled")
                                                if newValue {
                                                    NezhaAgentService.shared.start()
                                                } else {
                                                    NezhaAgentService.shared.stop()
                                                }
                                            }
                                        ))
                                        .toggleStyle(.switch)
                                        .labelsHidden()
                                        
                                        Button("设定...") {
                                            self.showNezhaConfig = true
                                        }
                                    }
                                }
                                
                                Divider().padding(.horizontal, 16)
                                
                                SettingsRow("启用 ServerStatus 客户端") {
                                    HStack(spacing: 12) {
                                        Toggle("", isOn: Binding(
                                            get: { self.serverStatusEnabled },
                                            set: { newValue in
                                                self.serverStatusEnabled = newValue
                                                UserDefaults.standard.set(newValue, forKey: "serverStatusEnabled")
                                                if newValue {
                                                    ServerStatusService.shared.start()
                                                } else {
                                                    ServerStatusService.shared.stop()
                                                }
                                            }
                                        ))
                                        .toggleStyle(.switch)
                                        .labelsHidden()
                                        
                                        Button("设定...") {
                                            self.showServerStatusConfig = true
                                        }
                                    }
                                }
                            }
                            
                            SettingsCard(title: "Uptime Kuma 心跳打卡") {
                                SettingsRow("启用 Uptime Kuma 推送") {
                                    HStack(spacing: 12) {
                                        Toggle("", isOn: Binding(
                                            get: { self.kumaEnabled },
                                            set: { newValue in
                                                self.kumaEnabled = newValue
                                                UserDefaults.standard.set(newValue, forKey: "kumaEnabled")
                                                if newValue {
                                                    UptimeKumaService.shared.start()
                                                } else {
                                                    UptimeKumaService.shared.stop()
                                                }
                                            }
                                        ))
                                        .toggleStyle(.switch)
                                        .labelsHidden()
                                        
                                        Button("设定...") {
                                            self.showKumaConfig = true
                                        }
                                    }
                                }
                            }
                            
                        case .status:
                            SettingsCard(title: "显示器与 Headless 守护策略") {
                                SettingsRow("断开全部外屏时自动恢复内屏") {
                                    Toggle("", isOn: $autoExitOnDisconnect)
                                        .toggleStyle(.switch)
                                        .labelsHidden()
                                }
                                
                                Divider().padding(.horizontal, 16)
                                
                                SettingsRow("接入外屏时自动进入无头模式") {
                                    Toggle("", isOn: $autoRestoreOnConnect)
                                        .toggleStyle(.switch)
                                        .labelsHidden()
                                }
                            }
                            
                            SettingsCard(title: "当前连接的显示器") {
                                if connectedDisplays.isEmpty {
                                    SettingsRow("未检测到有效显示器") {
                                        Text("无")
                                            .foregroundColor(.secondary)
                                    }
                                } else {
                                    VStack(alignment: .leading, spacing: 0) {
                                        ForEach(Array(connectedDisplays.enumerated()), id: \.offset) { index, display in
                                            if index > 0 {
                                                Divider().padding(.horizontal, 16)
                                            }
                                            SettingsRow(display.name) {
                                                Image(systemName: display.isBuiltIn ? "laptopcomputer" : (display.isApple ? "apple.studio.display" : "display"))
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
                .background(detailBackgroundColor)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(detailBackgroundColor)
        }
        .ignoresSafeArea()
        .frame(width: 680, height: 580)
        
        // ------------------ Web控制面板配置弹窗 ------------------
        .sheet(isPresented: $showWebServerConfig) {
            VStack(alignment: .leading, spacing: 16) {
                Text("局域网 Web 控制面板配置")
                    .font(.headline)
                    .fontWeight(.bold)
                
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("管理密码:")
                            .foregroundColor(.secondary)
                            .frame(width: 80, alignment: .leading)
                        TextField("设置密码", text: Binding(
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
                        Text("访问地址:")
                            .foregroundColor(.secondary)
                            .frame(width: 80, alignment: .leading)
                        Text("http://\(webServerIP):8080")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.accentColor)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 8)
                
                Spacer()
                
                HStack {
                    Spacer()
                    Button("完成") {
                        self.showWebServerConfig = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 380, height: 180)
        }
        
        // ------------------ 电池休眠保护配置弹窗 ------------------
        .sheet(isPresented: $showBatteryConfig) {
            VStack(alignment: .leading, spacing: 16) {
                Text("低电量电池保护配置")
                    .font(.headline)
                    .fontWeight(.bold)
                
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("当前电量:")
                            .foregroundColor(.secondary)
                            .frame(width: 90, alignment: .leading)
                        Text("\(batteryCapacity)%")
                            .fontWeight(.semibold)
                    }
                    
                    HStack {
                        Text("电源状态:")
                            .foregroundColor(.secondary)
                            .frame(width: 90, alignment: .leading)
                        Text(batteryState == "AC Power" ? "外接电源直供" : "电池供电中")
                            .fontWeight(.medium)
                    }
                    
                    HStack {
                        Text("休眠电量阈值:")
                            .foregroundColor(.secondary)
                            .frame(width: 90, alignment: .leading)
                        Slider(value: Binding(
                            get: { Double(self.batteryThreshold) },
                            set: { newValue in
                                let intVal = Int(newValue)
                                self.batteryThreshold = intVal
                                UserDefaults.standard.set(intVal, forKey: "BatteryThreshold")
                                BatteryManager.shared.handlePowerSourceChanged()
                            }
                        ), in: 10...50, step: 5)
                        .frame(width: 160)
                        
                        Text("\(batteryThreshold)%")
                            .fontWeight(.bold)
                    }
                }
                .padding(.vertical, 8)
                
                Spacer()
                
                HStack {
                    Spacer()
                    Button("完成") {
                        self.showBatteryConfig = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 380, height: 220)
        }
        
        // ------------------ SMC 过热温度报警配置弹窗 ------------------
        .sheet(isPresented: $showOverheatConfig) {
            VStack(alignment: .leading, spacing: 16) {
                Text("芯片过热报警配置")
                    .font(.headline)
                    .fontWeight(.bold)
                
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("当前温度:")
                            .foregroundColor(.secondary)
                            .frame(width: 90, alignment: .leading)
                        Text(String(format: "%.1f°C", smc.currentTemperature))
                            .fontWeight(.semibold)
                            .foregroundColor(smc.currentTemperature >= overheatThreshold ? .red : .primary)
                    }
                    
                    HStack {
                        Text("报警温度阈值:")
                            .foregroundColor(.secondary)
                            .frame(width: 90, alignment: .leading)
                        Slider(value: Binding(
                            get: { self.overheatThreshold },
                            set: { newValue in
                                self.overheatThreshold = newValue
                                UserDefaults.standard.set(newValue, forKey: "overheatThreshold")
                            }
                        ), in: 60...95, step: 5)
                        .frame(width: 160)
                        
                        Text("\(Int(overheatThreshold))°C")
                            .fontWeight(.bold)
                    }
                }
                .padding(.vertical, 8)
                
                Spacer()
                
                HStack {
                    Spacer()
                    Button("完成") {
                        self.showOverheatConfig = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 380, height: 200)
        }
        
        // ------------------ 推送通道集成配置弹窗 ------------------
        .sheet(isPresented: $showNotificationsConfig) {
            VStack(alignment: .leading, spacing: 16) {
                Text("消息推送通道配置")
                    .font(.headline)
                    .fontWeight(.bold)
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Toggle("启用 Bark 推送 (iOS)", isOn: Binding(
                                    get: { self.barkEnabled },
                                    set: { newValue in
                                        self.barkEnabled = newValue
                                        UserDefaults.standard.set(newValue, forKey: "barkEnabled")
                                    }
                                ))
                                .toggleStyle(.switch)
                                Spacer()
                            }
                            
                            if barkEnabled {
                                HStack {
                                    Text("Bark Key:")
                                        .foregroundColor(.secondary)
                                        .frame(width: 80, alignment: .leading)
                                    TextField("填入 Bark Device Key", text: Binding(
                                        get: { self.barkKey },
                                        set: { newValue in
                                            self.barkKey = newValue
                                            UserDefaults.standard.set(newValue, forKey: "barkKey")
                                        }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                }
                                .padding(.leading, 12)
                            }
                        }
                        
                        Divider()
                        
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Toggle("启用 Telegram Bot 推送", isOn: Binding(
                                    get: { self.telegramEnabled },
                                    set: { newValue in
                                        self.telegramEnabled = newValue
                                        UserDefaults.standard.set(newValue, forKey: "telegramEnabled")
                                    }
                                ))
                                .toggleStyle(.switch)
                                Spacer()
                            }
                            
                            if telegramEnabled {
                                VStack(spacing: 8) {
                                    HStack {
                                        Text("Bot Token:")
                                            .foregroundColor(.secondary)
                                            .frame(width: 80, alignment: .leading)
                                        TextField("填入 Bot Token", text: Binding(
                                            get: { self.telegramBotToken },
                                            set: { newValue in
                                                self.telegramBotToken = newValue
                                                UserDefaults.standard.set(newValue, forKey: "telegramBotToken")
                                            }
                                        ))
                                        .textFieldStyle(.roundedBorder)
                                    }
                                    
                                    HStack {
                                        Text("Chat ID:")
                                            .foregroundColor(.secondary)
                                            .frame(width: 80, alignment: .leading)
                                        TextField("填入 Chat ID", text: Binding(
                                            get: { self.telegramChatId },
                                            set: { newValue in
                                                self.telegramChatId = newValue
                                                UserDefaults.standard.set(newValue, forKey: "telegramChatId")
                                            }
                                        ))
                                        .textFieldStyle(.roundedBorder)
                                    }
                                }
                                .padding(.leading, 12)
                            }
                        }
                        
                        Divider()
                        
                        HStack {
                            Button("发送测试通知") {
                                NotificationService.shared.sendAlert(type: .test, title: "连接测试", body: "这是一条来自 MacHead 的集成状态测试通知，连接正常！", force: true)
                            }
                            .buttonStyle(.bordered)
                            Spacer()
                        }
                    }
                    .padding(.vertical, 4)
                }
                
                Spacer()
                
                HStack {
                    Spacer()
                    Button("完成") {
                        self.showNotificationsConfig = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 400, height: 380)
        }
        
        // ------------------ 哪吒监控配置弹窗 ------------------
        .sheet(isPresented: $showNezhaConfig) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("哪吒监控配置")
                        .font(.headline)
                        .fontWeight(.bold)
                    Spacer()
                    Button("测试重新连接") {
                        IntegrationManager.shared.reloadServices()
                    }
                    .controlSize(.small)
                }
                
                // 实时诊断卡片
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(nezhaStatusColor)
                            .frame(width: 8, height: 8)
                        Text("当前状态:")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Text(nezhaStatusBadgeText)
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(nezhaStatusColor)
                    }
                    
                    Text(nezhaStatus.displayText)
                        .font(.caption2)
                        .foregroundColor(nezhaStatusColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(nezhaStatusColor.opacity(0.1))
                .cornerRadius(8)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("面板地址:")
                            .foregroundColor(.secondary)
                            .frame(width: 80, alignment: .leading)
                        TextField("host:port (如 104.223.55.31:8008)", text: $nezhaServer)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                            .onChange(of: nezhaServer) { newValue in
                                UserDefaults.standard.set(newValue, forKey: "nezhaServer")
                            }
                    }
                    
                    HStack {
                        Text("连接密钥:")
                            .foregroundColor(.secondary)
                            .frame(width: 80, alignment: .leading)
                        SecureField("Secret Key", text: $nezhaSecret)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                            .onChange(of: nezhaSecret) { newValue in
                                UserDefaults.standard.set(newValue, forKey: "nezhaSecret")
                            }
                    }
                    
                    HStack {
                        Text("安全传输:")
                            .foregroundColor(.secondary)
                            .frame(width: 80, alignment: .leading)
                        Toggle("启用 SSL/TLS 加密", isOn: $nezhaTls)
                            .toggleStyle(.switch)
                            .onChange(of: nezhaTls) { newValue in
                                UserDefaults.standard.set(newValue, forKey: "nezhaTls")
                            }
                    }
                }
                .padding(.vertical, 4)
                
                Spacer()
                
                HStack {
                    Spacer()
                    Button("完成") {
                        IntegrationManager.shared.reloadServices()
                        self.showNezhaConfig = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 440, height: 380)
        }
        
        // ------------------ ServerStatus 配置弹窗 ------------------
        .sheet(isPresented: $showServerStatusConfig) {
            VStack(alignment: .leading, spacing: 16) {
                Text("ServerStatus 客户端配置")
                    .font(.headline)
                    .fontWeight(.bold)
                
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("服务端地址:")
                            .foregroundColor(.secondary)
                            .frame(width: 90, alignment: .leading)
                        TextField("grpc://host:port", text: Binding(
                            get: { self.serverStatusAddr },
                            set: { newValue in
                                self.serverStatusAddr = newValue
                                UserDefaults.standard.set(newValue, forKey: "serverStatusAddr")
                                IntegrationManager.shared.reloadServices()
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                    }
                    
                    HStack {
                        Text("主机用户名:")
                            .foregroundColor(.secondary)
                            .frame(width: 90, alignment: .leading)
                        TextField("User ID", text: Binding(
                            get: { self.serverStatusUser },
                            set: { newValue in
                                self.serverStatusUser = newValue
                                UserDefaults.standard.set(newValue, forKey: "serverStatusUser")
                                IntegrationManager.shared.reloadServices()
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                    }
                    
                    HStack {
                        Text("连接密码:")
                            .foregroundColor(.secondary)
                            .frame(width: 90, alignment: .leading)
                        SecureField("Password", text: Binding(
                            get: { self.serverStatusPassword },
                            set: { newValue in
                                self.serverStatusPassword = newValue
                                UserDefaults.standard.set(newValue, forKey: "serverStatusPassword")
                                IntegrationManager.shared.reloadServices()
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                    }
                }
                .padding(.vertical, 8)
                
                Spacer()
                
                HStack {
                    Spacer()
                    Button("完成") {
                        self.showServerStatusConfig = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 380, height: 240)
        }
        
        // ------------------ Uptime Kuma 配置弹窗 ------------------
        .sheet(isPresented: $showKumaConfig) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Uptime Kuma 推送配置")
                    .font(.headline)
                    .fontWeight(.bold)
                
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("推送 URL:")
                            .foregroundColor(.secondary)
                            .frame(width: 80, alignment: .leading)
                        TextField("http(s)://...", text: Binding(
                            get: { self.kumaPushUrl },
                            set: { newValue in
                                self.kumaPushUrl = newValue
                                UserDefaults.standard.set(newValue, forKey: "kumaPushUrl")
                                IntegrationManager.shared.reloadServices()
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                    }
                    
                    HStack {
                        Text("汇报间隔:")
                            .foregroundColor(.secondary)
                            .frame(width: 80, alignment: .leading)
                        Slider(value: Binding(
                            get: { self.kumaInterval },
                            set: { newValue in
                                self.kumaInterval = newValue
                                UserDefaults.standard.set(newValue, forKey: "kumaInterval")
                                IntegrationManager.shared.reloadServices()
                            }
                        ), in: 10...300, step: 10)
                        .frame(width: 160)
                        
                        Text("\(Int(kumaInterval)) 秒")
                            .fontWeight(.bold)
                    }
                }
                .padding(.vertical, 8)
                
                Spacer()
                
                HStack {
                    Spacer()
                    Button("完成") {
                        self.showKumaConfig = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 380, height: 200)
        }
        .onAppear {
            updateConnectedDisplays()
            updateBatteryState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .headlessModeStateChanged)) { _ in
            updateConnectedDisplays()
            updateBatteryState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .nezhaStatusChanged)) { notif in
            if let status = notif.object as? NezhaStatus {
                self.nezhaStatus = status
            }
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
        
        self.disableKeyboardInHeadless = UserDefaults.standard.bool(forKey: "DisableKeyboardInHeadless")
        self.disableKeyboardWhenExtKeyConnected = UserDefaults.standard.bool(forKey: "DisableKeyboardWhenExternalKeyboardConnected")
        self.disableTrackpadInHeadless = UserDefaults.standard.bool(forKey: "DisableTrackpadInHeadless")
        self.disableTrackpadWhenExtMouseConnected = UserDefaults.standard.bool(forKey: "DisableTrackpadWhenExternalMouseConnected")
        
        // Sync integrations states
        self.nezhaEnabled = UserDefaults.standard.bool(forKey: "nezhaEnabled")
        self.nezhaServer = UserDefaults.standard.string(forKey: "nezhaServer") ?? ""
        self.nezhaSecret = UserDefaults.standard.string(forKey: "nezhaSecret") ?? ""
        self.nezhaTls = UserDefaults.standard.bool(forKey: "nezhaTls")
        self.nezhaStatus = NezhaAgentService.shared.currentStatus
        
        self.serverStatusEnabled = UserDefaults.standard.bool(forKey: "serverStatusEnabled")
        self.serverStatusAddr = UserDefaults.standard.string(forKey: "serverStatusAddr") ?? ""
        self.serverStatusUser = UserDefaults.standard.string(forKey: "serverStatusUser") ?? ""
        self.serverStatusPassword = UserDefaults.standard.string(forKey: "serverStatusPassword") ?? ""
        
        self.kumaEnabled = UserDefaults.standard.bool(forKey: "kumaEnabled")
        self.kumaPushUrl = UserDefaults.standard.string(forKey: "kumaPushUrl") ?? ""
        self.kumaInterval = UserDefaults.standard.double(forKey: "kumaInterval") == 0 ? 60.0 : UserDefaults.standard.double(forKey: "kumaInterval")
        
        self.notificationsEnabled = UserDefaults.standard.bool(forKey: "notificationsEnabled")
        self.barkEnabled = UserDefaults.standard.bool(forKey: "barkEnabled")
        self.barkKey = UserDefaults.standard.string(forKey: "barkKey") ?? ""
        self.telegramEnabled = UserDefaults.standard.bool(forKey: "telegramEnabled")
        self.telegramBotToken = UserDefaults.standard.string(forKey: "telegramBotToken") ?? ""
        self.telegramChatId = MapKeysToString(UserDefaults.standard.string(forKey: "telegramChatId"))
        self.overheatAlertEnabled = UserDefaults.standard.bool(forKey: "overheatAlertEnabled")
        self.overheatThreshold = UserDefaults.standard.double(forKey: "overheatThreshold") == 0 ? 85.0 : UserDefaults.standard.double(forKey: "overheatThreshold")
    }
    
    private func MapKeysToString(_ val: String?) -> String {
        return val ?? ""
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

// SwiftUI VisualEffectView helper for macOS background styling
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
