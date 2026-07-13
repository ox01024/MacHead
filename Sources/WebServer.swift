import Foundation
import Network
import SystemConfiguration

@_silgen_name("IOHIDEventSystemClientCreate")
func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> AnyObject?

@_silgen_name("IOHIDEventSystemClientSetMatching")
func IOHIDEventSystemClientSetMatching(_ client: AnyObject, _ matching: CFDictionary) -> Int32

@_silgen_name("IOHIDEventSystemClientCopyServices")
func IOHIDEventSystemClientCopyServices(_ client: AnyObject) -> CFArray?

@_silgen_name("IOHIDServiceClientCopyProperty")
func IOHIDServiceClientCopyProperty(_ service: AnyObject, _ property: CFString) -> AnyObject?

@_silgen_name("IOHIDServiceClientCopyEvent")
func IOHIDServiceClientCopyEvent(_ service: AnyObject, _ eventType: UInt32, _ flags: UInt32, _ options: UInt32) -> AnyObject?

@_silgen_name("IOHIDEventGetFloatValue")
func IOHIDEventGetFloatValue(_ event: AnyObject, _ field: UInt32) -> Double


final class WebServer {
    static let shared = WebServer()
    
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
        
        guard let port = NWEndpoint.Port(rawValue: 8080) else { return }
        
        do {
            let newListener = try NWListener(using: .tcp, on: port)
            self.listener = newListener
            
            newListener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    NSLog("MacHead: Web 服务器启动就绪，端口: 8080")
                case .failed(let error):
                    NSLog("MacHead: Web 服务器失败: %@", error.localizedDescription)
                    self.stop()
                default:
                    break
                }
            }
            
            newListener.newConnectionHandler = { connection in
                connection.start(queue: .main)
                self.handleConnection(connection)
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
            
            // Route "/login" and "/logout" without global auth block
            if path == "/login" {
                if method == "GET" {
                    self.sendResponse(html: self.getLoginHTML(), connection: connection)
                } else if method == "POST" {
                    let enteredPassword = self.extractPassword(from: bodyPart)
                    let correctPassword = UserDefaults.standard.string(forKey: "WebServerPassword") ?? ""
                    
                    if correctPassword.isEmpty || enteredPassword == correctPassword {
                        let cookieHeader = "Set-Cookie: session=\(self.sessionToken); Path=/; HttpOnly; SameSite=Strict"
                        self.sendRedirect(to: "/", extraHeaders: [cookieHeader], connection: connection)
                    } else {
                        self.sendResponse(html: self.getLoginHTML(error: "密码错误，请重新输入"), connection: connection)
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
            
            self.routeRequest(method: method, path: path, connection: connection)
        }
    }
    
    private func extractPassword(from body: String) -> String? {
        let pairs = body.components(separatedBy: "&")
        for pair in pairs {
            let kv = pair.components(separatedBy: "=")
            if kv.count == 2 && kv[0] == "password" {
                return kv[1].removingPercentEncoding
            }
        }
        return nil
    }
    
    private func verifyAuthorization(headers: [String]) -> Bool {
        return verifySession(headers: headers)
    }
    
    private func verifySession(headers: [String]) -> Bool {
        let password = UserDefaults.standard.string(forKey: "WebServerPassword") ?? ""
        guard !password.isEmpty else { return true }
        
        for line in headers {
            if line.lowercased().hasPrefix("cookie:") {
                if line.contains("session=\(sessionToken)") {
                    return true
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
    
    private func routeRequest(method: String, path: String, connection: NWConnection) {
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
        } else if method == "POST" && path == "/api/toggle-restore-on-connect" {
            DispatchQueue.main.async {
                let key = "AutoRestoreHeadlessOnConnect"
                let val = !UserDefaults.standard.bool(forKey: key)
                UserDefaults.standard.set(val, forKey: key)
                NotificationCenter.default.post(name: .headlessModeStateChanged, object: nil)
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
            "Access-Control-Allow-Origin: *",
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
            parts.append("\(days)天")
        }
        if hours > 0 || days > 0 {
            parts.append("\(hours)小时")
        }
        parts.append("\(minutes)分钟")
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
        let cpuTemp = getCPUTemperature()
        let gpuMem = getGPUMemoryUsage()
        
        BatteryManager.shared.updateBatteryRegistryInfo()
        
        let disk = getDiskUsage()
        let uptime = getSystemUptime()
        let thermal = getThermalState()
        let (rxSpeed, txSpeed) = getNetworkSpeed()
        
        return """
        {
          "headlessModeEnabled": \(HeadlessModeController.shared.isHeadlessModeEnabled),
          "preventIdleSleep": \(UserDefaults.standard.bool(forKey: "PreventIdleSleep")),
          "keepRunningOnLidClose": \(UserDefaults.standard.bool(forKey: "KeepRunningOnLidClose")),
          "trackpadDisabled": \(UserDefaults.standard.bool(forKey: "DisableTrackpadWhenExternalMouseConnected")),
          "keyboardAndTrackpadDisabledInHeadless": \(UserDefaults.standard.bool(forKey: "DisableKeyboardAndTrackpadInHeadlessMode")),
          "microphoneMuted": \(MediaDeviceManager.shared.isMuted),
          "batteryCapacity": \(BatteryManager.shared.currentCapacity),
          "isCharging": \(BatteryManager.shared.isCharging),
          "powerState": "\(BatteryManager.shared.powerState)",
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
          "thermalState": "\(thermal)",
          "batteryHealth": \(BatteryManager.shared.batteryHealth),
          "batteryCycleCount": \(BatteryManager.shared.cycleCount),
          "batteryTemp": \(BatteryManager.shared.batteryTemperature),
          "rxSpeed": \(rxSpeed),
          "txSpeed": \(txSpeed)
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
    
    private func getCPUTemperature() -> Double {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else {
            return 0.0
        }
        
        let matching: [String: Any] = [
            "PrimaryUsagePage": 0xff00,
            "PrimaryUsage": 0x05
        ]
        
        _ = IOHIDEventSystemClientSetMatching(client, matching as CFDictionary)
        
        guard let services = IOHIDEventSystemClientCopyServices(client) as? [AnyObject] else {
            return 0.0
        }
        
        var cpuTemps: [Double] = []
        
        for service in services {
            let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String ?? ""
            let nameLower = name.lowercased()
            
            if nameLower.contains("tdie") || nameLower.contains("cpu") || nameLower.contains("pacc") || nameLower.contains("eacc") {
                if let event = IOHIDServiceClientCopyEvent(service, 15, 0, 0) {
                    let temp = IOHIDEventGetFloatValue(event, 983040)
                    if temp > 0.0 && temp < 150.0 {
                        cpuTemps.append(temp)
                    }
                }
            }
        }
        
        if cpuTemps.isEmpty {
            return BatteryManager.shared.batteryTemperature
        }
        
        return cpuTemps.reduce(0, +) / Double(cpuTemps.count)
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
    
    private func getMemoryUsage() -> Double {
        let stats = getMemoryStats()
        guard stats.total > 0 else { return 0.0 }
        return (stats.used / stats.total) * 100.0
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
    
    private func getLoginHTML(error: String? = nil) -> String {
        if let resourcePath = Bundle.main.path(forResource: "Login", ofType: "html"),
           var html = try? String(contentsOfFile: resourcePath, encoding: .utf8) {
            if let error = error {
                let errorDiv = "<div class=\"error-msg\">\(error)</div>"
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
                \(error != nil ? "<div class=\"error\">\(error!)</div>" : "")
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

