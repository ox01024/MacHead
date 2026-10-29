import SwiftUI
import AppKit

struct StatusPopoverView: View {
    @ObservedObject private var l10n = LocalizationManager.shared
    @ObservedObject private var battery = BatteryManager.shared
    @ObservedObject private var smc = SMCManager.shared
    @State private var isHeadless = HeadlessModeController.shared.isHeadlessModeEnabled
    @State private var externalDisplaysCount = HeadlessModeController.shared.currentExternalDisplays().count
    @State private var webServerIP = WebServer.shared.getLocalIPAddress()
    @State private var copiedServerInfo = false
    @State private var tailcatStatus: TailcatStatus = TailcatService.shared.currentStatus
    @State private var tailcatAccountLoggedIn = TailcatService.shared.isAccountLoggedIn
    @State private var tailcatAccountName = TailcatService.shared.loggedInUserName

    var onOpenPreferences: () -> Void
    var onQuitApp: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            // MARK: - Header
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: isHeadless ? "macmini.fill" : "laptopcomputer")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(isHeadless ? .purple : .green)

                    Text("MacHead")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                }

                Spacer()

                Button(action: {
                    l10n.toggleLanguage()
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "globe")
                            .font(.system(size: 10, weight: .medium))
                        Text(l10n.isEnglish ? "EN" : "中")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(0.06))
                    )
                }
                .buttonStyle(PlainButtonStyle())
                .help(L("切换界面语言 (中文 / English)", "Switch Language (中文 / English)"))

                HStack(spacing: 4) {
                    Circle()
                        .fill(isHeadless ? Color.purple : Color.green)
                        .frame(width: 8, height: 8)
                    Text(isHeadless ? L("无头模式", "Headless") : L("正常运行", "Normal"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(isHeadless ? Color.purple.opacity(0.15) : Color.green.opacity(0.15))
                )
            }

            // MARK: - Hero Mode Toggle Button
            Button(action: {
                if isHeadless {
                    HeadlessModeController.shared.disableHeadlessMode()
                } else {
                    HeadlessModeController.shared.enableHeadlessMode()
                }
                isHeadless = HeadlessModeController.shared.isHeadlessModeEnabled
            }) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.2))
                            .frame(width: 36, height: 36)

                        Image(systemName: isHeadless ? "sun.max.fill" : "moon.stars.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(isHeadless
                             ? L("恢复内置屏幕显示", "Restore Built-In Display")
                             : L("开启 Headless 无头模式", "Enable Headless Mode"))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)

                        Text(isHeadless
                             ? L("内屏已断开 · 再次点击即可恢复", "Internal screen off · Click to restore")
                             : L("安全断开内屏 · 降温省电挂机", "Power off internal display · Cool & save power"))
                            .font(.system(size: 11))
                            .foregroundColor(Color.white.opacity(0.85))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.7))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(height: 60)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: isHeadless ? [Color.green, Color.teal] : [Color.purple, Color.indigo],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                )
                .shadow(color: (isHeadless ? Color.green : Color.purple).opacity(0.3), radius: 8, x: 0, y: 4)
            }
            .buttonStyle(PlainButtonStyle())

            // MARK: - Metrics Cards Grid
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                // Card 1: 屏幕与外设
                MetricTileView(
                    icon: "display",
                    iconColor: .blue,
                    title: L("显示器", "Displays"),
                    value: isHeadless ? L("内屏已熄灭", "Internal Off") : L("内屏亮起", "Internal On"),
                    subtitle: externalDisplaysCount > 0
                        ? L("外接屏: \(externalDisplaysCount) 台", "External: \(externalDisplaysCount) connected")
                        : L("未接入外设屏", "No external display")
                )

                // Card 2: 电池与电源状态
                MetricTileView(
                    icon: powerTileIcon,
                    iconColor: powerTileColor,
                    title: battery.isUPSActive ? L("UPS 供电中", "On Battery (UPS)") : L("电源状态", "Power Source"),
                    value: "\(battery.currentCapacity)%",
                    subtitle: powerTileSubtitle
                )

                // Card 3: CPU 与热度
                MetricTileView(
                    icon: "thermometer.medium",
                    iconColor: smc.currentTemperature > 75 ? .red : .teal,
                    title: L("CPU 温度", "CPU Thermal"),
                    value: smc.currentTemperature > 0 ? String(format: "%.1f °C", smc.currentTemperature) : "-- °C",
                    subtitle: smc.fanSpeed > 0
                        ? L("风扇: \(smc.fanSpeed) RPM", "Fan: \(smc.fanSpeed) RPM")
                        : L("静音被动散热", "Silent / Passive")
                )

                // Card 4: 电池健康/寿命
                MetricTileView(
                    icon: battery.powerWatts > 0 ? "bolt.fill" : "heart.fill",
                    iconColor: battery.isUPSActive ? .orange : (battery.batteryHealth >= 80 ? .green : .orange),
                    title: battery.powerWatts > 0 ? L("即时功耗", "Live Power") : L("电池健康度", "Battery Health"),
                    value: battery.powerWatts > 0
                        ? String(format: "%.1f W", battery.powerWatts)
                        : (battery.batteryHealth > 0 ? String(format: "%.0f%%", battery.batteryHealth) : L("正常", "Normal")),
                    subtitle: battery.powerWatts > 0
                        ? L("健康: \(Int(battery.batteryHealth))% · \(battery.cycleCount)次", "Health: \(Int(battery.batteryHealth))% · \(battery.cycleCount) cyc")
                        : batteryHealthSubtitle
                )
            }

            // MARK: - Web Server & Quick Access Banner
            if UserDefaults.standard.bool(forKey: "EnableWebServer") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: "globe")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.blue)
                            Text(L("Web 控制台与 API", "LAN Web Console & API"))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                        Text(verbatim: "http://\(webServerIP):\(WebServer.shared.portString)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button(action: {
                        let urlStr = "http://\(webServerIP):\(WebServer.shared.portString)"
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(urlStr, forType: .string)
                        copiedServerInfo = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            copiedServerInfo = false
                        }
                    }) {
                        Text(copiedServerInfo ? L("已复制", "Copied") : L("复制链接", "Copy URL"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.blue)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.12))
                            .cornerRadius(6)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
            }

            if case .connected = tailcatStatus, tailcatAccountLoggedIn {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: "icloud.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.green)
                            Text(L("Web 终端已同步至云端", "Synced with MacHead Cloud"))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                        Text(verbatim: L("账号: \(tailcatAccountName)", "Account: \(tailcatAccountName)"))
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(.green)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button(action: {
                        if let url = URL(string: TailcatService.shared.dashEntryUrl) {
                            NSWorkspace.shared.open(url)
                        }
                    }) {
                        Text(L("打开 Dash", "Open Dash"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.green)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.green.opacity(0.14))
                            .cornerRadius(6)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
            }

            Divider()

            // MARK: - Footer Actions
            HStack {
                Button(action: onOpenPreferences) {
                    HStack(spacing: 4) {
                        Image(systemName: "gearshape.fill")
                        Text(L("偏好设置...", "Settings..."))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                }
                .buttonStyle(PlainButtonStyle())

                Spacer()

                Button(action: onQuitApp) {
                    HStack(spacing: 4) {
                        Image(systemName: "power")
                        Text(L("退出", "Quit"))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.red)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(14)
        .frame(width: 330)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeInOut(duration: 0.15), value: isHeadless)
        .onAppear {
            self.webServerIP = WebServer.shared.getLocalIPAddress()
            self.tailcatStatus = TailcatService.shared.currentStatus
        }
        .onReceive(NotificationCenter.default.publisher(for: .tailcatStatusChanged)) { notif in
            if let status = notif.object as? TailcatStatus {
                self.tailcatStatus = status
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tailcatAccountChanged)) { _ in
            self.tailcatAccountLoggedIn = TailcatService.shared.isAccountLoggedIn
            self.tailcatAccountName = TailcatService.shared.loggedInUserName
        }
        .onReceive(NotificationCenter.default.publisher(for: .headlessModeStateChanged)) { _ in
            self.isHeadless = HeadlessModeController.shared.isHeadlessModeEnabled
            self.externalDisplaysCount = HeadlessModeController.shared.currentExternalDisplays().count
            self.webServerIP = WebServer.shared.getLocalIPAddress()
        }
        .onReceive(NotificationCenter.default.publisher(for: .webServerStateChanged)) { _ in
            self.webServerIP = WebServer.shared.getLocalIPAddress()
        }
    }

    // MARK: - Computed Properties for Metrics Cards
    private var powerTileIcon: String {
        if battery.isCharging { return "bolt.batteryblock.fill" }
        if battery.isUPSActive { return "bolt.slash.fill" }
        if battery.isChargeLimitEnabled { return "checkmark.shield.fill" }
        return "battery.100"
    }

    private var powerTileColor: Color {
        if battery.isCharging { return .green }
        if battery.isUPSActive { return .orange }
        if battery.isChargeLimitEnabled { return .green }
        return .blue
    }

    private var powerTileSubtitle: String {
        if battery.isUPSActive {
            let time = battery.timeRemainingFormatted.isEmpty
                ? L("测算中", "Estimating")
                : battery.timeRemainingFormatted
            return "🔋 UPS (\(time))"
        }
        let adapterStr = battery.adapterWatts > 0 ? "\(battery.adapterWatts)W" : "AC"
        if battery.isCharging {
            return L("⚡️ 充电中 (\(adapterStr))", "⚡️ Charging (\(adapterStr))")
        }
        if battery.isChargeLimitEnabled {
            return L("⚡️ AC 直供 (\(battery.chargeLimitPercent)% 限充)", "⚡️ AC Direct (\(battery.chargeLimitPercent)% Limit)")
        }
        return L("⚡️ AC 直供 (\(adapterStr))", "⚡️ AC Direct (\(adapterStr))")
    }

    private var batteryHealthSubtitle: String {
        let tempStr = battery.batteryTemperature > 0
            ? String(format: "%.1f°C", battery.batteryTemperature)
            : L("良好", "Good")
        return L("循环 \(battery.cycleCount) 次 · \(tempStr)", "\(battery.cycleCount) cycles · \(tempStr)")
    }
}

struct MetricTileView: View {
    let icon: String
    let iconColor: Color
    let title: String
    let value: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(iconColor)

                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }

            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
                .lineLimit(1)

            Text(subtitle)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}
