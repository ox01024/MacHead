import Foundation
import Network
import SystemConfiguration

extension Notification.Name {
    public static let webServerStateChanged = Notification.Name("com.waffle.MacHead.webServerStateChanged")
}

final class WebServer {
    static let shared = WebServer()
    static let defaultPort: UInt16 = 8080

    var currentPort: UInt16 {
        let stored = UserDefaults.standard.integer(forKey: "WebServerPort")
        if stored >= 1 && stored <= 65535 {
            return UInt16(stored)
        }
        return Self.defaultPort
    }

    var portString: String {
        return String(currentPort)
    }

    var isRunning: Bool {
        return listener != nil
    }

    private let sessionToken = "MacHeadSession-\(UUID().uuidString)"

    private var listener: NWListener?
    private var lastCPUInfo: processor_info_array_t?
    private var lastCPUInfoCount: mach_msg_type_number_t = 0

    private var lastNetworkTime: Date?
    private var lastInboundBytes: UInt64 = 0
    private var lastOutboundBytes: UInt64 = 0

    private init() {}

    func start() {
        let enableWebServer = UserDefaults.standard.bool(forKey: "EnableWebServer")
        guard enableWebServer else { return }
        guard listener == nil else { return }

        let portNumber = currentPort
        guard let port = NWEndpoint.Port(rawValue: portNumber) else { return }

        do {
            let newListener = try NWListener(using: .tcp, on: port)
            self.listener = newListener

            newListener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    NSLog("MacHead: Web 服务器启动就绪，端口: %d", portNumber)
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .webServerStateChanged, object: nil)
                    }
                case .failed(let error):
                    NSLog("MacHead: Web 服务器失败: %@", error.localizedDescription)
                    self?.stop()
                default:
                    break
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .main)
                self?.handleConnection(connection)
            }

            newListener.start(queue: .main)
        } catch {
            NSLog("MacHead: 无法启动 Web 服务器: %@", error.localizedDescription)
        }
    }

    func stop() {
        if let activeListener = listener {
            activeListener.cancel()
            listener = nil
            NSLog("MacHead: Web 服务器已关闭")
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .webServerStateChanged, object: nil)
            }
        }
    }

    func restart() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.start()
        }
    }
    
    private func handleConnection(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, context, isComplete, error in
            guard let data = data, !data.isEmpty else {
                connection.cancel()
                return
            }
            
            let requestStr = String(decoding: data, as: UTF8.self)
            let parts = requestStr.components(separatedBy: "\r\n\r\n")
            let headersPart = parts[0]
            let bodyPart = parts.count > 1 ? parts[1] : ""
            
            let lines = headersPart.components(separatedBy: "\r\n")
            guard !lines.isEmpty else {
                connection.cancel()
                return
            }
            
            let firstLineParts = lines[0].components(separatedBy: " ")
            guard firstLineParts.count >= 2 else {
                connection.cancel()
                return
            }
            
            let method = firstLineParts[0]
            let path = firstLineParts[1]
            
            // Enforce Same-Origin check on POST requests to prevent cross-site CSRF
            if method == "POST" && !self.verifySameOriginPost(headers: lines) {
                let forbidden = "{\"error\":\"forbidden cross-origin request\"}".data(using: .utf8)!
                self.sendResponse(statusCode: 403, statusText: "Forbidden", content: forbidden, contentType: "application/json", connection: connection)
                return
            }

            // Route "/login" and "/logout" without global auth block
            if path == "/login" {
                if method == "GET" {
                    self.sendResponse(html: self.getLoginHTML(), connection: connection)
                } else if method == "POST" {
                    let enteredPassword = self.extractPassword(from: bodyPart) ?? ""
                    let correctPassword = UserDefaults.standard.string(forKey: "WebServerPassword") ?? ""

                    if correctPassword.isEmpty || self.constantTimeEqual(enteredPassword, correctPassword) {
                        let cookieHeader = "Set-Cookie: session=\(self.sessionToken); Path=/; HttpOnly; SameSite=Strict"
                        self.sendRedirect(to: "/", extraHeaders: [cookieHeader], connection: connection)
                    } else {
                        self.sendResponse(html: self.getLoginHTML(errorZh: "密码错误，请重新输入", errorEn: "Incorrect password. Please try again."), connection: connection)
                    }
                }
                return
            }
            
            if method == "GET" && path == "/logout" {
                let cookieHeader = "Set-Cookie: session=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT"
                self.sendRedirect(to: "/login", extraHeaders: [cookieHeader], connection: connection)
                return
            }
            
            // Validate Authorization: Cookie session first, then HTTP Basic Auth fallback
            if !self.verifyAuthorization(headers: lines) {
                if path.hasPrefix("/api/") {
                    self.sendJSONUnauthorizedResponse(connection: connection)
                } else {
                    self.sendRedirect(to: "/login", connection: connection)
                }
                return
            }
            
            self.routeRequest(method: method, path: path, bodyPart: bodyPart, connection: connection)
        }
    }
    
    private func extractParameter(named name: String, from body: String) -> String? {
        let pairs = body.components(separatedBy: "&")
        for pair in pairs {
            let kv = pair.components(separatedBy: "=")
            if kv.count == 2 && kv[0] == name {
                return kv[1].removingPercentEncoding
            }
        }
        return nil
    }

    private func extractPassword(from body: String) -> String? {
        return extractParameter(named: "password", from: body)
    }
    
    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        guard aBytes.count == bBytes.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<aBytes.count {
            diff |= aBytes[i] ^ bBytes[i]
        }
        return diff == 0
    }

    private func verifySameOriginPost(headers: [String]) -> Bool {
        var hostHeader = ""
        var originHeader = ""
        for line in headers {
            let lower = line.lowercased()
            if lower.hasPrefix("host:") {
                hostHeader = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            } else if lower.hasPrefix("origin:") {
                originHeader = line.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
        }
        if originHeader.isEmpty {
            return true
        }
        if originHeader == "null" {
            return false
        }
        guard let url = URL(string: originHeader), let originHost = url.host?.lowercased() else {
            return false
        }
        let originHostPort: String
        if let port = url.port {
            originHostPort = "\(originHost):\(port)"
        } else {
            originHostPort = originHost
        }
        return originHostPort == hostHeader || originHost == hostHeader
    }

    private func verifyAuthorization(headers: [String]) -> Bool {
        return verifySession(headers: headers)
    }

    private func verifySession(headers: [String]) -> Bool {
        let password = UserDefaults.standard.string(forKey: "WebServerPassword") ?? ""
        guard !password.isEmpty else { return true }

        for line in headers {
            if line.lowercased().hasPrefix("cookie:") {
                let cookieVal = line.dropFirst(7)
                for part in cookieVal.components(separatedBy: ";") {
                    let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("session=") {
                        let provided = String(trimmed.dropFirst("session=".count))
                        if constantTimeEqual(provided, sessionToken) {
                            return true
                        }
                    }
                }
            }
        }
        return false
    }
    
    private func sendJSONUnauthorizedResponse(connection: NWConnection) {
        let content = "{\"error\":\"unauthorized\"}".data(using: .utf8)!
        sendResponse(statusCode: 401, statusText: "Unauthorized", content: content, contentType: "application/json", connection: connection)
    }
    
    private func sendRedirect(to url: String, extraHeaders: [String] = [], connection: NWConnection) {
        let content = "Redirecting...".data(using: .utf8)!
        var redirectHeaders = ["Location: \(url)"]
        redirectHeaders.append(contentsOf: extraHeaders)
        sendResponse(statusCode: 302, statusText: "Found", content: content, contentType: "text/plain", extraHeaders: redirectHeaders, connection: connection)
    }
    
    private func routeRequest(method: String, path: String, bodyPart: String = "", connection: NWConnection) {
        if method == "GET" && path == "/" {
            sendResponse(html: getDashboardHTML(), connection: connection)
        } else if method == "GET" && path == "/api/status" {
            sendResponse(json: getStatusJSON(), connection: connection)
        } else if method == "POST" && path == "/api/toggle-headless" {
            DispatchQueue.main.async {
                if HeadlessModeController.shared.isHeadlessModeEnabled {
                    HeadlessModeController.shared.disableHeadlessMode()
                } else {
                    HeadlessModeController.shared.enableHeadlessMode()
                }
                NotificationCenter.default.post(name: .headlessModeStateChanged, object: nil)
                self.sendResponse(json: self.getStatusJSON(), connection: connection)
            }
        } else if method == "POST" && path == "/api/toggle-trackpad" {
            DispatchQueue.main.async {
                let key = "DisableTrackpadWhenExternalMouseConnected"
                let val = !UserDefaults.standard.bool(forKey: key)
                UserDefaults.standard.set(val, forKey: key)
                InputDeviceManager.shared.evaluateTrackpadAndKeyboardState()
                NotificationCenter.default.post(name: .headlessModeStateChanged, object: nil)
                self.sendResponse(json: self.getStatusJSON(), connection: connection)
            }
        } else if method == "POST" && path == "/api/toggle-keyboard-headless" {
            DispatchQueue.main.async {
                let key = "DisableKeyboardAndTrackpadInHeadlessMode"
                let val = !UserDefaults.standard.bool(forKey: key)
                UserDefaults.standard.set(val, forKey: key)
                InputDeviceManager.shared.evaluateTrackpadAndKeyboardState()
                NotificationCenter.default.post(name: .headlessModeStateChanged, object: nil)
                self.sendResponse(json: self.getStatusJSON(), connection: connection)
            }
        } else if method == "POST" && path == "/api/toggle-microphone" {
            DispatchQueue.main.async {
                let key = "MuteMicrophoneInHeadlessMode"
                let val = !UserDefaults.standard.bool(forKey: key)
                UserDefaults.standard.set(val, forKey: key)
                if HeadlessModeController.shared.isHeadlessModeEnabled {
                    if val {
                        MediaDeviceManager.shared.muteBuiltInMicrophone()
                    } else {
                        MediaDeviceManager.shared.forceUnmute()
                    }
                }
                NotificationCenter.default.post(name: .headlessModeStateChanged, object: nil)
                self.sendResponse(json: self.getStatusJSON(), connection: connection)
            }
        } else if method == "POST" && path == "/api/toggle-sleep" {
            DispatchQueue.main.async {
                let key = "PreventIdleSleep"
                let val = !UserDefaults.standard.bool(forKey: key)
                UserDefaults.standard.set(val, forKey: key)
                HeadlessModeController.shared.evaluatePowerAssertion()
                NotificationCenter.default.post(name: .headlessModeStateChanged, object: nil)
                self.sendResponse(json: self.getStatusJSON(), connection: connection)
            }
        } else if method == "POST" && path == "/api/toggle-keep-running" {
            DispatchQueue.main.async {
                let key = "KeepRunningOnLidClose"
                let val = !UserDefaults.standard.bool(forKey: key)
                UserDefaults.standard.set(val, forKey: key)
                HeadlessModeController.shared.evaluatePowerAssertion()
                NotificationCenter.default.post(name: .headlessModeStateChanged, object: nil)
                self.sendResponse(json: self.getStatusJSON(), connection: connection)
            }
        } else if method == "POST" && path == "/api/toggle-exit-on-disconnect" {
            DispatchQueue.main.async {
                let key = "AutoExitHeadlessOnDisconnect"
                let val = !UserDefaults.standard.bool(forKey: key)
                UserDefaults.standard.set(val, forKey: key)
                NotificationCenter.default.post(name: .headlessModeStateChanged, object: nil)
                self.sendResponse(json: self.getStatusJSON(), connection: connection)
            }

        } else if method == "POST" && path == "/api/toggle-cloudflare" {
            DispatchQueue.main.async {
                let key = "cloudflareEnabled"
                let val = !UserDefaults.standard.bool(forKey: key)
                UserDefaults.standard.set(val, forKey: key)
                IntegrationManager.shared.reloadServices()
                NotificationCenter.default.post(name: .headlessModeStateChanged, object: nil)
                self.sendResponse(json: self.getStatusJSON(), connection: connection)
            }
        } else if method == "POST" && path == "/api/save-cloudflare-token" {
            DispatchQueue.main.async {
                if let tokenVal = self.extractParameter(named: "token", from: bodyPart) {
                    UserDefaults.standard.set(tokenVal, forKey: "cloudflareToken")
                }
                IntegrationManager.shared.reloadServices()
                self.sendResponse(json: self.getStatusJSON(), connection: connection)
            }
        } else if method == "POST" && path == "/api/toggle-restore-on-connect" {
            DispatchQueue.main.async {
                let key = "AutoRestoreHeadlessOnConnect"
                let val = !UserDefaults.standard.bool(forKey: key)
                UserDefaults.standard.set(val, forKey: key)
                NotificationCenter.default.post(name: .headlessModeStateChanged, object: nil)
                self.sendResponse(json: self.getStatusJSON(), connection: connection)
            }
        } else if method == "POST" && path == "/api/toggle-charge-limit" {
            DispatchQueue.main.async {
                BatteryManager.shared.customLimitEnabled.toggle()
                self.sendResponse(json: self.getStatusJSON(), connection: connection)
            }
        } else if method == "POST" && path == "/api/set-charge-limit" {
            DispatchQueue.main.async {
                if let limitStr = self.extractParameter(named: "limit", from: bodyPart),
                   let intVal = Int(limitStr) {
                    BatteryManager.shared.customLimitThreshold = max(50, min(90, intVal))
                }
                self.sendResponse(json: self.getStatusJSON(), connection: connection)
            }
        } else {
            sendResponse(statusCode: 404, statusText: "Not Found", content: "Page Not Found".data(using: .utf8)!, contentType: "text/plain", connection: connection)
        }
    }
    
    private func sendResponse(html: String, connection: NWConnection) {
        let content = html.data(using: .utf8)!
        sendResponse(statusCode: 200, statusText: "OK", content: content, contentType: "text/html; charset=utf-8", connection: connection)
    }
    
    private func sendResponse(json: String, connection: NWConnection) {
        let content = json.data(using: .utf8)!
        sendResponse(statusCode: 200, statusText: "OK", content: content, contentType: "application/json", connection: connection)
    }
    
    private func sendResponse(statusCode: Int, statusText: String, content: Data, contentType: String, extraHeaders: [String] = [], connection: NWConnection) {
        var headersList = [
            "HTTP/1.1 \(statusCode) \(statusText)",
            "Content-Type: \(contentType)",
            "Content-Length: \(content.count)",
            "X-Frame-Options: DENY",
            "X-Content-Type-Options: nosniff",
            "Cache-Control: no-store",
            "Connection: close"
        ]
        headersList.append(contentsOf: extraHeaders)
        headersList.append("")
        headersList.append("")
        
        let headers = headersList.joined(separator: "\r\n")
        
        var responseData = headers.data(using: .utf8)!
        responseData.append(content)
        
        connection.send(content: responseData, completion: .contentProcessed({ error in
            connection.cancel()
        }))
    }
    
    private func getDiskUsage() -> (usedGB: Double, totalGB: Double, percent: Double) {
        let path = "/"
        let fileManager = FileManager.default
        do {
            let attrs = try fileManager.attributesOfFileSystem(forPath: path)
            if let totalBytes = attrs[.systemSize] as? Int64,
               let freeBytes = attrs[.systemFreeSize] as? Int64 {
                let totalGB = Double(totalBytes) / (1024.0 * 1024.0 * 1024.0)
                let freeGB = Double(freeBytes) / (1024.0 * 1024.0 * 1024.0)
                let usedGB = totalGB - freeGB
                let percent = totalGB > 0 ? (usedGB / totalGB) * 100.0 : 0.0
                return (usedGB, totalGB, percent)
            }
        } catch {
            NSLog("MacHead: Failed to get disk usage: %@", error.localizedDescription)
        }
        return (0.0, 0.0, 0.0)
    }
    
    private func getSystemUptime() -> String {
        let uptime = ProcessInfo.processInfo.systemUptime
        let days = Int(uptime) / 86400
        let hours = (Int(uptime) % 86400) / 3600
        let minutes = (Int(uptime) % 3600) / 60
        
        var parts: [String] = []
        if days > 0 {
            parts.append(L("\(days)天", "\(days)d"))
        }
        if hours > 0 || days > 0 {
            parts.append(L("\(hours)小时", "\(hours)h"))
        }
        parts.append(L("\(minutes)分钟", "\(minutes)m"))
        return parts.joined(separator: " ")
    }
    
    private func getThermalState() -> String {
        let state = ProcessInfo.processInfo.thermalState
        switch state {
        case .nominal:
            return "Nominal"
        case .fair:
            return "Fair"
        case .serious:
            return "Serious"
        case .critical:
            return "Critical"
        @unknown default:
            return "Unknown"
        }
    }
    
    private func getNetworkBytes() -> (ibytes: UInt64, obytes: UInt64) {
        var ibytes: UInt64 = 0
        var obytes: UInt64 = 0
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0 else { return (0, 0) }
        defer { freeifaddrs(ifaddr) }
        
        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            guard let interface = ptr?.pointee else { continue }
            let name = String(cString: interface.ifa_name)
            
            guard name != "lo0" else { continue }
            
            let addr = interface.ifa_addr.pointee
            if addr.sa_family == UInt8(AF_LINK) {
                if let data = interface.ifa_data {
                    let networkData = data.assumingMemoryBound(to: if_data.self)
                    ibytes += UInt64(networkData.pointee.ifi_ibytes)
                    obytes += UInt64(networkData.pointee.ifi_obytes)
                }
            }
        }
        return (ibytes, obytes)
    }
    
    private func getNetworkSpeed() -> (rxSpeed: Double, txSpeed: Double) {
        let currentBytes = getNetworkBytes()
        let now = Date()
        
        defer {
            lastInboundBytes = currentBytes.ibytes
            lastOutboundBytes = currentBytes.obytes
            lastNetworkTime = now
        }
        
        guard let lastTime = lastNetworkTime, lastInboundBytes > 0 else {
            return (0.0, 0.0)
        }
        
        let timeInterval = now.timeIntervalSince(lastTime)
        guard timeInterval > 0 else { return (0.0, 0.0) }
        
        let rxBytesDiff = currentBytes.ibytes >= lastInboundBytes ? currentBytes.ibytes - lastInboundBytes : 0
        let txBytesDiff = currentBytes.obytes >= lastOutboundBytes ? currentBytes.obytes - lastOutboundBytes : 0
        
        let rxSpeed = Double(rxBytesDiff) / timeInterval
        let txSpeed = Double(txBytesDiff) / timeInterval
        
        return (rxSpeed, txSpeed)
    }

    private func getStatusJSON() -> String {
        let cpu = getCPUUsage()
        let ramStats = getMemoryStats()
        let ram = ramStats.total > 0 ? (ramStats.used / ramStats.total) * 100.0 : 0.0
        let gpu = getGPUUsage()
        let cpuTemp = SMCManager.shared.currentTemperature
        let gpuMem = getGPUMemoryUsage()
        
        let battery = BatteryManager.shared
        battery.updateBatteryRegistryInfo()

        let disk = getDiskUsage()
        let uptime = getSystemUptime()
        let thermal = getThermalState()
        let (rxSpeed, txSpeed) = getNetworkSpeed()

        return """
        {
          "webServerPort": \(currentPort),
          "headlessModeEnabled": \(HeadlessModeController.shared.isHeadlessModeEnabled),
          "preventIdleSleep": \(UserDefaults.standard.bool(forKey: "PreventIdleSleep")),
          "keepRunningOnLidClose": \(UserDefaults.standard.bool(forKey: "KeepRunningOnLidClose")),
          "trackpadDisabled": \(UserDefaults.standard.bool(forKey: "DisableTrackpadWhenExternalMouseConnected")),
          "keyboardAndTrackpadDisabledInHeadless": \(UserDefaults.standard.bool(forKey: "DisableKeyboardAndTrackpadInHeadlessMode")),
          "microphoneMuted": \(MediaDeviceManager.shared.isMuted),
          "batteryCapacity": \(battery.currentCapacity),
          "isCharging": \(battery.isCharging),
          "isCharged": \(battery.isCharged),
          "powerState": "\(battery.powerState)",
          "cpuUsage": \(cpu),
          "cpuTemp": \(cpuTemp),
          "memoryUsage": \(ram),
          "ramUsedGB": \(ramStats.used),
          "ramTotalGB": \(ramStats.total),
          "gpuUsage": \(gpu),
          "vramUsedGB": \(gpuMem.used),
          "vramAllocatedGB": \(gpuMem.allocated),
          "autoExitHeadlessOnDisconnect": \(UserDefaults.standard.bool(forKey: "AutoExitHeadlessOnDisconnect")),
          "autoRestoreHeadlessOnConnect": \(UserDefaults.standard.bool(forKey: "AutoRestoreHeadlessOnConnect")),
          "diskUsedGB": \(disk.usedGB),
          "diskTotalGB": \(disk.totalGB),
          "diskPercent": \(disk.percent),
          "uptime": "\(uptime)",
          "uptimeSeconds": \(Int(ProcessInfo.processInfo.systemUptime)),
          "thermalState": "\(thermal)",
          "batteryHealth": \(battery.batteryHealth),
          "batteryCycleCount": \(battery.cycleCount),
          "batteryTemp": \(battery.batteryTemperature),
          "batteryPowerWatts": \(battery.powerWatts),
          "batteryVoltage": \(battery.voltage),
          "batteryAmperage": \(battery.amperage),
          "adapterWatts": \(battery.adapterWatts),
          "adapterName": "\(battery.adapterName)",
          "rawCurrentCapacity": \(battery.rawCurrentCapacity),
          "rawMaxCapacity": \(battery.rawMaxCapacity),
          "designCapacity": \(battery.designCapacity),
          "isUPSActive": \(battery.isUPSActive),
          "timeRemainingMinutes": \(battery.timeRemainingMinutes),
          "timeRemainingFormatted": "\(battery.timeRemainingFormatted)",
          "isChargeLimitEnabled": \(battery.isChargeLimitEnabled),
          "chargeLimitPercent": \(battery.chargeLimitPercent),
          "chargeLimitSource": "\(battery.chargeLimitSource)",
          "customLimitEnabled": \(battery.customLimitEnabled),
          "customLimitThreshold": \(battery.customLimitThreshold),
          "isSupportedNativeLimit": \(battery.isSupportedNativeLimit),
          "rxSpeed": \(rxSpeed),
          "txSpeed": \(txSpeed),
          "frpEnabled": \(UserDefaults.standard.bool(forKey: "frpEnabled")),
          "frpRunning": \(FrpService.shared.isRunning()),
          "cloudflareEnabled": \(UserDefaults.standard.bool(forKey: "cloudflareEnabled")),
          "cloudflareStatus": "\(CloudflareService.shared.currentStatus.displayText)",
          "hasCloudflareToken": \(!(UserDefaults.standard.string(forKey: "cloudflareToken") ?? "").isEmpty),
          "sshEnabled": \(RemoteSharingService.shared.isSSHRunning),
          "vncEnabled": \(RemoteSharingService.shared.isVNCRunning),
          "smbEnabled": \(RemoteSharingService.shared.isSMBRunning),
          "systemUser": "\(RemoteSharingService.shared.currentUser)",
          "appLanguage": "\(LocalizationManager.shared.effectiveLanguageCode)"
        }
        """
    }
    
    func getLocalIPAddress() -> String {
        var address = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return address }
        guard let firstAddr = ifaddr else { return address }
        
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let addr = ptr.pointee.ifa_addr.pointee
            if addr.sa_family == UInt8(AF_INET) {
                let name = String(cString: ptr.pointee.ifa_name)
                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                        address = String(cString: hostname)
                        break
                    }
                }
            }
        }
        freeifaddrs(ifaddr)
        return address
    }
    

    
    private func getGPUMemoryUsage() -> (used: Double, allocated: Double) {
        let serviceMatching = IOServiceMatching("IOAccelerator")
        var iterator = io_iterator_t()
        var usedBytes: Double = 0.0
        var allocatedBytes: Double = 0.0
        
        if IOServiceGetMatchingServices(0, serviceMatching, &iterator) == kIOReturnSuccess {
            var regEntry = IOIteratorNext(iterator)
            while regEntry != 0 {
                var properties: Unmanaged<CFMutableDictionary>? = nil
                if IORegistryEntryCreateCFProperties(regEntry, &properties, kCFAllocatorDefault, 0) == kIOReturnSuccess {
                    if let dict = properties?.takeRetainedValue() as? [String: AnyObject] {
                        if let perfStats = dict["PerformanceStatistics"] as? [String: AnyObject] {
                            if let inUse = perfStats["In use system memory"] as? NSNumber {
                                usedBytes = max(usedBytes, inUse.doubleValue)
                            } else if let inUseVal = perfStats["In use system memory"] as? Int64 {
                                usedBytes = max(usedBytes, Double(inUseVal))
                            }
                            
                            if let alloc = perfStats["Alloc system memory"] as? NSNumber {
                                allocatedBytes = max(allocatedBytes, alloc.doubleValue)
                            } else if let allocVal = perfStats["Alloc system memory"] as? Int64 {
                                allocatedBytes = max(allocatedBytes, Double(allocVal))
                            }
                        }
                    }
                }
                IOObjectRelease(regEntry)
                regEntry = IOIteratorNext(iterator)
            }
            IOObjectRelease(iterator)
        }
        
        let usedGB = usedBytes / (1024.0 * 1024.0 * 1024.0)
        let allocatedGB = allocatedBytes / (1024.0 * 1024.0 * 1024.0)
        return (usedGB, allocatedGB)
    }
    
    private func getMemoryStats() -> (used: Double, total: Double) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        
        guard result == KERN_SUCCESS else {
            return (0.0, 0.0)
        }
        
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        
        let activeBytes = Double(stats.active_count) * Double(pageSize)
        let wireBytes = Double(stats.wire_count) * Double(pageSize)
        let compressedBytes = Double(stats.compressor_page_count) * Double(pageSize)
        
        let usedBytes = activeBytes + wireBytes + compressedBytes
        let usedGB = usedBytes / (1024.0 * 1024.0 * 1024.0)
        let totalGB = Double(totalBytes) / (1024.0 * 1024.0 * 1024.0)
        return (usedGB, totalGB)
    }
    

    private func getGPUUsage() -> Double {
        let serviceMatching = IOServiceMatching("IOAccelerator")
        var iterator = io_iterator_t()
        var usage: Double = 0.0
        
        if IOServiceGetMatchingServices(0, serviceMatching, &iterator) == kIOReturnSuccess {
            var regEntry = IOIteratorNext(iterator)
            while regEntry != 0 {
                var properties: Unmanaged<CFMutableDictionary>? = nil
                if IORegistryEntryCreateCFProperties(regEntry, &properties, kCFAllocatorDefault, 0) == kIOReturnSuccess {
                    if let dict = properties?.takeRetainedValue() as? [String: AnyObject] {
                        if let perfStats = dict["PerformanceStatistics"] as? [String: AnyObject] {
                            if let deviceUtil = perfStats["Device Utilization %"] as? NSNumber {
                                usage = max(usage, deviceUtil.doubleValue)
                            } else if let coreUtil = perfStats["GPU Core Utilization"] as? NSNumber {
                                usage = max(usage, coreUtil.doubleValue)
                            } else if let coreUtilVal = perfStats["GPU Core Utilization"] as? Int {
                                usage = max(usage, Double(coreUtilVal))
                            } else if let deviceUtilVal = perfStats["Device Utilization %"] as? Int {
                                usage = max(usage, Double(deviceUtilVal))
                            }
                        }
                    }
                }
                IOObjectRelease(regEntry)
                regEntry = IOIteratorNext(iterator)
            }
            IOObjectRelease(iterator)
        }
        return usage
    }
    
    private func getCPUUsage() -> Double {
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0
        
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &cpuInfo, &numCPUInfo)
        guard result == KERN_SUCCESS, let cpuInfo = cpuInfo else { return 0.0 }
        
        defer {
            if let last = lastCPUInfo {
                vm_deallocate(mach_task_self_, vm_address_t(bitPattern: last), vm_size_t(lastCPUInfoCount) * vm_size_t(MemoryLayout<integer_t>.size))
            }
            lastCPUInfo = cpuInfo
            lastCPUInfoCount = numCPUInfo
        }
        
        guard let lastInfo = lastCPUInfo else { return 0.0 }
        
        var totalInUse: Int32 = 0
        var totalTotal: Int32 = 0
        
        for i in 0..<Int(numCPUs) {
            let base = i * Int(CPU_STATE_MAX)
            let lastBase = i * Int(CPU_STATE_MAX)
            
            let user = cpuInfo[base + Int(CPU_STATE_USER)] - lastInfo[lastBase + Int(CPU_STATE_USER)]
            let system = cpuInfo[base + Int(CPU_STATE_SYSTEM)] - lastInfo[lastBase + Int(CPU_STATE_SYSTEM)]
            let idle = cpuInfo[base + Int(CPU_STATE_IDLE)] - lastInfo[lastBase + Int(CPU_STATE_IDLE)]
            let nice = cpuInfo[base + Int(CPU_STATE_NICE)] - lastInfo[lastBase + Int(CPU_STATE_NICE)]
            
            let inUse = user + system + nice
            let total = inUse + idle
            
            totalInUse += inUse
            totalTotal += total
        }
        
        guard totalTotal > 0 else { return 0.0 }
        return (Double(totalInUse) / Double(totalTotal)) * 100.0
    }
    
    private func getDashboardHTML() -> String {
        if let resourcePath = Bundle.main.path(forResource: "Dashboard", ofType: "html"),
           let html = try? String(contentsOfFile: resourcePath, encoding: .utf8) {
            return html
        }
        
        // Fallback fallback if resource loading fails
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <title>MacHead - Dashboard Load Failure</title>
            <style>
                body { font-family: system-ui, -apple-system, sans-serif; background: #121214; color: #fff; padding: 40px; text-align: center; }
                h1 { color: #ff453a; }
            </style>
        </head>
        <body>
            <h1>Dashboard Resource Missing</h1>
            <p>Please ensure Dashboard.html is packaged inside the application bundle's Resources folder.</p>
        </body>
        </html>
        """
    }
    
    private func escapeHTML(_ str: String) -> String {
        return str
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private func getLoginHTML(errorZh: String? = nil, errorEn: String? = nil) -> String {
        let safeZh = errorZh.map { escapeHTML($0) }
        let safeEn = errorEn.map { escapeHTML($0) }
        let defaultMsg = safeZh ?? safeEn
        if let resourcePath = Bundle.main.path(forResource: "Login", ofType: "html"),
           var html = try? String(contentsOfFile: resourcePath, encoding: .utf8) {
            if let defaultMsg = defaultMsg {
                let zhAttr = safeZh ?? defaultMsg
                let enAttr = safeEn ?? defaultMsg
                let errorDiv = "<div class=\"error-msg\" id=\"error-msg\" data-zh=\"\(zhAttr)\" data-en=\"\(enAttr)\">\(zhAttr)</div>"
                html = html.replacingOccurrences(of: "<!-- ERROR_PLACEHOLDER -->", with: errorDiv)
            } else {
                html = html.replacingOccurrences(of: "<!-- ERROR_PLACEHOLDER -->", with: "")
            }
            return html
        }

        // Fallback fallback if resource loading fails
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <title>MacHead - 登录</title>
            <style>
                body { font-family: system-ui, -apple-system, sans-serif; background: #14120b; color: #edecec; padding: 40px; text-align: center; }
                .card { background: #1c1b14; border: 1px solid rgba(255,255,255,0.08); border-radius: 12px; padding: 30px; display: inline-block; max-width: 320px; text-align: left; margin-top: 100px; }
                input[type="password"] { width: 100%; box-sizing: border-box; background: #0b0a05; color: #fff; border: 1px solid rgba(255,255,255,0.1); border-radius: 6px; padding: 10px; margin-top: 10px; margin-bottom: 20px; outline: none; }
                input[type="password"]:focus { border-color: #007aff; }
                input[type="submit"] { width: 100%; background: #007aff; color: #fff; border: none; border-radius: 6px; padding: 10px; font-weight: bold; cursor: pointer; }
                .error { color: #ff453a; font-size: 13px; margin-bottom: 15px; background: rgba(255, 69, 58, 0.1); padding: 8px; border-radius: 4px; }
            </style>
        </head>
        <body>
            <div class="card">
                <h2>MacHead Console Login</h2>
                \(defaultMsg != nil ? "<div class=\"error\">\(defaultMsg!)</div>" : "")
                <form method="POST" action="/login">
                    <label>Password</label>
                    <input type="password" name="password" autofocus required>
                    <input type="submit" value="Log In">
                </form>
            </div>
        </body>
        </html>
        """
    }


}
