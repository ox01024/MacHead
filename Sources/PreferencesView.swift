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
    case power
    case hardware
    case integrations
    case tunneling
    case status

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .general: return L("常规设置", "General")
        case .power: return L("电池", "Battery")
        case .hardware: return L("硬件与外设", "Hardware & Peripherals")
        case .integrations: return L("监控与通知", "Monitoring & Alerts")
        case .tunneling: return L("内网穿透", "Tunneling")
        case .status: return L("显示器与状态", "Displays & Status")
        }
    }

    var iconName: String {
        switch self {
        case .general: return "gearshape.fill"
        case .power: return "battery.100"
        case .hardware: return "keyboard.fill"
        case .integrations: return "bell.badge.fill"
        case .tunneling: return "arrow.left.arrow.right"
        case .status: return "display.2"
        }
    }

    var iconColor: Color {
        switch self {
        case .general: return .gray // Metallic grey to match native General tab, prevents blending when row is highlighted
        case .power: return .green
        case .hardware: return .orange
        case .integrations: return .purple
        case .tunneling: return .blue
        case .status: return .teal
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
    
    @AppStorage("AutoEnableHeadlessOnLaunch") private var autoEnableOnLaunch = false
    @AppStorage("PreventIdleSleep") private var preventIdleSleep = true
    @AppStorage("KeepRunningOnLidClose") private var keepRunningOnLidClose = false
    @AppStorage("AutoExitHeadlessOnDisconnect") private var autoExitOnDisconnect = true
    @AppStorage("AutoRestoreHeadlessOnConnect") private var autoRestoreOnConnect = true
    @State private var launchAtLogin = LaunchAtLoginHelper.shared.isEnabled
    @AppStorage(CLIToolInstaller.defaultsKey) private var cliToolEnabled = false
    @AppStorage("telemetryEnabled") private var telemetryEnabled = true
    @State private var connectedDisplays: [DisplayInfo] = []
    
    // Multi-select states for built-in keyboard & trackpad disabling conditions
    @State private var disableKeyboardInHeadless = UserDefaults.standard.bool(forKey: "DisableKeyboardInHeadless")
    @State private var disableKeyboardWhenExtKeyConnected = UserDefaults.standard.bool(forKey: "DisableKeyboardWhenExternalKeyboardConnected")
    @State private var disableTrackpadInHeadless = UserDefaults.standard.bool(forKey: "DisableTrackpadInHeadless")
    @State private var disableTrackpadWhenExtMouseConnected = UserDefaults.standard.bool(forKey: "DisableTrackpadWhenExternalMouseConnected")

    @State private var enableBatteryProtection = UserDefaults.standard.bool(forKey: "EnableBatteryProtection")
    @State private var batteryThreshold = UserDefaults.standard.integer(forKey: "BatteryThreshold") == 0 ? 20 : UserDefaults.standard.integer(forKey: "BatteryThreshold")
    @State private var muteMicrophone = UserDefaults.standard.bool(forKey: "MuteMicrophoneInHeadlessMode")
    @State private var isMicrophoneMuted = MediaDeviceManager.shared.isMuted
    @State private var enableWebServer = UserDefaults.standard.bool(forKey: "EnableWebServer")
    @State private var webServerIP = WebServer.shared.getLocalIPAddress()
    @State private var webServerPassword = UserDefaults.standard.string(forKey: "WebServerPassword") ?? ""
    @State private var webServerPort = String(WebServer.shared.currentPort)
    @State private var isAccessibilityTrusted = AXIsProcessTrusted()

    // Hardware & Battery metrics watchers
    @ObservedObject private var l10n = LocalizationManager.shared
    @ObservedObject private var smc = SMCManager.shared
    @ObservedObject private var battery = BatteryManager.shared
    @ObservedObject private var remoteSharing = RemoteSharingService.shared

    @State private var copiedServiceHint: String? = nil

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
        case .connected: return L("已连接", "Connected")
        case .connecting: return L("连接中...", "Connecting...")
        case .error: return L("连接失败", "Failed")
        case .stopped: return L("已停用", "Disabled")
        }
    }

    @State private var serverStatusEnabled = UserDefaults.standard.bool(forKey: "serverStatusEnabled")
    @State private var serverStatusAddr = UserDefaults.standard.string(forKey: "serverStatusAddr") ?? ""
    @State private var serverStatusUser = UserDefaults.standard.string(forKey: "serverStatusUser") ?? ""
    @State private var serverStatusPassword = UserDefaults.standard.string(forKey: "serverStatusPassword") ?? ""

    @State private var kumaEnabled = UserDefaults.standard.bool(forKey: "kumaEnabled")
    @State private var kumaPushUrl = UserDefaults.standard.string(forKey: "kumaPushUrl") ?? ""
    @State private var kumaInterval = UserDefaults.standard.double(forKey: "kumaInterval") == 0 ? 60.0 : UserDefaults.standard.double(forKey: "kumaInterval")

    @State private var frpEnabled = UserDefaults.standard.bool(forKey: "frpEnabled")
    @State private var frpMode = UserDefaults.standard.string(forKey: "frpMode") ?? "quick"
    @State private var frpServerAddr = UserDefaults.standard.string(forKey: "frpServerAddr") ?? ""
    @State private var frpServerPort = UserDefaults.standard.string(forKey: "frpServerPort") ?? "7000"
    @State private var frpToken = UserDefaults.standard.string(forKey: "frpToken") ?? ""
    @State private var frpProxyName = UserDefaults.standard.string(forKey: "frpProxyName") ?? "machead-ssh"
    @State private var frpProxyType = UserDefaults.standard.string(forKey: "frpProxyType") ?? "tcp"
    @State private var frpLocalIP = UserDefaults.standard.string(forKey: "frpLocalIP") ?? "127.0.0.1"
    @State private var frpLocalPort = UserDefaults.standard.string(forKey: "frpLocalPort") ?? "22"
    @State private var frpRemotePort = UserDefaults.standard.string(forKey: "frpRemotePort") ?? "6022"
    @State private var frpCustomDomains = UserDefaults.standard.string(forKey: "frpCustomDomains") ?? ""
    @State private var frpSubdomain = UserDefaults.standard.string(forKey: "frpSubdomain") ?? ""
    @State private var frpCustomConfig = UserDefaults.standard.string(forKey: "frpCustomConfig") ?? ""
    @State private var frpStatus: FrpStatus = FrpService.shared.currentStatus
    @State private var frpRules: [FrpProxyRule] = FrpService.loadRules()
    @State private var frpBinaryPath = UserDefaults.standard.string(forKey: "frpBinaryPath") ?? ""

    private var frpStatusColor: Color {
        switch frpStatus {
        case .connected: return .green
        case .connecting: return .orange
        case .error: return .red
        case .stopped: return .gray
        }
    }

    private var frpStatusBadgeText: String {
        switch frpStatus {
        case .connected: return L("已连接", "Connected")
        case .connecting: return L("连接中...", "Connecting...")
        case .error: return L("连接失败", "Failed")
        case .stopped: return L("已停用", "Disabled")
        }
    }

    @State private var notificationsEnabled = UserDefaults.standard.bool(forKey: "notificationsEnabled")
    @State private var barkEnabled = UserDefaults.standard.bool(forKey: "barkEnabled")
    @State private var barkKey = UserDefaults.standard.string(forKey: "barkKey") ?? ""
    @State private var telegramEnabled = UserDefaults.standard.bool(forKey: "telegramEnabled")
    @State private var telegramBotToken = UserDefaults.standard.string(forKey: "telegramBotToken") ?? ""
    @State private var telegramChatId = UserDefaults.standard.string(forKey: "telegramChatId") ?? ""
    @State private var overheatAlertEnabled = UserDefaults.standard.bool(forKey: "overheatAlertEnabled")
    @State private var overheatThreshold = UserDefaults.standard.double(forKey: "overheatThreshold") == 0 ? 85.0 : UserDefaults.standard.double(forKey: "overheatThreshold")




        @State private var devTunnelEnabled = UserDefaults.standard.bool(forKey: "devTunnelEnabled")
    @State private var devTunnelMode = UserDefaults.standard.string(forKey: "devTunnelMode") ?? "login"
    @State private var devTunnelId = UserDefaults.standard.string(forKey: "devTunnelId") ?? ""
    @State private var devTunnelToken = UserDefaults.standard.string(forKey: "devTunnelToken") ?? ""
    @State private var devTunnelAllowAnonymous = UserDefaults.standard.object(forKey: "devTunnelAllowAnonymous") != nil ? UserDefaults.standard.bool(forKey: "devTunnelAllowAnonymous") : true
    @State private var devTunnelPortRules: [DevTunnelPortRule] = DevTunnelService.loadPortRules()
    @State private var devTunnelEnableSSH = UserDefaults.standard.bool(forKey: "devTunnelEnableSSH")
    @State private var devTunnelStatus: DevTunnelStatus = DevTunnelService.shared.currentStatus
    @State private var showDevTunnelConfig = false
    @State private var isDevTunnelConfigModified = false
    @State private var isDevTunnelTesting = false
    @State private var devTunnelTestResult: (success: Bool, message: String)? = nil
    @State private var devTunnelLoggedInUser: String? = DevTunnelService.shared.checkUserLoginStatus()
    @State private var isDevTunnelLoggingIn = false
    @State private var isDevTunnelInstalling = false
    @State private var devTunnelBinaryPath: String? = DevTunnelService.shared.findBinaryPath()
    @State private var devTunnelInstallError: String? = nil
    @State private var devTunnelQuota: DevTunnelQuotaInfo? = nil
    @State private var isQueryingLimits = false

    private var devTunnelStatusColor: Color {
        switch devTunnelStatus {
        case .connected: return .green
        case .connecting: return .orange
        case .error: return .red
        case .stopped: return .gray
        }
    }

    private var devTunnelStatusBadgeText: String {
        switch devTunnelStatus {
        case .connected: return L("已连接", "Connected")
        case .connecting: return L("连接中...", "Connecting...")
        case .error: return L("连接失败", "Failed")
        case .stopped: return L("已停用", "Disabled")
        }
    }

    @State private var cloudflareEnabled = UserDefaults.standard.bool(forKey: "cloudflareEnabled")
    @State private var cloudflareToken = UserDefaults.standard.string(forKey: "cloudflareToken") ?? ""
    @State private var cloudflareStatus: CloudflareStatus = CloudflareService.shared.currentStatus
    @State private var showCloudflareConfig = false
    @State private var isCloudflareConfigModified = false
    @State private var isCloudflareTesting = false
    @State private var cloudflareTestResult: (success: Bool, message: String)? = nil

    private var cloudflareStatusColor: Color {
        switch cloudflareStatus {
        case .connected: return .green
        case .connecting: return .orange
        case .error: return .red
        case .stopped: return .gray
        }
    }

    private var cloudflareStatusBadgeText: String {
        switch cloudflareStatus {
        case .connected: return L("已连接", "Connected")
        case .connecting: return L("连接中...", "Connecting...")
        case .error: return L("连接失败", "Failed")
        case .stopped: return L("已停用", "Disabled")
        }
    }

    @State private var showLoggedInAccountPopover = false
    @State private var isHoveringAccountRow = false
    @State private var tailcatAccountLoggedIn = TailcatService.shared.isAccountLoggedIn
    @State private var tailcatAccountName = TailcatService.shared.loggedInUserName
    @State private var tailcatAvatarImage: NSImage? = TailcatService.shared.cachedAvatarImage
    @State private var tailcatWaitingBrowserAuth = TailcatService.shared.isWaitingForBrowserAuth

    @State private var selectedTab = PreferenceTab.general

    // Modals visibility states for Switch + Button (设定...) sheets
    @State private var showWebServerConfig = false
    @State private var showOverheatConfig = false
    @State private var showNotificationsConfig = false
    @State private var showNezhaConfig = false
    @State private var isNezhaConfigModified = false
    @State private var showServerStatusConfig = false
    @State private var showKumaConfig = false
    @State private var showBatteryConfig = false
    @State private var showFrpConfig = false
    @State private var isFrpConfigModified = false

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
                // macOS 12 兼容:单值 selection 重载需 macOS 13+,统一走 Set 绑定的跨版本重载
                let sidebarList = List(selection: Binding(
                    get: { Set([selectedTab]) },
                    set: { selectedTab = $0.first ?? selectedTab }
                )) {
                    ForEach(PreferenceTab.allCases) { tab in
                        HStack(spacing: 8) {
                            Image(systemName: tab.iconName)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 20, height: 20)
                                // macOS 12 兼容:Color.gradient 需 macOS 13,用 LinearGradient(colors:) 等价实现
                                .background(LinearGradient(
                                    colors: [tab.iconColor, tab.iconColor.opacity(0.75)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ))
                                .cornerRadius(5)

                            Text(tab.title)
                                .font(.body)
                        }
                        .tag(tab)
                        .frame(height: 28)
                    }
                }
                .listStyle(.sidebar)
                if #available(macOS 13.0, *) {
                    sidebarList.scrollContentBackground(.hidden)
                } else {
                    // macOS 12 的 sidebar List 自带半透明材质,保持默认背景即可
                    sidebarList
                }
                
                Spacer()

                // Sidebar Footer (Global Account — Native macOS Sidebar Row Style)
                VStack(alignment: .leading, spacing: 6) {
                    Divider()
                        .opacity(0.4)
                        .padding(.horizontal, 6)

                    Group {
                        if tailcatAccountLoggedIn {
                            Button(action: {
                                showLoggedInAccountPopover.toggle()
                            }) {
                                HStack(spacing: 9) {
                                    if let avatarImg = tailcatAvatarImage {
                                        Image(nsImage: avatarImg)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(width: 24, height: 24)
                                            .clipShape(Circle())
                                            .overlay(
                                                Circle()
                                                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                                            )
                                            .shadow(color: Color.black.opacity(0.08), radius: 1.5, x: 0, y: 1)
                                    } else {
                                        ZStack {
                                            Circle()
                                                .fill(
                                                    LinearGradient(
                                                        colors: [Color.green, Color.blue],
                                                        startPoint: .topLeading,
                                                        endPoint: .bottomTrailing
                                                    )
                                                )
                                                .frame(width: 24, height: 24)
                                            Text(String((tailcatAccountName.isEmpty ? "M" : tailcatAccountName).prefix(1)).uppercased())
                                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                                .foregroundColor(.white)
                                        }
                                        .shadow(color: Color.black.opacity(0.08), radius: 1.5, x: 0, y: 1)
                                    }

                                    Text(tailcatAccountName)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)

                                    Spacer(minLength: 0)

                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundColor(.secondary.opacity(isHoveringAccountRow ? 0.85 : 0.35))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $showLoggedInAccountPopover, arrowEdge: .trailing) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Button(action: {
                                        showLoggedInAccountPopover = false
                                        if let url = URL(string: TailcatService.shared.dashEntryUrl) {
                                            NSWorkspace.shared.open(url)
                                        }
                                    }) {
                                        HStack(spacing: 6) {
                                            Image(systemName: "arrow.up.right.circle.fill")
                                                .foregroundColor(.green)
                                            Text(L("打开 Dash 控制台", "Open Dash Console"))
                                                .font(.caption)
                                            Spacer()
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(Color.primary.opacity(0.06))
                                        .cornerRadius(6)
                                    }
                                    .buttonStyle(.plain)

                                    Button(action: {
                                        showLoggedInAccountPopover = false
                                        TailcatService.shared.logoutAccount()
                                    }) {
                                        HStack(spacing: 6) {
                                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                                .foregroundColor(.red)
                                            Text(L("退出账号", "Sign Out"))
                                                .font(.caption)
                                                .foregroundColor(.red)
                                            Spacer()
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(Color.red.opacity(0.08))
                                        .cornerRadius(6)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(10)
                                .frame(width: 168)
                            }
                        } else if tailcatWaitingBrowserAuth {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.55)
                                    .frame(width: 20, height: 20)
                                Text(L("等待授权...", "Waiting for Auth..."))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Button(L("取消", "Cancel")) {
                                    TailcatService.shared.cancelBrowserAuth()
                                }
                                .font(.system(size: 11))
                                .buttonStyle(.plain)
                                .foregroundColor(.red)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                        } else {
                            Button(action: {
                                TailcatService.shared.loginWithBrowser(provider: nil)
                            }) {
                                HStack(spacing: 9) {
                                    Image(systemName: "person.crop.circle")
                                        .font(.system(size: 16, weight: .regular))
                                        .foregroundColor(.secondary)
                                        .frame(width: 24, height: 24)

                                    Text(L("登录账号", "Sign In"))
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)

                                    Spacer(minLength: 0)

                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundColor(.secondary.opacity(isHoveringAccountRow ? 0.85 : 0.35))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isHoveringAccountRow ? Color.primary.opacity(0.065) : Color.clear)
                    )
                    .onHover { hovering in
                        withAnimation(.easeOut(duration: 0.12)) {
                            isHoveringAccountRow = hovering
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
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
                            SettingsCard(title: L("启动与运行", "Startup & General")) {
                                SettingsRow(L("界面语言", "Interface Language"), subtitle: L("支持跟随系统地区语言或手动固定中英文显示", "Follow system locale or manually choose Chinese / English")) {
                                    Picker("", selection: $l10n.selectedLanguage) {
                                        ForEach(AppLanguage.allCases) { lang in
                                            Text(lang.displayName).tag(lang)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .frame(width: 140)
                                }

                                Divider().padding(.horizontal, 16)

                                SettingsRow(L("开机自启动", "Launch at Login")) {
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

                                SettingsRow(L("启动时自动进入无头模式", "Auto-Enable Headless Mode on Launch")) {
                                    Toggle("", isOn: $autoEnableOnLaunch)
                                        .toggleStyle(.switch)
                                        .labelsHidden()
                                }

                                Divider().padding(.horizontal, 16)

                                SettingsRow(L("启用 machead 命令行工具", "Enable 'machead' CLI Tool")) {
                                    Toggle("", isOn: $cliToolEnabled)
                                        .toggleStyle(.switch)
                                        .labelsHidden()
                                        .onChange(of: cliToolEnabled) { newValue in
                                            if newValue {
                                                CLIToolInstaller.install()
                                            } else {
                                                CLIToolInstaller.remove()
                                            }
                                        }
                                }

                                Divider().padding(.horizontal, 16)

                                SettingsRow(L("匿名使用统计", "Anonymous Usage Telemetry")) {
                                    Toggle("", isOn: $telemetryEnabled)
                                        .toggleStyle(.switch)
                                        .labelsHidden()
                                }
                                .help(L(
                                    "帮助我们改进 MacHead：仅发送随机匿名 ID、系统与应用版本及功能开关状态，不含任何个人信息，可随时关闭。",
                                    "Help improve MacHead: sends only a random anonymous ID, macOS & app versions, and feature flags. No personal data is collected."
                                ))
                            }

                            SettingsCard(title: L("局域网远程控制", "LAN Remote Control")) {
                                SettingsRow(L("启用局域网 Web 控制面板", "Enable LAN Web Control Panel")) {
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

                                        Button(L("设定...", "Configure...")) {
                                            self.webServerPort = String(WebServer.shared.currentPort)
                                            self.webServerIP = WebServer.shared.getLocalIPAddress()
                                            self.showWebServerConfig = true
                                        }
                                    }
                                }

                                if enableWebServer {
                                    SettingsRow(L("访问地址", "Access URL")) {
                                        HStack(spacing: 8) {
                                            Text(verbatim: "http://\(webServerIP):\(WebServer.shared.portString)")
                                                .font(.system(.caption, design: .monospaced))
                                                .foregroundColor(.accentColor)
                                                .textSelection(.enabled)

                                            Button(action: {
                                                let urlStr = "http://\(webServerIP):\(WebServer.shared.portString)"
                                                NSPasteboard.general.clearContents()
                                                NSPasteboard.general.setString(urlStr, forType: .string)
                                            }) {
                                                Image(systemName: "doc.on.doc")
                                                    .font(.caption)
                                            }
                                            .buttonStyle(.borderless)
                                            .help(L("复制访问地址", "Copy Access URL"))
                                        }
                                    }
                                }
                            }

                            SettingsCard(title: L("macOS 原生远程管理感知", "macOS Native Remote Sharing")) {
                                SettingsRow(L("SSH 远程登录", "SSH Remote Login"), subtitle: L("端口 22 · 字符终端", "Port 22 · Terminal Shell")) {
                                    HStack(spacing: 8) {
                                        serviceStatusBadge(isActive: remoteSharing.isSSHRunning)

                                        if remoteSharing.isSSHRunning {
                                            Text(verbatim: remoteSharing.sshCommand)
                                                .font(.system(.caption, design: .monospaced))
                                                .foregroundColor(.accentColor)
                                                .textSelection(.enabled)

                                            copyButton(for: remoteSharing.sshCommand, serviceKey: "ssh")
                                        }
                                    }
                                }

                                Divider().padding(.horizontal, 16)

                                SettingsRow(L("屏幕共享 (VNC)", "Screen Sharing (VNC)"), subtitle: L("端口 5900 · 远程桌面", "Port 5900 · Remote Desktop")) {
                                    HStack(spacing: 8) {
                                        serviceStatusBadge(isActive: remoteSharing.isVNCRunning)

                                        if remoteSharing.isVNCRunning {
                                            Text(verbatim: remoteSharing.vncURL)
                                                .font(.system(.caption, design: .monospaced))
                                                .foregroundColor(.accentColor)
                                                .textSelection(.enabled)

                                            copyButton(for: remoteSharing.vncURL, serviceKey: "vnc")
                                        }
                                    }
                                }

                                Divider().padding(.horizontal, 16)

                                SettingsRow(L("文件共享 (SMB)", "File Sharing (SMB)"), subtitle: L("端口 445 · 局域网访达与文件挂载", "Port 445 · Finder & Network Mount")) {
                                    HStack(spacing: 8) {
                                        serviceStatusBadge(isActive: remoteSharing.isSMBRunning)

                                        if remoteSharing.isSMBRunning {
                                            Text(verbatim: remoteSharing.smbURL)
                                                .font(.system(.caption, design: .monospaced))
                                                .foregroundColor(.accentColor)
                                                .textSelection(.enabled)

                                            copyButton(for: remoteSharing.smbURL, serviceKey: "smb")
                                        }
                                    }
                                }

                                Divider().padding(.horizontal, 16)

                                SettingsRow(L("系统共享管理", "System Sharing Settings"), subtitle: L("开启或关闭服务请前往 macOS 系统设置", "Enable or disable sharing services in macOS System Settings")) {
                                    HStack(spacing: 8) {
                                        Button(action: {
                                            remoteSharing.refresh()
                                        }) {
                                            Image(systemName: "arrow.clockwise")
                                                .font(.caption)
                                        }
                                        .buttonStyle(.borderless)
                                        .help(L("刷新端口监听状态", "Refresh listening port status"))

                                        Button(L("配置系统共享...", "System Sharing...")) {
                                            remoteSharing.openSystemSharingSettings()
                                        }
                                    }
                                }
                            }

                        case .power:
                            if battery.isUPSActive {
                                HStack(spacing: 12) {
                                    Image(systemName: "bolt.batteryblock.fill")
                                        .font(.system(size: 22, weight: .bold))
                                        .foregroundColor(.orange)

                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(L("正在以电池 UPS 模式运行", "Running in Battery UPS Mode"))
                                                .font(.system(size: 13, weight: .bold))
                                                .foregroundColor(.primary)

                                            Text(L("无人值守供电中", "Unattended Power"))
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundColor(.orange)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 1)
                                                .background(Capsule().fill(Color.orange.opacity(0.18)))
                                        }

                                        Text(L(
                                            "外部市电已中断 · 预计还可支撑运行约 \(battery.timeRemainingFormatted) · 放电功率 \(String(format: "%.1f", battery.powerWatts))W",
                                            "AC power interrupted · Est. runtime \(battery.timeRemainingFormatted) · Discharge \(String(format: "%.1f", battery.powerWatts))W"
                                        ))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()
                                }
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.orange.opacity(0.10))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                                )
                                .padding(.bottom, 8)
                            }

                            // ═══════════════════════════════════════════════════════════
                            // 区块一：电源与运行控制策略 (全部开关集中排列)
                            // ═══════════════════════════════════════════════════════════

                            SettingsCard(title: L("供电与运行策略", "Power & Runtime Policy")) {
                                SettingsRow(L("防止空闲睡眠", "Prevent Idle Sleep"), subtitle: L("阻止系统在无人操作时自动进入睡眠", "Prevent macOS from automatically sleeping when idle")) {
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

                                SettingsRow(L("合盖后仍然保持运行状态", "Keep Running on Lid Close"), subtitle: L("合盖时维持系统活跃，无缝充当常驻服务器", "Keep system awake with lid closed for always-on server operation")) {
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

                            SettingsCard(title: L("长期插电防鼓包养护 (Charge Limit)", "Battery Charge Limit & Protection")) {
                                SettingsRow(L("启用充电上限保护", "Enable Charge Limit Protection"), subtitle: L("到达指定上限后暂停充电，延缓电池高压与长期发热鼓包", "Pause charging at threshold to prevent high-voltage stress and swelling")) {
                                    HStack(spacing: 8) {
                                        Toggle("", isOn: $battery.customLimitEnabled)
                                            .toggleStyle(.switch)
                                            .labelsHidden()
                                    }
                                }

                                if battery.customLimitEnabled {
                                    Divider().padding(.horizontal, 16)

                                    SettingsRow(
                                        L("充电上限阈值", "Charge Limit Threshold"),
                                        subtitle: L(
                                            "达到 \(battery.customLimitThreshold)% 时停止充电，降至 \(max(20, battery.customLimitThreshold - 5))% 时恢复补电 (Sailing Mode)",
                                            "Stops charging at \(battery.customLimitThreshold)%, resumes at \(max(20, battery.customLimitThreshold - 5))% (Sailing Mode)"
                                        )
                                    ) {
                                        HStack(spacing: 10) {
                                            Slider(value: Binding(
                                                get: { Double(self.battery.customLimitThreshold) },
                                                set: { self.battery.customLimitThreshold = Int($0) }
                                            ), in: 50...90, step: 5)
                                            .frame(width: 130)

                                            Text("\(battery.customLimitThreshold)%")
                                                .font(.system(.body, design: .rounded))
                                                .fontWeight(.bold)
                                                .frame(width: 38, alignment: .trailing)
                                        }
                                    }

                                    Divider().padding(.horizontal, 16)

                                    SettingsRow(
                                        L("底层 SMC 控充权限", "SMC Charge Control Permission"),
                                        subtitle: battery.isPrivilegedHelperConfigured
                                            ? L("已建立静默控充通道，后台控充时无需反复输入密码", "Passwordless SMC channel active for background charge control")
                                            : L("老系统自主截断充电电流需配置免密权限 (仅需授权一次)", "One-time admin authorization required for background SMC charge control")
                                    ) {
                                        HStack(spacing: 8) {
                                            if battery.isPrivilegedHelperConfigured {
                                                Text(L("已授权 (静默生效)", "Authorized (Silent)"))
                                                    .font(.system(size: 12, weight: .medium))
                                                    .foregroundColor(.green)

                                                Button(L("移除授权", "Revoke")) {
                                                    _ = BatteryManager.shared.removePrivilegedAccess()
                                                }
                                                .buttonStyle(.plain)
                                                .foregroundColor(.secondary)
                                                .font(.system(size: 11))
                                            } else {
                                                Button(L("配置免密授权 (仅需一次)...", "Authorize (One-Time)...")) {
                                                    _ = BatteryManager.shared.requestPrivilegedAccess()
                                                }
                                                .buttonStyle(.plain)
                                                .foregroundColor(.accentColor)
                                                .font(.system(size: 12, weight: .medium))
                                            }
                                        }
                                    }
                                }

                                Divider().padding(.horizontal, 16)

                                SettingsRow(
                                    L("系统环境与策略模式", "System Environment & Policy"),
                                    subtitle: battery.isSupportedNativeLimit
                                        ? L("macOS 15+ 具备固件级限充能力", "macOS 15+ supports firmware-level charge limiting")
                                        : L("老款系统 (macOS 14/13/Intel) 无原生限充，完全依赖 MacHead 自主控制", "Older macOS / Intel relies on MacHead SMC charge control")
                                ) {
                                    HStack(spacing: 8) {
                                        HStack(spacing: 4) {
                                            Circle()
                                                .fill(battery.isChargeLimitEnabled ? Color.green : Color.orange)
                                                .frame(width: 7, height: 7)
                                            Text(battery.chargeLimitSource)
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundColor(.secondary)
                                        }

                                        if battery.isSupportedNativeLimit {
                                            Button(L("系统设置...", "System Settings...")) {
                                                BatteryManager.shared.openSystemBatterySettings()
                                            }
                                            .buttonStyle(.plain)
                                            .foregroundColor(.accentColor)
                                        }
                                    }
                                }
                            }

                            SettingsCard(title: L("断电与休眠保护", "Power Outage & Hibernate Protection")) {
                                SettingsRow(L("启用低电量电池保护", "Enable Low Battery Protection"), subtitle: L("断电且电量低于安全阈值时自动休眠，防止电池过放损坏", "Automatically sleep when battery drops below threshold during outage")) {
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

                                        Button(L("设定...", "Configure...")) {
                                            self.showBatteryConfig = true
                                        }
                                    }
                                }
                            }

                            // ═══════════════════════════════════════════════════════════
                            // 区块二：电池指标与健康监控看板 (全部信息读数集中排列)
                            // ═══════════════════════════════════════════════════════════

                            SettingsCard(title: L("实时电气指标", "Real-Time Electrical Telemetry")) {
                                SettingsRow(L("即时充放电功率", "Real-Time Power")) {
                                    Text(battery.powerWatts > 0 ? String(format: "%.2f W", battery.powerWatts) : (battery.isCharging ? L("充电中", "Charging") : L("0.00 W (直供)", "0.00 W (AC Direct)")))
                                        .fontWeight(.semibold)
                                        .foregroundColor(battery.isUPSActive ? .orange : (battery.isCharging ? .green : .primary))
                                }

                                Divider().padding(.horizontal, 16)

                                SettingsRow(L("母线电压 / 实时电流", "Bus Voltage / Current")) {
                                    Text(String(format: "%.2f V / %d mA", battery.voltage, battery.amperage))
                                        .fontWeight(.medium)
                                }

                                Divider().padding(.horizontal, 16)

                                SettingsRow(L("外接供电适配器", "External Power Adapter")) {
                                    Text(battery.adapterWatts > 0 ? "\(battery.adapterWatts)W (\(battery.adapterName.isEmpty ? L("交流适配器", "AC Adapter") : battery.adapterName))" : (battery.isUPSActive ? L("未连接 (电池供电)", "Disconnected (On Battery)") : L("外接电源", "AC Power")))
                                        .fontWeight(.medium)
                                }

                                Divider().padding(.horizontal, 16)

                                SettingsRow(L("电源预估状态", "Estimated Power Status")) {
                                    Text(battery.timeRemainingFormatted.isEmpty ? L("正常运行", "Normal Operation") : battery.timeRemainingFormatted)
                                        .fontWeight(.medium)
                                        .foregroundColor(battery.isUPSActive ? .orange : .secondary)
                                }
                            }

                            SettingsCard(title: L("电池健康与容量", "Battery Health & Capacity")) {
                                SettingsRow(L("当前剩余电量", "Current Charge")) {
                                    HStack(spacing: 8) {
                                        Image(systemName: battery.isCharging ? "bolt.batteryblock.fill" : (battery.currentCapacity > 20 ? "battery.100" : "battery.25"))
                                            .foregroundColor(battery.isCharging ? .green : (battery.currentCapacity > 20 ? .blue : .orange))
                                        Text("\(battery.currentCapacity)% (\(battery.powerState == "AC Power" ? L("外接交流电", "AC Power") : L("电池供电", "Battery Power")))")
                                            .fontWeight(.medium)
                                    }
                                }

                                Divider().padding(.horizontal, 16)

                                SettingsRow(L("最大可用容量 (mAh)", "Max Capacity (mAh)")) {
                                    if battery.rawMaxCapacity > 0 {
                                        Text(L(
                                            "\(battery.rawCurrentCapacity) / \(battery.rawMaxCapacity) mAh (设计: \(battery.designCapacity) mAh)",
                                            "\(battery.rawCurrentCapacity) / \(battery.rawMaxCapacity) mAh (Design: \(battery.designCapacity) mAh)"
                                        ))
                                            .fontWeight(.medium)
                                    } else {
                                        Text(L("读取中...", "Reading..."))
                                            .foregroundColor(.secondary)
                                    }
                                }

                                Divider().padding(.horizontal, 16)

                                SettingsRow(L("电池健康度 (最大容量)", "Battery Health (Max Capacity)")) {
                                    Text(battery.batteryHealth > 0 ? String(format: "%.1f%%", battery.batteryHealth) : L("检测中", "Detecting"))
                                        .fontWeight(.medium)
                                        .foregroundColor(battery.batteryHealth >= 80 ? .primary : .orange)
                                }

                                Divider().padding(.horizontal, 16)

                                SettingsRow(L("充放电循环次数", "Cycle Count")) {
                                    Text(L("\(battery.cycleCount) 次", "\(battery.cycleCount) cycles"))
                                        .fontWeight(.medium)
                                }

                                if battery.batteryTemperature > 0 {
                                    Divider().padding(.horizontal, 16)

                                    SettingsRow(L("电池包温度", "Battery Temperature")) {
                                        Text(String(format: "%.1f°C", battery.batteryTemperature))
                                            .fontWeight(.medium)
                                            .foregroundColor(battery.batteryTemperature > 38 ? .red : .primary)
                                    }
                                }
                            }

                        case .hardware:
                            SettingsCard(title: L("输入设备保护", "Input Device Protection")) {
                                SettingsRow(L("禁用内置键盘", "Disable Built-in Keyboard")) {
                                    HStack(spacing: 16) {
                                        Toggle(L("无头模式下", "In Headless Mode"), isOn: Binding(
                                            get: { self.disableKeyboardInHeadless },
                                            set: { newValue in
                                                self.disableKeyboardInHeadless = newValue
                                                UserDefaults.standard.set(newValue, forKey: "DisableKeyboardInHeadless")
                                                InputDeviceManager.shared.evaluateTrackpadAndKeyboardState()
                                                self.isAccessibilityTrusted = AXIsProcessTrusted()
                                            }
                                        ))
                                        .toggleStyle(.checkbox)

                                        Toggle(L("外接键盘下", "With External Keyboard"), isOn: Binding(
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

                                SettingsRow(L("禁用内置触控板", "Disable Built-in Trackpad")) {
                                    HStack(spacing: 16) {
                                        Toggle(L("无头模式下", "In Headless Mode"), isOn: Binding(
                                            get: { self.disableTrackpadInHeadless },
                                            set: { newValue in
                                                self.disableTrackpadInHeadless = newValue
                                                UserDefaults.standard.set(newValue, forKey: "DisableTrackpadInHeadless")
                                                InputDeviceManager.shared.evaluateTrackpadAndKeyboardState()
                                            }
                                        ))
                                        .toggleStyle(.checkbox)

                                        Toggle(L("外接鼠标下", "With External Mouse"), isOn: Binding(
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
                                            Text(L("未授权辅助功能权限", "Accessibility Permission Required"))
                                                .bold()
                                        }
                                        Text(L(
                                            "请在“系统设置 -> 隐私与安全性 -> 辅助功能”中允许 MacHead，以使屏蔽键盘功能生效。",
                                            "Please enable MacHead in 'System Settings -> Privacy & Security -> Accessibility' to allow built-in keyboard blocking."
                                        ))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Button(L("去系统设置开启", "Open System Settings")) {
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

                            SettingsCard(title: L("多媒体设备", "Audio & Media Devices")) {
                                SettingsRow(L("内置麦克风状态", "Built-in Microphone Status")) {
                                    Text(isMicrophoneMuted ? L("已静音 🔇", "Muted 🔇") : L("正常 🎙️", "Active 🎙️"))
                                        .fontWeight(.medium)
                                }

                                Divider().padding(.horizontal, 16)

                                SettingsRow(L("无头模式下自动静音内置麦克风", "Auto-Mute Built-in Microphone in Headless Mode")) {
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
                            SettingsCard(title: L("系统硬件监控 & 告警", "Hardware Monitoring & Alerts")) {
                                SettingsRow(L("当前芯片温度", "Current CPU Temperature")) {
                                    Text(String(format: "%.1f°C", smc.currentTemperature))
                                        .fontWeight(.semibold)
                                        .foregroundColor(smc.currentTemperature >= overheatThreshold ? .red : .primary)
                                }

                                Divider().padding(.horizontal, 16)

                                SettingsRow(L("当前风扇转速", "Current Fan Speed")) {
                                    Text(smc.isFanless ? L("无风扇 (被动散热)", "Fanless (Passive Cooling)") : (smc.fanSpeed > 0 ? "\(smc.fanSpeed) RPM" : L("正常 (系统自动控制)", "Normal (Auto Controlled)")))
                                        .fontWeight(.semibold)
                                }

                                Divider().padding(.horizontal, 16)

                                SettingsRow(L("启用芯片过热报警", "Enable CPU Overheat Alert")) {
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

                                        Button(L("设定...", "Configure...")) {
                                            self.showOverheatConfig = true
                                        }
                                    }
                                }

                                Divider().padding(.horizontal, 16)

                                SettingsRow(L("启用消息推送通道", "Enable Push Notification Channels")) {
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

                                        Button(L("设定...", "Configure...")) {
                                            self.showNotificationsConfig = true
                                        }
                                    }
                                }
                            }

                            SettingsCard(title: L("哪吒监控 & ServerStatus 探针", "Nezha Monitoring & ServerStatus Agent")) {
                                SettingsRow(L("启用哪吒监控 (Nezha Agent)", "Enable Nezha Agent")) {
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

                                        Button(L("设定...", "Configure...")) {
                                             self.isNezhaConfigModified = false
                                             self.showNezhaConfig = true
                                         }
                                    }
                                }

                                Divider().padding(.horizontal, 16)

                                SettingsRow(L("启用 ServerStatus 客户端", "Enable ServerStatus Client")) {
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

                                        Button(L("设定...", "Configure...")) {
                                            self.showServerStatusConfig = true
                                        }
                                    }
                                }
                            }



                            SettingsCard(title: L("Uptime Kuma 心跳打卡", "Uptime Kuma Heartbeat")) {
                                SettingsRow(L("启用 Uptime Kuma 推送", "Enable Uptime Kuma Push")) {
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

                                        Button(L("设定...", "Configure...")) {
                                            self.showKumaConfig = true
                                        }
                                    }
                                }
                            }

                        case .tunneling:
                            SettingsCard(title: L("Microsoft Dev Tunnels 穿透服务", "Microsoft Dev Tunnels")) {
                                SettingsRow(L("启用 Dev Tunnels (微软中继)", "Enable Dev Tunnels (Azure Relay)")) {
                                    HStack(spacing: 10) {
                                        if devTunnelEnabled {
                                            HStack(spacing: 4) {
                                                Circle()
                                                    .fill(devTunnelStatusColor)
                                                    .frame(width: 6, height: 6)
                                                Text(devTunnelStatusBadgeText)
                                                    .font(.caption2)
                                                    .fontWeight(.medium)
                                                    .foregroundColor(devTunnelStatusColor)
                                            }
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(devTunnelStatusColor.opacity(0.12))
                                            .cornerRadius(5)
                                        }

                                        Toggle("", isOn: Binding(
                                            get: { self.devTunnelEnabled },
                                            set: { newValue in
                                                self.devTunnelEnabled = newValue
                                                UserDefaults.standard.set(newValue, forKey: "devTunnelEnabled")
                                                if newValue {
                                                    DevTunnelService.shared.start()
                                                } else {
                                                    DevTunnelService.shared.stop()
                                                }
                                            }
                                        ))
                                        .toggleStyle(.switch)
                                        .labelsHidden()

                                        Button(L("设定...", "Configure...")) {
                                            self.isDevTunnelConfigModified = false
                                            self.devTunnelTestResult = nil
                                            self.devTunnelLoggedInUser = DevTunnelService.shared.checkUserLoginStatus()
                                            DevTunnelService.shared.queryUserLimits { info in
                                                self.devTunnelQuota = info
                                            }
                                            self.showDevTunnelConfig = true
                                        }
                                    }
                                }

                                if case .connected(let webUrl, _) = devTunnelStatus, devTunnelEnabled {
                                    Divider().padding(.horizontal, 16)
                                    VStack(alignment: .leading, spacing: 6) {
                                        let portUrls = DevTunnelService.shared.activePortUrls
                                        if !portUrls.isEmpty {
                                            ForEach(portUrls.keys.sorted(), id: \.self) { port in
                                                if let url = portUrls[port] {
                                                    HStack(spacing: 8) {
                                                        Image(systemName: port == "22" ? "terminal" : "link")
                                                            .foregroundColor(port == "22" ? .purple : .green)
                                                            .font(.caption)

                                                        let ruleName = devTunnelPortRules.first(where: { $0.port == port })?.name ?? L("端口 \(port)", "Port \(port)")
                                                        Text("\(ruleName) (\(port)):")
                                                            .font(.caption2)
                                                            .foregroundColor(.secondary)

                                                        Text(url)
                                                            .font(.system(.caption, design: .monospaced))
                                                            .foregroundColor(.primary)
                                                            .lineLimit(1)

                                                        Spacer()

                                                        Button(action: {
                                                            NSPasteboard.general.clearContents()
                                                            NSPasteboard.general.setString(url, forType: .string)
                                                        }) {
                                                            Text(L("复制", "Copy"))
                                                                .font(.caption2)
                                                        }
                                                        .buttonStyle(.plain)
                                                        .padding(.horizontal, 8)
                                                        .padding(.vertical, 2)
                                                        .background(Color.green.opacity(0.15))
                                                        .cornerRadius(4)
                                                    }
                                                }
                                            }
                                        } else {
                                            HStack(spacing: 8) {
                                                Image(systemName: "link")
                                                    .foregroundColor(.green)
                                                    .font(.caption)
                                                Text(webUrl)
                                                    .font(.system(.caption, design: .monospaced))
                                                    .foregroundColor(.primary)
                                                    .lineLimit(1)
                                                Spacer()
                                                Button(action: {
                                                    NSPasteboard.general.clearContents()
                                                    NSPasteboard.general.setString(webUrl, forType: .string)
                                                }) {
                                                    Text(L("复制", "Copy"))
                                                        .font(.caption2)
                                                }
                                                .buttonStyle(.plain)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 2)
                                                .background(Color.green.opacity(0.15))
                                                .cornerRadius(4)
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                }

                                if case .error(let msg) = devTunnelStatus, devTunnelEnabled {
                                    Divider().padding(.horizontal, 16)
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundColor(.orange)
                                            .font(.caption)
                                        Text(msg)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                }
                            }

                            SettingsCard(title: L("Cloudflare Tunnel 穿透服务", "Cloudflare Tunnel")) {
                                SettingsRow(L("启用 Cloudflare Tunnel (cloudflared)", "Enable Cloudflare Tunnel (cloudflared)")) {
                                    HStack(spacing: 10) {
                                        if cloudflareEnabled {
                                            HStack(spacing: 4) {
                                                Circle()
                                                    .fill(cloudflareStatusColor)
                                                    .frame(width: 6, height: 6)
                                                Text(cloudflareStatusBadgeText)
                                                    .font(.caption2)
                                                    .fontWeight(.medium)
                                                    .foregroundColor(cloudflareStatusColor)
                                            }
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(cloudflareStatusColor.opacity(0.12))
                                            .cornerRadius(5)
                                        }

                                        Toggle("", isOn: Binding(
                                            get: { self.cloudflareEnabled },
                                            set: { newValue in
                                                self.cloudflareEnabled = newValue
                                                UserDefaults.standard.set(newValue, forKey: "cloudflareEnabled")
                                                if newValue {
                                                    CloudflareService.shared.start()
                                                } else {
                                                    CloudflareService.shared.stop()
                                                }
                                            }
                                        ))
                                        .toggleStyle(.switch)
                                        .labelsHidden()

                                        Button(L("设定...", "Configure...")) {
                                            self.isCloudflareConfigModified = false
                                            self.cloudflareTestResult = nil
                                            self.showCloudflareConfig = true
                                        }
                                    }
                                }

                                if case .error(let msg) = cloudflareStatus, cloudflareEnabled {
                                    Divider().padding(.horizontal, 16)
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundColor(.orange)
                                            .font(.caption)
                                        Text(msg)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                }
                            }

                            SettingsCard(title: L("FRP 内网穿透服务", "FRP Reverse Proxy")) {
                                SettingsRow(L("启用 FRP 客户端 (frpc)", "Enable FRP Client (frpc)")) {
                                    HStack(spacing: 10) {
                                        if frpEnabled {
                                            HStack(spacing: 4) {
                                                Circle()
                                                    .fill(frpStatusColor)
                                                    .frame(width: 6, height: 6)
                                                Text(frpStatusBadgeText)
                                                    .font(.caption2)
                                                    .fontWeight(.medium)
                                                    .foregroundColor(frpStatusColor)
                                            }
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(frpStatusColor.opacity(0.12))
                                            .cornerRadius(5)
                                        }

                                        Toggle("", isOn: Binding(
                                            get: { self.frpEnabled },
                                            set: { newValue in
                                                self.frpEnabled = newValue
                                                UserDefaults.standard.set(newValue, forKey: "frpEnabled")
                                                if newValue {
                                                    FrpService.shared.start()
                                                } else {
                                                    FrpService.shared.stop()
                                                }
                                            }
                                        ))
                                        .toggleStyle(.switch)
                                        .labelsHidden()

                                        Button(L("设定...", "Configure...")) {
                                             self.isFrpConfigModified = false
                                             self.showFrpConfig = true
                                         }
                                    }
                                }
                            }

                        case .status:

                            SettingsCard(title: L("显示器与 Headless 守护策略", "Display & Headless Guard Policy")) {
                                SettingsRow(L("断开全部外屏时自动恢复内屏", "Auto-Restore Built-in Display When External Disconnected")) {
                                    Toggle("", isOn: $autoExitOnDisconnect)
                                        .toggleStyle(.switch)
                                        .labelsHidden()
                                }

                                Divider().padding(.horizontal, 16)

                                SettingsRow(L("接入外屏时自动进入无头模式", "Auto-Enable Headless Mode When External Display Connected")) {
                                    Toggle("", isOn: $autoRestoreOnConnect)
                                        .toggleStyle(.switch)
                                        .labelsHidden()
                                }
                            }

                            SettingsCard(title: L("当前连接的显示器", "Connected Displays")) {
                                if connectedDisplays.isEmpty {
                                    SettingsRow(L("未检测到有效显示器", "No active displays detected")) {
                                        Text(L("无", "None"))
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
                Text(L("局域网 Web 控制面板配置", "LAN Web Control Panel Configuration"))
                    .font(.headline)
                    .fontWeight(.bold)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(L("管理密码:", "Password:"))
                            .foregroundColor(.secondary)
                            .frame(width: 75, alignment: .leading)
                        TextField(L("设置密码", "Set Password"), text: Binding(
                            get: { self.webServerPassword },
                            set: { newValue in
                                self.webServerPassword = newValue
                                UserDefaults.standard.set(newValue, forKey: "WebServerPassword")
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 190)
                    }

                    HStack(alignment: .top) {
                        Text(L("服务端口:", "Port:"))
                            .foregroundColor(.secondary)
                            .frame(width: 75, alignment: .leading)
                            .padding(.top, 4)

                        VStack(alignment: .leading, spacing: 4) {
                            TextField("8080", text: $webServerPort)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 190)
                                .onChange(of: webServerPort) { newValue in
                                    let filtered = newValue.filter { "0123456789".contains($0) }
                                    if filtered != newValue {
                                        self.webServerPort = filtered
                                    }
                                }
                                .onSubmit {
                                    commitWebServerPort()
                                }

                            if let portVal = Int(webServerPort), portVal > 0 && portVal < 1024 {
                                Text(L("小于 1024 的特权端口可能需要 root 权限", "Ports below 1024 may require root privileges"))
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                            } else if let portVal = Int(webServerPort), portVal > 65535 {
                                Text(L("端口超出有效范围 (1 - 65535)", "Port out of valid range (1 - 65535)"))
                                    .font(.caption2)
                                    .foregroundColor(.red)
                            }
                        }
                    }

                    HStack {
                        Text(L("访问地址:", "Access URL:"))
                            .foregroundColor(.secondary)
                            .frame(width: 75, alignment: .leading)
                        Text(verbatim: "http://\(webServerIP):\(displayWebServerPort)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.accentColor)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 4)

                Spacer()

                HStack {
                    Spacer()
                    Button(L("完成", "Done")) {
                        commitWebServerPort()
                        self.showWebServerConfig = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 400, height: 235)
            .onDisappear {
                commitWebServerPort()
            }
        }

        // ------------------ 电池休眠保护配置弹窗 ------------------
        .sheet(isPresented: $showBatteryConfig) {
            VStack(alignment: .leading, spacing: 16) {
                Text(L("低电量电池保护配置", "Low Battery Protection Settings"))
                    .font(.headline)
                    .fontWeight(.bold)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(L("当前电量:", "Current Level:"))
                            .foregroundColor(.secondary)
                            .frame(width: 105, alignment: .leading)
                        Text("\(battery.currentCapacity)%")
                            .fontWeight(.semibold)
                    }

                    HStack {
                        Text(L("电源状态:", "Power Source:"))
                            .foregroundColor(.secondary)
                            .frame(width: 105, alignment: .leading)
                        Text(battery.powerState == "AC Power" ? L("外接电源直供", "AC Power") : L("电池供电中", "On Battery"))
                            .fontWeight(.medium)
                    }

                    HStack {
                        Text(L("休眠电量阈值:", "Sleep Threshold:"))
                            .foregroundColor(.secondary)
                            .frame(width: 105, alignment: .leading)
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
                    Button(L("完成", "Done")) {
                        self.showBatteryConfig = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 390, height: 220)
        }

        // ------------------ SMC 过热温度报警配置弹窗 ------------------
        .sheet(isPresented: $showOverheatConfig) {
            VStack(alignment: .leading, spacing: 16) {
                Text(L("芯片过热报警配置", "CPU Overheat Alert Settings"))
                    .font(.headline)
                    .fontWeight(.bold)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(L("当前温度:", "Current Temp:"))
                            .foregroundColor(.secondary)
                            .frame(width: 105, alignment: .leading)
                        Text(String(format: "%.1f°C", smc.currentTemperature))
                            .fontWeight(.semibold)
                            .foregroundColor(smc.currentTemperature >= overheatThreshold ? .red : .primary)
                    }

                    HStack {
                        Text(L("报警温度阈值:", "Alert Threshold:"))
                            .foregroundColor(.secondary)
                            .frame(width: 105, alignment: .leading)
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
                    Button(L("完成", "Done")) {
                        self.showOverheatConfig = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 390, height: 200)
        }

        // ------------------ 推送通道集成配置弹窗 ------------------
        .sheet(isPresented: $showNotificationsConfig) {
            VStack(alignment: .leading, spacing: 16) {
                Text(L("消息推送通道配置", "Push Notification Channels"))
                    .font(.headline)
                    .fontWeight(.bold)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Toggle(L("启用 Bark 推送 (iOS)", "Enable Bark Push (iOS)"), isOn: Binding(
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
                                    TextField(L("填入 Bark Device Key", "Enter Bark Device Key"), text: Binding(
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
                                Toggle(L("启用 Telegram Bot 推送", "Enable Telegram Bot Push"), isOn: Binding(
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
                                        TextField(L("填入 Bot Token", "Enter Bot Token"), text: Binding(
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
                                        TextField(L("填入 Chat ID", "Enter Chat ID"), text: Binding(
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
                            Button(L("发送测试通知", "Send Test Notification")) {
                                NotificationService.shared.sendAlert(
                                    type: .test,
                                    title: L("连接测试", "Connection Test"),
                                    body: L("这是一条来自 MacHead 的集成状态测试通知，连接正常！", "This is a test notification from MacHead. Connection is working!"),
                                    force: true
                                )
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
                    Button(L("完成", "Done")) {
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
                    Text(L("哪吒监控配置", "Nezha Monitoring Settings"))
                        .font(.headline)
                        .fontWeight(.bold)

                    Toggle(L("启用服务", "Enable"), isOn: Binding(
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
                    .controlSize(.small)
                    .padding(.leading, 8)

                    Spacer()

                    Button(L("测试连接并启用", "Test & Enable")) {
                        self.nezhaEnabled = true
                        UserDefaults.standard.set(true, forKey: "nezhaEnabled")
                        NezhaAgentService.shared.stop()
                        DispatchQueue.global(qos: .userInitiated).async {
                            Thread.sleep(forTimeInterval: 0.2)
                            NezhaAgentService.shared.start()
                        }
                    }
                    .controlSize(.small)
                }

                // 实时诊断卡片
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(nezhaStatusColor)
                            .frame(width: 8, height: 8)
                        Text(L("当前状态:", "Status:"))
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
                        Text(L("面板地址:", "Server:"))
                            .foregroundColor(.secondary)
                            .frame(width: 80, alignment: .leading)
                        TextField(L("host:port (如 104.223.55.31:8008)", "host:port (e.g. 104.223.55.31:8008)"), text: $nezhaServer)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                            .onChange(of: nezhaServer) { newValue in
                                UserDefaults.standard.set(newValue, forKey: "nezhaServer")
                                self.isNezhaConfigModified = true
                            }
                    }

                    HStack {
                        Text(L("连接密钥:", "Secret:"))
                            .foregroundColor(.secondary)
                            .frame(width: 80, alignment: .leading)
                        SecureField("Secret Key", text: $nezhaSecret)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                            .onChange(of: nezhaSecret) { newValue in
                                UserDefaults.standard.set(newValue, forKey: "nezhaSecret")
                                self.isNezhaConfigModified = true
                            }
                    }

                    HStack {
                        Text(L("安全传输:", "Security:"))
                            .foregroundColor(.secondary)
                            .frame(width: 80, alignment: .leading)
                        Toggle(L("启用 SSL/TLS 加密", "Enable SSL/TLS"), isOn: $nezhaTls)
                            .toggleStyle(.switch)
                            .onChange(of: nezhaTls) { newValue in
                                UserDefaults.standard.set(newValue, forKey: "nezhaTls")
                                self.isNezhaConfigModified = true
                            }
                    }
                }
                .padding(.vertical, 4)

                Spacer()

                HStack {
                    Spacer()
                    Button(L("完成", "Done")) {
                        if self.isNezhaConfigModified {
                            self.isNezhaConfigModified = false
                            IntegrationManager.shared.reloadServices()
                        }
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
                Text(L("ServerStatus 客户端配置", "ServerStatus Client Settings"))
                    .font(.headline)
                    .fontWeight(.bold)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(L("服务端地址:", "Server:"))
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
                        Text(L("主机用户名:", "Username:"))
                            .foregroundColor(.secondary)
                            .frame(width: 90, alignment: .leading)
                        TextField(L("用户名", "User ID"), text: Binding(
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
                        Text(L("连接密码:", "Password:"))
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
                    Button(L("完成", "Done")) {
                        self.showServerStatusConfig = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 380, height: 240)
        }

        // ------------------ Uptime Kuma 配置弹窗 ------------------
        // ------------------ FRP 内网穿透配置弹窗 ------------------
        // ------------------ FRP 内网穿透配置弹窗 ------------------

        // ------------------ Cloudflare Tunnel 配置弹窗 ------------------
        .sheet(isPresented: $showCloudflareConfig) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.orange)
                    Text(L("Cloudflare Tunnel 配置 (cloudflared)", "Cloudflare Tunnel Settings (cloudflared)"))
                        .font(.headline)
                    Spacer()
                }

                Text(L(
                    "输入您的 Cloudflare Tunnel 运行 Token。应用将在后台自动调用内置的 cloudflared 客户端建立免公网 IP 穿透隧道。",
                    "Enter your Cloudflare Tunnel Token. MacHead will run the bundled cloudflared client in the background to establish a public tunnel."
                ))
                    .font(.caption)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Text(L("隧道 Token", "Tunnel Token"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    SecureField(L("输入 eyJh... 格式的 Cloudflare Token", "Enter Cloudflare Token (eyJh...)"), text: Binding(
                        get: { self.cloudflareToken },
                        set: { newValue in
                            if self.cloudflareToken != newValue {
                                self.cloudflareToken = newValue
                                self.isCloudflareConfigModified = true
                            }
                        }
                    ))
                        .textFieldStyle(.roundedBorder)
                }

                if let result = cloudflareTestResult {
                    HStack(spacing: 8) {
                        Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(result.success ? .green : .red)
                            .font(.caption)
                        Text(result.message)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(result.success ? Color.green.opacity(0.1) : Color.red.opacity(0.1))
                    .cornerRadius(6)
                }

                HStack {
                    Button(action: {
                        self.isCloudflareTesting = true
                        self.cloudflareTestResult = nil
                        CloudflareService.shared.testConnection(token: self.cloudflareToken) { success, message in
                            self.isCloudflareTesting = false
                            self.cloudflareTestResult = (success, message)
                        }
                    }) {
                        HStack(spacing: 6) {
                            if isCloudflareTesting {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(isCloudflareTesting ? L("正在测试...", "Testing...") : L("测试连接", "Test Connection"))
                        }
                    }
                    .disabled(isCloudflareTesting || cloudflareToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Spacer()

                    Button(L("取消", "Cancel")) {
                        self.cloudflareTestResult = nil
                        self.showCloudflareConfig = false
                    }
                    .buttonStyle(.plain)

                    Button(L("保存并应用", "Save & Apply")) {
                        self.cloudflareTestResult = nil
                        if self.isCloudflareConfigModified {
                            self.isCloudflareConfigModified = false
                            UserDefaults.standard.set(self.cloudflareToken, forKey: "cloudflareToken")
                            IntegrationManager.shared.reloadServices()
                        }
                        self.showCloudflareConfig = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .frame(width: 440)
        }

        
        // ------------------ Dev Tunnels 配置弹窗 ------------------
        .sheet(isPresented: $showDevTunnelConfig) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: "network.badge.shield.half.filled")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.blue)
                    Text(L("Microsoft Dev Tunnels 配置", "Microsoft Dev Tunnels Settings"))
                        .font(.headline)
                    Spacer()
                }

                Text(L(
                    "微软官方提供的安全跨网穿透隧道。通过 Azure Relay 边缘网络建立公网访问，支持自动端口多路复用与 GitHub 身份鉴权。",
                    "Microsoft's official secure cross-network tunnel via Azure Relay edge network, supporting port multiplexing and GitHub authentication."
                ))
                    .font(.caption)
                    .foregroundColor(.secondary)

                // CLI Component Status Card
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("devtunnel CLI 组件", "devtunnel CLI Component"))
                        .font(.caption)
                        .fontWeight(.semibold)

                    if let binaryPath = devTunnelBinaryPath {
                        HStack {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundColor(.green)
                            Text(L("已就绪", "Ready"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(binaryPath)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                        }
                    } else {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text(L(
                                "未检测到 devtunnel CLI。该组件不随 App 内置，点击右侧按钮从微软官方下载安装。",
                                "devtunnel CLI not found. Click Install to download from Microsoft's official release."
                            ))
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(action: {
                                self.isDevTunnelInstalling = true
                                DevTunnelService.shared.installBinary { result in
                                    self.isDevTunnelInstalling = false
                                    switch result {
                                    case .success(let path):
                                        self.devTunnelBinaryPath = path
                                    case .failure(let error):
                                        self.devTunnelInstallError = error.localizedDescription
                                    }
                                }
                            }) {
                                HStack(spacing: 4) {
                                    if isDevTunnelInstalling {
                                        ProgressView().controlSize(.small)
                                    }
                                    Text(isDevTunnelInstalling ? L("安装中...", "Installing...") : L("一键安装", "Install"))
                                }
                            }
                            .controlSize(.small)
                            .disabled(isDevTunnelInstalling)
                        }

                        if let installError = devTunnelInstallError {
                            Text(L("安装失败: \(installError)", "Install failed: \(installError)"))
                                .font(.caption2)
                                .foregroundColor(.red)
                        }

                        Text(L(
                            "也可自行安装后重启 App（如 brew install --cask devtunnel），MacHead 会自动识别 PATH 中的命令。",
                            "Or install manually (e.g. 'brew install --cask devtunnel') and relaunch MacHead."
                        ))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(8)
                .background(Color.primary.opacity(0.04))
                .cornerRadius(6)

                // Account Login Status Card
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("微软 / GitHub 账号鉴权", "Microsoft / GitHub Authentication"))
                        .font(.caption)
                        .fontWeight(.semibold)

                    HStack {
                        if let user = devTunnelLoggedInUser {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundColor(.green)
                            Text(L("已登录: \(user)", "Signed in: \(user)"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Button(L("退出登录", "Sign Out")) {
                                DevTunnelService.shared.logout()
                                self.devTunnelLoggedInUser = nil
                            }
                            .controlSize(.small)
                        } else {
                            Image(systemName: "person.crop.circle.badge.questionmark")
                                .foregroundColor(.orange)
                            Text(L("尚未登录账号 (可通过浏览器一键授权)", "Not signed in (authorize via browser)"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(action: {
                                self.isDevTunnelLoggingIn = true
                                DevTunnelService.shared.loginWithBrowser(provider: "github") { success, msg in
                                    self.isDevTunnelLoggingIn = false
                                    self.devTunnelLoggedInUser = DevTunnelService.shared.checkUserLoginStatus()
                                }
                            }) {
                                HStack(spacing: 4) {
                                    if isDevTunnelLoggingIn {
                                        ProgressView().controlSize(.small)
                                    }
                                    Text(L("登录 GitHub 账号", "Sign in with GitHub"))
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.04))
                    .cornerRadius(6)
                }

                // Quota & Traffic Usage Card
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L("月度流量与配额状态", "Monthly Bandwidth & Quota"))
                            .font(.caption)
                            .fontWeight(.semibold)
                        Spacer()
                        if isQueryingLimits {
                            ProgressView().controlSize(.small)
                        } else {
                            Button(L("刷新配额", "Refresh Quota")) {
                                self.isQueryingLimits = true
                                DevTunnelService.shared.queryUserLimits { info in
                                    self.isQueryingLimits = false
                                    self.devTunnelQuota = info
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.caption2)
                            .foregroundColor(.accentColor)
                        }
                    }

                    if let quota = devTunnelQuota {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(L(
                                    "已用流量: \(String(format: "%.2f", quota.bandwidthUsedGB)) GB / \(String(format: "%.1f", quota.bandwidthLimitGB)) GB",
                                    "Bandwidth Used: \(String(format: "%.2f", quota.bandwidthUsedGB)) GB / \(String(format: "%.1f", quota.bandwidthLimitGB)) GB"
                                ))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(Int(quota.bandwidthPercent))%")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .foregroundColor(quota.bandwidthPercent > 85 ? .red : (quota.bandwidthPercent > 60 ? .orange : .green))
                            }

                            ProgressView(value: quota.bandwidthPercent, total: 100.0)
                                .accentColor(quota.bandwidthPercent > 85 ? .red : (quota.bandwidthPercent > 60 ? .orange : .blue))

                            HStack {
                                Text(L(
                                    "活跃隧道数: \(quota.currentTunnels) / \(quota.maxTunnels)",
                                    "Active Tunnels: \(quota.currentTunnels) / \(quota.maxTunnels)"
                                ))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(8)
                        .background(Color.primary.opacity(0.04))
                        .cornerRadius(6)
                    } else {
                        HStack {
                            Text(L(
                                "微软官方免费配额：每月 5 GB 流量，支持 10 条隧道与多端口多路复用。",
                                "Microsoft Free Quota: 5 GB monthly bandwidth, up to 10 tunnels and multi-port forwarding."
                            ))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(8)
                        .background(Color.primary.opacity(0.04))
                        .cornerRadius(6)
                    }
                }

                // Mode selector
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("隧道模式", "Tunnel Mode"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("", selection: Binding(
                        get: { self.devTunnelMode },
                        set: { self.devTunnelMode = $0; self.isDevTunnelConfigModified = true }
                    )) {
                        Text(L("账号自动模式 (推荐)", "Account Mode (Recommended)")).tag("login")
                        Text(L("Access Token 模式", "Access Token Mode")).tag("token")
                    }
                    .pickerStyle(.segmented)
                }

                if devTunnelMode == "token" {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("Tunnel ID (选填)", "Tunnel ID (Optional)"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField(L("例如: machead-server", "e.g. machead-server"), text: Binding(
                            get: { self.devTunnelId },
                            set: { self.devTunnelId = $0; self.isDevTunnelConfigModified = true }
                        ))
                        .textFieldStyle(.roundedBorder)

                        Text(L("访问 Token", "Access Token"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        SecureField(L("输入 devtunnel 生成的 Access Token", "Enter devtunnel Access Token"), text: Binding(
                            get: { self.devTunnelToken },
                            set: { self.devTunnelToken = $0; self.isDevTunnelConfigModified = true }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                }

                // Local Port Forwarding Rules
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L("本地端口映射配置", "Local Port Forwarding Rules"))
                            .font(.caption)
                            .fontWeight(.semibold)
                        Spacer()
                        Button(action: {
                            var rules = self.devTunnelPortRules
                            rules.append(DevTunnelPortRule(name: L("自定义服务 \(rules.count + 1)", "Custom Service \(rules.count + 1)"), port: "", protocolType: "auto", isEnabled: true))
                            self.devTunnelPortRules = rules
                            self.isDevTunnelConfigModified = true
                        }) {
                            HStack(spacing: 3) {
                                Image(systemName: "plus.circle.fill")
                                Text(L("添加端口", "Add Port"))
                            }
                            .font(.caption2)
                            .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)
                    }

                    VStack(spacing: 6) {
                        ForEach(devTunnelPortRules.indices, id: \.self) { idx in
                            HStack(spacing: 8) {
                                Toggle("", isOn: Binding(
                                    get: { devTunnelPortRules[idx].isEnabled },
                                    set: { devTunnelPortRules[idx].isEnabled = $0; isDevTunnelConfigModified = true }
                                ))
                                .toggleStyle(.checkbox)
                                .labelsHidden()

                                TextField(L("服务名称", "Service Name"), text: Binding(
                                    get: { devTunnelPortRules[idx].name },
                                    set: { devTunnelPortRules[idx].name = $0; isDevTunnelConfigModified = true }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 130)

                                TextField(L("本地端口", "Local Port"), text: Binding(
                                    get: { devTunnelPortRules[idx].port },
                                    set: { devTunnelPortRules[idx].port = $0; isDevTunnelConfigModified = true }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 75)

                                Picker("", selection: Binding(
                                    get: { devTunnelPortRules[idx].protocolType },
                                    set: { devTunnelPortRules[idx].protocolType = $0; isDevTunnelConfigModified = true }
                                )) {
                                    Text(L("自动", "Auto")).tag("auto")
                                    Text("HTTP").tag("http")
                                    Text("HTTPS").tag("https")
                                }
                                .pickerStyle(.menu)
                                .frame(width: 85)

                                if devTunnelPortRules.count > 1 {
                                    Button(action: {
                                        var rules = self.devTunnelPortRules
                                        rules.remove(at: idx)
                                        self.devTunnelPortRules = rules
                                        self.isDevTunnelConfigModified = true
                                    }) {
                                        Image(systemName: "trash")
                                            .foregroundColor(.red.opacity(0.8))
                                            .font(.caption)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.04))
                    .cornerRadius(8)

                    Toggle(L("允许公网匿名访问 (免 GitHub OAuth 拦截)", "Allow Anonymous Public Access (Bypass GitHub OAuth Gate)"), isOn: Binding(
                        get: { self.devTunnelAllowAnonymous },
                        set: { self.devTunnelAllowAnonymous = $0; self.isDevTunnelConfigModified = true }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .padding(.top, 4)
                }

                // Test result banner
                if let result = devTunnelTestResult {
                    HStack(spacing: 8) {
                        Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(result.success ? .green : .red)
                            .font(.caption)
                        Text(result.message)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(result.success ? Color.green.opacity(0.1) : Color.red.opacity(0.1))
                    .cornerRadius(6)
                }

                HStack {
                    Button(action: {
                        self.isDevTunnelTesting = true
                        self.devTunnelTestResult = nil
                        DevTunnelService.shared.testConnection(
                            mode: self.devTunnelMode,
                            tunnelId: self.devTunnelId,
                            token: self.devTunnelToken,
                            allowAnonymous: self.devTunnelAllowAnonymous,
                            rules: self.devTunnelPortRules
                        ) { success, msg in
                            self.isDevTunnelTesting = false
                            self.devTunnelTestResult = (success, msg)
                        }
                    }) {
                        HStack(spacing: 6) {
                            if isDevTunnelTesting {
                                ProgressView().controlSize(.small)
                            }
                            Text(isDevTunnelTesting ? L("正在测试...", "Testing...") : L("测试连接", "Test Connection"))
                        }
                    }
                    .disabled(isDevTunnelTesting)

                    Spacer()

                    Button(L("取消", "Cancel")) {
                        self.devTunnelTestResult = nil
                        self.showDevTunnelConfig = false
                    }
                    .buttonStyle(.plain)

                    Button(L("保存并应用", "Save & Apply")) {
                        self.devTunnelTestResult = nil
                        if self.isDevTunnelConfigModified {
                            self.isDevTunnelConfigModified = false
                            DevTunnelService.savePortRules(self.devTunnelPortRules)
                            UserDefaults.standard.set(self.devTunnelMode, forKey: "devTunnelMode")
                            UserDefaults.standard.set(self.devTunnelId, forKey: "devTunnelId")
                            UserDefaults.standard.set(self.devTunnelToken, forKey: "devTunnelToken")
                            UserDefaults.standard.set(self.devTunnelAllowAnonymous, forKey: "devTunnelAllowAnonymous")
                            UserDefaults.standard.set(self.devTunnelEnableSSH, forKey: "devTunnelEnableSSH")
                            IntegrationManager.shared.reloadServices()
                        }
                        self.showDevTunnelConfig = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .frame(width: 460)
        }

        .sheet(isPresented: $showFrpConfig) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(L("FRP 内网穿透配置 (frpc)", "FRP Reverse Proxy Settings (frpc)"))
                        .font(.headline)
                        .fontWeight(.bold)

                    Toggle(L("启用服务", "Enable"), isOn: Binding(
                        get: { self.frpEnabled },
                        set: { newValue in
                            self.frpEnabled = newValue
                            UserDefaults.standard.set(newValue, forKey: "frpEnabled")
                            if newValue {
                                FrpService.shared.start()
                            } else {
                                FrpService.shared.stop()
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .padding(.leading, 8)

                    Spacer()

                    Button(L("测试连接并启用", "Test & Enable")) {
                        self.frpEnabled = true
                        UserDefaults.standard.set(true, forKey: "frpEnabled")
                        FrpService.saveRules(self.frpRules)
                        FrpService.shared.stop()
                        DispatchQueue.global(qos: .userInitiated).async {
                            Thread.sleep(forTimeInterval: 0.2)
                            FrpService.shared.start()
                        }
                    }
                    .controlSize(.small)
                }

                // 实时诊断卡片
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(frpStatusColor)
                            .frame(width: 8, height: 8)
                        Text(L("当前状态:", "Status:"))
                            .font(.caption)
                            .fontWeight(.semibold)
                        Text(frpStatusBadgeText)
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(frpStatusColor)
                    }

                    Text(frpStatus.displayText)
                        .font(.caption2)
                        .foregroundColor(frpStatusColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(frpStatusColor.opacity(0.1))
                .cornerRadius(8)

                Picker(L("配置模式", "Config Mode"), selection: Binding(
                    get: { self.frpMode },
                    set: { newValue in
                        self.frpMode = newValue
                        UserDefaults.standard.set(newValue, forKey: "frpMode")
                        self.isFrpConfigModified = true
                    }
                )) {
                    Text(L("快捷模式", "Quick Mode")).tag("quick")
                    Text(L("自定义配置", "Custom Config")).tag("custom")
                }
                .pickerStyle(.segmented)

                if frpMode == "quick" {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            // 服务端信息卡片
                            VStack(alignment: .leading, spacing: 10) {
                                Text(L("FRP 服务端基本信息", "FRP Server Details"))
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.secondary)

                                HStack {
                                    Text(L("服务器地址:", "Server Addr:"))
                                        .foregroundColor(.secondary)
                                        .frame(width: 90, alignment: .leading)
                                    TextField(L("x.x.x.x 或 frp.domain.com", "x.x.x.x or frp.domain.com"), text: $frpServerAddr)
                                        .textFieldStyle(.roundedBorder)
                                        .onChange(of: frpServerAddr) { newValue in
                                            UserDefaults.standard.set(newValue, forKey: "frpServerAddr")
                                            self.isFrpConfigModified = true
                                        }
                                }

                                HStack {
                                    Text(L("服务器端口:", "Server Port:"))
                                        .foregroundColor(.secondary)
                                        .frame(width: 90, alignment: .leading)
                                    TextField("7000", text: $frpServerPort)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 100)
                                        .onChange(of: frpServerPort) { newValue in
                                            UserDefaults.standard.set(newValue, forKey: "frpServerPort")
                                            self.isFrpConfigModified = true
                                        }
                                }

                                HStack {
                                    Text(L("认证 Token:", "Auth Token:"))
                                        .foregroundColor(.secondary)
                                        .frame(width: 90, alignment: .leading)
                                    SecureField(L("可选，无 Token 可留空", "Optional (leave empty if none)"), text: $frpToken)
                                        .textFieldStyle(.roundedBorder)
                                        .onChange(of: frpToken) { newValue in
                                            UserDefaults.standard.set(newValue, forKey: "frpToken")
                                            self.isFrpConfigModified = true
                                        }
                                }

                                HStack {
                                    Text(L("frpc 路径:", "frpc Path:"))
                                        .foregroundColor(.secondary)
                                        .frame(width: 90, alignment: .leading)
                                    TextField(L("自动使用内置 frpc 或系统路径", "Auto-detect bundled or system frpc"), text: $frpBinaryPath)
                                        .textFieldStyle(.roundedBorder)
                                        .onChange(of: frpBinaryPath) { newValue in
                                            UserDefaults.standard.set(newValue, forKey: "frpBinaryPath")
                                            self.isFrpConfigModified = true
                                        }
                                    Button(L("浏览...", "Browse...")) {
                                        let panel = NSOpenPanel()
                                        panel.canChooseFiles = true
                                        panel.canChooseDirectories = false
                                        panel.allowsMultipleSelection = false
                                        panel.message = L("选择 frpc 可执行文件", "Select frpc binary")
                                        panel.prompt = L("选择", "Select")
                                        if panel.runModal() == .OK, let url = panel.url {
                                            self.frpBinaryPath = url.path
                                            UserDefaults.standard.set(url.path, forKey: "frpBinaryPath")
                                            self.isFrpConfigModified = true
                                        }
                                    }
                                    .controlSize(.small)
                                }
                            }
                            .padding(12)
                            .background(Color.primary.opacity(0.04))
                            .cornerRadius(8)

                            // 代理隧道规则列表栏
                            HStack {
                                Text(L("代理隧道映射规则 (\(frpRules.count) 条)", "Proxy Mapping Rules (\(frpRules.count))"))
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.secondary)

                                Spacer()

                                Button(action: {
                                    let newRule = FrpProxyRule(
                                        name: "proxy-\(frpRules.count + 1)",
                                        type: "tcp",
                                        localIP: "127.0.0.1",
                                        localPort: "8080",
                                        remotePort: "\(8080 + frpRules.count)"
                                    )
                                    self.frpRules.append(newRule)
                                    FrpService.saveRules(self.frpRules)
                                    self.isFrpConfigModified = true
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "plus.circle.fill")
                                        Text(L("添加隧道规则", "Add Proxy Rule"))
                                    }
                                    .font(.caption.weight(.medium))
                                }
                                .buttonStyle(.borderless)
                            }

                            if frpRules.isEmpty {
                                VStack(spacing: 8) {
                                    Text(L("暂无代理隧道映射规则", "No proxy mapping rules configured"))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Button(L("添加默认规则 (SSH + Web)", "Add Default Rules (SSH + Web)")) {
                                        self.frpRules = FrpService.loadRules()
                                        self.frpBinaryPath = UserDefaults.standard.string(forKey: "frpBinaryPath") ?? ""
                                        FrpService.saveRules(self.frpRules)
                                        self.isFrpConfigModified = true
                                    }
                                    .controlSize(.small)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(16)
                                .background(Color.primary.opacity(0.03))
                                .cornerRadius(8)
                            } else {
                                ForEach(Array(frpRules.enumerated()), id: \.element.id) { index, rule in
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Text("#\(index + 1)")
                                                .font(.caption2)
                                                .fontWeight(.bold)
                                                .foregroundColor(.secondary)
                                                .frame(width: 20)

                                            TextField(L("规则名称", "Rule Name"), text: Binding(
                                                get: { self.frpRules[index].name },
                                                set: { newValue in
                                                    self.frpRules[index].name = newValue
                                                    FrpService.saveRules(self.frpRules)
                                                    self.isFrpConfigModified = true
                                                }
                                            ))
                                            .textFieldStyle(.roundedBorder)
                                            .frame(width: 140)

                                            Picker("", selection: Binding(
                                                get: { self.frpRules[index].type },
                                                set: { newValue in
                                                    self.frpRules[index].type = newValue
                                                    FrpService.saveRules(self.frpRules)
                                                    self.isFrpConfigModified = true
                                                }
                                            )) {
                                                Text("TCP").tag("tcp")
                                                Text("UDP").tag("udp")
                                                Text("HTTP").tag("http")
                                                Text("HTTPS").tag("https")
                                            }
                                            .pickerStyle(.segmented)
                                            .frame(width: 180)

                                            Spacer()

                                            Button(action: {
                                                self.frpRules.remove(at: index)
                                                FrpService.saveRules(self.frpRules)
                                                self.isFrpConfigModified = true
                                            }) {
                                                Image(systemName: "trash")
                                                    .foregroundColor(.red)
                                            }
                                            .buttonStyle(.borderless)
                                            .help(L("删除此规则", "Delete rule"))
                                        }

                                        HStack(spacing: 8) {
                                            Text(L("本地IP:", "Local IP:"))
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                            TextField("127.0.0.1", text: Binding(
                                                get: { self.frpRules[index].localIP },
                                                set: { newValue in
                                                    self.frpRules[index].localIP = newValue
                                                    FrpService.saveRules(self.frpRules)
                                                    self.isFrpConfigModified = true
                                                }
                                            ))
                                            .textFieldStyle(.roundedBorder)
                                            .frame(width: 90)

                                            Text(L("本地端口:", "Local Port:"))
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                            TextField("22", text: Binding(
                                                get: { self.frpRules[index].localPort },
                                                set: { newValue in
                                                    self.frpRules[index].localPort = newValue
                                                    FrpService.saveRules(self.frpRules)
                                                    self.isFrpConfigModified = true
                                                }
                                            ))
                                            .textFieldStyle(.roundedBorder)
                                            .frame(width: 55)

                                            if frpRules[index].type == "tcp" || frpRules[index].type == "udp" {
                                                Text(L("远程端口:", "Remote Port:"))
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                                TextField("6022", text: Binding(
                                                    get: { self.frpRules[index].remotePort },
                                                    set: { newValue in
                                                        self.frpRules[index].remotePort = newValue
                                                        FrpService.saveRules(self.frpRules)
                                                        self.isFrpConfigModified = true
                                                    }
                                                ))
                                                .textFieldStyle(.roundedBorder)
                                                .frame(width: 65)
                                            } else {
                                                Text(L("绑定域名:", "Domain:"))
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                                TextField("domain.com", text: Binding(
                                                    get: { self.frpRules[index].customDomains },
                                                    set: { newValue in
                                                        self.frpRules[index].customDomains = newValue
                                                        FrpService.saveRules(self.frpRules)
                                                        self.isFrpConfigModified = true
                                                    }
                                                ))
                                                .textFieldStyle(.roundedBorder)
                                                .frame(width: 110)
                                            }
                                        }
                                        .padding(.leading, 24)
                                    }
                                    .padding(10)
                                    .background(Color.primary.opacity(0.03))
                                    .cornerRadius(8)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                                    )
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("配置文件内容 (支持 TOML / INI 语法):", "Config File Content (TOML / INI):"))
                            .font(.caption)
                            .foregroundColor(.secondary)

                        TextEditor(text: Binding(
                            get: { self.frpCustomConfig },
                            set: { newValue in
                                self.frpCustomConfig = newValue
                                UserDefaults.standard.set(newValue, forKey: "frpCustomConfig")
                                self.isFrpConfigModified = true
                            }
                        ))
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 260)
                        .padding(4)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                        )
                    }
                }

                Spacer()

                HStack {
                    Spacer()
                    Button(L("完成", "Done")) {
                        FrpService.saveRules(self.frpRules)
                        if self.isFrpConfigModified {
                            self.isFrpConfigModified = false
                            IntegrationManager.shared.reloadServices()
                        }
                        self.showFrpConfig = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 540, height: 600)
        }

        .sheet(isPresented: $showKumaConfig) {
            VStack(alignment: .leading, spacing: 16) {
                Text(L("Uptime Kuma 推送配置", "Uptime Kuma Push Settings"))
                    .font(.headline)
                    .fontWeight(.bold)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(L("推送 URL:", "Push URL:"))
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
                        Text(L("汇报间隔:", "Interval:"))
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

                        Text(L("\(Int(kumaInterval)) 秒", "\(Int(kumaInterval))s"))
                            .fontWeight(.bold)
                    }
                }
                .padding(.vertical, 8)

                Spacer()

                HStack {
                    Spacer()
                    Button(L("完成", "Done")) {
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
            remoteSharing.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .appLanguageChanged)) { _ in
            updateConnectedDisplays()
            updateBatteryState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .headlessModeStateChanged)) { _ in
            updateConnectedDisplays()
            updateBatteryState()
        }
        
                .onReceive(NotificationCenter.default.publisher(for: .devTunnelStatusChanged)) { notif in
            if let status = notif.object as? DevTunnelStatus {
                self.devTunnelStatus = status
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cloudflareStatusChanged)) { notif in
            if let status = notif.object as? CloudflareStatus {
                self.cloudflareStatus = status
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tailcatAccountChanged)) { _ in
            self.tailcatAccountLoggedIn = TailcatService.shared.isAccountLoggedIn
            self.tailcatAccountName = TailcatService.shared.loggedInUserName
            self.tailcatAvatarImage = TailcatService.shared.cachedAvatarImage
            self.tailcatWaitingBrowserAuth = TailcatService.shared.isWaitingForBrowserAuth
        }
        .onReceive(NotificationCenter.default.publisher(for: .frpStatusChanged)) { notif in
            if let status = notif.object as? FrpStatus {
                self.frpStatus = status
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .nezhaStatusChanged)) { notif in
            if let status = notif.object as? NezhaStatus {
                self.nezhaStatus = status
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .webServerStateChanged)) { _ in
            self.webServerIP = WebServer.shared.getLocalIPAddress()
            self.webServerPort = String(WebServer.shared.currentPort)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            self.isAccessibilityTrusted = AXIsProcessTrusted()
            self.remoteSharing.refresh()
        }
    }

    private func updateBatteryState() {
        self.isMicrophoneMuted = MediaDeviceManager.shared.isMuted
        self.webServerIP = WebServer.shared.getLocalIPAddress()
        self.webServerPort = String(WebServer.shared.currentPort)
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
        
        self.frpEnabled = UserDefaults.standard.bool(forKey: "frpEnabled")
        self.frpMode = UserDefaults.standard.string(forKey: "frpMode") ?? "quick"
        self.frpServerAddr = UserDefaults.standard.string(forKey: "frpServerAddr") ?? ""
        self.frpServerPort = UserDefaults.standard.string(forKey: "frpServerPort") ?? "7000"
        self.frpToken = UserDefaults.standard.string(forKey: "frpToken") ?? ""
        self.frpProxyName = UserDefaults.standard.string(forKey: "frpProxyName") ?? "machead-ssh"
        self.frpProxyType = UserDefaults.standard.string(forKey: "frpProxyType") ?? "tcp"
        self.frpLocalIP = UserDefaults.standard.string(forKey: "frpLocalIP") ?? "127.0.0.1"
        self.frpLocalPort = UserDefaults.standard.string(forKey: "frpLocalPort") ?? "22"
        self.frpRemotePort = UserDefaults.standard.string(forKey: "frpRemotePort") ?? "6022"
        self.frpCustomDomains = UserDefaults.standard.string(forKey: "frpCustomDomains") ?? ""
        self.frpSubdomain = UserDefaults.standard.string(forKey: "frpSubdomain") ?? ""
        self.frpCustomConfig = UserDefaults.standard.string(forKey: "frpCustomConfig") ?? ""
        self.frpStatus = FrpService.shared.currentStatus
        self.frpRules = FrpService.loadRules()
        self.frpBinaryPath = UserDefaults.standard.string(forKey: "frpBinaryPath") ?? ""
        
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
        guard let displays = DisplayManager.shared.onlineDisplayIDs() else { return }

        self.connectedDisplays = displays.compactMap { id in
            let isBuiltIn = CGDisplayIsBuiltin(id) != 0
            // 虚拟/软件显示屏（unkn virt 等）不作为外接显示器列出，与菜单栏计数口径一致
            if !isBuiltIn && DisplayManager.isVirtualDisplay(id) { return nil }
            let vendorID = CGDisplayVendorNumber(id)
            let isApple = vendorID == 0x05AC // Apple's Vendor ID
            let name: String
            if isBuiltIn {
                name = L("内置显示屏 (Color LCD)", "Built-in Display (Color LCD)")
            } else {
                name = isApple ? L("Apple 显示器 (ID: \(id))", "Apple Display (ID: \(id))") : L("外接显示器 (ID: \(id))", "External Display (ID: \(id))")
            }
            return DisplayInfo(id: id, name: name, isBuiltIn: isBuiltIn, isApple: isApple)
        }
    }

    private var displayWebServerPort: String {
        if let portNum = Int(webServerPort), portNum >= 1 && portNum <= 65535 {
            return String(portNum)
        }
        return WebServer.shared.portString
    }

    private func commitWebServerPort() {
        let trimmed = webServerPort.trimmingCharacters(in: .whitespacesAndNewlines)
        if let portNum = Int(trimmed), portNum >= 1 && portNum <= 65535 {
            let oldPort = UserDefaults.standard.integer(forKey: "WebServerPort")
            if oldPort != portNum {
                UserDefaults.standard.set(portNum, forKey: "WebServerPort")
                if enableWebServer {
                    WebServer.shared.restart()
                }
            }
        } else {
            let current = WebServer.shared.currentPort
            webServerPort = "\(current)"
            UserDefaults.standard.set(Int(current), forKey: "WebServerPort")
        }
        self.webServerIP = WebServer.shared.getLocalIPAddress()
    }

    @ViewBuilder
    private func serviceStatusBadge(isActive: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isActive ? Color.green : Color.gray)
                .frame(width: 6, height: 6)
            Text(isActive ? L("已监听", "Listening") : L("未开启", "Disabled"))
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundColor(isActive ? .green : .secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background((isActive ? Color.green : Color.gray).opacity(0.12))
        .cornerRadius(5)
    }

    @ViewBuilder
    private func copyButton(for text: String, serviceKey: String) -> some View {
        Button(action: {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copiedServiceHint = serviceKey
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                if self.copiedServiceHint == serviceKey {
                    self.copiedServiceHint = nil
                }
            }
        }) {
            Image(systemName: copiedServiceHint == serviceKey ? "checkmark" : "doc.on.doc")
                .font(.caption)
                .foregroundColor(copiedServiceHint == serviceKey ? .green : .secondary)
        }
        .buttonStyle(.borderless)
        .help(L("复制连接链接", "Copy connection URL"))
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
